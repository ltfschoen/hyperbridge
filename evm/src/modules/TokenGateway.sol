// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "ismp/IIsmpModule.sol";
import "ismp/IIsmp.sol";
import "ERC6160/interfaces/IERC6160Ext20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import "../hosts/EvmHost.sol";
import "../interfaces/IUniswapV2Router.sol";

struct SendParams {
    // amount to be sent
    uint256 amount;
    // Relayer fee
    uint256 fee;
    // Gas limit for the request
    uint256 gaslimit;
    // The token identifier
    bytes32 tokenId;
    // recipient address
    address to;
    // recipient state machine
    bytes dest;
    // timeout in seconds
    uint64 timeout;
    // if to burn wrapper or native
    bool redeem;
    // this is an erc20 that a will select to be used for fee
    address tokenIntendedForFee;
    
    // amount for fee, if bridged token is feetoken require that amount or less is taken by host
    // else, swap the amount for fee into dai and use fee to limit slippage,
    // ideally minAmountOut should be the fees you expect to pay
    // uint256 amountForFee;
}

struct Body {
    // amount to be sent
    uint256 amount;
    // The token identifier
    bytes32 tokenId;
    // flag to redeem the erc20 asset on the destination
    bool redeem;
    // sender address
    address from;
    // recipient address
    address to;
}

contract TokenGateway is IIsmpModule {
    address private host;
    address private admin;
    IUniswapV2Router immutable uniswapV2Router;

    // mapping of token identifier to erc6160 contracts
    mapping(bytes32 => address) private _erc6160s;
    // mapping of token identifier to erc20 contracts
    mapping(bytes32 => address) private _erc20s;
    // foreign to local asset identifier mapping
    mapping(bytes32 => bytes32) private _assets;
    // chain to its gateway address
    mapping(bytes => bytes) private _chainToGateway;

    // User has received some assets, source chain & nonce
    event AssetReceived(bytes source, uint256 nonce);

    // restricts call to `IIsmpHost`
    modifier onlyIsmpHost() {
        if (msg.sender != host) {
            revert("Unauthorized call");
        }
        _;
    }

    // restricts call to `admin`
    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert("Unauthorized call");
        }
        _;
    }

    constructor(address _admin, address _uniswapV2Router) {
        admin = _admin;
        uniswapV2Router = IUniswapV2Router(_uniswapV2Router);
    }

    // set the ismp host address
    function setIsmpHost(address _host) public onlyAdmin {
        host = _host;
    }

    function setTokenIdentifiersERC20(bytes32 _tokenId, address _erc20) external onlyAdmin {
        _erc20s[_tokenId] = _erc20;
    }

    function setTokenIdentifiersERC6160(bytes32 _tokenId, address _erc6160) external onlyAdmin {
        _erc6160s[_tokenId] = _erc6160;
    }

    function setForeignTokenIdToLocalTokenId(bytes32 _foreignTokenId, bytes32 _localTokenId) external onlyAdmin {
        _assets[_foreignTokenId] = _localTokenId;
    }

    function setChainsGateway(bytes memory _chain, address _host) external onlyAdmin {
        _chainToGateway[_chain] = abi.encodePacked(_host);
    }

    // The Gateway contract has to have the roles `MINTER` and `BURNER`.
    function send(SendParams memory params) public {
        address from = msg.sender;

        address erc20 = _erc20s[params.tokenId];

        address erc6160 = _erc6160s[params.tokenId];

        address intendedTokenForFee = params.tokenIntendedForFee;

        require(params.to != address(0), "Burn your funds some other way");

        uint256 toBridge = params.amount;

        bytes memory data = abi.encode(
            Body({from: from, to: params.to, amount: toBridge, tokenId: params.tokenId, redeem: params.redeem})
        );

        bytes memory to = _chainToGateway[params.dest];
        require(to.length > 0, "Unsupported chain");

        DispatchPost memory request = DispatchPost({
            dest: params.dest,
            to: to,
            body: data,
            timeout: params.timeout,
            gaslimit: uint64(params.gaslimit),
            fee: params.fee
        });

        if (erc20 != address(0) && !params.redeem && intendedTokenForFee != address(0)) {
            address feeToken = EvmHost(host).dai();

            // custody the user's funds
            // require(params.amountForFee <= toBridge, "fee greater than amount");

            require(
                IERC20(erc20).transferFrom(from, address(this), params.amount), "Gateway: Insufficient user balance"
            );

            // Calculate output fee in DAI before swap: We can use swapTokensForExactTokens() on Uniswap since we know the output amount
            HostParams memory _hostParams = EvmHost(host).hostParams();
            uint256 _fee = (_hostParams.perByteFee * request.body.length) + request.fee;

            // only swap if the fee token is not the token intended for fee and if the amount the user chose to bridge is > 0
            if (feeToken != intendedTokenForFee && _fee > 0) {

                address[] memory path = new address[](2);
                path[0] = intendedTokenForFee;
                path[1] = feeToken;

                uint intendedFeeTokenAmountIn = uniswapV2Router.getAmountsIn(_fee, path)[0];

                // How do we handle cases of slippage

                require(IERC20(intendedTokenForFee).transferFrom(from, address(this), intendedFeeTokenAmountIn), "insufficient intended fee token");

                require(IERC20(intendedTokenForFee).approve(address(uniswapV2Router), intendedFeeTokenAmountIn), "approve failed.");


                uniswapV2Router.swapExactTokensForTokens(
                    intendedFeeTokenAmountIn, _fee, path, tx.origin, block.timestamp
                );

                // unchecked {
                //     toBridge -= params.amountForFee;
                // }
            }
        } else if (erc6160 != address(0) && params.redeem) {
            // we're sending an erc6160 asset so we should redeem on the destination if we can.
            IERC6160Ext20(erc6160).burn(from, params.amount, "");
        } else {
            revert("Gateway: Unknown Token Identifier");
        }

        IIsmp(host).dispatch(request);
    }

    function onAccept(PostRequest memory request) public onlyIsmpHost {
        Body memory body = abi.decode(request.body, (Body));

        bytes32 localAsset = _assets[body.tokenId];
        address erc20 = _erc20s[localAsset];
        address erc6160 = _erc6160s[localAsset];

        // prefer to give the user erc20
        if (erc20 != address(0) && body.redeem) {
            // a relayer/user is redeeming the native asset
            require(IERC20(erc20).transfer(body.to, body.amount), "Gateway: Insufficient Balance");
        } else if (erc20 != address(0) && erc6160 != address(0)) {
            // relayers double as liquidity providers, todo: protocol fees
            require(
                IERC20(erc20).transferFrom(tx.origin, body.to, body.amount), "Gateway: Insufficient relayer balance"
            );
            // hand the relayer the erc6160, so they can redeem on the source chain
            IERC6160Ext20(erc6160).mint(tx.origin, body.amount, "");
        } else if (erc6160 != address(0)) {
            IERC6160Ext20(erc6160).mint(body.to, body.amount, "");
        } else {
            revert("Gateway: Unknown Token Identifier");
        }

        emit AssetReceived(request.source, request.nonce);
    }

    function onPostRequestTimeout(PostRequest memory request) public onlyIsmpHost {
        Body memory body = abi.decode(request.body, (Body));

        address erc20 = _erc20s[body.tokenId];
        address erc6160 = _erc6160s[body.tokenId];

        if (erc20 != address(0) && !body.redeem) {
            require(IERC20(erc20).transfer(body.from, body.amount), "Gateway: Insufficient Balance");
        } else if (erc6160 != address(0) && body.redeem) {
            IERC6160Ext20(erc6160).mint(body.from, body.amount, "");
        } else {
            revert("Gateway: Inconsistent State");
        }
    }

    function onPostResponse(PostResponse memory) external view onlyIsmpHost {
        revert("Token gateway doesn't emit Post responses");
    }

    function onPostResponseTimeout(PostResponse memory) external view onlyIsmpHost {
        revert("Token gateway doesn't emit Post responses");
    }

    function onGetResponse(GetResponse memory) external view onlyIsmpHost {
        revert("Token gateway doesn't emit Get requests");
    }

    function onGetTimeout(GetRequest memory) external view onlyIsmpHost {
        revert("Token gateway doesn't emit Get Requests");
    }
}
