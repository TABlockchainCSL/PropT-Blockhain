// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {
    MockDividendDistributor,
    MockERC20,
    MockKYCRegistry
} from "../amm/helpers/AMMTestBase.sol";

/// @notice Replays observed Goro token #18 post-launch daily flow through the
/// real PropertyPMM implementation. It is a controlled stress simulation, not
/// a historical execution-price backtest.
contract PropertyPMMGoroFlowSimulationTest is Test {
    uint256 private constant ONE = 1e18;
    uint256 private constant BPS = 10_000;

    // --- Scenario parameters: vary these for the thesis sensitivity analysis.
    uint256 private constant INITIAL_BASE_LIQUIDITY_BPS = 3_000; // 30% of supply
    uint256 private constant INITIAL_VALUATION_PRICE = 10_000 * ONE; // quote/base
    uint256 private constant PMM_K = 1e17; // 0.10
    uint256 private constant LP_FEE_RATE = 5e15; // 0.50%
    uint256 private constant MAINTAINER_FEE_RATE = 0;
    uint256 private constant MARKET_PARTICIPATION_BPS = 10_000; // PMM receives all observed flow

    address private constant OWNER = address(0xA11CE);
    address private constant LP = address(0xB0B);
    address private constant TRADER = address(0xCAFE);
    address private constant MAINTAINER = address(0xD00D);
    address private constant SUPERVISOR = address(0xE001);

    struct SimulationResult {
        uint256 executedBuyBase;
        uint256 executedSellBase;
        uint256 rejectedBuyBase;
        uint256 rejectedSellBase;
        uint256 endingBaseReserve;
        uint256 endingQuoteReserve;
    }

    function testGoroPostLaunchFlow_SellThenBuy() external {
        string memory tokenId = vm.envOr("PMM_TOKEN_ID", string("18"));
        SimulationResult memory result = _run(false, tokenId, _pmmK());
        _logResult("sell_then_buy", result);
        assertGt(result.executedBuyBase + result.executedSellBase, 0, "NO_FLOW_EXECUTED");
    }

    function testGoroPostLaunchFlow_BuyThenSell() external {
        string memory tokenId = vm.envOr("PMM_TOKEN_ID", string("18"));
        SimulationResult memory result = _run(true, tokenId, _pmmK());
        _logResult("buy_then_sell", result);
        assertGt(result.executedBuyBase + result.executedSellBase, 0, "NO_FLOW_EXECUTED");
    }

    function _run(bool buyFirst, string memory tokenId, uint256 pmmK) private returns (SimulationResult memory result) {
        string memory flowFile = string.concat("goro data/pmm_token_", tokenId, "_post_launch_daily_flow.csv");
        string memory scenarioTag = vm.envOr("PMM_SCENARIO_TAG", string(""));
        string memory outputFile = bytes(scenarioTag).length == 0
            ? string.concat("goro data/pmm_token_", tokenId, buyFirst ? "_price_buy_then_sell.csv" : "_price_sell_then_buy.csv")
            : string.concat(
                "goro data/pmm_token_",
                tokenId,
                "_",
                scenarioTag,
                buyFirst ? "_price_buy_then_sell.csv" : "_price_sell_then_buy.csv"
            );
        vm.closeFile(flowFile);
        vm.readLine(flowFile); // CSV header
        uint256 totalTokenSupply = _csvUint(vm.readLine(flowFile), 7) * ONE;
        (PropertyPMM pool, MockERC20 base, MockERC20 quote) = _deployPool(
            totalTokenSupply, pmmK, _initialBaseLiquidityBps()
        );
        vm.writeFile(outputFile, "block_date,mid_price_quote_per_token,base_reserve,quote_reserve,executed_buy_base,executed_sell_base,rejected_buy_base,rejected_sell_base\n");

        vm.closeFile(flowFile);
        vm.readLine(flowFile); // CSV header
        while (true) {
            try vm.readLine(flowFile) returns (string memory line) {
                if (bytes(line).length == 0) break;
                uint256 sellAmount = _csvUint(line, 3) * ONE * MARKET_PARTICIPATION_BPS / BPS;
                uint256 buyAmount = _csvUint(line, 4) * ONE * MARKET_PARTICIPATION_BPS / BPS;

                if (buyFirst) {
                    _buy(pool, quote, buyAmount, result);
                    _sell(pool, base, sellAmount, result);
                } else {
                    _sell(pool, base, sellAmount, result);
                    _buy(pool, quote, buyAmount, result);
                }
                _writeSnapshot(outputFile, line, pool, result);
            } catch {
                break; // EOF
            }
        }

        result.endingBaseReserve = pool.baseBalance();
        result.endingQuoteReserve = pool.quoteBalance();
    }

    function _deployPool(uint256 totalTokenSupply, uint256 pmmK, uint256 initialBaseLiquidityBps)
        private
        returns (PropertyPMM pool, MockERC20 base, MockERC20 quote)
    {
        MockKYCRegistry kyc = new MockKYCRegistry();
        kyc.setVerified(OWNER, true);
        kyc.setVerified(LP, true);
        kyc.setVerified(TRADER, true);
        kyc.setVerified(MAINTAINER, true);

        base = new MockERC20("Goro Token 18", "GORO-18", 18);
        quote = new MockERC20("Simulation USD", "sUSD", 18);
        base.setKycRegistry(address(kyc));
        MockDividendDistributor distributor = new MockDividendDistributor(address(base), address(quote));

        vm.prank(OWNER);
        pool = new PropertyPMM(
            OWNER,
            SUPERVISOR,
            MAINTAINER,
            address(base),
            address(quote),
            INITIAL_VALUATION_PRICE,
            LP_FEE_RATE,
            MAINTAINER_FEE_RATE,
            pmmK,
            address(distributor)
        );

        uint256 initialBase = totalTokenSupply * initialBaseLiquidityBps / BPS;
        uint256 initialQuote = initialBase * INITIAL_VALUATION_PRICE / ONE;
        base.mint(LP, initialBase);
        quote.mint(LP, initialQuote);
        quote.mint(TRADER, type(uint128).max);

        vm.startPrank(LP);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        pool.provideLiquidity(initialBase, initialQuote, 0);
        vm.stopPrank();

        vm.prank(OWNER);
        pool.enableTrading();
    }

    function _buy(PropertyPMM pool, MockERC20 quote, uint256 amount, SimulationResult memory result) private {
        if (amount == 0) return;
        vm.startPrank(TRADER);
        quote.approve(address(pool), type(uint256).max);
        try pool.buyBaseToken(amount, type(uint256).max) {
            result.executedBuyBase += amount;
        } catch {
            result.rejectedBuyBase += amount;
        }
        vm.stopPrank();
    }

    function _sell(PropertyPMM pool, MockERC20 base, uint256 amount, SimulationResult memory result) private {
        if (amount == 0) return;
        base.mint(TRADER, amount);
        vm.startPrank(TRADER);
        base.approve(address(pool), type(uint256).max);
        try pool.sellBaseToken(amount, 0) {
            result.executedSellBase += amount;
        } catch {
            result.rejectedSellBase += amount;
        }
        vm.stopPrank();
    }

    /// @dev The project Foundry version has no vm.split; this parser is enough
    /// for the unquoted numeric CSV fields used by the simulation input.
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
        SimulationResult memory result
    ) private {
        string memory snapshot = string.concat(
            _csvField(inputLine, 0),
            ",",
            vm.toString(pool.getMidPrice()),
            ",",
            vm.toString(pool.baseBalance()),
            ",",
            vm.toString(pool.quoteBalance()),
            ",",
            vm.toString(result.executedBuyBase),
            ",",
            vm.toString(result.executedSellBase),
            ",",
            vm.toString(result.rejectedBuyBase),
            ",",
            vm.toString(result.rejectedSellBase)
        );
        vm.writeLine(outputFile, snapshot);
    }

    function _logResult(string memory order, SimulationResult memory result) private {
        emit log_named_string("execution_order", order);
        emit log_named_uint("executed_buy_base", result.executedBuyBase / ONE);
        emit log_named_uint("executed_sell_base", result.executedSellBase / ONE);
        emit log_named_uint("rejected_buy_base", result.rejectedBuyBase / ONE);
        emit log_named_uint("rejected_sell_base", result.rejectedSellBase / ONE);
        emit log_named_uint("ending_base_reserve", result.endingBaseReserve / ONE);
        emit log_named_uint("ending_quote_reserve", result.endingQuoteReserve / ONE);
    }

    function _pmmK() private view returns (uint256) {
        return vm.envOr("PMM_K_WAD", PMM_K);
    }

    function _initialBaseLiquidityBps() private view returns (uint256) {
        return vm.envOr("PMM_INITIAL_BASE_LIQUIDITY_BPS", INITIAL_BASE_LIQUIDITY_BPS);
    }
}
