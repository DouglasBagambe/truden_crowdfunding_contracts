import hre from "hardhat";
import { ethers as Ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

interface DeploymentAddresses {
  mockERC20: string;
  counter: string;
  investmentNFT: string;
  escrow: string;
  voting: string;
  dealRoom: string;
  network: string;
  deployer: string;
  timestamp: number;
}

async function main() {
  try {
    const __filename = fileURLToPath(import.meta.url);
    const __dirname = path.dirname(__filename);
    const argv = process.argv;
    const idxLong = argv.indexOf("--network");
    const idxShort = argv.indexOf("-n");
    const cliNetwork =
      idxLong !== -1
        ? argv[idxLong + 1]
        : idxShort !== -1
          ? argv[idxShort + 1]
          : undefined;
    const envNetwork = process.env.HARDHAT_NETWORK as string | undefined;
    const runtimeNetwork = ((hre as any).network?.name as string) || undefined;
    const networkName =
      (cliNetwork as string) || envNetwork || runtimeNetwork || "hardhat";
    const networksCfg =
      ((hre as any).config?.networks as Record<string, any>) || {};
    const selectedCfg = networksCfg[networkName] || {};
    const selectedUrl = (selectedCfg as any)?.url;
    const configuredUrl = (() => {
      switch (networkName) {
        case "celoSepolia":
          return process.env.CELO_SEPOLIA_RPC || "";
        case "celoMainnet":
          return process.env.CELO_MAINNET_RPC || "";
        case "sepolia":
          return process.env.SEPOLIA_RPC_URL || "";
        case "baseSepolia":
          return process.env.BASE_SEPOLIA_RPC || "";
        case "baseMainnet":
          return process.env.BASE_MAINNET_RPC || "";
        case "localhost":
        case "hardhat":
          return "http://127.0.0.1:8545";
        default:
          return ""; // require explicit URL for unknown networks
      }
    })();
    let connection: string;
    if (typeof selectedUrl === "string" && selectedUrl.trim() !== "") {
      connection = selectedUrl;
    } else if (selectedUrl && typeof selectedUrl === "object") {
      const inner = (selectedUrl as any).url ?? (selectedUrl as any).href ?? "";
      connection = typeof inner === "string" ? inner : "";
    } else {
      connection = "";
    }
    if (!connection) {
      connection = String(configuredUrl || "");
    }
    const chainId =
      (selectedCfg.chainId as number) ||
      (() => {
        switch (networkName) {
          case "celoSepolia":
            return 11142220;
          case "celoMainnet":
            return 42220;
          case "sepolia":
            return 11155111;
          case "baseSepolia":
            return 84532;
          case "baseMainnet":
            return 8453;
          default:
            return 31337;
        }
      })();
    const network = { name: networkName, chainId };

    const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
    if (!privateKey) {
      throw new Error("DEPLOYER_PRIVATE_KEY is not set in environment");
    }

    if (
      !connection ||
      (typeof connection === "string" && connection.trim() === "")
    ) {
      throw new Error(`No RPC URL configured for network ${network.name}`);
    }

    const provider = new Ethers.JsonRpcProvider(String(connection));
    const wallet = new Ethers.Wallet(privateKey, provider);
    const deploymentAddresses: DeploymentAddresses = {
      mockERC20: "",
      counter: "",
      investmentNFT: "",
      escrow: "",
      voting: "",
      dealRoom: "",
      network: network.name,
      deployer: wallet.address,
      timestamp: Date.now(),
    };

    console.log("\n========================================");
    console.log("🚀 DEPLOYMENT STARTED");
    console.log("========================================");
    console.log(`Network: ${network.name} (Chain ID: ${network.chainId})`);
    console.log(`Deployer: ${wallet.address}`);
    const balance = await provider.getBalance(wallet.address);
    console.log(`Balance: ${Ethers.formatEther(balance)} ETH`);
    console.log("========================================\n");

    // Fetch the current nonce once so every deploy uses the right value
    // (avoids stale-nonce errors if a prior run partially succeeded)
    let nonce = await provider.getTransactionCount(wallet.address, 'pending');
    console.log(`Starting nonce: ${nonce}`);

    // ========== Deploy MockERC20 ==========
    console.log("📦 Deploying MockERC20...");
    const mockErc20ArtifactPath = path.join(
      __dirname,
      "../artifacts/contracts/MockERC20.sol/MockERC20.json"
    );
    const mockErc20Artifact = JSON.parse(
      fs.readFileSync(mockErc20ArtifactPath, "utf8")
    );
    const MockErc20Factory = new Ethers.ContractFactory(
      mockErc20Artifact.abi,
      mockErc20Artifact.bytecode,
      wallet
    );
    const mockERC20 = await MockErc20Factory.deploy(
      "Test Token",
      "TST",
      Ethers.parseEther("1000000"),
      { nonce: nonce++ }
    );
    await mockERC20.waitForDeployment();
    deploymentAddresses.mockERC20 = await mockERC20.getAddress();
    console.log("✅ MockERC20 deployed to:", deploymentAddresses.mockERC20);

    // ========== Deploy Counter ==========
    console.log("\n📦 Deploying Counter...");
    const counterArtifactPath = path.join(
      __dirname,
      "../artifacts/contracts/Counter.sol/Counter.json"
    );
    const counterArtifact = JSON.parse(
      fs.readFileSync(counterArtifactPath, "utf8")
    );
    const CounterFactory = new Ethers.ContractFactory(
      counterArtifact.abi,
      counterArtifact.bytecode,
      wallet
    );
    const counter = await CounterFactory.deploy({ nonce: nonce++ });
    await counter.waitForDeployment();
    deploymentAddresses.counter = await counter.getAddress();
    console.log("✅ Counter deployed to:", deploymentAddresses.counter);

    // ========== Deploy Escrow ==========
    console.log("\n📦 Deploying Escrow...");
    const feeRecipient = process.env.FEE_RECIPIENT || wallet.address;
    const escrowArtifactPath = path.join(
      __dirname,
      "../artifacts/contracts/Escrow.sol/Escrow.json"
    );
    const escrowArtifact = JSON.parse(
      fs.readFileSync(escrowArtifactPath, "utf8")
    );
    const EscrowFactory = new Ethers.ContractFactory(
      escrowArtifact.abi,
      escrowArtifact.bytecode,
      wallet
    );
    const escrow = await EscrowFactory.deploy(feeRecipient, { nonce: nonce++ });
    await escrow.waitForDeployment();
    deploymentAddresses.escrow = await escrow.getAddress();
    console.log("✅ Escrow deployed to:", deploymentAddresses.escrow);

    // ========== Deploy InvestmentNFT ==========
    console.log("\n📦 Deploying InvestmentNFT...");
    const baseURI = "https://ipfs.io/ipfs/";
    const escrowAddress = deploymentAddresses.escrow;
    const investmentNftArtifactPath = path.join(
      __dirname,
      "../artifacts/contracts/InvestmentNFT.sol/InvestmentNFT.json"
    );
    const investmentNftArtifact = JSON.parse(
      fs.readFileSync(investmentNftArtifactPath, "utf8")
    );
    const InvestmentNftFactory = new Ethers.ContractFactory(
      investmentNftArtifact.abi,
      investmentNftArtifact.bytecode,
      wallet
    );
    const investmentNFT = await InvestmentNftFactory.deploy(
      baseURI,
      feeRecipient,
      escrowAddress,
      { nonce: nonce++ }
    );
    await investmentNFT.waitForDeployment();
    deploymentAddresses.investmentNFT = await investmentNFT.getAddress();
    console.log(
      "✅ InvestmentNFT deployed to:",
      deploymentAddresses.investmentNFT
    );

    // ========== Deploy Voting ==========
    console.log("\n📦 Deploying Voting...");
    const governanceToken =
      process.env.GOVERNANCE_TOKEN || deploymentAddresses.mockERC20;
    const nftContract =
      process.env.NFT_CONTRACT || deploymentAddresses.investmentNFT;
    const votingArtifactPath = path.join(
      __dirname,
      "../artifacts/contracts/Voting.sol/Voting.json"
    );
    const votingArtifact = JSON.parse(
      fs.readFileSync(votingArtifactPath, "utf8")
    );
    const VotingFactory = new Ethers.ContractFactory(
      votingArtifact.abi,
      votingArtifact.bytecode,
      wallet
    );
    const voting = await VotingFactory.deploy(
      governanceToken,
      escrowAddress,
      nftContract,
      { nonce: nonce++ }
    );
    await voting.waitForDeployment();
    deploymentAddresses.voting = await voting.getAddress();
    console.log("✅ Voting deployed to:", deploymentAddresses.voting);

    // ========== Deploy DealRoom ==========
    console.log("\n📦 Deploying DealRoom...");
    const dealRoomArtifactPath = path.join(
      __dirname,
      "../artifacts/contracts/DealRoom.sol/DealRoom.json"
    );
    const dealRoomArtifact = JSON.parse(
      fs.readFileSync(dealRoomArtifactPath, "utf8")
    );
    const DealRoomFactory = new Ethers.ContractFactory(
      dealRoomArtifact.abi,
      dealRoomArtifact.bytecode,
      wallet
    );
    const dealRoom = await DealRoomFactory.deploy({ nonce: nonce++ });
    await dealRoom.waitForDeployment();
    deploymentAddresses.dealRoom = await dealRoom.getAddress();
    console.log("✅ DealRoom deployed to:", deploymentAddresses.dealRoom);

    // ========== Save Deployment Addresses ==========
    const deploymentsDir = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsDir)) {
      fs.mkdirSync(deploymentsDir, { recursive: true });
    }

    const deploymentFile = path.join(
      deploymentsDir,
      `${network.name}-${Date.now()}.json`
    );
    fs.writeFileSync(
      deploymentFile,
      JSON.stringify(deploymentAddresses, null, 2)
    );

    // Also update the latest deployment file
    const latestFile = path.join(deploymentsDir, `${network.name}-latest.json`);
    fs.writeFileSync(latestFile, JSON.stringify(deploymentAddresses, null, 2));

    console.log("\n========================================");
    console.log("✨ DEPLOYMENT COMPLETED SUCCESSFULLY ✨");
    console.log("========================================");
    console.log("\n📋 DEPLOYMENT SUMMARY:");
    console.log(`Network: ${network.name}`);
    // removed reference to undefined deployer
    console.log(`\n📦 CONTRACT ADDRESSES:`);
    console.log(`MockERC20:    ${deploymentAddresses.mockERC20}`);
    console.log(`Counter:      ${deploymentAddresses.counter}`);
    console.log(`Escrow:       ${deploymentAddresses.escrow}`);
    console.log(`InvestmentNFT: ${deploymentAddresses.investmentNFT}`);
    console.log(`Voting:       ${deploymentAddresses.voting}`);
    console.log(`DealRoom:     ${deploymentAddresses.dealRoom}`);
    console.log(`\n📁 Deployment file saved to: ${deploymentFile}`);
    console.log("========================================\n");

    return deploymentAddresses;
  } catch (error) {
    console.error("\n❌ DEPLOYMENT FAILED:");
    console.error(error);
    process.exitCode = 1;
  }
}

main();
