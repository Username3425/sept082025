// scripts/deploy.js

const hre = require("hardhat");
require("dotenv").config();
const tokenName = process.env.TOKEN_NAME || "sept";
const tokenSymbol = process.env.TOKEN_SYMBOL || "SEPT";

async function main() {
  console.log("Deploying SEPT1 token to Hoodi network...");
  console.log("Network:", hre.network.name);
  console.log("Chain ID:", hre.network.config.chainId);
 
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  
  
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  
  const Token1 = await ethers.getContractFactory("Token1");
  const token = await Token1.deploy(
    tokenName,      // Token name
    tokenSymbol       // Token symbol
  );

  
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();

  console.log("\n=== DEPLOYMENT SUCCESSFUL ===");
  console.log("SEPT1 Token deployed to:", tokenAddress);
  console.log("Token name:", await token.name());
  console.log("Token symbol:", await token.symbol());
  console.log("Token decimals:", await token.decimals());
  console.log("Owner:", await token.owner());

  
  console.log("\nWaiting for block confirmations...");
  await token.deploymentTransaction().wait(5);

  
  if (hre.network.name === "hoodi" && process.env.HOODI_EXPLORER_API_KEY) {
    console.log("Attempting to verify contract on Hoodi explorer...");
    try {
      await hre.run("verify:verify", {
        address: tokenAddress,
        constructorArguments: ["sept1", "SEPT1"],
      });
      console.log("Contract verified on Hoodi explorer!");
    } catch (error) {
      console.log("Verification not available or failed:", error.message);
    }
  }

 
  console.log("\n=== NETWORK INFO ===");
  console.log("Network Name:", hre.network.name);
  console.log("Chain ID:", hre.network.config.chainId);
  console.log("RPC URL:", hre.network.config.url);
  
  
  console.log("\n=== NEXT STEPS ===");
  console.log("1. Save the contract address:", tokenAddress);
  console.log("2. Add it to your frontend configuration");
  console.log("3. Run setup script to configure operators: npx hardhat run scripts/setup-sept1.js --network hoodi");
  console.log("4. Fund the contract with initial fiat backing");
  
  console.log("\n=== CONTRACT INTERACTION ===");
  console.log("View on explorer: https://explorer.hoodi.xyz/address/" + tokenAddress);
  console.log("Add to MetaMask:");
  console.log("- Token Address:", tokenAddress);
  console.log("- Token Symbol: SEPT1");
  console.log("- Token Decimals: 2");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });