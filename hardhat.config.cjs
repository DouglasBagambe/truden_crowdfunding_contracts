require("dotenv/config");
require("@nomicfoundation/hardhat-toolbox-viem");
require("@nomicfoundation/hardhat-verify");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  networks: {
    sepolia: {
      type: "http",
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      chainId: 11155111,
    },
    celoSepolia: {
      type: "http",
      url:
        process.env.CELO_SEPOLIA_RPC ||
        "https://forno.celo-sepolia.celo-testnet.org",
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      chainId: 11142220,
    },
    celoMainnet: {
      type: "http",
      url: process.env.CELO_MAINNET_RPC || "https://forno.celo.org",
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      chainId: 42220,
    },
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
  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY || "",
      celoSepolia: process.env.CELOSCAN_API_KEY || "",
      celoMainnet: process.env.CELOSCAN_API_KEY || "",
      baseSepolia: process.env.BASESCAN_API_KEY || "",
      baseMainnet: process.env.BASESCAN_API_KEY || "",
    },
    customChains: [
      {
        network: "celoSepolia",
        chainId: 11142220,
        urls: {
          apiURL: "https://api-sepolia.celoscan.io/api",
          browserURL: "https://sepolia.celoscan.io",
        },
      },
      {
        network: "celoMainnet",
        chainId: 42220,
        urls: {
          apiURL: "https://api.celoscan.io/api",
          browserURL: "https://celoscan.io",
        },
      },
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
      {
        network: "baseMainnet",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
    ],
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};
