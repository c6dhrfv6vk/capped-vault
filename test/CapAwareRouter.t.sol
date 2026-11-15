// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CappedVault} from "../src/CappedVault.sol";
import {TestToken} from "../src/mocks/TestToken.sol";
import {CapAwareRouter} from "../src/periphery/CapAwareRouter.sol";

contract CapAwareRouterTest is Test {
    TestToken internal asset;
    CappedVault internal vault;
    CapAwareRouter internal router;

    address internal alice = address(0xA11CE);
    address internal feeSink = address(0xFEE5);

    uint256 internal constant CAP = 1_000e18;

    function setUp() public {
        asset = new TestToken("Mock USD", "mUSD", 18);
        vault = new CappedVault(asset, "Capped mUSD", "cmUSD", CAP, 0, feeSink, address(this));
        router = new CapAwareRouter(vault);

        asset.mint(alice, 10 * CAP);
        vm.prank(alice);
        asset.approve(address(router), type(uint256).max);
    }

    function _route(uint256 assetsIn) internal returns (uint256 deposited, uint256 shares) {
        vm.prank(alice);
        return router.depositUpToCap(assetsIn, alice);
    }

    function testFuzzRoutesUpToCapacity(uint96 listed) public {
        uint256 assetsIn = bound(listed, 1, 4 * CAP);
        uint256 balanceBefore = asset.balanceOf(alice);

        (uint256 deposited, uint256 shares) = _route(assetsIn);

        uint256 expected = assetsIn < CAP ? assetsIn : CAP;
        assertEq(deposited, expected);
        assertEq(vault.totalAssets(), expected);
        assertEq(shares, vault.balanceOf(alice));
        assertEq(asset.balanceOf(alice), balanceBefore - expected);
        assertEq(asset.balanceOf(address(router)), 0);
        assertEq(asset.allowance(address(router), address(vault)), 0);
    }

    function testRefundsEverythingWhenVaultIsFull() public {
        _route(CAP);
        uint256 balanceFull = asset.balanceOf(alice);

        (uint256 deposited, uint256 shares) = _route(100e18);

        assertEq(deposited, 0);
        assertEq(shares, 0);
        assertEq(asset.balanceOf(alice), balanceFull);
        assertEq(vault.balanceOf(alice), CAP);
    }

    function testPartialRouteLeavesRefund() public {
        _route(CAP - 40e18);
        uint256 balanceBefore = asset.balanceOf(alice);

        (uint256 deposited,) = _route(100e18);

        assertEq(deposited, 40e18);
        assertEq(asset.balanceOf(alice), balanceBefore - 40e18);
        assertEq(vault.remainingCapacity(), 0);
    }

    function testZeroDepositRefundsNothing() public {
        uint256 balanceBefore = asset.balanceOf(alice);

        (uint256 deposited, uint256 shares) = _route(0);

        assertEq(deposited, 0);
        assertEq(shares, 0);
        assertEq(asset.balanceOf(alice), balanceBefore);
    }

    function testRevertsOnZeroReceiver() public {
        vm.prank(alice);
        vm.expectRevert(CapAwareRouter.ZeroReceiver.selector);
        router.depositUpToCap(1e18, address(0));
    }

    function testRouterExposesVaultAsset() public view {
        assertEq(address(router.asset()), address(asset));
        assertEq(address(router.vault()), address(vault));
    }
}
