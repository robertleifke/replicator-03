// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Gaussian} from "solstat/Gaussian.sol";
import {PYIndexLib, PYIndex} from "pendle/core/StandardizedYield/PYIndex.sol";
import {IPPrincipalToken} from "pendle/interfaces/IPPrincipalToken.sol";
import {IStandardizedYield} from "pendle/interfaces/IStandardizedYield.sol";
import {IPYieldToken} from "pendle/interfaces/IPYieldToken.sol";

import "./lib/RmmLib.sol";
import "./lib/RmmErrors.sol";
import "./lib/RmmEvents.sol";

contract RMM is ERC20 {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    using PYIndexLib for IPYieldToken;
    using PYIndexLib for PYIndex;

    int256 public constant INIT_UPPER_BOUND = 30;
    uint256 public constant IMPLIED_RATE_TIME = 365 * 86400;
    uint256 public constant BURNT_LIQUIDITY = 1000;
    address public immutable WETH;

    IPPrincipalToken public PT; // slot 6
    IStandardizedYield public SY; // slot 7
    IPYieldToken public YT; // slot 8

    uint256 public reserveX; // slot 9
    uint256 public reserveY; // slot 10
    uint256 public totalLiquidity; // slot 11

    uint256 public strike; // slot 12
    uint256 public sigma; // slot 13
    uint256 public fee; // slot 14
    uint256 public maturity; // slot 15

    uint256 public initTimestamp; // slot 16
    uint256 public lastTimestamp; // slot 17
    uint256 public lastImpliedPrice; // slot 18

    address public curator; // slot 19
    uint256 public lock_ = 1; // slot 20

    modifier lock() {
        if (lock_ != 1) revert Reentrancy();
        lock_ = 0;
        _;
        lock_ = 1;
    }

    /// @dev Applies updates to the trading function and validates the adjustment.
    modifier evolve(PYIndex index) {
        int256 initial = tradingFunction(index);
        _;
        int256 terminal = tradingFunction(index);

        if (abs(terminal) > 10) {
            revert OutOfRange(initial, terminal);
        }
    }

    constructor(address weth_, string memory name_, string memory symbol_) ERC20(name_, symbol_, 18) {
        WETH = weth_;
    }

    receive() external payable {}

    function prepareInit(uint256 priceX, uint256 totalAsset, uint256 strike_, uint256 sigma_, uint256 maturity_)
        public
        view
        returns (uint256 totalLiquidity_, uint256 amountY)
    {
        uint256 tau_ = computeTauWadYears(maturity_ - block.timestamp);
        PoolPreCompute memory comp = PoolPreCompute({reserveInAsset: totalAsset, strike_: strike_, tau_: tau_});
        uint256 initialLiquidity =
            computeLGivenX({reserveX_: totalAsset, S: priceX, strike_: strike_, sigma_: sigma_, tau_: tau_});
        amountY =
            computeY({reserveX_: totalAsset, liquidity: initialLiquidity, strike_: strike_, sigma_: sigma_, tau_: tau_});
        totalLiquidity_ = solveL(comp, initialLiquidity, amountY, sigma_);
    }

    /// @dev Initializes the pool with an initial price, amount of `x` tokens, and parameters.
    function init(
        address PT_,
        uint256 priceX,
        uint256 amountX,
        uint256 strike_,
        uint256 sigma_,
        uint256 fee_,
        address curator_
    ) external lock {
        if (strike != 0) revert AlreadyInitialized();
        PT = IPPrincipalToken(PT_);
        SY = IStandardizedYield(PT.SY());
        YT = IPYieldToken(PT.YT());

        PYIndex index = YT.newIndex();
        uint256 totalAsset = index.syToAsset(amountX);

        strike = strike_;
        sigma = sigma_;
        fee = fee_;
        maturity = PT.expiry();
        initTimestamp = block.timestamp;
        curator = curator_;

        (uint256 totalLiquidity_, uint256 amountY) = prepareInit(priceX, totalAsset, strike_, sigma_, maturity);

        _mint(msg.sender, totalLiquidity_ - BURNT_LIQUIDITY);
        _mint(address(0), BURNT_LIQUIDITY);
        _adjust(toInt(amountX), toInt(amountY), toInt(totalLiquidity_), strike_, index);
        _debit(address(SY), reserveX);
        _debit(address(PT), reserveY);

        emit Init(
            msg.sender,
            address(SY),
            address(PT_),
            amountX,
            amountY,
            totalLiquidity_,
            strike_,
            sigma_,
            fee_,
            maturity,
            curator_
        );
    }

    /// @dev Applies an adjustment to the reserves, liquidity, and last timestamp before validating it with the trading function.
    function _adjust(int256 deltaX, int256 deltaY, int256 deltaLiquidity, uint256 strike_, PYIndex index)
        internal
        evolve(index)
    {
        lastTimestamp = block.timestamp;
        reserveX = sum(reserveX, deltaX);
        reserveY = sum(reserveY, deltaY);
        totalLiquidity = sum(totalLiquidity, deltaLiquidity);
        strike = strike_;
        uint256 timeToExpiry = maturity - block.timestamp;
        lastImpliedPrice = timeToExpiry > 0
            ? uint256(
                int256(approxSpotPrice(index.syToAsset(reserveX))).lnWad() * int256(IMPLIED_RATE_TIME)
                    / int256(timeToExpiry)
            )
            : 1 ether;
    }

    function prepareSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 timestamp, PYIndex index)
        public
        view
        returns (uint256 amountInWad, uint256 amountOutWad, uint256 amountOut, int256 deltaLiquidity, uint256 strike_)
    {
        if (tokenIn != address(SY) && tokenIn != address(PT)) revert("Invalid tokenIn");
        if (tokenOut != address(SY) && tokenOut != address(PT)) revert("Invalid tokenOut");

        bool xIn = tokenIn == address(SY);
        amountInWad = xIn ? upscale(amountIn, scalar(address(SY))) : upscale(amountIn, scalar(address(PT)));
        uint256 feeAmount = amountInWad.mulWadUp(fee);
        PoolPreCompute memory comp = preparePoolPreCompute(index, timestamp);
        uint256 nextLiquidity;
        uint256 nextReserve;
        if (xIn) {
            comp.reserveInAsset += index.syToAsset(feeAmount);
            nextLiquidity = solveL(comp, totalLiquidity, reserveY, sigma);
            comp.reserveInAsset -= index.syToAsset(feeAmount);
            nextReserve = solveY(
                comp.reserveInAsset + index.syToAsset(amountInWad), nextLiquidity, comp.strike_, sigma, comp.tau_
            );
            amountOutWad = reserveY - nextReserve;
        } else {
            nextLiquidity = solveL(comp, totalLiquidity, reserveY + feeAmount, sigma);
            nextReserve = solveX(reserveY + amountInWad, nextLiquidity, comp.strike_, sigma, comp.tau_);
            amountOutWad = reserveX - index.assetToSy(nextReserve);
        }
        strike_ = comp.strike_;
        deltaLiquidity = toInt(nextLiquidity) - toInt(totalLiquidity);
        amountOut = downscaleDown(amountOutWad, xIn ? scalar(address(PT)) : scalar(address(SY)));
    }

    /// @dev Swaps tokenX to tokenY, sending at least `minAmountOut` tokenY to `to`.
    function swapX(uint256 amountIn, uint256 minAmountOut, address to, bytes calldata data)
        external
        lock
        returns (uint256 amountOut, int256 deltaLiquidity)
    {
        uint256 amountInWad;
        uint256 amountOutWad;
        uint256 strike_;
        PYIndex index = YT.newIndex();
        (amountInWad, amountOutWad, amountOut, deltaLiquidity, strike_) =
            prepareSwap(address(SY), address(PT), amountIn, block.timestamp, index);

        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountInWad, minAmountOut, amountOut);
        }

        _adjust(toInt(amountInWad), -toInt(amountOutWad), deltaLiquidity, strike_, index);
        (uint256 creditNative) = _credit(address(PT), to, amountOutWad, 0, data);
        (uint256 debitNative) = _debit(address(SY), amountInWad);

        emit Swap(msg.sender, to, address(SY), address(PT), debitNative, creditNative, deltaLiquidity);
    }

    function swapY(uint256 amountIn, uint256 minAmountOut, address to, bytes calldata data)
        external
        lock
        returns (uint256 amountOut, int256 deltaLiquidity)
    {
        uint256 amountInWad;
        uint256 amountOutWad;
        uint256 strike_;
        uint256 delta;
        PYIndex index = YT.newIndex();
        (amountInWad, amountOutWad, amountOut, deltaLiquidity, strike_) =
            prepareSwap(address(PT), address(SY), amountIn, block.timestamp, index);

        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountInWad, minAmountOut, amountOut);
        }

        _adjust(-toInt(amountOutWad), toInt(amountInWad), deltaLiquidity, strike_, index);
        if (data.length > 0) {
            delta = index.assetToSyUp(amountInWad) - amountOutWad;
        }
        (uint256 creditNative) = _credit(address(SY), to, amountOutWad, delta, data);
        (uint256 debitNative) = _debit(address(PT), amountInWad);

        emit Swap(msg.sender, to, address(PT), address(SY), debitNative, creditNative, deltaLiquidity);
    }

    function mintSY(address receiver, address tokenIn, uint256 amountTokenToDeposit, uint256 minSharesOut)
        external
        payable
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0)) {
            amountOut =
                SY.deposit{value: amountTokenToDeposit}(receiver, address(0), amountTokenToDeposit, minSharesOut);
        } else {
            ERC20(tokenIn).transferFrom(msg.sender, address(this), amountTokenToDeposit);
            ERC20(tokenIn).approve(address(SY), amountTokenToDeposit);
            amountOut = SY.deposit(receiver, tokenIn, amountTokenToDeposit, minSharesOut);
        }
    }

    function prepareAllocate(uint256 deltaX, uint256 deltaY, PYIndex index)
        public
        view
        returns (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity, uint256 lptMinted)
    {
        deltaXWad = upscale(index.syToAsset(deltaX), scalar(address(SY)));
        deltaYWad = upscale(deltaY, scalar(address(PT)));

        PoolPreCompute memory comp =
            PoolPreCompute({reserveInAsset: index.syToAsset(reserveX + deltaXWad), strike_: strike, tau_: lastTau()});
        uint256 nextLiquidity = solveL(
            comp,
            computeLGivenX(
                comp.reserveInAsset + deltaXWad, approxSpotPrice(comp.reserveInAsset), strike, sigma, lastTau()
            ),
            reserveY + deltaYWad,
            sigma
        );
        if (nextLiquidity < totalLiquidity) {
            revert InvalidAllocate(deltaX, deltaY, totalLiquidity, nextLiquidity);
        }
        deltaLiquidity = nextLiquidity - totalLiquidity;
        lptMinted = deltaLiquidity.mulDivDown(totalSupply, nextLiquidity);
    }

    /// todo: should allocates be executed on the stale curve? I dont think the curve should be updated in allocates.
    function allocate(uint256 deltaX, uint256 deltaY, uint256 minLiquidityOut, address to)
        external
        lock
        returns (uint256 deltaLiquidity)
    {
        uint256 deltaXWad;
        uint256 deltaYWad;
        uint256 lptMinted;
        PYIndex index = YT.newIndex();
        (deltaXWad, deltaYWad, deltaLiquidity, lptMinted) = prepareAllocate(deltaX, deltaY, index);
        if (deltaLiquidity < minLiquidityOut) {
            revert InsufficientLiquidityOut(deltaX, deltaY, minLiquidityOut, deltaLiquidity);
        }

        _mint(to, lptMinted);
        _adjust(toInt(deltaXWad), toInt(deltaYWad), toInt(deltaLiquidity), strike, index);

        (uint256 debitNativeX) = _debit(address(SY), deltaXWad);
        (uint256 debitNativeY) = _debit(address(PT), deltaYWad);

        emit Allocate(msg.sender, to, debitNativeX, debitNativeY, deltaLiquidity);
    }

    function prepareDeallocate(uint256 deltaLiquidity)
        public
        view
        returns (uint256 deltaXWad, uint256 deltaYWad, uint256 lptBurned)
    {
        uint256 liquidity = totalLiquidity;
        deltaXWad = deltaLiquidity.mulDivDown(reserveX, liquidity);
        deltaYWad = deltaLiquidity.mulDivDown(reserveY, liquidity);
        lptBurned = deltaLiquidity.mulDivUp(totalSupply, liquidity);
    }

    /// @dev Burns `deltaLiquidity` * `totalSupply` / `totalLiquidity` rounded up
    /// and returns `deltaLiquidity` * `reserveX` / `totalLiquidity`
    ///           + `deltaLiquidity` * `reserveY` / `totalLiquidity` of ERC-20 tokens.
    function deallocate(uint256 deltaLiquidity, uint256 minDeltaXOut, uint256 minDeltaYOut, address to)
        external
        lock
        returns (uint256 deltaX, uint256 deltaY)
    {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 lptBurned) = prepareDeallocate(deltaLiquidity);
        (deltaX, deltaY) =
            (downscaleDown(deltaXWad, scalar(address(SY))), downscaleDown(deltaYWad, scalar(address(PT))));

        if (minDeltaXOut > deltaX) {
            revert InsufficientOutput(deltaLiquidity, minDeltaXOut, deltaX);
        }
        if (minDeltaYOut > deltaY) {
            revert InsufficientOutput(deltaLiquidity, minDeltaYOut, deltaY);
        }

        _burn(msg.sender, lptBurned); // uses state totalLiquidity
        _adjust(-toInt(deltaXWad), -toInt(deltaYWad), -toInt(deltaLiquidity), strike, YT.newIndex());

        (uint256 creditNativeX) = _credit(address(SY), to, deltaXWad, 0, "");
        (uint256 creditNativeY) = _credit(address(PT), to, deltaYWad, 0, "");

        emit Deallocate(msg.sender, to, creditNativeX, creditNativeY, deltaLiquidity);
    }

    // payments

    /// @dev Handles the request of payment for a given token.
    function _debit(address token, uint256 amountWad) internal returns (uint256 paymentNative) {
        uint256 balanceNative = _balanceNative(token);
        uint256 amountNative = downscaleDown(amountWad, scalar(token));

        if (!Token(token).transferFrom(msg.sender, address(this), amountNative)) {
            revert PaymentFailed(token, msg.sender, address(this), amountNative);
        }

        paymentNative = _balanceNative(token) - balanceNative;
        if (paymentNative < amountNative) {
            revert InsufficientPayment(token, paymentNative, amountNative);
        }
    }

    /// @dev Handles sending tokens as payment to the recipient `to`.
    function _credit(address token, address to, uint256 amount, uint256 delta, bytes memory data)
        internal
        returns (uint256 paymentNative)
    {
        uint256 balanceNative = _balanceNative(token);
        uint256 amountNative = downscaleDown(amount, scalar(token));

        // Send the tokens to the recipient.
        if (data.length > 0) {
            if (!Token(token).transferFrom(msg.sender, address(this), delta)) {
                revert PaymentFailed(token, msg.sender, address(this), delta);
            }
            mintPtYt(amount + delta, msg.sender);
        } else if (!Token(token).transfer(to, amountNative)) {
            revert PaymentFailed(token, address(this), to, amountNative);
        }

        paymentNative = balanceNative - _balanceNative(token);
        if (paymentNative < amountNative) {
            revert InsufficientPayment(token, paymentNative, amountNative);
        }
    }

    function preparePoolPreCompute(PYIndex index, uint256 blockTime) public view returns (PoolPreCompute memory) {
        uint256 tau_ = futureTau(blockTime);
        uint256 totalAsset = index.syToAsset(reserveX);
        uint256 strike_ = computeKGivenLastPrice(totalAsset, totalLiquidity, sigma, tau_);
        return PoolPreCompute(totalAsset, strike_, tau_);
    }

    /// @dev Retrieves the balance of a token in this contract, reverting if the call fails or returns unexpected data.
    function _balanceNative(address token) internal view returns (uint256) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(Token.balanceOf.selector, address(this)));
        if (!success || data.length != 32) revert BalanceError();
        return abi.decode(data, (uint256));
    }

    // maths

    /// @dev Computes the time to maturity based on the `lastTimestamp` and converts it to units of WAD years.
    function lastTau() public view returns (uint256) {
        if (maturity < lastTimestamp) {
            return 0;
        }

        return computeTauWadYears(maturity - lastTimestamp);
    }

    /// @dev Computes the time to maturity based on the current `block.timestamp` and converts it to units of WAD years.
    function currentTau() public view returns (uint256) {
        if (maturity < block.timestamp) {
            return 0;
        }

        return computeTauWadYears(maturity - block.timestamp);
    }

    function futureTau(uint256 timestamp) public view returns (uint256) {
        if (maturity < timestamp) {
            return 0;
        }

        return computeTauWadYears(maturity - timestamp);
    }

    /// @dev Computes the trading function result using the current state.
    function tradingFunction(PYIndex index) public view returns (int256) {
        if (totalLiquidity == 0) return 0; // Not initialized.
        uint256 totalAsset = index.syToAsset(reserveX);
        return computeTradingFunction(totalAsset, reserveY, totalLiquidity, strike, sigma, lastTau());
    }

    /// @notice Uses state and approximate spot price to approximate the total value of the pool in terms of Y token.
    /// @dev Do not rely on this for onchain calculations.
    // function totalValue(total) public view returns (uint256) {
    //     return approxSpotPrice().mulWadDown(reserveX) + reserveY;
    // }

    /// @notice Uses state to approximate the spot price of the X token in terms of the Y token.
    /// @dev Do not rely on this for onchain calculations.
    function approxSpotPrice(uint256 totalAsset) public view returns (uint256) {
        return computeSpotPrice(totalAsset, totalLiquidity, strike, sigma, lastTau());
    }

    function computeKGivenLastPrice(uint256 reserveX_, uint256 liquidity, uint256 sigma_, uint256 tau_)
        public
        view
        returns (uint256)
    {
        int256 timeToExpiry = int256(maturity - block.timestamp);
        int256 rt = int256(lastImpliedPrice) * int256(timeToExpiry) / int256(IMPLIED_RATE_TIME);
        int256 rate = rt.expWad();
        return uint256(rate);
        // uint256 a = sigma_.mulWadDown(sigma_).mulWadDown(tau_).mulWadDown(0.5 ether);
        // // // $$\Phi^{-1} (1 - \frac{x}{L})$$
        // int256 b = Gaussian.ppf(int256(1 ether - reserveX_.divWadDown(liquidity)));
        // int256 exp = (b * (int256(computeSigmaSqrtTau(sigma_, tau_))) / 1e18 - int256(a)).expWad();
        // return uint256(rate).divWadDown(uint256(exp));

        // return uint256(int256(lastImpliedPrice).powWad(int256(tau_))).divWadDown(uint256(exp));
    }

    function computeSYToYT(PYIndex index, uint256 exactSYIn, uint256 blockTime, uint256 initialGuess)
        public
        view
        returns (uint256)
    {
        uint256 min = exactSYIn;
        uint256 max = initialGuess;
        for (uint256 iter = 0; iter < 100; ++iter) {
            uint256 guess = (min + max) / 2;
            (,, uint256 amountOut,,) = prepareSwap(address(PT), address(SY), guess, blockTime, index);
            uint256 netSyToPt = index.assetToSyUp(guess);

            uint256 netSyToPull = netSyToPt - amountOut;
            if (netSyToPull <= exactSYIn) {
                if (isASmallerApproxB(netSyToPull, exactSYIn, 10_000)) {
                    return guess;
                }
                min = guess;
            } else {
                max = guess - 1;
            }
        }
    }

    function isASmallerApproxB(uint256 a, uint256 b, uint256 eps) internal pure returns (bool) {
        return a <= b && a >= b.mulWadDown(1e18 - eps);
    }

    function mintPtYt(uint256 amount, address to) internal returns (uint256 amountPY) {
        SY.transfer(address(YT), amount);
        amountPY = YT.mintPY(to, to);
    }
}
