// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "forge-std/console2.sol";

import "./lib/RmmLib.sol";
import "./lib/RmmErrors.sol";
import "./lib/RmmEvents.sol";
import "./lib/LiquidityLib.sol";

contract RMM is ERC20 {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    using SafeTransferLib for ERC20;

    uint256 public sigma;
    uint256 public fee;
    uint256 public maturity;

    uint256 public reserveX;
    uint256 public reserveY;
    uint256 public totalLiquidity;
    uint256 public strike;

    uint256 public lastTimestamp;
    uint256 public lastImpliedPrice;

    uint256 private _lock = 1;

    address public tokenX;
    address public tokenY;

    modifier lock() {
        if (_lock != 1) revert Reentrancy();
        _lock = 0;
        _;
        _lock = 1;
    }

    modifier evolve() {
        _;
        int256 terminal = tradingFunction();

        if (abs(terminal) > 100) {
            revert OutOfRange(terminal);
        }
    }

    constructor(string memory name_, string memory symbol_, address tokenX_, address tokenY_, uint256 sigma_, uint256 fee_)
        ERC20(name_, symbol_, 18)
    {

        sigma = sigma_;
        maturity = block.timestamp + 7 days; // Example: set maturity to 7 days from now
        fee = fee_;
        tokenX = tokenX_;
        tokenY = tokenY_;
    }

    function init(uint256 priceX, uint256 amountX, uint256 strike_)
        external
        lock
        returns (uint256 totalLiquidity_, uint256 amountY)
    {
        if (strike_ <= 1e18 || strike != 0) revert InvalidStrike();

        (totalLiquidity_, amountY) = prepareInit(priceX, amountX, strike_, sigma);

        _mint(msg.sender, totalLiquidity_ - 1000);
        _mint(address(0), 1000);
        _adjust(toInt(amountX), toInt(amountY), toInt(totalLiquidity_), strike_);
        
        // Transfer tokens directly from the user
        tokenX.safeTransferFrom(msg.sender, address(this), amountX);
        tokenY.safeTransferFrom(msg.sender, address(this), amountY);

        emit Init(
            msg.sender, address(tokenX), address(tokenY), amountX, amountY, totalLiquidity_, strike_, sigma, fee, maturity
        );
    }

    receive() external payable {}

    /// @dev soemthign
    function swap(
        uint256 minAmountOut,
        uint256 upperBound,
        uint256 epsilon,
        address to
    ) external lock returns (uint256 amountOut, int256 deltaLiquidity) {
        uint256 amountInWad;
        uint256 amountOutWad;
        uint256 strike_;
    

        emit Swap(msg.sender, to, debitNative, amountOut, deltaLiquidity);
    }

    function allocate(bool inTermsOfX, uint256 amount, uint256 minLiquidityOut, address to)
        external
        lock
        returns (uint256)
    {
        if (block.timestamp >= maturity) revert MaturityReached();

        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity, uint256 lptMinted) =
            prepareAllocate(inTermsOfX, amount);
        if (deltaLiquidity < minLiquidityOut) {
            revert InsufficientOutput(amount, minLiquidityOut, deltaLiquidity);
        }

        _mint(to, lptMinted);
        _updateReserves(toInt(deltaXWad), toInt(deltaYWad), toInt(deltaLiquidity));

        (uint256 debitNativeX) = _debit(address(SY), deltaXWad);
        (uint256 debitNativeY) = _debit(address(PT), deltaYWad);

        emit Allocate(msg.sender, to, debitNativeX, debitNativeY, deltaLiquidity);

        return deltaLiquidity;
    }

    function deallocate(uint256 deltaLiquidity, uint256 minDeltaXOut, uint256 minDeltaYOut, address to)
        external
        lock
        returns (uint256 deltaX, uint256 deltaY)
    {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 lptBurned) = prepareDeallocate(deltaLiquidity);
        // Convert from WAD (18 decimals) to token-specific decimals
        deltaX = downscaleDown(deltaXWad, ERC20(tokenX).decimals());
        deltaY = downscaleDown(deltaYWad, ERC20(tokenY).decimals());

        if (minDeltaXOut > deltaX) {
            revert InsufficientOutput(deltaLiquidity, minDeltaXOut, deltaX);
        }
        if (minDeltaYOut > deltaY) {
            revert InsufficientOutput(deltaLiquidity, minDeltaYOut, deltaY);
        }

        _burn(msg.sender, lptBurned); // uses state totalLiquidity
        _updateReserves(-toInt(deltaXWad), -toInt(deltaYWad), -toInt(deltaLiquidity));

        (uint256 creditNativeX) = _credit(tokenX, to, deltaXWad);
        (uint256 creditNativeY) = _credit(tokenY, to, deltaYWad);

        emit Deallocate(msg.sender, to, creditNativeX, creditNativeY, deltaLiquidity);
    }

    function _updateReserves(int256 deltaX, int256 deltaY, int256 deltaLiquidity)
        internal
        evolve
    {
        reserveX = sum(reserveX, deltaX);
        reserveY = sum(reserveY, deltaY);
        totalLiquidity = sum(totalLiquidity, deltaLiquidity);
    }

    function _adjust(int256 deltaX, int256 deltaY, int256 deltaLiquidity, uint256 strike_)
        internal
        evolve
    {
        lastTimestamp = block.timestamp;
        reserveX = sum(reserveX, deltaX);
        reserveY = sum(reserveY, deltaY);
        totalLiquidity = sum(totalLiquidity, deltaLiquidity);
        strike = strike_;
        int256 timeToExpiry = int256(maturity) - int256(block.timestamp);

        lastImpliedPrice = timeToExpiry > 0
            ? uint256(int256(computeSpotPrice(reserveX, totalLiquidity, strike, sigma, lastTau())).lnWad() * int256(365 * 86400) / timeToExpiry)
            : 1 ether;
    }

    function _debit(address token, uint256 amountWad) internal returns (uint256 paymentNative) {
        uint256 balanceNative = _balanceNative(token);
        uint256 amountNative = downscaleDown(amountWad, scalar(token));

        ERC20(token).safeTransferFrom(msg.sender, address(this), amountNative);

        paymentNative = _balanceNative(token) - balanceNative;
        if (paymentNative < amountNative) {
            revert InsufficientPayment(token, paymentNative, amountNative);
        }
    }

    function _credit(address token, address to, uint256 amount) internal returns (uint256 paymentNative) {
        uint256 balanceNative = _balanceNative(token);
        uint256 amountNative = downscaleDown(amount, scalar(token));

        ERC20(token).safeTransfer(to, amountNative);

        paymentNative = balanceNative - _balanceNative(token);
        if (paymentNative < amountNative) {
            revert InsufficientPayment(token, paymentNative, amountNative);
        }
    }

    function _balanceNative(address token) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!success || data.length != 32) revert BalanceError();
        return abi.decode(data, (uint256));
    }

    function tradingFunction() public view returns (int256) {
        if (totalLiquidity == 0) return 0; // Not initialized.
        return computeTradingFunction(reserveX, reserveY, totalLiquidity, strike, sigma, lastTau());
    }

    function computeKGivenLastPrice(uint256 reserveX_, uint256 liquidity, uint256 sigma_, uint256 tau_)
        public
        view
        returns (uint256)
    {
        int256 timeToExpiry = int256(maturity - block.timestamp);
        int256 rt = int256(lastImpliedPrice) * int256(timeToExpiry) / int256(365 * 86400);
        int256 lastPrice = rt.expWad();

        uint256 a = sigma_.mulWadDown(sigma_).mulWadDown(tau_).mulWadDown(0.5 ether);
        // // $$\Phi^{-1} (1 - \frac{x}{L})$$
        int256 b = Gaussian.ppf(int256(1 ether - reserveX_.divWadDown(liquidity)));
        int256 exp = (b * (int256(computeSigmaSqrtTau(sigma_, tau_))) / 1e18 - int256(a)).expWad();
        return uint256(lastPrice).divWadDown(uint256(exp));
    }

    function prepareInit(uint256 priceX, uint256 amountX, uint256 strike_, uint256 sigma_)
        public
        view
        returns (uint256 totalLiquidity_, uint256 amountY)
    {
        uint256 totalAsset = reserveX;
        uint256 tau_ = computeTauWadYears(maturity - block.timestamp);
        PoolPreCompute memory comp = PoolPreCompute({reserveInAsset: totalAsset, strike_: strike_, tau_: tau_});
        uint256 initialLiquidity =
            computeLGivenX({reserveX_: totalAsset, S: priceX, strike_: strike_, sigma_: sigma_, tau_: tau_});
        amountY =
            computeY({reserveX_: totalAsset, liquidity: initialLiquidity, strike_: strike_, sigma_: sigma_, tau_: tau_});
        totalLiquidity_ = solveL(comp, initialLiquidity, amountY, sigma_);
    }

    function prepareAllocate(bool inTermsOfX, uint256 amount)
        public
        view
        returns (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity, uint256 lptMinted)
    {
        if (inTermsOfX) {
            deltaXWad = amount;
            (deltaYWad, deltaLiquidity) = computeAllocationGivenDeltaX(deltaXWad, reserveX, reserveY, totalLiquidity);
        } else {
            deltaYWad = amount;
            (deltaXWad, deltaLiquidity) = computeAllocationGivenDeltaY(deltaYWad, reserveX, reserveY, totalLiquidity);
        }

        lptMinted = deltaLiquidity.mulDivDown(totalSupply, totalLiquidity + deltaLiquidity);
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

    function preparePoolPreCompute(uint256 blockTime) public view returns (PoolPreCompute memory) {
        uint256 tau_ = futureTau(blockTime);
        uint256 totalAsset = reserveX;
        uint256 strike_ = computeKGivenLastPrice(totalAsset, totalLiquidity, sigma, tau_);
        return PoolPreCompute(totalAsset, strike_, tau_);
    }

    function lastTau() public view returns (uint256) {
        if (maturity < lastTimestamp) {
            return 0;
        }

        return computeTauWadYears(maturity - lastTimestamp);
    }

    function futureTau(uint256 timestamp) public view returns (uint256) {
        if (maturity < timestamp) {
            return 0;
        }

        return computeTauWadYears(maturity - timestamp);
    }
}
