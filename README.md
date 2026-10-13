# Zapline

> Production-grade Uniswap V2 integration suite and decentralized finance security lab. Built in Solidity 0.8.24 with Foundry, verified against live Ethereum mainnet state via forked simulation.

[![CI](https://github.com/Jash-Bohare/Zapline/actions/workflows/test.yml/badge.svg)](https://github.com/Jash-Bohare/Zapline/actions/workflows/test.yml)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF4B4B.svg)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Overview

**Zapline** is a comprehensive, production-hardened suite of smart contracts integrating with Uniswap V2, paired with a hands-on **Security Lab** that demonstrates real-world DeFi attack vectors, root causes, exploit proofs-of-concept, and their corresponding cryptographic and economic mitigations.

### Core Modules

1. **SwapExecutor (`src/SwapExecutor.sol`)**:
   - Optimal exact-input and exact-output multi-hop swap execution with strict deadline and slippage bounds.
   - Dual-pricing validation against internal `V2Library` formulas.
   - Automatic refund of unspent input tokens, native ETH unwrapping, and USDT non-standard approval handling.
2. **Single-Sided Zap (`src/Zap.sol`)**:
   - Single-token LP entry and exit (`zapIn`, `zapInETH`, `zapOut`, `zapOutETH`).
   - Closed-form optimal swap math (`ZapMath.sol`) computing the exact split without brute force.
   - 512-bit safe integer Newton-Raphson square root algorithm to prevent arithmetic overflow on large pools.
   - Strict dust bounding returning unswapped or unpooled residual tokens to the caller.
3. **Cumulative TWAP Oracle (`src/oracle/TwapOracle.sol`)**:
   - Sliding-window time-weighted average price oracle consuming Uniswap V2 cumulative price accumulators (`price0CumulativeLast`, `price1CumulativeLast`).
   - Ring buffer storing up to 256 time-stamped observations with configurable spacing (`minSpacing = 10m`) and window (`minWindow = 30m`).
   - Resilient against flash-loan and single-block spot price manipulation.
4. **ERC-4626 LP Vault (`src/LPVault.sol`)**:
   - Yield-bearing vault wrapping Uniswap V2 LP positions.
   - **Fair-reserves + TWAP valuation** formula:
     $$\text{totalAssets} = 2 \times \sqrt{r_D \times v_O} \times \frac{\text{vaultLP}}{\text{totalLPSupply}} + \text{idleAsset}$$
     where $v_O$ is the TWAP price of the non-deposit asset.
   - Immune to sandwiching and flash-loan spot price manipulation.
   - Virtual share offset (`_decimalsOffset() = 6`) completely neutralizing first-depositor inflation attacks.
5. **FlashSwap Arbitrage (`src/FlashSwap.sol`)**:
   - Spatial cross-venue arbitrage engine between Uniswap V2 (borrow venue) and SushiSwap (sell venue).
   - Strict callback security verifying both caller (`_activePair`) and initiator (`sender == address(this)`).
   - Zero-capital arbitrage execution returning net profits directly to a specified beneficiary.

---

## Architecture

```text
                               ┌────────────────────────────────┐
                               │           User / EOA           │
                               └───────┬──────────────┬─────────┘
                                       │              │
                       Deposit Asset D │              │ Execute Swap / Zap
                                       ▼              ▼
                       ┌──────────────────┐  ┌──────────────────┐
                       │     LPVault      │  │   SwapExecutor   │
                       │   (ERC-4626)     │  │   (Multi-hop)    │
                       └────────┬─────────┘  └────────┬─────────┘
                                │                     │
                        Zaps in │                     │ Direct Swaps
                                ▼                     ▼
                       ┌──────────────────┐  ┌──────────────────┐
                       │       Zap        │  │   TwapOracle     │
                       │  (Single-Sided)  │  │  (Ring Buffer)   │
                       └────────┬─────────┘  └────────┬─────────┘
                                │                     │
                     Pool Math  │   Fair Valuation    │
                     & Liquidity│   (2*sqrt(rD*vO))   │
                                ▼                     ▼
                       ┌────────────────────────────────────────┐
                       │          Uniswap V2 Pair (AMM)         │
                       │             (USDC / WETH)              │
                       └────────────────────────────────────────┘
                                       ▲
                                       │ Flash Borrow & Callback
                               ┌───────┴──────────┐
                               │    FlashSwap     ├───► Sells on SushiSwap
                               │   (Arbitrage)    │
                               └──────────────────┘
```

---

## Security Lab & Attack PoCs

The repository includes complete exploit proofs-of-concept and production mitigations for the four most prevalent AMM integration vulnerabilities.

```text
test/attacks/
├── 01_SpotOracleManipulation.t.sol   # Flash loan spot oracle price manipulation
├── 02_SandwichNoSlippage.t.sol       # MEV sandwich attack on zero-slippage swaps
├── 03_UnsafeFlashCallback.t.sol      # Unauthenticated flash-swap callback drain
├── 04_VaultInflation.t.sol           # ERC-4626 first-depositor share inflation
└── mocks/
    ├── VulnerableLender.sol          # Spot oracle vulnerable lending protocol
    ├── FixedLender.sol               # TWAP-secured lending protocol
    └── NaiveFlashReceiver.sol        # Unauthenticated callback mock
```

### Attack 1: Spot Oracle Manipulation
- **What happens**: An attacker manipulates an AMM pair's instantaneous reserves using a large swap (or flash loan), artificially inflating collateral valuation to borrow and drain funds from a lending protocol.
- **Root cause**: Lending protocol (`VulnerableLender`) reads instantaneous reserves via `pair.getReserves()` to calculate collateral price:
  ```solidity
  // VULNERABLE:
  uint256 price = (reserveUSDC * 1e18) / reserveWETH;
  ```
- **Exploit**:
  1. Attacker observes pool at ~3,485 USDC/WETH.
  2. Attacker dumps 5,000,000 USDC into pool, pushing spot price to >10,000 USDC/WETH.
  3. Attacker deposits 10 WETH collateral, valued by vulnerable lender at >$100,000 instead of $34,850.
  4. Attacker borrows 56,000 USDC against 10 WETH collateral (exceeding true collateral value).
  5. Attacker swaps back, leaving protocol with an undercollateralized bad debt of >$20,000.
- **Fix**: Replace spot pricing with `TwapOracle` sliding-window time-weighted average price:
  ```solidity
  // FIXED (FixedLender.sol):
  uint256 twapPrice = oracle.consult(pair, collateralToken, 1 ether);
  ```
- **Proof**: Run `forge test --match-contract SpotOracleManipulationTest -vv`
- **Residual risk**: TWAP resistance depends on pool liquidity and window length. Extremely deep pockets can still move TWAP over multi-block periods on thin pools.

---

### Attack 2: Sandwich Attack (Zero Slippage)
- **What happens**: An MEV bot detects a pending user swap with `amountOutMin = 0` (or wide slippage), front-runs the user to worsen the execution price, and back-runs to pocket risk-free profit.
- **Root cause**: User specifies `minOut = 0` or UI passes empty slippage tolerance.
- **Exploit**:
  1. Victim initiates swap of 100,000 USDC for WETH with `minOut = 0`.
  2. Attacker front-runs by purchasing WETH with 500,000 USDC, pushing WETH price higher.
  3. Victim's swap executes at the inflated price, suffering severe price impact.
  4. Attacker back-runs by selling their WETH back for USDC, capturing thousands in net profit at victim's expense.
- **Fix**: Require explicit user-defined slippage bounds (`minOut` checked via `V2Library.getAmountOut`):
  ```solidity
  // FIXED (SwapExecutor.sol):
  if (amounts[path.length - 1] < minOut) revert SlippageExceeded(amounts[path.length - 1], minOut);
  ```
- **Proof**: Run `forge test --match-contract SandwichNoSlippageTest -vv`
- **Residual risk**: Slippage protection is only as effective as the threshold set by the caller.

---

### Attack 3: Unsafe Flash-Swap Callback
- **What happens**: An attacker drains a contract whose `uniswapV2Call` callback trusts unauthenticated calldata without verifying the caller or the transaction initiator.
- **Root cause**: `NaiveFlashReceiver` decodes payment recipient directly from unverified calldata:
  ```solidity
  // VULNERABLE (NaiveFlashReceiver.sol):
  (address token, address payTo, uint256 amount) = abi.decode(data, (address, address, uint256));
  IERC20(token).safeTransfer(payTo, amount);
  ```
- **Exploit Variants**:
  - **Variant A (Direct Call)**: Attacker directly invokes `naiveReceiver.uniswapV2Call(...)` with `payTo = attacker`. Naive receiver transfers 100 WETH treasury directly to attacker.
  - **Variant B (Real Pair Initiator)**: Attacker initiates a real flash swap on Uniswap V2 specifying `to = naiveReceiver` and encoding `payTo = attacker`. Naive receiver drains 100 WETH to attacker.
- **Fix**: Require three layers of authentication:
  ```solidity
  // FIXED (FlashSwap.sol):
  if (msg.sender != _activePair) revert UnauthorizedCaller();
  if (sender != address(this)) revert UnauthorizedSender();
  if (factory.getPair(token0, token1) != msg.sender) revert UnauthorizedCaller();
  ```
- **Proof**: Run `forge test --match-contract UnsafeFlashCallbackTest -vv`
- **Residual risk**: None; external calls cannot trigger unauthorized execution.

---

### Attack 4: Vault First-Depositor Inflation
- **What happens**: The first depositor in a naive ERC-4626 vault deposits 1 wei of assets, then donates a large balance of LP tokens directly to the vault. A subsequent depositor's shares round down to zero, losing their deposit entirely.
- **Root cause**: Naive share conversion formula without virtual offset:
  $$\text{shares} = \frac{\text{assets} \times \text{totalSupply}}{\text{totalAssets}}$$
- **Exploit**:
  1. Attacker deposits 1 wei of assets, receiving 1 share (`totalSupply = 1`).
  2. Attacker donates 100 LP tokens directly to vault (`totalAssets` becomes huge; `totalSupply = 1`).
  3. Victim deposits 50 LP tokens worth of assets. $\text{shares} = 50 \times 1 / 150 = 0$ (rounds down to 0).
  4. Victim receives 0 shares.
  5. Attacker redeems 1 share and withdraws both their donation and victim's deposit.
- **Fix**: OpenZeppelin virtual shares with `_decimalsOffset() = 6`:
  ```solidity
  // FIXED (LPVault.sol):
  function _decimalsOffset() internal view virtual override returns (uint8) {
      return 6;
  }
  ```
  Shares are minted using virtual supply $+10^6$ and virtual assets $+1$, making inflation economically infeasible.
- **Proof**: Run `forge test --match-contract VaultInflationAttackTest -vv`
- **Residual risk**: None; share rounding is bounded within negligible basis points.

---

## Test Suite & Verification

The test suite runs against Ethereum mainnet fork at block `26131429`.

```bash
# Run all unit and fuzz tests
forge test

# Run the stateful invariant suite
forge test --match-contract VaultInvariantsTest

# Run the complete Security Lab attack simulations
forge test --match-path "test/attacks/*" -vv

# Check gas snapshots
forge snapshot --check

# Generate test coverage report
forge coverage --report summary --no-match-coverage "(test|script|mocks)"
```

### Test Summary

| Category | Suite | Tests | Result |
| :--- | :--- | :---: | :---: |
| **V2 Refresher** | `V2Refresher.t.sol` | 9 | PASS |
| **Swap Execution** | `SwapExecutor.t.sol` | 17 | PASS |
| **Single-Sided Zap** | `Zap.t.sol` | 17 | PASS |
| **Oracle** | `TwapOracle.t.sol` | 10 | PASS |
| **LP Vault** | `LPVault.t.sol` | 13 | PASS |
| **Flash Arbitrage** | `FlashSwap.t.sol` | 11 | PASS |
| **Attack 01** | `01_SpotOracleManipulation.t.sol` | 2 | PASS |
| **Attack 02** | `02_SandwichNoSlippage.t.sol` | 2 | PASS |
| **Attack 03** | `03_UnsafeFlashCallback.t.sol` | 4 | PASS |
| **Attack 04** | `04_VaultInflation.t.sol` | 2 | PASS |
| **Invariants** | `VaultInvariants.t.sol` | 4 | PASS |
| **Total** | **11 Suites** | **88 Tests** | **100% PASS** |

---

## Deployment & Scripts

Deployment scripts are configured in `script/`:
- `script/Deploy.s.sol`: Deploys `SwapExecutor`, `Zap`, `TwapOracle`, `LPVault`, and `FlashSwap`.
- `script/Demo.s.sol`: End-to-end interactive simulation script demonstrating swaps, zaps, vault deposits, and arbitrage.

```bash
# Dry-run deployment against local fork
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL

# Live deployment (provide private key when ready)
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

---

## Security Verification & Auditing Checklist

- [x] **No Unprotected Callbacks**: Strict verification on `msg.sender == _activePair` and `sender == address(this)`.
- [x] **No Spot Price Oracles**: Fair reserves valuation with sliding-window TWAP.
- [x] **Virtual Share Offset**: 6 decimal offset in `LPVault` prevents inflation attacks.
- [x] **Reentrancy Protection**: `ReentrancyGuard` on all state-modifying external calls.
- [x] **Safe Token Handling**: `SafeERC20` with `forceApprove` for non-standard ERC-20 tokens (USDT).
- [x] **Strict Slippage Bounding**: Caller-mandated minimum output amounts.
- [x] **Stateless Dust Invariant**: Unspent input and residual dust refunded to caller.

---

## License

This project is licensed under the [MIT License](LICENSE).
