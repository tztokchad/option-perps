require("dotenv").config();
require("@nomiclabs/hardhat-waffle");
require("hardhat-gas-reporter");
require("@atixlabs/hardhat-time-n-mine");
require("hardhat-deploy");
require("hardhat-deploy-ethers");
require("@nomiclabs/hardhat-etherscan");

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.9",
        settings: {
          optimizer: {
            enabled: true,
            runs: 5000
          }
        }
      },
      {
        version: "0.6.12",
        settings: {
          optimizer: {
            enabled: true,
            runs: 5000
          }
        }
      }
    ]
  },
  namedAccounts: {
    deployer: 0,
    user1: 1
  },
  networks: {
    arbitrum: {
      chainId: 42161,
      url: "https://arb1.arbitrum.io/rpc",
      accounts: [process.env.KEY]
    },
    hardhat: {
      forking: {
        url: process.env.ARBITRUM_NET_API_URL,
        blockNumber: 44832616
      },
      chainId: 42161
    }
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY,
      arbitrumOne: process.env.ARBISCAN_API_KEY
    }
  },
  mocha: {
    timeout: 140000
  }
};
