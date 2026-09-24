import hre from "hardhat";
import { ethers as Ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

interface DeploymentAddresses {
  escrow: string;
  governance: string;
  receipt: string;
  evidence: string;
  network: string;
  chainId: number;
  deployer: string;
  admin: string;
  feeRecipient: string;
  eligibilitySigner: string;
  timestamp: number;
}

const DEFAULT_ROLE_TRANSFER_DELAY = 86_400n;
const DEFAULT_GOVERNANCE_EXECUTION_DELAY = 86_400n;
const DEFAULT_GOVERNANCE_CHALLENGE_PERIOD = 3_600n;

function requiredAddress(name: string): string {
  const value = process.env[name];

  if (!value || !Ethers.isAddress(value) || value === Ethers.ZeroAddress) {
    throw new Error(`${name} must be a non-zero EVM address`);
  }

  return value;
}

function requiredString(name: string): string {
  const value = process.env[name]?.trim();

  if (!value) {
    throw new Error(`${name} is required`);
  }

  return value;
}

function delay(name: string, fallback: bigint, minimum: bigint): bigint {
  const value = process.env[name];
  const parsed = value === undefined ? fallback : BigInt(value);

  if (parsed < minimum || parsed > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`${name} is outside the supported range`);
  }

  return parsed;
}

function artifact(name: string, dirname: string) {
  const artifactPath = path.join(
    dirname,
    `../artifacts/contracts/${name}.sol/${name}.json`,
  );

  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact missing for ${name}; run npm run compile first`);
  }

  return JSON.parse(fs.readFileSync(artifactPath, "utf8"));
}

async function deploy(
  name: string,
  args: readonly unknown[],
  wallet: Ethers.Wallet,
  dirname: string,
  nonce: number,
): Promise<Ethers.Contract> {
  const contractArtifact = artifact(name, dirname);

  const factory = new Ethers.ContractFactory(
    contractArtifact.abi,
    contractArtifact.bytecode,
    wallet,
  );

  const contract = await factory.deploy(...args, { nonce });
  await contract.waitForDeployment();

  return contract as unknown as Ethers.Contract;
}

async function assertDeployedCode(
  provider: Ethers.JsonRpcProvider,
  address: string,
  name: string,
) {
  if ((await provider.getCode(address)) === "0x") {
    throw new Error(`${name} deployment has no bytecode at ${address}`);
  }
}

async function main() {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = path.dirname(__filename);

  const hardhatConnection = await hre.network.connect();
  const { networkName, networkConfig } = hardhatConnection;

  if (networkConfig.type !== "http") {
    throw new Error(
      "A configured external HTTP network is required; local deployment is intentionally unsupported",
    );
  }

  const rpcUrlByNetwork: Record<string, string | undefined> = {
  sepolia: process.env.SEPOLIA_RPC_URL,
  celoSepolia: process.env.CELO_SEPOLIA_RPC,
  celoMainnet: process.env.CELO_MAINNET_RPC,
  baseSepolia: process.env.BASE_SEPOLIA_RPC,
  baseMainnet: process.env.BASE_MAINNET_RPC,
};

const rpcUrl = rpcUrlByNetwork[networkName];
  const configuredChainId = networkConfig.chainId;

  if (!rpcUrl) {
    throw new Error(`RPC URL is missing for network ${networkName}`);
  }

  const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;

  if (!deployerPrivateKey) {
    throw new Error("DEPLOYER_PRIVATE_KEY is required");
  }

  const admin = requiredAddress("CONTRACT_ADMIN");
  const feeRecipient = requiredAddress("FEE_RECIPIENT");
  const eligibilitySigner = requiredAddress("ELIGIBILITY_SIGNER");
  const receiptUri = requiredString("RECEIPT_URI");

  const roleTransferDelay = delay(
    "ROLE_TRANSFER_DELAY_SECONDS",
    DEFAULT_ROLE_TRANSFER_DELAY,
    86_400n,
  );

  const executionDelay = delay(
    "GOVERNANCE_EXECUTION_DELAY_SECONDS",
    DEFAULT_GOVERNANCE_EXECUTION_DELAY,
    86_400n,
  );

  const challengePeriod = delay(
    "GOVERNANCE_CHALLENGE_PERIOD_SECONDS",
    DEFAULT_GOVERNANCE_CHALLENGE_PERIOD,
    3_600n,
  );

  if (challengePeriod > executionDelay) {
    throw new Error(
      "GOVERNANCE_CHALLENGE_PERIOD_SECONDS cannot exceed execution delay",
    );
  }

  const provider = new Ethers.JsonRpcProvider(rpcUrl);
  const wallet = new Ethers.Wallet(deployerPrivateKey, provider);

  const actualChainId = Number((await provider.getNetwork()).chainId);

  if (
    configuredChainId !== undefined &&
    actualChainId !== configuredChainId
  ) {
    throw new Error(
      `RPC chain ID ${actualChainId} does not match configured ${configuredChainId}`,
    );
  }

  let nonce = await provider.getTransactionCount(wallet.address, "pending");

  const escrow = await deploy(
    "KeiboCampaignEscrow",
    [admin, feeRecipient, roleTransferDelay],
    wallet,
    __dirname,
    nonce++,
  );

  const governance = await deploy(
    "KeiboGovernance",
    [
      admin,
      await escrow.getAddress(),
      executionDelay,
      challengePeriod,
    ],
    wallet,
    __dirname,
    nonce++,
  );

  const receipt = await deploy(
    "KeiboInvestmentReceipt",
    [receiptUri, admin, eligibilitySigner],
    wallet,
    __dirname,
    nonce++,
  );

  const evidence = await deploy(
    "KeiboDealRoomEvidence",
    [admin],
    wallet,
    __dirname,
    nonce++,
  );

  await Promise.all([
    assertDeployedCode(provider, await escrow.getAddress(), "KeiboCampaignEscrow"),
    assertDeployedCode(provider, await governance.getAddress(), "KeiboGovernance"),
    assertDeployedCode(provider, await receipt.getAddress(), "KeiboInvestmentReceipt"),
    assertDeployedCode(provider, await evidence.getAddress(), "KeiboDealRoomEvidence"),
  ]);

  if (Ethers.getAddress(await escrow.getFunction("feeRecipient")()) !== Ethers.getAddress(feeRecipient)) {
    throw new Error("Escrow fee recipient verification failed");
  }
  if (Ethers.getAddress(await receipt.getFunction("eligibilitySigner")()) !== Ethers.getAddress(eligibilitySigner)) {
    throw new Error("Receipt eligibility signer verification failed");
  }
  if ((await governance.getFunction("executionDelay")()) !== executionDelay ||
      (await governance.getFunction("challengePeriod")()) !== challengePeriod) {
    throw new Error("Governance timing verification failed");
  }

  const defaultAdminRole = await escrow.getFunction("DEFAULT_ADMIN_ROLE")();
  const guardianRole = await escrow.getFunction("GUARDIAN_ROLE")();

  const grantRole = escrow.getFunction("grantRole");

  await (
    await grantRole(defaultAdminRole, await governance.getAddress(), {
      nonce: nonce++,
    })
  ).wait();

  const campaignManagerRole = await escrow.getFunction("CAMPAIGN_MANAGER_ROLE")();
  const treasuryRole = await escrow.getFunction("TREASURY_ROLE")();
  for (const [role, holder, label] of [
    [defaultAdminRole, admin, "admin"],
    [guardianRole, admin, "guardian"],
    [campaignManagerRole, admin, "campaign manager"],
    [treasuryRole, admin, "treasury"],
    [defaultAdminRole, await governance.getAddress(), "governance admin"],
    [guardianRole, await governance.getAddress(), "governance guardian"],
  ] as const) {
    if (!(await escrow.getFunction("hasRole")(role, holder))) {
      throw new Error(`Escrow ${label} role verification failed`);
    }
  }

  await (
    await grantRole(guardianRole, await governance.getAddress(), {
      nonce: nonce++,
    })
  ).wait();

  const deploymentAddresses: DeploymentAddresses = {
    escrow: await escrow.getAddress(),
    governance: await governance.getAddress(),
    receipt: await receipt.getAddress(),
    evidence: await evidence.getAddress(),
    network: networkName,
    chainId: actualChainId,
    deployer: wallet.address,
    admin,
    feeRecipient,
    eligibilitySigner,
    timestamp: Date.now(),
  };

  const deploymentsDir = path.join(__dirname, "../deployments");
  fs.mkdirSync(deploymentsDir, { recursive: true });

  const serialized = JSON.stringify(deploymentAddresses, null, 2);

  const deploymentFile = path.join(
    deploymentsDir,
    `${networkName}-${deploymentAddresses.timestamp}.json`,
  );

  fs.writeFileSync(deploymentFile, serialized);
  fs.writeFileSync(
    path.join(deploymentsDir, `${networkName}-latest.json`),
    serialized,
  );

  console.log(serialized);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
