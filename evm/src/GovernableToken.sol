// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {ERC20} from "openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import "ismp/IIsmpModule.sol";
import "../lib/ERC6160/src/tokens/ERC6160Ext20.sol";

contract GovernableToken is IIsmpModule, ERC6160Ext20 {
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x0;
    bytes32 constant HOST_ROLE = keccak256("HOST_ROLE");

    constructor(string memory _name, string memory _symbol, address _defaultOwner) ERC6160Ext20(_defaultOwner, _name, _symbol) {}

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "Does not have role"); 
        _;
    }

    function _grantRole(bytes32 role, address account) private onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = true;
    }

    function _revokeRole(bytes32 role, address account) private onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = false;
    }

    function mint(address account, uint256 amount, bytes calldata) external override onlyRole(MINTER_ROLE) {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount, bytes calldata) external override onlyRole(BURNER_ROLE)  {
        _burn(account, amount);
    }

    function onAccept(PostRequest calldata request) external onlyRole(HOST_ROLE) {
        (address account, bytes32 role, bool grant) = abi.decode(request.body, (address, bytes32, bool));
        grant ? _grantRole(role, account) : _revokeRole(role, account);
    }

    function onPostResponse(PostResponse memory) external view onlyRole(HOST_ROLE) {
        revert("Token gateway doesn't emit Post responses");
    }

    function onGetResponse(GetResponse memory) external view onlyRole(HOST_ROLE) {
        revert("Token gateway doesn't emit Get responses");
    }

    function onPostRequestTimeout(PostRequest memory) external view onlyRole(HOST_ROLE) {
        revert("Token gateway doesn't emit Post responses");
    }

    function onPostResponseTimeout(PostResponse memory) external view onlyRole(HOST_ROLE) {
        revert("Token gateway doesn't emit Post responses");
    }

    function onGetTimeout(GetRequest memory) external view onlyRole(HOST_ROLE) {
        revert("Token gateway doesn't emit Get requests");
    }
}