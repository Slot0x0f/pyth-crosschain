// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "pyth-sdk-solidity/IPyth.sol";
import "pyth-sdk-solidity/PythStructs.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "./LPToken.sol";

// Example oracle AMM powered by Pyth price feeds.
//
// The contract holds a pool of two ERC-20 tokens, the BASE and the QUOTE, and allows users to swap tokens
// for the pair BASE/QUOTE. For example, the base could be WETH and the quote could be USDC, in which case you can
// buy WETH for USDC and vice versa. The pool offers to swap between the tokens at the current Pyth exchange rate for
// BASE/QUOTE, which is computed from the BASE/USD price feed and the QUOTE/USD price feed.
//
// This contract only implements the swap functionality. It does not implement any pool balancing logic (e.g., skewing the
// price to reflect an unbalanced pool) or depositing / withdrawing funds. When deployed, the contract needs to be sent
// some quantity of both the base and quote token in order to function properly (using the ERC20 transfer function to
// the contract's address).
contract OracleSwap {
    event Transfer(address from, address to, uint amountUsd, uint amountWei);

    IPyth pyth;

    bytes32 baseTokenPriceId;
    bytes32 quoteTokenPriceId;

    ERC20 public baseToken;
    ERC20 public quoteToken;
    LPToken public lpToken;
    mapping(address => uint256) public liquidityProvided;
    uint256 public feeRateBips = 30; // 0.3% fee rate. 


    constructor(
        address _pyth,
        bytes32 _baseTokenPriceId,
        bytes32 _quoteTokenPriceId,
        address _baseToken,
        address _quoteToken
    ) {
        pyth = IPyth(_pyth);
        baseTokenPriceId = _baseTokenPriceId;
        quoteTokenPriceId = _quoteTokenPriceId;
        baseToken = ERC20(_baseToken);
        quoteToken = ERC20(_quoteToken);
        lpToken = new LPToken();
    }

    // Buy or sell a quantity of the base token. `size` represents the quantity of the base token with the same number
    // of decimals as expected by its ERC-20 implementation. If `isBuy` is true, the contract will send the caller
    // `size` base tokens; if false, `size` base tokens will be transferred from the caller to the contract. Some
    // number of quote tokens will be transferred in the opposite direction; the exact number will be determined by
    // the current pyth price. The transaction will fail if either the pool or the sender does not have enough of the
    // requisite tokens for these transfers.
    //
    // `pythUpdateData` is the binary pyth price update data (retrieved from Pyth's price
    // service); this data should contain a price update for both the base and quote price feeds.
    // See the frontend code for an example of how to retrieve this data and pass it to this function.
    function swap(
        bool isBuy,
        uint size,
        bytes[] calldata pythUpdateData
    ) external payable {
        uint updateFee = pyth.getUpdateFee(pythUpdateData);
        pyth.updatePriceFeeds{value: updateFee}(pythUpdateData);

        PythStructs.Price memory currentBasePrice = pyth.getPrice(
            baseTokenPriceId
        );
        PythStructs.Price memory currentQuotePrice = pyth.getPrice(
            quoteTokenPriceId
        );

        // Note: this code does all arithmetic with 18 decimal points. This approach should be fine for most
        // price feeds, which typically have ~8 decimals. You can check the exponent on the price feed to ensure
        // this doesn't lose precision.
        uint256 basePrice = convertToUint(currentBasePrice, 18);
        uint256 quotePrice = convertToUint(currentQuotePrice, 18);

        // This computation loses precision. The infinite-precision result is between [quoteSize, quoteSize + 1]
        // We need to round this result in favor of the contract.
        uint256 fee = (size * feeRateBips) / 10000;
        uint256 sizeAfterFee = size - fee;
        uint256 quoteSize = (sizeAfterFee * basePrice) / quotePrice;

        // TODO: use confidence interval

        if (isBuy) {
            // (Round up)
            quoteSize += 1;

            quoteToken.transferFrom(msg.sender, address(this), quoteSize);
            baseToken.transfer(msg.sender, size);
        } else {
            baseToken.transferFrom(msg.sender, address(this), size);
            quoteToken.transfer(msg.sender, quoteSize);
        }
    }

function addLiquidity(uint256 baseAmountDesired, uint256 quoteAmountDesired) external {
    uint256 totalBaseLiquidity = baseToken.balanceOf(address(this));
    uint256 totalQuoteLiquidity = quoteToken.balanceOf(address(this));

    uint256 totalLPLiquidity = lpToken.totalSupply();
    
    // Calculate the actual amounts of base and quote tokens to deposit, respecting the pool's existing ratio
    uint256 baseAmount;
    uint256 quoteAmount;
    if (totalBaseLiquidity == 0 || totalQuoteLiquidity == 0) {
        // If the pool is empty, accept the desired amounts
        baseAmount = baseAmountDesired;
        quoteAmount = quoteAmountDesired;
    } else {
        // Calculate the ideal amount of quote tokens to deposit based on the existing ratio and the desired base amount
        uint256 quoteAmountIdeal = (baseAmountDesired * totalQuoteLiquidity) / totalBaseLiquidity;
        if (quoteAmountDesired >= quoteAmountIdeal) {
            // If the user has provided enough quote tokens, accept the ideal amount and the desired base amount
            baseAmount = baseAmountDesired;
            quoteAmount = quoteAmountIdeal;
        } else {
            // If the user has not provided enough quote tokens, accept all provided quote tokens and adjust the base amount
            baseAmount = (quoteAmountDesired * totalBaseLiquidity) / totalQuoteLiquidity;
            quoteAmount = quoteAmountDesired;
        }
    }

    require(baseAmount > 0 && quoteAmount > 0, "Invalid liquidity amounts");

    // Transfer the calculated amounts of base and quote tokens from the user to the contract
    baseToken.transferFrom(msg.sender, address(this), baseAmount);
    quoteToken.transferFrom(msg.sender, address(this), quoteAmount);

    // Calculate LP tokens to mint
    // If the total LP supply is 0, initialize it with the deposited base amount, or create a fixed initial supply
    uint256 lpAmount = totalLPLiquidity > 0 ? 
        (baseAmount * totalLPLiquidity) / totalBaseLiquidity : 
        baseAmount; // or some other initial supply logic
    
    // Mint LP tokens to the user
    lpToken.mint(msg.sender, lpAmount);

    // Update liquidity provided mapping
    liquidityProvided[msg.sender] += lpAmount;

    //emit LiquidityAdded(msg.sender, baseAmount, quoteAmount, lpAmount);
}

function removeLiquidity(uint256 lpAmount) external {
    require(lpAmount > 0, "Cannot remove zero liquidity");
    require(lpToken.balanceOf(msg.sender) >= lpAmount, "Insufficient LP tokens");
    
    // Burn LP tokens from sender
    lpToken.burnFrom(msg.sender, lpAmount);

    // Get the total liquidity in the pool (base + quote)
    uint256 totalBaseLiquidity = baseToken.balanceOf(address(this));
    uint256 totalQuoteLiquidity = quoteToken.balanceOf(address(this));
    
    // Check total liquidity in LP tokens to avoid division by zero
    uint256 totalLPLiquidity = lpToken.totalSupply();
    require(totalLPLiquidity > 0, "No liquidity in the pool");

    // Calculate the proportion of liquidity provided by lpAmount
    uint256 baseAmount = (lpAmount * totalBaseLiquidity) / totalLPLiquidity;
    uint256 quoteAmount = (lpAmount * totalQuoteLiquidity) / totalLPLiquidity;

    uint256 baseFee = (lpAmount * baseToken.balanceOf(address(this))) / lpToken.totalSupply();
    uint256 quoteFee = (lpAmount * quoteToken.balanceOf(address(this))) / lpToken.totalSupply();

    baseAmount += baseFee;
    quoteAmount += quoteFee;

    // Ensure the contract has enough liquidity to return
    require(baseAmount <= totalBaseLiquidity, "Insufficient base liquidity in the pool");
    require(quoteAmount <= totalQuoteLiquidity, "Insufficient quote liquidity in the pool");

    // Transfer proportionate base and quote tokens back to the user
    baseToken.transfer(msg.sender, baseAmount);
    quoteToken.transfer(msg.sender, quoteAmount);

    // Update the liquidity provided mapping
    liquidityProvided[msg.sender] -= lpAmount;
    require(liquidityProvided[msg.sender] >= 0, "Negative liquidity provided");

    //emit LiquidityRemoved(msg.sender, baseAmount, quoteAmount, lpAmount);
}


    // TODO: we should probably move something like this into the solidity sdk
    function convertToUint(
        PythStructs.Price memory price,
        uint8 targetDecimals
    ) private pure returns (uint256) {
        if (price.price < 0 || price.expo > 0 || price.expo < -255) {
            revert();
        }

        uint8 priceDecimals = uint8(uint32(-1 * price.expo));

        if (targetDecimals >= priceDecimals) {
            return
                uint(uint64(price.price)) *
                10 ** uint32(targetDecimals - priceDecimals);
        } else {
            return
                uint(uint64(price.price)) /
                10 ** uint32(priceDecimals - targetDecimals);
        }
    }

    // Get the number of base tokens in the pool
    function baseBalance() public view returns (uint256) {
        return baseToken.balanceOf(address(this));
    }

    // Get the number of quote tokens in the pool
    function quoteBalance() public view returns (uint256) {
        return quoteToken.balanceOf(address(this));
    }

    //Funtion to add liquidity and mint LP token for depositor

    // Send all tokens in the oracle AMM pool to the caller of this method.
    // (This function is for demo purposes only. You wouldn't include this on a real contract.)
    function withdrawAll() external {
        baseToken.transfer(msg.sender, baseToken.balanceOf(address(this)));
        quoteToken.transfer(msg.sender, quoteToken.balanceOf(address(this)));
    }

    // Reinitialize the parameters of this contract.
    // (This function is for demo purposes only. You wouldn't include this on a real contract.)
    function reinitialize(
        bytes32 _baseTokenPriceId,
        bytes32 _quoteTokenPriceId,
        address _baseToken,
        address _quoteToken
    ) external {
        baseTokenPriceId = _baseTokenPriceId;
        quoteTokenPriceId = _quoteTokenPriceId;
        baseToken = ERC20(_baseToken);
        quoteToken = ERC20(_quoteToken);
    }

    receive() external payable {}
}
