// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ETH(ERC20) + RTGS(ISO20022) = SEPT
 * @dev Цей проєкт є варіантом Minimum Viable Product (MVP) у сфері інтеграції світів RTGS та DEX. MVP використовує тестову мережу ETH (Hoodi), не містить підтримку hardware гаманців, мультипідписів, повної адаптації з ISO 20022 тощо. Мета проєкту - зацікавило питання :)
 */
contract Token1 is ERC20, Ownable, Pausable, ReentrancyGuard {
    
    // Constants
    uint8 private constant DECIMALS = 2;
    uint256 private constant SECONDS_IN_DAY = 86400;
    uint256 public constant MAX_BATCH_SIZE = 100;
    
    // Enums
    enum OperatorType { Mint, RTGS, KYC }
    enum MessageStatus { Pending, Validated, Accepted, Rejected, Settled, Cancelled }
    enum TransactionType { Transfer, Mint, Burn, RTGSOutgoing, RTGSIncoming }
    
    // Structs
    struct Party {
        string name;
        string bic;
        string iban;
        string country;
        bool registered;
        uint256 registeredAt;
    }
    
    struct RTGSMessage {
        bytes32 messageId;
        bytes32 endToEndId;
        address sender;
        address receiver;
        uint256 amount;
        MessageStatus status;
        string statusReason;
        uint256 createdAt;
        uint256 updatedAt;
        TransactionType txType;
        string externalAccount; // IBAN для зовнішніх переказів
    }
    
    struct DailyLimit {
        uint256 limit;
        uint256 spent;
        uint256 lastResetTimestamp;
    }
    
    struct BatchResult {
        bytes32 batchId;
        uint256 totalAmount;
        uint256 successCount;
        uint256 failureCount;
        uint256 timestamp;
    }
    
    // Стан (змінні стану)
    mapping(address => mapping(OperatorType => bool)) public operators;
    mapping(address => bool) public auditors;
    mapping(address => bool) public whitelist;
    mapping(address => bool) public blacklist;
    mapping(address => bool) public frozen;
    mapping(address => Party) public parties;
    mapping(bytes32 => RTGSMessage) public rtgsMessages;
    mapping(address => bytes32[]) public userTransactionHistory;
    mapping(address => DailyLimit) public dailyLimits;
    mapping(bytes32 => BatchResult) public batchResults;
    
    uint256 public defaultDailyLimit;
    uint256 public messageNonce;
    bool public softPaused;
    
    // Спеціальний резервний рахунок RTGS для забезпечення. Загальна архітектура на даному етапі передбачається через резервуванняабо блокування сум одночасно у Світі1 та у Світі2. На цьому побудована логіка взаємодії.
    address public constant RTGS_RESERVE = address(0xdead);
    uint256 public totalFiatBacking; // Загальна сума резерву фіатних грошей на боці RTGS (формат 2 знаки після коми)
    uint256 public totalBlockedForRTGS; // Загальна кількість токенів, заблокованих для переказів у світ RTGS
    
    // Події. Для Minimum Viable Product (MVP) їх кількість обмежена.
    event OperatorGranted(address indexed operator, OperatorType role, address indexed grantedBy);
    event OperatorRevoked(address indexed operator, OperatorType role, address indexed revokedBy);
    event AuditorGranted(address indexed auditor, address indexed grantedBy);
    event AuditorRevoked(address indexed auditor, address indexed revokedBy);
    event WhitelistChanged(address indexed account, bool status, address indexed changedBy);
    event BlacklistChanged(address indexed account, bool status, address indexed changedBy);
    event AccountFrozen(address indexed account, address indexed frozenBy);
    event AccountUnfrozen(address indexed account, address indexed unfrozenBy);
    event PartyRegistered(address indexed party, string bic, string iban, address indexed registeredBy);
    event LimitChanged(address indexed account, uint256 oldLimit, uint256 newLimit, address indexed changedBy);
    event RTGSMessageCreated(bytes32 indexed messageId, bytes32 endToEndId, address indexed sender, string externalAccount, uint256 amount);
    event RTGSIncomingCreated(bytes32 indexed messageId, bytes32 endToEndId, string externalAccount, address indexed receiver, uint256 amount);
    event PaymentStatusChanged(bytes32 indexed messageId, MessageStatus oldStatus, MessageStatus newStatus, string reason);
    event SettlementCompleted(bytes32 indexed messageId, address indexed sender, address indexed receiver, uint256 amount);
    event BatchProcessed(bytes32 indexed batchId, uint256 totalAmount, uint256 successCount, uint256 failureCount);
    event DailyLimitExceeded(address indexed account, uint256 attemptedAmount, uint256 limit);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event SoftPauseToggled(bool isPaused, address indexed toggledBy);
    event FiatBackingUpdated(uint256 oldAmount, uint256 newAmount, address indexed updatedBy);
    event TokensBlockedForRTGS(address indexed from, uint256 amount);
    event TokensUnblockedFromRTGS(address indexed to, uint256 amount);
    event OwnershipTransferredWithRoles(address indexed previousOwner, address indexed newOwner);
    
    // Власник автоматично має всі ролі. З точки зору безпеки бюрократії та здорового глузду це не правильно, але суттєво полегшує початкову архітектуру, призначення якої MVP.
    modifier onlyOperator(OperatorType opType) {
        require(msg.sender == owner() || operators[msg.sender][opType], "Not authorized operator");
        _;
    }
    
    modifier onlyAuditor() {
        require(msg.sender == owner() || auditors[msg.sender], "Not authorized auditor");
        _;
    }
    
    modifier notBlacklisted(address account) {
        require(!blacklist[account], "Account is blacklisted");
        _;
    }
    
    modifier notFrozen(address account) {
        require(!frozen[account], "Account is frozen");
        _;
    }
    
    modifier onlyWhitelisted(address account) {
        require(whitelist[account], "Account not whitelisted");
        _;
    }
    
    modifier checkDailyLimit(address from, uint256 amount) {
        _updateDailyLimit(from);
        DailyLimit storage limit = dailyLimits[from];
        uint256 effectiveLimit = limit.limit > 0 ? limit.limit : defaultDailyLimit;
        
        if (effectiveLimit > 0 && limit.spent + amount > effectiveLimit) {
            emit DailyLimitExceeded(from, amount, effectiveLimit);
            revert("Daily limit exceeded");
        }
        _;
    }
    
    modifier notSoftPaused() {
        require(!softPaused, "Outgoing transfers are paused");
        _;
    }
    
    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {
        // автоматично призначаємо власнику всі ролі, бонус, так, це не правильно, але це MVP
        _setupOwnerRoles(msg.sender);
        defaultDailyLimit = 1000000 * (10 ** decimals()); // 1M 
    }
    
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
    
    // Налаштування ролей для власника
    function _setupOwnerRoles(address newOwner) private {
        // Додаємо до whitelist
        whitelist[newOwner] = true;
        emit WhitelistChanged(newOwner, true, address(this));
        
        // Призначаємо всі ролі оператора
        operators[newOwner][OperatorType.Mint] = true;
        operators[newOwner][OperatorType.RTGS] = true;
        operators[newOwner][OperatorType.KYC] = true;
        
        emit OperatorGranted(newOwner, OperatorType.Mint, address(this));
        emit OperatorGranted(newOwner, OperatorType.RTGS, address(this));
        emit OperatorGranted(newOwner, OperatorType.KYC, address(this));
        
        // Призначаємо роль auditor
        auditors[newOwner] = true;
        emit AuditorGranted(newOwner, address(this));
    }
    
    // При передачі власності автоматично налаштовуємо ролі. Для MVP це не знадобиться, для проду питання. Але із зміни права власності контракту який по замовчанню у Remix все це і почалося най буде )
    function transferOwnership(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        
        address oldOwner = owner();
        
        // Спочатку налаштовуємо ролі для нового власника
        _setupOwnerRoles(newOwner);
        
        // Потім передаємо власність
        super.transferOwnership(newOwner);
        
        emit OwnershipTransferredWithRoles(oldOwner, newOwner);
    }
    
    // Видалення всіх ролей у колишнього власника
    function revokeAllRolesFromAddress(address account) external onlyOwner {
        require(account != owner(), "Cannot revoke roles from current owner");
        
        // Видаляємо ролі оператора
        if (operators[account][OperatorType.Mint]) {
            operators[account][OperatorType.Mint] = false;
            emit OperatorRevoked(account, OperatorType.Mint, msg.sender);
        }
        if (operators[account][OperatorType.RTGS]) {
            operators[account][OperatorType.RTGS] = false;
            emit OperatorRevoked(account, OperatorType.RTGS, msg.sender);
        }
        if (operators[account][OperatorType.KYC]) {
            operators[account][OperatorType.KYC] = false;
            emit OperatorRevoked(account, OperatorType.KYC, msg.sender);
        }
        
        // Видаляємо роль auditor
        if (auditors[account]) {
            auditors[account] = false;
            emit AuditorRevoked(account, msg.sender);
        }
    }
    
    // Перевірка ролей
    function hasOperatorRole(address account, OperatorType role) external view returns (bool) {
        return account == owner() || operators[account][role];
    }
    
    function hasAuditorRole(address account) external view returns (bool) {
        return account == owner() || auditors[account];
    }
    
    function hasAllOperatorRoles(address account) external view returns (bool) {
        if (account == owner()) return true;
        return operators[account][OperatorType.Mint] && 
               operators[account][OperatorType.RTGS] && 
               operators[account][OperatorType.KYC];
    }
    
    function getAllRolesStatus(address account) external view returns (
        bool isMintOperator,
        bool isRTGSOperator, 
        bool isKYCOperator,
        bool isAuditor,
        bool isWhitelisted,
        bool isBlacklisted,
        bool isFrozen,
        bool isOwner
    ) {
        isOwner = (account == owner());
        isMintOperator = isOwner || operators[account][OperatorType.Mint];
        isRTGSOperator = isOwner || operators[account][OperatorType.RTGS];
        isKYCOperator = isOwner || operators[account][OperatorType.KYC];
        isAuditor = isOwner || auditors[account];
        isWhitelisted = whitelist[account];
        isBlacklisted = blacklist[account];
        isFrozen = frozen[account];
    }
    
    // Тільки власник може призначати ролі
    function grantOperator(address operator, OperatorType role) external onlyOwner {
        require(operator != owner(), "Owner already has all roles");
        operators[operator][role] = true;
        emit OperatorGranted(operator, role, msg.sender);
    }
    
    function revokeOperator(address operator, OperatorType role) external onlyOwner {
        require(operator != owner(), "Cannot revoke owner's roles");
        operators[operator][role] = false;
        emit OperatorRevoked(operator, role, msg.sender);
    }
    
    function grantAuditor(address auditor) external onlyOwner {
        require(auditor != owner(), "Owner already has auditor role");
        auditors[auditor] = true;
        emit AuditorGranted(auditor, msg.sender);
    }
    
    function revokeAuditor(address auditor) external onlyOwner {
        require(auditor != owner(), "Cannot revoke owner's auditor role");
        auditors[auditor] = false;
        emit AuditorRevoked(auditor, msg.sender);
    }
    
    // Масове призначення ролей
    function grantAllOperatorRoles(address operator) external onlyOwner {
        require(operator != owner(), "Owner already has all roles");
        
        operators[operator][OperatorType.Mint] = true;
        operators[operator][OperatorType.RTGS] = true;
        operators[operator][OperatorType.KYC] = true;
        
        emit OperatorGranted(operator, OperatorType.Mint, msg.sender);
        emit OperatorGranted(operator, OperatorType.RTGS, msg.sender);
        emit OperatorGranted(operator, OperatorType.KYC, msg.sender);
    }
    
    // KYC/AML 
    function addToWhitelist(address account) external onlyOperator(OperatorType.KYC) {
        whitelist[account] = true;
        emit WhitelistChanged(account, true, msg.sender);
    }
    
    function removeFromWhitelist(address account) external onlyOperator(OperatorType.KYC) {
        require(account != owner(), "Cannot remove owner from whitelist");
        whitelist[account] = false;
        emit WhitelistChanged(account, false, msg.sender);
    }
    
    function addToBlacklist(address account) external onlyOperator(OperatorType.KYC) {
        require(account != owner(), "Cannot blacklist owner");
        blacklist[account] = true;
        emit BlacklistChanged(account, true, msg.sender);
    }
    
    function removeFromBlacklist(address account) external onlyOperator(OperatorType.KYC) {
        blacklist[account] = false;
        emit BlacklistChanged(account, false, msg.sender);
    }
    
    function freezeAccount(address account) external onlyOperator(OperatorType.KYC) {
        require(account != owner(), "Cannot freeze owner");
        frozen[account] = true;
        emit AccountFrozen(account, msg.sender);
    }
    
    function unfreezeAccount(address account) external onlyOperator(OperatorType.KYC) {
        frozen[account] = false;
        emit AccountUnfrozen(account, msg.sender);
    }
    
    // ISO20022 функції
    function registerParty(
        address party,
        string calldata name,
        string calldata bic,
        string calldata iban,
        string calldata country
    ) external onlyOperator(OperatorType.KYC) {
        parties[party] = Party({
            name: name,
            bic: bic,
            iban: iban,
            country: country,
            registered: true,
            registeredAt: block.timestamp
        });
        
        if (!whitelist[party]) {
            whitelist[party] = true;
            emit WhitelistChanged(party, true, msg.sender);
        }
        
        emit PartyRegistered(party, bic, iban, msg.sender);
    }
    
    // Управління лімітами
    function setDailyLimit(address account, uint256 limit) external onlyOperator(OperatorType.KYC) {
        uint256 oldLimit = dailyLimits[account].limit;
        dailyLimits[account].limit = limit;
        emit LimitChanged(account, oldLimit, limit, msg.sender);
    }
    
    function setDefaultDailyLimit(uint256 limit) external onlyOwner {
        defaultDailyLimit = limit;
    }
    
    // Фіат фіат фіат
    function updateFiatBacking(uint256 newAmount) external onlyOperator(OperatorType.RTGS) {
        uint256 oldAmount = totalFiatBacking;
        totalFiatBacking = newAmount;
        emit FiatBackingUpdated(oldAmount, newAmount, msg.sender);
    }
    
    // Поки фіату не має - мінту зась
    function mint(address to, uint256 amount) external onlyOperator(OperatorType.Mint) {
        require(totalSupply() + amount <= totalFiatBacking, "Insufficient fiat backing");
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external onlyOperator(OperatorType.Mint) {
        _burn(from, amount);
    }
    
    // Поки whitelist не має - трансферу зась
    function transfer(address to, uint256 amount) public override 
        whenNotPaused 
        notSoftPaused
        notBlacklisted(msg.sender)
        notBlacklisted(to)
        notFrozen(msg.sender)
        notFrozen(to)
        onlyWhitelisted(msg.sender)
        onlyWhitelisted(to)
        checkDailyLimit(msg.sender, amount)
        returns (bool) 
    {
        _updateSpentLimit(msg.sender, amount);
        return super.transfer(to, amount);
    }
    
    function transferFrom(address from, address to, uint256 amount) public override
        whenNotPaused
        notSoftPaused
        notBlacklisted(from)
        notBlacklisted(to)
        notFrozen(from)
        notFrozen(to)
        onlyWhitelisted(from)
        onlyWhitelisted(to)
        checkDailyLimit(from, amount)
        returns (bool)
    {
        _updateSpentLimit(from, amount);
        return super.transferFrom(from, to, amount);
    }
    
    // Надсилання токенів на зовнішній обліковий запис RTGS
    function sendToRTGS(
        bytes32 endToEndId,
        string calldata externalIBAN,
        string calldata, // beneficiaryName щоб не забути
        string calldata, // beneficiaryBIC щоб не забути
        uint256 amount
    ) external 
        whenNotPaused
        notSoftPaused
        notBlacklisted(msg.sender)
        notFrozen(msg.sender)
        onlyWhitelisted(msg.sender)
        checkDailyLimit(msg.sender, amount)
        nonReentrant
        returns (bytes32)
    {
        require(parties[msg.sender].registered, "Sender not registered");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(bytes(externalIBAN).length > 0, "Invalid IBAN");
        
        bytes32 messageId = _generateMessageId(msg.sender, address(0));
        
        // Блокуємо на контракті
        _transfer(msg.sender, address(this), amount);
        totalBlockedForRTGS += amount;
        
        // Створюємо RTGS message (дуже скорочений варіант, повний RTGS ISO20022 message це наш шанс не побачити MVP ще довго)
        rtgsMessages[messageId] = RTGSMessage({
            messageId: messageId,
            endToEndId: endToEndId,
            sender: msg.sender,
            receiver: address(0), 
            amount: amount,
            status: MessageStatus.Pending,
            statusReason: "",
            createdAt: block.timestamp,
            updatedAt: block.timestamp,
            txType: TransactionType.RTGSOutgoing,
            externalAccount: externalIBAN
        });
        
        userTransactionHistory[msg.sender].push(messageId);
        _updateSpentLimit(msg.sender, amount);
        
        emit RTGSMessageCreated(messageId, endToEndId, msg.sender, externalIBAN, amount);
        emit TokensBlockedForRTGS(msg.sender, amount);
        
        return messageId;
    }
    
    // Отримання із світу RTGS 
    function receiveFromRTGS(
        bytes32 endToEndId,
        string calldata senderIBAN,
        string calldata, // senderName щоб не забути
        string calldata, // senderBIC щоб не забути
        address receiver,
        uint256 amount
    ) external 
        onlyOperator(OperatorType.RTGS)
        notBlacklisted(receiver)
        notFrozen(receiver)
        onlyWhitelisted(receiver)
        nonReentrant
        returns (bytes32)
    {
        require(parties[receiver].registered, "Receiver not registered");
        require(totalSupply() + amount <= totalFiatBacking, "Insufficient fiat backing");
        
        bytes32 messageId = _generateMessageId(address(0), receiver);
        
        // Створення вхідного повідомлення RTGS
        rtgsMessages[messageId] = RTGSMessage({
            messageId: messageId,
            endToEndId: endToEndId,
            sender: address(0), // Зовнішній відправник
            receiver: receiver,
            amount: amount,
            status: MessageStatus.Pending,
            statusReason: "",
            createdAt: block.timestamp,
            updatedAt: block.timestamp,
            txType: TransactionType.RTGSIncoming,
            externalAccount: senderIBAN
        });
        
        userTransactionHistory[receiver].push(messageId);
        
        emit RTGSIncomingCreated(messageId, endToEndId, senderIBAN, receiver, amount);
        
        return messageId;
    }
    
    // Статус
    function processRTGSPayment(
        bytes32 messageId,
        MessageStatus status,
        string calldata reason
    ) external onlyOperator(OperatorType.RTGS) {
        RTGSMessage storage message = rtgsMessages[messageId];
        require(message.createdAt > 0, "Message not found");
        require(message.status == MessageStatus.Pending || message.status == MessageStatus.Validated, "Invalid status transition");
        
        MessageStatus oldStatus = message.status;
        message.status = status;
        message.statusReason = reason;
        message.updatedAt = block.timestamp;
        
        emit PaymentStatusChanged(messageId, oldStatus, status, reason);
        
        if (message.txType == TransactionType.RTGSOutgoing) {
            _processOutgoingRTGS(message, status);
        } else if (message.txType == TransactionType.RTGSIncoming) {
            _processIncomingRTGS(message, status);
        }
    }
    
    function _processOutgoingRTGS(RTGSMessage storage message, MessageStatus status) private {
        if (status == MessageStatus.Settled) {
            // RTGS підтвердив переказ фіатних грошей - спалюємо заблоковані токени
            _burn(address(this), message.amount);
            totalBlockedForRTGS -= message.amount;
            emit SettlementCompleted(message.messageId, message.sender, address(0), message.amount);
        } else if (status == MessageStatus.Rejected || status == MessageStatus.Cancelled) {
            // Повернтаємо токени відправнику
            _transfer(address(this), message.sender, message.amount);
            totalBlockedForRTGS -= message.amount;
            _revertSpentLimit(message.sender, message.amount);
            emit TokensUnblockedFromRTGS(message.sender, message.amount);
        }
    }
    
    function _processIncomingRTGS(RTGSMessage storage message, MessageStatus status) private {
        if (status == MessageStatus.Settled) {
            // Підтверджене отримання фіатних грошей у RTGS - відправка токенів одержувачу
            _mint(message.receiver, message.amount);
            emit SettlementCompleted(message.messageId, address(0), message.receiver, message.amount);
        }
        // Якщо відхилено, жодних дій не передбачено, оскільки токени ще не мінтили. Можна ще подумати.
    }
    
    // Мабуть це все ж не потрібно, теоретично ця тема більш актуальна для МП СЕП. Видалю потім, поки жалко.
    function processBatchRTGSPayments(
        bytes32[] calldata messageIds,
        MessageStatus[] calldata statuses,
        string[] calldata reasons
    ) external onlyOperator(OperatorType.RTGS) {
        require(messageIds.length == statuses.length && statuses.length == reasons.length, "Array length mismatch");
        require(messageIds.length <= MAX_BATCH_SIZE, "Batch size exceeded");
        
        bytes32 batchId = keccak256(abi.encodePacked(block.timestamp, msg.sender, messageIds.length));
        BatchResult memory result = BatchResult({
            batchId: batchId,
            totalAmount: 0,
            successCount: 0,
            failureCount: 0,
            timestamp: block.timestamp
        });
        
        for (uint i = 0; i < messageIds.length; i++) {
            RTGSMessage storage message = rtgsMessages[messageIds[i]];
            if (message.createdAt > 0 && (message.status == MessageStatus.Pending || message.status == MessageStatus.Validated)) {
                MessageStatus oldStatus = message.status;
                message.status = statuses[i];
                message.statusReason = reasons[i];
                message.updatedAt = block.timestamp;
                
                emit PaymentStatusChanged(messageIds[i], oldStatus, statuses[i], reasons[i]);
                
                if (message.txType == TransactionType.RTGSOutgoing) {
                    _processOutgoingRTGS(message, statuses[i]);
                } else if (message.txType == TransactionType.RTGSIncoming) {
                    _processIncomingRTGS(message, statuses[i]);
                }
                
                if (statuses[i] == MessageStatus.Settled) {
                    result.totalAmount += message.amount;
                    result.successCount++;
                } else if (statuses[i] == MessageStatus.Rejected || statuses[i] == MessageStatus.Cancelled) {
                    result.failureCount++;
                }
            }
        }
        
        batchResults[batchId] = result;
        emit BatchProcessed(batchId, result.totalAmount, result.successCount, result.failureCount);
    }
    
    // Публічні функції - питаня хто що може бачити суттєве. Поки так.
    function getUserTransactionHistory(address user) external view onlyAuditor returns (bytes32[] memory) {
        return userTransactionHistory[user];
    }
    
    function getRTGSMessage(bytes32 messageId) external view onlyAuditor returns (RTGSMessage memory) {
        return rtgsMessages[messageId];
    }
    
    function getPartyInfo(address party) external view onlyAuditor returns (Party memory) {
        return parties[party];
    }
        
    /**
     * @dev Користувач може отримати свої власні RTGS транзакції
     */
    function getMyRTGSMessages() external view returns (bytes32[] memory) {
        return userTransactionHistory[msg.sender];
    }
    
    /**
     * @dev Отримати кількість RTGS транзакцій користувача
     */
    function getUserTransactionCount(address user) external view returns (uint256) {
        return userTransactionHistory[user].length;
    }
    
    /**
     * @dev Отримати RTGS транзакції користувача
     */
    function getUserRTGSMessages(address user, uint256 offset, uint256 limit) 
        external 
        view 
        returns (bytes32[] memory messageIds, RTGSMessage[] memory messages) 
    {
        require(
            user == msg.sender || msg.sender == owner() || auditors[msg.sender], 
            "Not authorized to view this user's messages"
        );
        
        bytes32[] storage userMessages = userTransactionHistory[user];
        uint256 total = userMessages.length;
        
        if (offset >= total) {
            return (new bytes32[](0), new RTGSMessage[](0));
        }
        
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        
        uint256 resultLength = end - offset;
        messageIds = new bytes32[](resultLength);
        messages = new RTGSMessage[](resultLength);
        
        for (uint256 i = 0; i < resultLength; i++) {
            bytes32 msgId = userMessages[offset + i];
            messageIds[i] = msgId;
            messages[i] = rtgsMessages[msgId];
        }
    }
    
    /**
     * @dev Отримати детальну інформацію про конкретне RTGS повідомлення
     * Користувач може бачити тільки свої повідомлення
     */
    function getRTGSMessagePublic(bytes32 messageId) external view returns (RTGSMessage memory) {
        RTGSMessage memory message = rtgsMessages[messageId];
        require(message.createdAt > 0, "Message not found");
        require(
            message.sender == msg.sender || 
            message.receiver == msg.sender || 
            msg.sender == owner() || 
            auditors[msg.sender], 
            "Not authorized to view this message"
        );
        
        return message;
    }
    
    /**
     * @dev Отримати останні N RTGS транзакцій користувача
     */
    function getMyRecentRTGSMessages(uint256 count) external view returns (RTGSMessage[] memory) {
        bytes32[] storage userMessages = userTransactionHistory[msg.sender];
        uint256 total = userMessages.length;
        
        if (total == 0 || count == 0) {
            return new RTGSMessage[](0);
        }
        
        uint256 resultCount = count > total ? total : count;
        RTGSMessage[] memory messages = new RTGSMessage[](resultCount);
        
        // Повертаємо останні повідомлення (з кінця масиву)
        for (uint256 i = 0; i < resultCount; i++) {
            bytes32 msgId = userMessages[total - 1 - i];
            messages[i] = rtgsMessages[msgId];
        }
        
        return messages;
    }
    
    /**
     * @dev Отримати RTGS транзакції за статусом
     */
    function getMyRTGSMessagesByStatus(MessageStatus status) external view returns (RTGSMessage[] memory) {
        bytes32[] storage userMessages = userTransactionHistory[msg.sender];
        uint256 total = userMessages.length;
        
        // Спочатку підраховуємо кількість повідомлень з потрібним статусом
        uint256 matchCount = 0;
        for (uint256 i = 0; i < total; i++) {
            if (rtgsMessages[userMessages[i]].status == status) {
                matchCount++;
            }
        }
        
        if (matchCount == 0) {
            return new RTGSMessage[](0);
        }
        
        // Заповнюємо масив результатів
        RTGSMessage[] memory messages = new RTGSMessage[](matchCount);
        uint256 resultIndex = 0;
        
        for (uint256 i = 0; i < total; i++) {
            RTGSMessage memory message = rtgsMessages[userMessages[i]];
            if (message.status == status) {
                messages[resultIndex] = message;
                resultIndex++;
            }
        }
        
        return messages;
    }
    
    function getDailyLimitInfo(address account) external view returns (uint256 limit, uint256 spent, uint256 remaining) {
        DailyLimit memory limitInfo = dailyLimits[account];
        
        // Перевіряємо чи потрібен ресет ліміту
        if (block.timestamp >= limitInfo.lastResetTimestamp + SECONDS_IN_DAY) {
            spent = 0;
        } else {
            spent = limitInfo.spent;
        }
        
        limit = limitInfo.limit > 0 ? limitInfo.limit : defaultDailyLimit;
        remaining = limit > spent ? limit - spent : 0;
    }
    
    function getBackingInfo() external view returns (uint256 fiatBacking, uint256 tokensIssued, uint256 blockedTokens) {
        return (totalFiatBacking, totalSupply(), totalBlockedForRTGS);
    }
    
    // екстрена допомога
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function toggleSoftPause() external onlyOwner {
        softPaused = !softPaused;
        emit SoftPauseToggled(softPaused, msg.sender);
    }
    
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        require(paused(), "Contract must be paused");
        _transfer(address(this), to, amount);
        emit EmergencyWithdraw(to, amount);
    }
    
    
    function _generateMessageId(address sender, address receiver) private returns (bytes32) {
        messageNonce++;
        return keccak256(abi.encodePacked(
            block.timestamp,
            sender,
            receiver,
            messageNonce,
            sender != address(0) ? parties[sender].bic : "",
            receiver != address(0) ? parties[receiver].bic : ""
        ));
    }
    
    function _updateDailyLimit(address account) private {
        DailyLimit storage limit = dailyLimits[account];
        if (block.timestamp >= limit.lastResetTimestamp + SECONDS_IN_DAY) {
            limit.spent = 0;
            limit.lastResetTimestamp = (block.timestamp / SECONDS_IN_DAY) * SECONDS_IN_DAY;
        }
    }
    
    function _updateSpentLimit(address account, uint256 amount) private {
        _updateDailyLimit(account);
        dailyLimits[account].spent += amount;
    }
    
    function _revertSpentLimit(address account, uint256 amount) private {
        if (dailyLimits[account].spent >= amount) {
            dailyLimits[account].spent -= amount;
        }
    }
    
    // OpenZeppelin v5.x виявився не сумісним з OpenZeppelin v4.x тут можуть бути трабли, відносно довго з ними грався
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        // Скіпаємо
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }
        
        // Скіпаємо
        if (from == address(this) || to == address(this)) {
            super._update(from, to, amount);
            return;
        }
        
        require(!paused(), "Token transfers are paused");
        require(!blacklist[from] && !blacklist[to], "Blacklisted address");
        require(!frozen[from] && !frozen[to], "Frozen address");
        require(whitelist[from] && whitelist[to], "Not whitelisted");
        
        super._update(from, to, amount);
    }
}