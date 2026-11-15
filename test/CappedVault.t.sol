// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CappedVault} from "../src/CappedVault.sol";
import {TestToken} from "../src/mocks/TestToken.sol";

contract CappedVaultTest is Test {
    TestToken internal asset;
    CappedVault internal vault;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal feeSink = address(0xFEE5);

    uint256 internal constant CAP = 1_000_000e18;
    uint16 internal constant FEE_BPS = 1_000; // 10%

    function setUp() public {
        asset = new TestToken("Mock USD", "mUSD", 18);
        vault = new CappedVault(asset, "Capped mUSD", "cmUSD", CAP, FEE_BPS, feeSink, address(this));

        asset.mint(alice, 10 * CAP);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(assets, who);
    }

    function _donate(uint256 amount) internal {
        asset.mint(address(vault), amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  CAP
    //////////////////////////////////////////////////////////////*/

    function testFuzzDepositStaysWithinCap(uint96 listed) public {
        uint256 amount = bound(listed, 1, CAP);
        _deposit(alice, amount);

        assertLe(vault.totalAssets(), vault.cap());
        assertEq(vault.remainingCapacity(), CAP - amount);
    }

    function testDepositJustAboveCapReverts() public {
        uint256 excess = vault.remainingCapacity() + 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CappedVault.CapExceeded.selector, excess, CAP));
        vault.deposit(excess, alice);
    }

    function testExactCapFillsVault() public {
        _deposit(alice, CAP);

        assertEq(vault.remainingCapacity(), 0);

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1, alice);
    }

    function testCapCountsDonatedAssets() public {
        _deposit(alice, CAP / 2);
        _donate(CAP / 2);

        assertEq(vault.remainingCapacity(), 0);
    }

    function testSetCapBelowAssetsReverts() public {
        _deposit(alice, 100_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(CappedVault.CapBelowAssets.selector, 1, 100_000e18)
        );
        vault.setCap(1);
    }

    function testOwnerLowersCap() public {
        _deposit(alice, 100_000e18);
        vault.setCap(200_000e18);

        assertEq(vault.remainingCapacity(), 100_000e18);
    }

    function testNonOwnerCannotSetCap() public {
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        vault.setCap(2 * CAP);
    }

    /*//////////////////////////////////////////////////////////////
                                  FEE
    //////////////////////////////////////////////////////////////*/

    function testHarvestMintsSharesWorthTheFee() public {
        uint256 depositAmount = 100_000e18;
        _deposit(alice, depositAmount);
        _donate(10_000e18); // 10% yield

        vault.harvest();

        // 10% of a 10_000e18 yield is 1_000e18 of assets.
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(feeSink)), 1_000e18, 1);
        assertEq(vault.lastTotalAssets(), vault.totalAssets());

        uint256 supplyAfterFirst = vault.totalSupply();
        vault.harvest(); // nothing new accrued
        assertEq(vault.totalSupply(), supplyAfterFirst);
    }

    function testWithdrawHarvestsBeforeBurningShares() public {
        _deposit(alice, 100_000e18);
        _donate(20_000e18);

        vm.prank(alice);
        vault.withdraw(50_000e18, alice, alice);

        assertGt(vault.balanceOf(feeSink), 0);
        assertLe(vault.totalAssets(), vault.cap());
    }

    function testLossIsNotChargedTwice() public {
        _deposit(alice, 100_000e18);

        asset.burn(address(vault), 10_000e18); // -10%
        vault.harvest();
        assertEq(vault.balanceOf(feeSink), 0);

        _donate(5_000e18); // recover, still below the old baseline
        vault.harvest();
        assertEq(vault.balanceOf(feeSink), 0);

        _donate(10_000e18); // now above baseline
        vault.harvest();
        assertGt(vault.balanceOf(feeSink), 0);
    }

    function testSetFeeHarvestsAtOldRate() public {
        _deposit(alice, 100_000e18);
        _donate(10_000e18);

        uint256 supplyBefore = vault.totalSupply();
        vault.setFee(2_000, bob);

        assertGt(vault.totalSupply(), supplyBefore);
        assertEq(vault.feeBps(), 2_000);
        assertEq(vault.feeRecipient(), bob);
    }

    function testSetFeeRejectsExcessiveRate() public {
        vm.expectRevert(abi.encodeWithSelector(CappedVault.FeeTooHigh.selector, 2_001));
        vault.setFee(2_001, bob);
    }

    function testSetFeeRejectsZeroRecipient() public {
        vm.expectRevert(CappedVault.ZeroAddress.selector);
        vault.setFee(0, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function testFuzzRedeemReturnsAssetsMinusFee(uint96 listed) public {
        uint256 assets = bound(listed, 10e18, CAP / 2);
        uint256 shares = _deposit(alice, assets);
        _donate(assets / 10);
        vault.harvest();

        uint256 preview = vault.previewRedeem(shares);
        assertGe(preview, assets); // yield passed through
        assertLt(preview, assets + assets / 10); // minus the fee

        vm.prank(alice);
        uint256 received = vault.redeem(shares, alice, alice);
        assertEq(received, preview);
    }

    function testRedeemHarvestsImplicitly() public {
        uint256 shares = _deposit(alice, 1_000e18);
        _donate(100e18);

        vm.prank(alice);
        uint256 received = vault.redeem(shares, alice, alice);

        assertGt(vault.balanceOf(feeSink), 0);
        assertLt(received, 1_100e18);
    }

    function testFullExitLeavesFeeSharesBacked() public {
        uint256 shares = _deposit(alice, 1_000e18);
        _donate(100e18);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        // The fee recipient's shares still own the retained fee.
        assertGt(vault.totalAssets(), 0);
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(feeSink)), 10e18, 1);
    }

    function testNoSharesBurnOnZeroDeposit() public {
        vm.prank(alice);
        vm.expectRevert("ZERO_SHARES");
        vault.deposit(0, alice);
    }
}
