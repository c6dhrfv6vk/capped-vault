# capped-vault

Small ERC-4626 vault with a hard deposit cap and a performance fee. Built for
vaults that must never exceed a risk limit set by the curator — an insurance
pool, a treasury sleeve, or a strategy with a fixed allocation.

The cap is checked against `totalAssets()`, so donations and yield count towards
it. Fees are paid in shares minted to a fee recipient on every harvest, which
keeps assets in the vault and makes fee accounting auditable from the share
supply alone.

## Invariants

- `totalAssets() <= cap` after every successful `deposit` and `mint`.
- `cap` is only ever lowered, never raised, and never below `totalAssets()`.
- `harvest()` mints at most `MAX_FEE_BPS` of the yield above the high-water mark.
- The fee baseline advances with deposits and drops with withdrawals, so neither
  is billed as yield.
- `withdraw` and `redeem` harvest before pricing, so an exit cannot drain the
  assets backing freshly minted fee shares.
- A drawdown never re-bills yield: the baseline only moves up on gains.
- The vault holds no approvals and makes no external calls beyond the asset.
- Fees are shares only — `harvest()` never moves assets.

## Roles

| Role | Powers | Trust assumption |
| --- | --- | --- |
| `owner` | `setCap` (down only), `setFee` | Cannot touch user funds or move the fee above `MAX_FEE_BPS` |
| `feeRecipient` | receives fee shares | Passive |
| anyone | `harvest()` | Idempotent, safe to call after any accrual |

## Install

```sh
git clone https://github.com/c6dhrfv6vk/capped-vault && cd capped-vault
forge install foundry-rs/forge-std transmissions11/solmate
forge build
```

## Usage

Deploy with the asset, share metadata, cap, fee and owner:

```solidity
CappedVault vault = new CappedVault(
    ERC20(usdc), "Capped USDC", "cvUSDC", 5_000_000e6, 1_000, treasury, multisig
);
```

Deposits revert with `CapExceeded(total, cap)` past the limit:

```solidity
vault.deposit(1_000e6, msg.sender); // reverts if it would push totalAssets() over cap
```

Harvest after yield shows up in `totalAssets()`:

```sh
cast send $VAULT "harvest()"
```

Test:

```sh
forge test
forge test --match-test testFuzz -vvv
```

## Layout

```
src/CappedVault.sol      vault, cap and fee accounting
src/mocks/TestToken.sol  mintable ERC-20 for tests only
test/CappedVault.t.sol   cap, fee, loss and redeem fuzz tests
```

## Upgrade path

The contract is not proxied. To migrate, lower the cap to zero as users exit, or
let the vault drain and deploy a new one; share balances are never migrated in
place, so indexers should key on the new address.

## License

MIT, 2026 Elena Petrova.
