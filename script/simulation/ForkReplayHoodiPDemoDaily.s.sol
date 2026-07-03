// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";

/// @notice Replays token #20 daily sell-then-buy flow against the freshly
/// redeployed PDemo PMM on a local Hoodi Anvil fork.
contract ForkReplayHoodiPDemoDaily is Script {
    address private constant P_DEMO = 0x82C96966167940B21D5382258730b4668E0fB336;
    address private constant T_USD = 0x829aD27d87C5bf4e70f7C7D40eB17a25e74f824e;
    uint256 private constant ONE = 1e18;
    string private constant FLOW_FILE = "goro data/pmm_token_20_post_launch_daily_flow.csv";

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 holderKey = vm.envUint("INVESTOR_A_PK");
        address deployer = vm.addr(deployerKey);
        address holder = vm.addr(holderKey);
        PropertyPMM pool = PropertyPMM(vm.envAddress("FORK_POOL"));
        string memory scenarioTag = vm.envOr("FORK_SCENARIO_TAG", string("pdemo_token_20_r_20"));
        uint256 quoteBuffer = vm.envOr("FORK_TRADER_QUOTE_BUFFER", uint256(50_000 * ONE));

        vm.startBroadcast(deployerKey);
        IERC20(T_USD).transfer(holder, quoteBuffer);
        vm.stopBroadcast();

        vm.startBroadcast(holderKey);
        IERC20(P_DEMO).approve(address(pool), type(uint256).max);
        IERC20(T_USD).approve(address(pool), type(uint256).max);
        _replay(pool, scenarioTag);
        vm.stopBroadcast();

        console2.log("Pool:", address(pool));
        console2.log("Final base reserve:", pool.baseBalance() / ONE);
        console2.log("Final quote reserve:", pool.quoteBalance() / ONE);
        console2.log("Final mid price:", pool.getMidPrice() / ONE);
    }

    function _replay(PropertyPMM pool, string memory scenarioTag) private {
        string memory outputFile = string.concat("goro data/fork_hoodi_", scenarioTag, "_daily.csv");
        vm.writeFile(outputFile, "block_date,mid_price,base_reserve,quote_reserve,rejected_buy,rejected_sell\n");
        uint256 rejectedBuy;
        uint256 rejectedSell;

        vm.closeFile(FLOW_FILE);
        vm.readLine(FLOW_FILE);
        while (true) {
            try vm.readLine(FLOW_FILE) returns (string memory line) {
                if (bytes(line).length == 0) break;
                uint256 sellAmount = _csvUint(line, 3) * ONE;
                uint256 buyAmount = _csvUint(line, 4) * ONE;
                if (sellAmount > 0) {
                    try pool.sellBaseToken(sellAmount, 0) {} catch { rejectedSell += sellAmount; }
                }
                if (buyAmount > 0) {
                    try pool.buyBaseToken(buyAmount, type(uint256).max) {} catch { rejectedBuy += buyAmount; }
                }
                _writeSnapshot(outputFile, line, pool, rejectedBuy, rejectedSell);
            } catch {
                break;
            }
        }
    }

    function _csvUint(string memory line, uint256 fieldIndex) private pure returns (uint256 value) {
        bytes memory data = bytes(line);
        uint256 currentField;
        bool inField;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == ",") {
                if (currentField == fieldIndex) return value;
                ++currentField;
                inField = false;
            } else if (currentField == fieldIndex) {
                require(data[i] >= "0" && data[i] <= "9", "INVALID_CSV_NUMBER");
                value = value * 10 + uint8(data[i]) - uint8(bytes1("0"));
                inField = true;
            }
        }
        require(currentField == fieldIndex && inField, "CSV_FIELD_NOT_FOUND");
    }

    function _csvField(string memory line, uint256 fieldIndex) private pure returns (string memory field) {
        bytes memory data = bytes(line);
        uint256 currentField;
        uint256 start;
        for (uint256 i; i <= data.length; ++i) {
            if (i == data.length || data[i] == ",") {
                if (currentField == fieldIndex) {
                    bytes memory result = new bytes(i - start);
                    for (uint256 j; j < result.length; ++j) result[j] = data[start + j];
                    return string(result);
                }
                ++currentField;
                start = i + 1;
            }
        }
        revert("CSV_FIELD_NOT_FOUND");
    }

    function _writeSnapshot(
        string memory outputFile,
        string memory inputLine,
        PropertyPMM pool,
        uint256 rejectedBuy,
        uint256 rejectedSell
    ) private {
        vm.writeLine(
            outputFile,
            string.concat(
                _csvField(inputLine, 0), ",", vm.toString(pool.getMidPrice()), ",", vm.toString(pool.baseBalance()), ",",
                vm.toString(pool.quoteBalance()), ",", vm.toString(rejectedBuy), ",", vm.toString(rejectedSell)
            )
        );
    }
}
