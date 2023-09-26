pragma solidity ^0.8.4;
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract LPToken is ERC20 {
    constructor() ERC20("Liquidity Token", "LP") {}

    function mint(address account, uint256 amount) public {
         _mint(account, amount);
    }

    function burnFrom(address account, uint256 amount) public {
         _burn(account, amount);
    }
}
