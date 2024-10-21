// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";

import {Gaussian, computeTradingFunction} from "./RMM.sol";
import {InsufficientTokenMinted} from "./lib/RmmErrors.sol";

contract LiquidityManager {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    function mintToken(address token, address receiver, address tokenIn, uint256 amountTokenToDeposit, uint256 minTokensOut)
        public
        payable
        returns (uint256 amountOut)
    {
        // Implementation depends on your specific requirements
        // This is a placeholder
        if (msg.value > 0) {
            // Handle ETH deposits
        }

        if (tokenIn != address(0)) {
            ERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountTokenToDeposit);
            // Implement token minting logic here
        }

        if (amountOut < minTokensOut) {
            revert InsufficientTokenMinted(amountOut, minTokensOut);
        }
    }

    struct AllocateArgs {
        address rmm;
        uint256 amountIn;
        uint256 minOut;
        uint256 minLiquidityDelta;
        uint256 initialGuess;
        uint256 epsilon;
    }

    function allocateFromToken(AllocateArgs calldata args) external returns (uint256 liquidity) {
        // Implementation depends on your specific RMM contract
        // This is a placeholder
    }

    struct ComputeArgs {
        address rmm;
        uint256 rX;
        uint256 rY;
        PYIndex index;
        uint256 maxIn;
        uint256 blockTime;
        uint256 initialGuess;
        uint256 epsilon;
    }

    function computePtToSyToAddLiquidity(ComputeArgs memory args) public view returns (uint256 guess, uint256 syOut) {
        uint256 min = 0;
        uint256 max = args.maxIn - 1;
        for (uint256 iter = 0; iter < 256; ++iter) {
            guess = args.initialGuess > 0 && iter == 0 ? args.initialGuess : (min + max) / 2;
            (,, syOut,,) = RMM(payable(args.rmm)).prepareSwapPtIn(guess, args.blockTime, args.index);

            uint256 syNumerator = syOut * (args.rX - syOut);
            uint256 ptNumerator = (args.maxIn - guess) * (args.rY + guess);

            if (isAApproxB(syNumerator, ptNumerator, args.epsilon)) {
                return (guess, syOut);
            }

            if (syNumerator <= ptNumerator) {
                min = guess + 1;
            } else {
                max = guess - 1;
            }
        }
    }

    function computeSyToPtToAddLiquidity(ComputeArgs memory args) public view returns (uint256 guess, uint256 ptOut) {
        RMM rmm = RMM(payable(args.rmm));
        uint256 min = 0;
        uint256 max = args.maxIn - 1;
        for (uint256 iter = 0; iter < 256; ++iter) {
            guess = args.initialGuess > 0 && iter == 0 ? args.initialGuess : (min + max) / 2;
            (,, ptOut,,) = rmm.prepareSwapSyIn(guess, args.blockTime, args.index);

            uint256 syNumerator = (args.maxIn - guess) * (args.rX + guess);
            uint256 ptNumerator = ptOut * (args.rY - ptOut);

            if (isAApproxB(syNumerator, ptNumerator, args.epsilon)) {
                return (guess, ptOut);
            }

            if (ptNumerator <= syNumerator) {
                min = guess + 1;
            } else {
                max = guess - 1;
            }
        }
    }

    function isAApproxB(uint256 a, uint256 b, uint256 eps) internal pure returns (bool) {
        return b.mulWadDown(1 ether - eps) <= a && a <= b.mulWadDown(1 ether + eps);
    }

    function calcMaxTokenOut(
        uint256 reserveX_,
        uint256 reserveY_,
        uint256 totalLiquidity_,
        uint256 strike_,
        uint256 sigma_,
        uint256 tau_
    ) internal pure returns (uint256) {
        int256 currentTF = computeTradingFunction(reserveX_, reserveY_, totalLiquidity_, strike_, sigma_, tau_);
        
        uint256 maxProportion = uint256(int256(1e18) - currentTF) * 1e18 / (2 * 1e18);
        
        uint256 maxTokenOut = reserveY_ * maxProportion / 1e18;
        
        return (maxTokenOut * 999) / 1000;
    }
}
