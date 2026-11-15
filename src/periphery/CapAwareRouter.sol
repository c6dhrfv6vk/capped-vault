// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {CappedVault} from "../CappedVault.sol";

/// @title CapAwareRouter
/// @notice Deposits as much of `assetsIn` as the vault's remaining capacity
///         allows and refunds the rest, so a depositor never has to guess the
///         current headroom or split a deposit by hand.
/// @dev Stateless and holds no balance between calls. It does not re-check the
///      cap after computing the amount: if the cap is lowered in the same block
///      by someone else, `CappedVault.deposit` reverts and the whole call rolls
///      back rather than silently depositing less.
contract CapAwareRouter {
    using SafeTransferLib for ERC20;

    error ZeroReceiver();

    event Routed(address indexed caller, address indexed receiver, uint256 deposited, uint256 refunded, uint256 shares);

    CappedVault public immutable vault;
    ERC20 public immutable asset;

    constructor(CappedVault vault_) {
        vault = vault_;
        asset = vault_.asset();
    }

    /// @notice Deposit `assetsIn` or the remaining capacity, whichever is smaller.
    /// @param assetsIn Assets to pull from the caller.
    /// @param receiver Share recipient.
    /// @return deposited Assets that actually entered the vault.
    /// @return shares Shares minted to `receiver`.
    function depositUpToCap(uint256 assetsIn, address receiver) external returns (uint256 deposited, uint256 shares) {
        if (receiver == address(0)) revert ZeroReceiver();

        asset.safeTransferFrom(msg.sender, address(this), assetsIn);

        uint256 room = vault.remainingCapacity();
        deposited = assetsIn < room ? assetsIn : room;
        shares = deposited == 0 ? 0 : vault.previewDeposit(deposited);

        // Dust deposits can round to zero shares; refund everything instead of
        // tripping the vault's ZERO_SHARES guard.
        if (shares == 0) {
            if (assetsIn != 0) asset.safeTransfer(msg.sender, assetsIn);
            emit Routed(msg.sender, receiver, 0, assetsIn, 0);
            return (0, 0);
        }

        uint256 refunded = assetsIn - deposited;
        if (refunded != 0) asset.safeTransfer(msg.sender, refunded);

        asset.safeApprove(address(vault), deposited);
        shares = vault.deposit(deposited, receiver);

        emit Routed(msg.sender, receiver, deposited, refunded, shares);
    }
}
