# Zapline: Uniswap V2 Integration Suite & Security Lab

> A production-grade, educational, and battle-tested Uniswap V2 integration suite paired with an interactive DeFi Security Lab. Built in Solidity `0.8.24` with Foundry.

[![CI](https://github.com/Jash-Bohare/Zapline/actions/workflows/test.yml/badge.svg)](https://github.com/Jash-Bohare/Zapline/actions/workflows/test.yml)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF4B4B.svg)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Base Sepolia](https://img.shields.io/badge/Deployed-Base%20Sepolia-blue)](https://sepolia.basescan.org)

---

## Table of Contents
1. [DeFi & AMM Fundamentals for Beginners](#defi--amm-fundamentals-for-beginners)
   - [What is an Automated Market Maker (AMM)?](#1-what-is-an-automated-market-maker-amm)
   - [The Constant Product Formula: $x \cdot y = k$](#2-the-constant-product-formula-x--y--k)
   - [Liquidity Pools and LP Tokens](#3-liquidity-pools-and-lp-tokens)
   - [Slippage, Price Impact, and MEV Sandwich Attacks](#4-slippage-price-impact-and-mev-sandwich-attacks)
   - [What is a "Zap" and Why Do We Need Square Root Math?](#5-what-is-a-zap-and-why-do-we-need-square-root-math)
   - [Spot Oracles vs. Time-Weighted Average Price (TWAP)](#6-spot-oracles-vs-time-weighted-average-price-twap)
   - [ERC-4626 Vaults and First-Depositor Inflation Attacks](#7-erc-4626-vaults-and-first-depositor-inflation-attacks)
   - [Flash Swaps and Cross-Venue Arbitrage (Why SushiSwap?)](#8-flash-swaps-and-cross-venue-arbitrage-why-sushiswap)
2. [Zapline Architecture & System Overview](#zapline-architecture--system-overview)
3. [Core Contracts Walkthrough](#core-contracts-walkthrough)
   - [`SwapExecutor.sol`](#1-swapexecutorsol--smart-multi-hop-router)
   - [`Zap.sol` & `ZapMath.sol`](#2-zapsol--zapmathsol--single-sided-lp-entryexit)
   - [`TwapOracle.sol`](#3-twaporaclesol--sliding-window-twap-oracle)
   - [`LPVault.sol`](#4-lpvaultsol--fair-reserve-erc-4626-vault)
   - [`FlashSwap.sol`](#5-flashswapsol--cross-venue-atomic-arbitrage)
4. [Security Lab: Real-World Attacks & Defenses](#security-lab-real-world-attacks--defenses)
   - [Attack 1: Spot Oracle Price Manipulation](#attack-1-spot-oracle-price-manipulation)
   - [Attack 2: MEV Sandwich Attack on Zero-Slippage Swaps](#attack-2-mev-sandwich-attack-on-zero-slippage-swaps)
   - [Attack 3: Unauthenticated Flash-Swap Callback Drain](#attack-3-unauthenticated-flash-swap-callback-drain)
   - [Attack 4: ERC-4626 First-Depositor Share Inflation](#attack-4-erc-4626-first-depositor-share-inflation)
5. [Live Base Sepolia Deployments & Verification](#live-base-sepolia-deployments--verification)
6. [Testing & Verification Guide](#testing--verification-guide)

---

## DeFi & AMM Fundamentals for Beginners

If you are new to Decentralized Finance (DeFi) or Uniswap V2, this section covers every foundational concept you need to know.

### 1. What is an Automated Market Maker (AMM)?
In traditional finance (TradFi), exchanges like NASDAQ or Binance use an **order book** where buyers and sellers submit bids and asks. An engine matches buyer and seller orders.

On a public blockchain like Ethereum, maintaining an order book on-chain is too slow and gas-expensive. **Uniswap V2** solves this with an **Automated Market Maker (AMM)**. Instead of waiting for a counterparty to trade with, users trade directly against a **smart contract holding a pool of two tokens**.

---

### 2. The Constant Product Formula: $x \cdot y = k$
Uniswap V2 pairs hold reserves of two tokens, Token 0 ($x$) and Token 1 ($y$). Every trade must preserve the constant product rule:

$$x \cdot y = k$$

When a trader deposits $\Delta x$ of Token 0, the pool's reserve of $x$ increases. To keep the invariant $k$ constant (ignoring fees for a moment), the pool must release $\Delta y$ of Token 1:

$$(x + \Delta x) \cdot (y - \Delta y) = k$$

Solving for $\Delta y$ with Uniswap's 0.3% protocol fee ($997/1000$ multiplier):

$$\Delta y = \frac{y \cdot \Delta x \cdot 997}{x \cdot 1000 + \Delta x \cdot 997}$$

Because the product $k$ must remain conserved, the more of Token $x$ you put in, the less of Token $y$ you receive per unit. This curve mathematically enforces continuous liquidity at every possible price from zero to infinity.

---

### 3. Liquidity Pools and LP Tokens
Where does the initial money in the pool come from? **Liquidity Providers (LPs)**.
- An LP deposits an **equal economic value** of both tokens (e.g. $1,000 worth of ETH and $1,000 worth of USDC).
- In exchange, the Uniswap pair mints **LP Tokens** to the LP as a receipt of ownership.
- Whenever traders swap tokens, they pay a 0.3% fee. This fee is automatically added to the pool's reserves, increasing the pool's total value ($k$). When LPs burn their LP tokens, they redeem their proportional share of the enlarged pool, earning passive yield.

---

### 4. Slippage, Price Impact, and MEV Sandwich Attacks
- **Price Impact**: When your trade is large relative to the pool's reserves, your trade moves the pool's price along the $x \cdot y = k$ curve.
- **Slippage**: Between the moment you broadcast a transaction and when a miner/validator includes it in a block, other transactions can change the pool's reserves, causing your executed price to differ from the quote you saw.
- **MEV Sandwich Attack**: If a user submits a swap with no minimum output limit (`amountOutMin = 0` or 100% slippage), searcher bots can front-run the trade by buying the token first, let the victim's trade push the price even higher, and immediately back-run by selling at the inflated price. **The victim loses money directly to the bot.**

---

### 5. What is a "Zap" and Why Do We Need Square Root Math?
Suppose you only hold ETH, but you want to provide liquidity to an ETH/USDC pool.
- **Manual tedious way**: You must figure out how much ETH to sell, swap that portion to USDC, hope price didn't shift, and then call `addLiquidity` with both tokens. Leftover dust is often trapped in your wallet.
- **Zap way**: You send 1 ETH to `Zap.sol`. The Zap contract calculates the **exact optimal split**:
  - It swaps portion $s$ of your ETH into USDC.
  - It pairs the newly acquired USDC with the remaining $(1 - s)$ ETH.
  - It deposits both into Uniswap V2, mints LP tokens directly to your wallet, and refunds any leftover wei.

#### Why the Square Root?
Because swapping $s$ into the pool increases the price of the pool according to $x \cdot y = k$, finding the exact swap size $s$ requires solving a quadratic equation:

$$c \cdot s^2 + b \cdot s - a = 0$$

Using the quadratic formula:

$$s = \frac{-b + \sqrt{b^2 - 4ac}}{2c}$$

Our library [`ZapMath.sol`](src/libraries/ZapMath.sol) implements a **512-bit safe integer Newton-Raphson square root algorithm** that computes this division and square root without precision loss or overflow even for multi-million-dollar liquidity pools.

---

### 6. Spot Oracles vs. Time-Weighted Average Price (TWAP)
- **Spot Price**: Reading the current ratio of reserves:
  $$\text{Spot Price} = \frac{\text{reserveUSDC}}{\text{reserveWETH}}$$
  **Warning**: Spot price is extremely dangerous! Anyone with a flash loan can borrow $50M, dump it into the pool, artificially move the spot price by 500% in 1 transaction, borrow funds from a lending protocol based on that fake price, and drain the protocol.
- **TWAP (Time-Weighted Average Price)**: Uniswap V2 records **price accumulators** (`price0CumulativeLast` and `price1CumulativeLast`) that increment on every block by:
  $$\text{priceCumulative} += \text{price} \times \Delta t$$
  To manipulate a 30-minute TWAP, an attacker would have to hold the pool at a distorted price across dozens of consecutive blocks, costing millions in arbitrage losses.

---

### 7. ERC-4626 Vaults and First-Depositor Inflation Attacks
**ERC-4626** is the Ethereum standard for yield-bearing token vaults. Users deposit an underlying asset (e.g. Uniswap LP tokens) and receive vault shares.
- **The Exploit**: An attacker deposits 1 wei of assets and gets 1 share. They then donate 100 LP tokens directly to the vault contract. The vault's `totalAssets` is now 100, but `totalSupply` is still 1. A normal user who tries to deposit 50 LP tokens calculates:
  $$\text{shares} = \frac{\text{deposit} \times \text{totalSupply}}{\text{totalAssets}} = \frac{50 \times 1}{100} = 0 \quad \text{(rounds down to 0!)}$$
  The user gets 0 shares, loses their 50 LP tokens, and the attacker redeems their 1 share to steal everything.
- **The Fix**: Our [`LPVault.sol`](src/LPVault.sol) implements **6 virtual share decimals** (`_decimalsOffset() = 6`), making this attack mathematically and economically impossible.

---

### 8. Flash Swaps and Cross-Venue Arbitrage (Why SushiSwap?)
- **What is a Flash Swap?** Uniswap V2 allows you to withdraw tokens from a pair with **zero upfront capital**, provided that by the end of the transaction, you either:
  1. Return the borrowed tokens plus a 0.3% fee, or
  2. Supply the equivalent value of the pair's other token.
- **Why is SushiSwap used in Zapline?**
  To demonstrate a real, profitable flash swap, you need a strategy. The standard DeFi strategy is **Spatial Arbitrage**:
  1. Borrow Token A from **Uniswap V2** (where Token A is cheap).
  2. Sell Token A on another exchange where Token A is trading higher (e.g. **SushiSwap**).
  3. Repay the flash swap to Uniswap V2.
  4. Pocket the risk-free profit!
  
  **SushiSwap** is a direct fork of Uniswap V2—it uses the exact same interface (`IUniswapV2Router02`) and AMM formulas. In our test suite and live deployments, SushiSwap represents **"Venue B"** (the second exchange where the borrowed tokens are sold for a profit).

---

## Zapline Architecture & System Overview

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
                               │    FlashSwap     ├───► Sells on Venue B (SushiSwap)
                               │   (Arbitrage)    │
                               └──────────────────┘
```

---

## Core Contracts Walkthrough

### 1. `SwapExecutor.sol` — Smart Multi-Hop Router
- **Multi-Hop Execution**: Supports chaining swaps across multiple pairs (e.g. `DAI -> WETH -> USDC`).
- **Exact-In and Exact-Out**: Allows users to specify exact input amounts or target exact received outputs.
- **Slippage Bounds**: Enforces `amountOutMin` and `amountInMax` checks against internal math (`V2Library`).
- **Native ETH Handling**: Wraps incoming ETH to WETH and unwraps WETH to native ETH when exiting.
- **USDT Compatibility**: Safely resets non-standard ERC-20 allowances using `forceApprove`.
- **Dust Refund**: Automatically refunds any unspent input tokens back to the user.

### 2. `Zap.sol` & `ZapMath.sol` — Single-Sided LP Entry/Exit
- **`zapIn` & `zapInETH`**: Takes a single token or native ETH, calculates optimal swap fraction $s$, executes swap, and adds liquidity to Uniswap V2 in one atomic transaction.
- **`zapOut` & `zapOutETH`**: Burns Uniswap V2 LP tokens, swaps one half into the other, and delivers 100% of the proceeds in a single chosen token.
- **Mathematical Safety**: [`ZapMath.sol`](src/libraries/ZapMath.sol) prevents uint256 overflow during quadratic calculations using 512-bit safe arithmetic.

### 3. `TwapOracle.sol` — Sliding-Window TWAP Oracle
- **Ring Buffer**: Stores up to 256 historical observations per pair.
- **Configurable Windows**: Tracks minimum window size (default 30 min) and minimum spacing between observations (default 10 min).
- **Price Consultation**: Computes time-weighted average price across the requested window, entirely immune to single-block flash loan manipulations.

### 4. `LPVault.sol` — Fair-Reserve ERC-4626 Vault
- **Asset**: Wraps Uniswap V2 LP tokens.
- **Fair-Reserve Valuation**: Instead of using spot prices to value LP tokens, it uses the fair-reserve formula:
  $$\text{totalAssets} = 2 \times \sqrt{r_0 \times r_1 \times P_{\text{TWAP}}} \times \frac{\text{vaultLP}}{\text{totalLPSupply}} + \text{idleAsset}$$
- **Virtual Share Decimals**: Overrides `_decimalsOffset() = 6` to eliminate first-depositor share inflation exploits.

### 5. `FlashSwap.sol` — Cross-Venue Atomic Arbitrage
- **Borrow**: Calls `pair.swap(amount0, amount1, address(this), data)` on Uniswap V2.
- **Callback**: Uniswap V2 invokes `uniswapV2Call`.
- **Arbitrage**: Sells borrowed tokens on the second venue (SushiSwap) via `IUniswapV2Router02`.
- **Repayment**: Calculates and transfers the required repayment + 0.3% fee back to the Uniswap V2 pair.
- **Profit**: Forwards all net surplus profit to the user.
- **Triple-Lock Security**: Reverts if caller is not the verified pair, if transaction sender is not `address(this)`, or if the pair was not created by the official factory.

---

## Security Lab: Real-World Attacks & Defenses

Our repository contains complete, executable test suites under `test/attacks/` demonstrating 4 critical DeFi attack vectors:

| Attack | Vulnerability | Exploitation Mechanism | Mitigating Contract |
| :--- | :--- | :--- | :--- |
| **01. Spot Oracle Manipulation** | Protocols relying on `pair.getReserves()` for collateral valuation | Attacker dumps flash loaned capital into AMM, inflates collateral price by 300%, borrows entire treasury, and leaves bad debt | [`TwapOracle.sol`](src/oracle/TwapOracle.sol) (Sliding window TWAP) |
| **02. Sandwich Attack** | User submits swap with `amountOutMin = 0` | MEV bots front-run user with large buy order, user buys at peak, bot back-runs with sell order, stealing user's funds | [`SwapExecutor.sol`](src/SwapExecutor.sol) (Strict slippage enforcement) |
| **03. Unsafe Flash Callback** | Contract implements `uniswapV2Call` but trusts arbitrary calldata | Attacker calls callback directly or initiates flash swap targeting the contract, draining funds | [`FlashSwap.sol`](src/FlashSwap.sol) (Triple-caller validation) |
| **04. First-Depositor Inflation** | ERC-4626 vault with zero initial virtual shares | First depositor deposits 1 wei, donates 100 LP tokens; subsequent depositor shares round down to zero | [`LPVault.sol`](src/LPVault.sol) (Virtual offset: `_decimalsOffset() = 6`) |

Run all attacks locally:
```bash
forge test --match-path "test/attacks/*" -vv
```

---

## Live Base Sepolia Deployments & Verification

All Zapline contracts are deployed live on **Base Sepolia (Chain ID: 84532)**:

| Contract | Address | Blockscout (Verified) | Sourcify (Exact Match) | BaseScan |
| :--- | :--- | :---: | :---: | :---: |
| **SwapExecutor** | `0x3b9822F6a5a85b02A484946466E4c10AE8DdB46b` | [View](https://base-sepolia.blockscout.com/address/0x3b9822F6a5a85b02A484946466E4c10AE8DdB46b) | [Verified](https://repo.sourcify.dev/contracts/full_match/84532/0x3b9822F6a5a85b02A484946466E4c10AE8DdB46b/) | [BaseScan](https://sepolia.basescan.org/address/0x3b9822F6a5a85b02A484946466E4c10AE8DdB46b#code) |
| **Zap** | `0xe0C3452F0eECaBD975Bc770dF83b1bDeFf6bfC19` | [View](https://base-sepolia.blockscout.com/address/0xe0C3452F0eECaBD975Bc770dF83b1bDeFf6bfC19) | [Verified](https://repo.sourcify.dev/contracts/full_match/84532/0xe0C3452F0eECaBD975Bc770dF83b1bDeFf6bfC19/) | [BaseScan](https://sepolia.basescan.org/address/0xe0C3452F0eECaBD975Bc770dF83b1bDeFf6bfC19#code) |
| **TwapOracle** | `0x83Ba06204136b0df38a2906673364600f0B0b7D0` | [View](https://base-sepolia.blockscout.com/address/0x83Ba06204136b0df38a2906673364600f0B0b7D0) | [Verified](https://repo.sourcify.dev/contracts/full_match/84532/0x83Ba06204136b0df38a2906673364600f0B0b7D0/) | [BaseScan](https://sepolia.basescan.org/address/0x83Ba06204136b0df38a2906673364600f0B0b7D0#code) |
| **LPVault** (USDC/WETH) | `0x89EC41722e401cE1dFBE459644f68a3d7180AcA6` | [View](https://base-sepolia.blockscout.com/address/0x89EC41722e401cE1dFBE459644f68a3d7180AcA6) | [Verified](https://repo.sourcify.dev/contracts/full_match/84532/0x89EC41722e401cE1dFBE459644f68a3d7180AcA6/) | [BaseScan](https://sepolia.basescan.org/address/0x89EC41722e401cE1dFBE459644f68a3d7180AcA6#code) |
| **FlashSwap** | `0x867741F11BC22dc9d898c1c8998B4D8721384536` | [View](https://base-sepolia.blockscout.com/address/0x867741F11BC22dc9d898c1c8998B4D8721384536) | [Verified](https://repo.sourcify.dev/contracts/full_match/84532/0x867741F11BC22dc9d898c1c8998B4D8721384536/) | [BaseScan](https://sepolia.basescan.org/address/0x867741F11BC22dc9d898c1c8998B4D8721384536#code) |
| **UniswapV2Router02** | `0xdEb6081F07acbcB5120E2D0a4225A0e30A19543e` | [View](https://base-sepolia.blockscout.com/address/0xdEb6081F07acbcB5120E2D0a4225A0e30A19543e) | [Verified](https://repo.sourcify.dev/contracts/full_match/84532/0xdEb6081F07acbcB5120E2D0a4225A0e30A19543e/) | [BaseScan](https://sepolia.basescan.org/address/0xdEb6081F07acbcB5120E2D0a4225A0e30A19543e#code) |
| **SushiRouter (Venue B)** | `0x5540ac46a74D2C1c055428cc83E0f4C165b52aad` | [View](https://base-sepolia.blockscout.com/address/0x5540ac46a74D2C1c055428cc83E0f4C165b52aad) | [Verified](https://repo.sourcify.dev/contracts/full_match/84532/0x5540ac46a74D2C1c055428cc83E0f4C165b52aad/) | [BaseScan](https://sepolia.basescan.org/address/0x5540ac46a74D2C1c055428cc83E0f4C165b52aad#code) |

### How to Verify on BaseScan (Etherscan API)
All contracts are already verified with 100% exact match on **Sourcify** and **Blockscout**.
To publish verified source code directly to **BaseScan** (which requires an Etherscan API key):
1. Obtain a free API key at [BaseScan API Keys](https://basescan.org/myapikey).
2. Add your key to `.env`:
   ```bash
   BASESCAN_API_KEY="your_api_key_here"
   ```
3. Run the automated verification script:
   ```bash
   ./script/VerifyBaseSepolia.sh
   ```

---

## Testing & Verification Guide

Zapline includes **109 passing tests** across unit, fuzz, invariant, and security attack suites.

```bash
# Run all 109 tests
forge test

# Run stateful invariant fuzzing
forge test --match-contract VaultInvariantsTest

# Run all security attack proofs-of-concept
forge test --match-path "test/attacks/*" -vv

# Check code formatting (enforced in CI)
forge fmt --check

# Generate code coverage report
forge coverage --report summary --no-match-coverage "(test|script|mocks|periphery)"
```

### Test Summary

| Category | Suite | Tests | Result |
| :--- | :--- | :---: | :---: |
| **V2 Refresher** | `V2Refresher.t.sol` | 9 | PASS |
| **Swap Execution** | `SwapExecutor.t.sol` | 17 | PASS |
| **Single-Sided Zap** | `Zap.t.sol` | 17 | PASS |
| **Oracle** | `TwapOracle.t.sol` | 10 | PASS |
| **LP Vault** | `LPVault.t.sol` | 13 | PASS |
| **Flash Arbitrage** | `FlashSwap.t.sol` | 13 | PASS |
| **Comprehensive Suite** | `ComprehensiveCoverage.t.sol` | 19 | PASS |
| **Attack 01** | `01_SpotOracleManipulation.t.sol` | 2 | PASS |
| **Attack 02** | `02_SandwichNoSlippage.t.sol` | 2 | PASS |
| **Attack 03** | `03_UnsafeFlashCallback.t.sol` | 4 | PASS |
| **Attack 04** | `04_VaultInflation.t.sol` | 2 | PASS |
| **Invariants** | `VaultInvariants.t.sol` | 4 | PASS |
| **Total** | **12 Suites** | **109 Tests** | **100% PASS** |

---

## License
MIT License. Created for decentralized finance builders and security researchers.
