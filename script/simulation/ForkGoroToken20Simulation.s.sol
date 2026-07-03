// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {TestnetERC20} from "../../src/amm/testnet/TestnetERC20.sol";
import {TestnetKYCRegistry} from "../../src/amm/testnet/TestnetKYCRegistry.sol";

/// @notice Minimal no-op distributor that satisfies PropertyPMM deployment validation.
contract ForkNoopDividendDistributor {
    address public immutable propertyToken;
    address public immutable stablecoin;

    constructor(address propertyToken_, address stablecoin_) {
        propertyToken = propertyToken_;
        stablecoin = stablecoin_;
    }

    function claimDividends(uint256) external {}
    function pendingDividends(address, uint256) external pure returns (uint256) { return 0; }
}

/// @notice On-chain replay of the token #20 post-launch Goro flow on a local Hoodi fork.
/// @dev The ERC-1155 Goro asset is represented by a fresh 18-decimal ERC-20 proxy;
/// this validates PropertyPMM state transitions on Anvil, not historical Goro execution.
contract ForkGoroToken20Simulation is Script {
    uint256 private constant ONE = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant TOKEN_20_SUPPLY = 619_080 * ONE;
    uint256 private constant VALUATION = 10_000 * ONE;
    uint256 private constant LP_FEE = 5e15;
    uint256 private constant K = 5e16;
    string private constant FLOW_FILE = "goro data/pmm_token_20_post_launch_daily_flow.csv";

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 reserveBps = vm.envOr("FORK_RESERVE_BPS", uint256(2_000));
        string memory scenarioTag = vm.envOr("FORK_SCENARIO_TAG", string("token_20_r_20"));
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        TestnetKYCRegistry kyc = new TestnetKYCRegistry();
        kyc.setVerified(deployer, true);

        TestnetERC20 base = new TestnetERC20("Goro Token 20 Fork Proxy", "GORO20F", 18);
        TestnetERC20 quote = new TestnetERC20("Fork USD", "fUSD", 18);
        base.setKycRegistry(address(kyc));
        ForkNoopDividendDistributor distributor = new ForkNoopDividendDistributor(address(base), address(quote));

        PropertyPMM pool = new PropertyPMM(
            deployer,
            deployer,
            address(0),
            address(base),
            address(quote),
            VALUATION,
            LP_FEE,
            0,
            K,
            address(distributor)
        );

        uint256 initialBase = TOKEN_20_SUPPLY * reserveBps / BPS;
        uint256 initialQuote = initialBase * VALUATION / ONE;
        base.mint(deployer, initialBase);
        quote.mint(deployer, type(uint128).max);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        pool.provideLiquidity(initialBase, initialQuote, 0);
        pool.enableTrading();

        _replay(pool, base, quote, deployer, scenarioTag);
        vm.stopBroadcast();

        console2.log("Fork PMM:", address(pool));
        console2.log("Fork base proxy:", address(base));
        console2.log("Fork quote proxy:", address(quote));
        console2.log("Base reserve:", pool.baseBalance() / ONE);
        console2.log("Quote reserve:", pool.quoteBalance() / ONE);
        console2.log("Mid price:", pool.getMidPrice() / ONE);
    }

    function _replay(
        PropertyPMM pool,
        TestnetERC20 base,
        TestnetERC20 quote,
        address deployer,
        string memory scenarioTag
    ) private {
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
                    base.mint(deployer, sellAmount);
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
