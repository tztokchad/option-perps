const fs = require("fs");
const utils = require("web3-utils");

const UniswapV2Pair = require("./artifacts/contracts/uniswapv2/UniswapV2Pair.sol/UniswapV2Pair.json")
  .bytecode;

(async () => {
  const initCodeHash = utils.keccak256(UniswapV2Pair).substring(2);
  console.log("Computed new init code hash:", initCodeHash);
  const fileName1 =
    "./contracts/external/uniswapv2/libraries/UniswapV2Library.sol";
  fs.readFile(fileName1, "utf8", function(err, data) {
    const formatted = data.replace(
      /^.+init code hash/gm,
      `                        hex"${initCodeHash}" // init code hash `
    );
    fs.writeFile(fileName1, formatted, "utf8", function(err) {
      if (err) return console.log(err);
    });
  });
})();
