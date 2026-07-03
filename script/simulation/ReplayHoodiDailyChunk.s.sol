// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";

/// @notice Replays a strict, contiguous range of token #20 daily observations.
/// Any failed swap reverts the simulation phase and prevents the whole chunk from broadcasting.
contract ReplayHoodiDailyChunk is Script {
    uint256 private constant ONE = 1e18;
    string private constant FLOW_FILE = "goro data/pmm_token_20_post_launch_daily_flow.csv";

    function run() external {
        uint256 holderKey = vm.envUint("INVESTOR_A_PK");
        PropertyPMM pool = PropertyPMM(vm.envAddress("REPLAY_POOL"));
        uint256 startDay = vm.envUint("REPLAY_START_DAY");
        uint256 dayCount = vm.envOr("REPLAY_DAY_COUNT", uint256(25));
        address holder = vm.addr(holderKey);

        vm.startBroadcast(holderKey);
        IERC20 base = IERC20(address(pool.baseToken()));
        IERC20 quote = IERC20(address(pool.quoteToken()));
        if (base.allowance(holder, address(pool)) < type(uint128).max) {
            base.approve(address(pool), type(uint256).max);
        }
        if (quote.allowance(holder, address(pool)) < type(uint128).max) {
            quote.approve(address(pool), type(uint256).max);
        }

        vm.closeFile(FLOW_FILE);
        vm.readLine(FLOW_FILE);
        uint256 processedDays;
        uint256 currentDay;
        while (processedDays < dayCount) {
            string memory line;
            try vm.readLine(FLOW_FILE) returns (string memory nextLine) {
                line = nextLine;
            } catch {
                break;
            }
            if (bytes(line).length == 0) break;
            if (currentDay++ < startDay) continue;

            uint256 sellAmount = _csvUint(line, 3) * ONE;
            uint256 buyAmount = _csvUint(line, 4) * ONE;
            if (sellAmount > 0) pool.sellBaseToken(sellAmount, 0);
            if (buyAmount > 0) pool.buyBaseToken(buyAmount, type(uint256).max);
            ++processedDays;
        }
        vm.stopBroadcast();

        console2.log("Replay holder:", holder);
        console2.log("Replay start day:", startDay);
        console2.log("Days processed:", processedDays);
        console2.log("Base reserve:", pool.baseBalance() / ONE);
        console2.log("Quote reserve:", pool.quoteBalance() / ONE);
        console2.log("Mid price:", pool.getMidPrice() / ONE);
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
}
