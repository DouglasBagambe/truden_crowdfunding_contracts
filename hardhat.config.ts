import "dotenv/config";
import hardhatToolboxViem from "@nomicfoundation/hardhat-toolbox-viem";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import { HardhatUserConfig } from "hardhat/config";

const config: HardhatUserConfig = {
  plugins: [hardhatToolboxViem, hardhatVerify],
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
      evmVersion: "paris",
    },
  },
  networks: {
    // Local testing
    hardhat: {
      type: "edr-simulated",
      chainId: 31337,
    },
    localhost: {
      type: "http",
      url: "http://127.0.0.1:8545",
    },

    // Ethereum Testnet
    sepolia: {
      type: "http",
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      chainId: 11155111,
    },

    // Celo Networks
    celoSepolia: {
      type: "http",
      url:
        process.env.CELO_SEPOLIA_RPC ||
        "https://forno.celo-sepolia.celo-testnet.org",
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      chainId: 11142220,
      gasPrice: "auto",
    },
    celoMainnet: {
      type: "http",
      url: process.env.CELO_MAINNET_RPC || "https://forno.celo.org",
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      chainId: 42220,
      gasPrice: "auto",
    },

    // Base Networks
    baseSepolia: {
      type: "http",
      url: process.env.BASE_SEPOLIA_RPC || "https://sepolia.base.org",
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      chainId: 84532,
    },
    baseMainnet: {
      type: "http",
      url: process.env.BASE_MAINNET_RPC || "https://mainnet.base.org",
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      chainId: 8453,
    },
  },
  verify: {
    etherscan: {
      apiKey: process.env.CELOSCAN_API_KEY || process.env.ETHERSCAN_API_KEY || "",
    },
  },
  chainDescriptors: {
    11142220: {
      name: "celoSepolia",
      blockExplorers: {
        etherscan: {
          name: "Celoscan",
          url: "https://sepolia.celoscan.io",
          apiUrl: "https://api-sepolia.celoscan.io/api",
        },
      },
    },
    42220: {
      name: "celoMainnet",
      blockExplorers: {
        etherscan: {
          name: "Celoscan",
          url: "https://celoscan.io",
          apiUrl: "https://api.celoscan.io/api",
        },
      },
    },
    84532: {
      name: "baseSepolia",
      blockExplorers: {
        etherscan: {
          name: "Basescan",
          url: "https://sepolia.basescan.org",
          apiUrl: "https://api-sepolia.basescan.org/api",
        },
      },
    },
    8453: {
      name: "baseMainnet",
      blockExplorers: {
        etherscan: {
          name: "Basescan",
          url: "https://basescan.org",
          apiUrl: "https://api.basescan.org/api",
        },
      },
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};

export default config;
