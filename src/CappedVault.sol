// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/tokens/ERC4626.sol";
import {Owned} from "solmate/auth/Owned.sol";

/// @title CappedVault
/// @notice ERC-4626 vault over one ERC-20 asset, with a hard deposit cap and a
///         performance fee charged on harvested yield.
/// @dev The cap is enforced on `totalAssets()`, so donations count towards it.
///      Fees are paid in shares, never by moving assets out of the vault, which
///      keeps `totalAssets()` monotonic on every operation except withdraw.
contract CappedVault is ERC4626, Owned {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Upper bound for the performance fee so a broken setter cannot
    ///         eat the whole yield.
    uint256 public constant MAX_FEE_BPS = 2_000;
    uint256 private constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum value of `totalAssets()`. Owner may only lower it.
    uint256 public cap;
    /// @notice Performance fee on harvested yield, in basis points.
    uint16 public feeBps;
    /// @notice Receiver of fee shares. Never the zero address.
    address public feeRecipient;
    /// @notice `totalAssets()` as of the last harvest, i.e. the yield baseline.
    uint256 public lastTotalAssets;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CapExceeded(uint256 totalAssets, uint256 cap);
    error CapBelowAssets(uint256 newCap, uint256 totalAssets);
    error FeeTooHigh(uint16 feeBps);
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CapUpdated(uint256 previousCap, uint256 newCap);
    event FeeUpdated(uint16 feeBps, address indexed recipient);
    event Harvested(uint256 yield_, uint256 feeAssets, uint256 feeShares);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param asset_ Underlying ERC-20, must implement `decimals()`.
    /// @param name_ Share token name.
    /// @param symbol_ Share token symbol.
    /// @param cap_ Initial deposit cap in asset units, must be non-zero.
    /// @param feeBps_ Initial performance fee in basis points, at most MAX_FEE_BPS.
    /// @param feeRecipient_ Receiver of fee shares, must be non-zero.
    /// @param owner_ Address allowed to tune the cap and the fee.
    constructor(
        ERC20 asset_,
        string memory name_,
        string memory symbol_,
        uint256 cap_,
        uint16 feeBps_,
        address feeRecipient_,
        address owner_
    ) ERC4626(asset_, name_, symbol_) Owned(owner_) {
        if (cap_ == 0) revert CapExceeded(0, 0);
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        if (feeRecipient_ == address(0)) revert ZeroAddress();

        cap = cap_;
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
        lastTotalAssets = totalAssets();

        emit CapUpdated(0, cap_);
        emit FeeUpdated(feeBps_, feeRecipient_);
    }

    /*//////////////////////////////////////////////////////////////
                               ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Lower the deposit cap. Never below current assets.
    function setCap(uint256 newCap) external onlyOwner {
        if (newCap < totalAssets()) revert CapBelowAssets(newCap, totalAssets());
        emit CapUpdated(cap, newCap);
        cap = newCap;
    }

    /// @notice Replace the performance fee and its receiver.
    /// @dev The outstanding yield is harvested first so it is billed at the old
    ///      rate instead of the new one.
    function setFee(uint16 newFeeBps, address newRecipient) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps);
        if (newRecipient == address(0)) revert ZeroAddress();

        harvest();
        emit FeeUpdated(newFeeBps, newRecipient);
        feeBps = newFeeBps;
        feeRecipient = newRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                               ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Assets held by the vault, including donations. Yield and donations
    ///         are what the performance fee is charged on.
    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Asset units still depositable before `totalAssets()` reaches `cap`.
    function remainingCapacity() public view returns (uint256) {
        uint256 total = totalAssets();
        return total >= cap ? 0 : cap - total;
    }

    /// @notice Mint fee shares for the yield accrued above the high-water mark.
    /// @dev Permissionless: the result does not depend on who calls it. The
    ///      baseline only ever moves up, so a drawdown is not billed again until
    ///      it is recovered.
    function harvest() public {
        uint256 current = totalAssets();
        uint256 baseline = lastTotalAssets;

        if (current <= baseline) return;
        lastTotalAssets = current;

        uint256 yield_ = current - baseline;
        uint256 feeAssets = (yield_ * feeBps) / BPS;
        if (feeAssets == 0) return;

        // Shares worth `feeAssets` priced against the vault net of the fee.
        uint256 feeShares = (feeAssets * totalSupply) / (current - feeAssets);
        if (feeShares == 0) return;

        _mint(feeRecipient, feeShares);

        emit Harvested(yield_, feeAssets, feeShares);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw `assets`, priced after the accrued fee is minted.
    /// @dev Base ERC-4626 prices before `beforeWithdraw`, which would let a full
    ///      exit drain the assets backing freshly minted fee shares.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        returns (uint256 shares)
    {
        harvest();
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeem `shares`, priced after the accrued fee is minted.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        returns (uint256 assets)
    {
        harvest();
        return super.redeem(shares, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                                HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Runs after the asset transfer, so `totalAssets()` already includes
    ///      `assets`. Deposits move the baseline up, otherwise they would be
    ///      billed as yield.
    function afterDeposit(uint256 assets, uint256) internal override {
        uint256 total = totalAssets();
        if (total > cap) revert CapExceeded(total, cap);
        lastTotalAssets += assets;
    }

    /// @dev Fees are accrued before shares are burned, then the burned assets
    ///      leave the baseline so they cannot be harvested twice.
    function beforeWithdraw(uint256 assets, uint256) internal override {
        harvest();
        lastTotalAssets -= assets;
    }
}
