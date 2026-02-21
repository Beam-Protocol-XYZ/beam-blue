// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {ICrossChainAdapter} from "../../interfaces/ICrossChainAdapter.sol";

/// @title ILayerZeroEndpointV2 (simplified)
/// @notice Minimal interface for LayerZero V2 endpoint
interface ILayerZeroEndpointV2 {
    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    function send(
        MessagingParams calldata _params,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory);

    function quote(
        MessagingParams calldata _params,
        address _sender
    ) external view returns (MessagingFee memory);

    function eid() external view returns (uint32);
}

/// @title LayerZeroAdapter
/// @notice LayerZero V2 implementation of cross-chain messaging adapter
contract LayerZeroAdapter is ICrossChainAdapter {
    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    ILayerZeroEndpointV2 public immutable endpoint;
    address public owner;

    /// @notice Trusted remote addresses per chain
    mapping(uint32 eid => address) public trustedRemotes;

    /// @notice Authorized senders (contracts that can send messages)
    mapping(address => bool) public authorizedSenders;

    /// @notice Receiver contract for incoming messages
    address public receiver;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event TrustedRemoteSet(uint32 eid, address remote);
    event AuthorizedSenderSet(address sender, bool authorized);
    event MessageSent(uint32 dstEid, address receiver, bytes32 guid);
    event MessageReceived(uint32 srcEid, address srcSender, bytes payload);

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error NotOwner();
    error NotEndpoint();
    error NotAuthorized();
    error UntrustedRemote();
    error ZeroAddress();
    error ZeroAmount();

    /* ═══════════════════════════════════════════ MODIFIERS ═══════════════════════════════════════════ */

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyEndpoint() {
        if (msg.sender != address(endpoint)) revert NotEndpoint();
        _;
    }

    modifier onlyAuthorized() {
        if (!authorizedSenders[msg.sender]) revert NotAuthorized();
        _;
    }

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(address _endpoint, address _owner, address _receiver) {
        if (_endpoint == address(0) || _owner == address(0))
            revert ZeroAddress();
        endpoint = ILayerZeroEndpointV2(_endpoint);
        owner = _owner;
        receiver = _receiver;
    }

    /* ═══════════════════════════════════════════ ADMIN FUNCTIONS ═══════════════════════════════════════════ */

    function withdrawEther(
        address payable to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function setTrustedRemote(uint32 eid, address remote) external onlyOwner {
        trustedRemotes[eid] = remote;
        emit TrustedRemoteSet(eid, remote);
    }

    function setAuthorizedSender(
        address sender,
        bool authorized
    ) external onlyOwner {
        authorizedSenders[sender] = authorized;
        emit AuthorizedSenderSet(sender, authorized);
    }

    function setReceiver(address _receiver) external onlyOwner {
        if (_receiver == address(0)) revert ZeroAddress();
        receiver = _receiver;
    }

    /* ═══════════════════════════════════════════ SEND FUNCTIONS ═══════════════════════════════════════════ */

    /// @inheritdoc ICrossChainAdapter
    function sendMessage(
        uint32 destChainId,
        address destReceiver,
        bytes calldata payload,
        bytes calldata options
    ) external payable onlyAuthorized returns (bytes32 messageId) {
        // Encode payload with sender info
        bytes memory fullPayload = abi.encode(msg.sender, payload);

        ILayerZeroEndpointV2.MessagingParams
            memory params = ILayerZeroEndpointV2.MessagingParams({
                dstEid: destChainId,
                receiver: bytes32(uint256(uint160(destReceiver))),
                message: fullPayload,
                options: options.length > 0 ? options : _getDefaultOptions(),
                payInLzToken: false
            });

        ILayerZeroEndpointV2.MessagingReceipt memory receipt = endpoint.send{
            value: msg.value
        }(
            params,
            msg.sender // refund address
        );

        messageId = receipt.guid;
        emit MessageSent(destChainId, destReceiver, messageId);
    }

    /// @inheritdoc ICrossChainAdapter
    function quoteFee(
        uint32 destChainId,
        bytes calldata payload,
        bytes calldata options
    ) external view returns (uint256 nativeFee) {
        bytes memory fullPayload = abi.encode(msg.sender, payload);

        ILayerZeroEndpointV2.MessagingParams memory params = ILayerZeroEndpointV2
            .MessagingParams({
                dstEid: destChainId,
                receiver: bytes32(0), // Not needed for quote
                message: fullPayload,
                options: options.length > 0 ? options : _getDefaultOptions(),
                payInLzToken: false
            });

        ILayerZeroEndpointV2.MessagingFee memory fee = endpoint.quote(
            params,
            address(this)
        );
        return fee.nativeFee;
    }

    /// @inheritdoc ICrossChainAdapter
    function getChainId() external view returns (uint32) {
        return endpoint.eid();
    }

    /* ═══════════════════════════════════════════ RECEIVE FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice LayerZero V2 receive callback
    /// @dev Called by the endpoint when a message is received
    function lzReceive(
        uint32 _srcEid,
        bytes32 _sender,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external onlyEndpoint {
        address srcSender = address(uint160(uint256(_sender)));

        // Verify trusted remote
        if (trustedRemotes[_srcEid] != srcSender) revert UntrustedRemote();

        // Decode the original sender and payload
        (address originalSender, bytes memory payload) = abi.decode(
            _message,
            (address, bytes)
        );

        // Forward to receiver
        if (receiver != address(0)) {
            // Call the receiver's receiveMessage function
            (bool success, ) = receiver.call(
                abi.encodeWithSignature(
                    "receiveMessage(uint32,address,bytes)",
                    _srcEid,
                    originalSender,
                    payload
                )
            );
            require(success, "Receiver call failed");
        }

        emit MessageReceived(_srcEid, originalSender, payload);
    }

    /* ═══════════════════════════════════════════ INTERNAL FUNCTIONS ═══════════════════════════════════════════ */

    function _getDefaultOptions() internal pure returns (bytes memory) {
        // Default: 200k gas limit for execution
        // Format: executorLzReceiveOption (type 1) + gas limit
        return
            abi.encodePacked(
                uint16(1), // OPTION_TYPE_LZRECEIVE
                uint256(200000) // gas limit
            );
    }
}
