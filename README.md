# AMM Logic (UniswapV2-style)

🔧 Minimal UniswapV2-like Automated Market Maker (AMM) implemented for experiments and tests.

## Overview

- Contracts:
  - `contracts/Factory.sol` — creates and tracks `UniswapV2Pair` instances.
  - `contracts/Pair.sol` — core AMM (reserves, mint/burn, swap, TWAP cumulatives).
  - `contracts/MockERC20.sol` — simple ERC20 token used in tests.
- Tests: `test/AMM.t.sol` — Foundry/forge tests that cover pair creation, liquidity provision, swaps, withdrawals and oracle cumulatives.

## Quickstart (Foundry)

Prerequisites:
- Foundry (forge + cast). Install: https://book.getfoundry.sh/
- Git (some `forge` operations expect a git repo)

Install libs:

```bash
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std
```

Run tests:

```bash
forge test -vvv
```

Run a single test (by name pattern):

```bash
forge test -m "MintLiquidity" -vvv
```

## Notes & Design Decisions

- Canonical token ordering: `token0 < token1` to avoid duplicate pairs and ensure deterministic reserves and events.
- Minting behavior: LP minted is `min(amount0 * totalSupply / reserve0, amount1 * totalSupply / reserve1)` — any unbalanced extra tokens remain in the pool and do not generate LP (they change price/value for existing LP holders).
- The initial liquidity provider receives `sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY` LP and a small `MINIMUM_LIQUIDITY` amount is locked (minted to a burn address) to prevent divide-by-zero.

## License

MIT
