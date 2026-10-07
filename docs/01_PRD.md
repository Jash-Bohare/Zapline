# V2 Zap & Vault: Product Requirements Document (PRD)

**Version:** 1.0 | **Owner:** Jash Bohare | **Type:** Solo portfolio project (contracts only)

---

## 1. Overview

### 1.1 What is this project?

A set of Solidity smart contracts that **integrate with the already-deployed Uniswap V2 protocol** (Factory, Router, Pair) the way real clients need it done. We do **not** rebuild Uniswap. We build on top of it.

### 1.2 One-line pitch

> Uniswap V2 integration contracts (swap executor, single-sided zap, LP vault, flash swap) tested on a mainnet fork, plus a security lab showing how unsafe V2 integrations get exploited and fixed.

### 1.3 Why does it exist?

| Reason | Explanation |
| --- | --- |
| **Learning** | Understand V2 deeply by using it: Factory, Pair, Router, reserves, fees, LP tokens, flash swaps, TWAP. |
| **Freelance** | Clients say "integrate Uniswap", not "build Uniswap". This project is that skill, demonstrated. |
| **Portfolio gap** | Existing projects (Axiom, ChronoVest, ClearSwap) are built from scratch. None integrate a live protocol or test on mainnet state. |
| **Security angle** | The security lab shows auditor-style thinking: attack, root cause, exploit, fix. |

---

## 2. Goals and Non-Goals

### 2.1 Goals

- **G1.** Correctly integrate the V2 Router and Pair from Solidity for swaps, liquidity and flash swaps.
- **G2.** Handle real-world token and ETH edge cases (USDT-style tokens, WETH wrapping, dust, rounding).
- **G3.** Test everything against **real mainnet state** using Foundry fork tests, including fuzz and invariant tests.
- **G4.** Demonstrate at least 3 integration attacks and their fixes.
- **G5.** Produce a repo and README a freelance client or reviewer can understand in 5 minutes.

### 2.2 Non-Goals (explicitly out of scope)

- Rebuilding Uniswap V2 (Pair, Router, Factory).
- Frontend, backend, indexer, charts or dashboards.
- Risk engine, MEV indicator or "profit scanner" UI.
- Production-grade arbitrage bot or real mainnet deployment with real funds.
- Uniswap V3/V4 support (noted as future work only).
- Governance, reward tokens, farming or yield-boosting mechanisms.

---

## 3. Target Audience

| Audience | What they should take away |
| --- | --- |
| **Freelance clients** | "This developer can safely integrate Uniswap into my product." |
| **Recruiters / reviewers** | Clear scope, clean code, serious testing, security awareness. |
| **Me (the developer)** | A working mental model of V2 that I can explain and extend to V3/V4. |

---

## 4. System Summary

Four contracts plus a security lab, all talking to deployed V2 contracts.

```text
User ──► SwapExecutor ──┐
User ──► Zap ───────────┼──► Uniswap V2 Router ──► Pair(s)
User ──► LPVault ──► Zap┘
Anyone ──► FlashSwap ──────────────────────────► Pair (direct)

Security Lab: VulnerableLender, attacker contracts, fixed versions (test-only)
```

| Component | One-line purpose |
| --- | --- |
| **SwapExecutor** | Safe wrapper around Router swaps (exact-in, exact-out, multi-hop, ETH). |
| **Zap** | Deposit ONE token, receive LP tokens; exit LP back to ONE token. |
| **LPVault** | ERC-4626-style vault: deposit a token, get shares of an auto-zapped LP position. |
| **FlashSwap** | Borrow from a Pair, use funds, repay with the 0.3% fee. |
| **Security Lab** | Exploit demos and fixes (spot oracle, sandwich, unsafe callback). |

---

## 5. Functional Requirements

Priority: **P0** = must have, **P1** = should have, **P2** = nice to have. IDs are used later in contract specs and tests so every requirement is traceable.

### 5.1 SwapExecutor

| ID | Requirement | Priority |
| --- | --- | --- |
| FR-SW-1 | Swap an exact input amount of token A for token B with `amountOutMin` protection. | P0 |
| FR-SW-2 | Swap for an exact output amount with `amountInMax` protection; refund unused input. | P0 |
| FR-SW-3 | Accept a user-supplied multi-hop `path` (e.g. USDC → DAI → WETH). | P0 |
| FR-SW-4 | Support ETH → token and token → ETH via WETH. | P0 |
| FR-SW-5 | Revert if `deadline` has passed. | P0 |
| FR-SW-6 | Use SafeERC20 for all transfers and approvals (USDT-style tokens must work). | P0 |
| FR-SW-7 | Output is sent to a user-specified `recipient`. | P1 |
| FR-SW-8 | Provide a view function that returns a quote (`getAmountsOut`) for a path. | P1 |
| FR-SW-9 | Owner can pause the contract; owner can rescue tokens accidentally sent in (never user funds in flight). | P1 |
| FR-SW-10 | Emit a `Swapped` event with tokens, amounts, recipient. | P1 |

### 5.2 Zap

| ID | Requirement | Priority |
| --- | --- | --- |
| FR-ZP-1 | **Zap in with a token:** user sends one token (e.g. USDC); contract swaps the optimal portion, adds liquidity, sends LP tokens to the user. | P0 |
| FR-ZP-2 | **Zap in with ETH:** same as above, starting from native ETH. | P0 |
| FR-ZP-3 | Compute the **optimal swap amount** on-chain so almost nothing is left over after adding liquidity. | P0 |
| FR-ZP-4 | Enforce `minLPOut` slippage protection. | P0 |
| FR-ZP-5 | Return any leftover dust (both tokens) to the user. | P0 |
| FR-ZP-6 | **Zap out:** user sends LP tokens, contract removes liquidity and swaps everything into ONE chosen token (or ETH). | P0 |
| FR-ZP-7 | Enforce `minAmountOut` on zap out. | P0 |
| FR-ZP-8 | Reject pairs that do not exist or have zero liquidity. | P0 |
| FR-ZP-9 | Support deadline checks and emit `ZappedIn` / `ZappedOut` events. | P1 |
| FR-ZP-10 | Contract holds no user funds after any call completes. | P0 |

### 5.3 LPVault

| ID | Requirement | Priority |
| --- | --- | --- |
| FR-VT-1 | Vault is bound to ONE V2 pair (e.g. USDC/WETH) and ONE deposit token (e.g. USDC). | P0 |
| FR-VT-2 | `deposit(assets)`: zaps the token into LP tokens, mints shares to the user. | P0 |
| FR-VT-3 | `withdraw` / `redeem`: burns shares, removes liquidity, zaps out to the deposit token. | P0 |
| FR-VT-4 | Share price = value of vault LP holdings ÷ total shares; it rises as pool fees accrue. | P0 |
| FR-VT-5 | Follow the ERC-4626 interface (`totalAssets`, `convertToShares`, `previewDeposit`, etc.). | P1 |
| FR-VT-6 | **Inflation / first-depositor attack** protection (virtual shares or dead shares). | P0 |
| FR-VT-7 | Valuation of LP tokens must NOT use manipulable spot price (use fair-reserves math or TWAP). | P0 |
| FR-VT-8 | User-supplied slippage on deposit and withdraw. | P0 |
| FR-VT-9 | Owner can pause deposits (withdrawals stay open). | P1 |

### 5.4 FlashSwap

| ID | Requirement | Priority |
| --- | --- | --- |
| FR-FS-1 | Initiate a flash swap by calling `pair.swap` with non-empty `data`. | P0 |
| FR-FS-2 | Implement `uniswapV2Call` and compute exact repayment including the 0.3% fee. | P0 |
| FR-FS-3 | **Verify** `msg.sender` is the real V2 pair (derived from Factory) and `sender` is this contract. | P0 |
| FR-FS-4 | Revert the whole transaction if repayment is impossible. | P0 |
| FR-FS-5 | Include one simple, working use case (e.g. arbitrage vs a Sushiswap pair on the fork, or self-liquidation style demo). | P1 |

### 5.5 Security Lab (test-only contracts)

| ID | Attack demo | What it shows | Priority |
| --- | --- | --- | --- |
| FR-SL-1 | **Spot-price oracle manipulation** | `VulnerableLender` values collateral using V2 spot price. A flash swap inflates the price and the attacker borrows far more than allowed. | P0 |
| FR-SL-2 | **TWAP fix** | Same lender with a TWAP oracle; the same attack fails. | P0 |
| FR-SL-3 | **Sandwich attack** | A swap with `amountOutMin = 0` gets sandwiched; the victim's loss is measured. Compare with a properly-protected swap. | P0 |
| FR-SL-4 | **Unsafe flash callback** | A callback that does not verify the caller is drained; the fixed version blocks it. | P1 |
| FR-SL-5 | **LP vault inflation attack** (if time) | Show the first-depositor attack and the virtual-shares fix. | P2 |

Each demo must be documented as: **Attack → Root cause → Exploit → Fix → Test**.

---

## 6. Non-Functional Requirements

### 6.1 Security

- **NFR-S1.** Reentrancy protection on every external entry point that moves funds.
- **NFR-S2.** No unlimited approvals left lingering; approve exact amounts or reset to zero after use.
- **NFR-S3.** Zero user funds held by Zap, SwapExecutor or FlashSwap between transactions.
- **NFR-S4.** All external calls follow checks-effects-interactions.
- **NFR-S5.** No reliance on `tx.origin`, spot price or `block.timestamp` for anything critical beyond deadlines.
- **NFR-S6.** Router and Factory addresses are immutable, set in the constructor.
- **NFR-S7.** Static analysis (Slither) has no unresolved high or medium findings.

### 6.2 Correctness and Testing

- **NFR-T1.** All tests run against a **mainnet fork** (pinned block number for reproducibility).
- **NFR-T2.** Line coverage ≥ 95% and branch coverage ≥ 85% on the 4 core contracts.
- **NFR-T3.** Every functional requirement maps to at least one test.
- **NFR-T4.** Fuzz tests on swap, zap in and zap out.
- **NFR-T5.** Invariant tests on the vault (e.g. total assets ≥ sum of user claims; contracts hold no stray funds).
- **NFR-T6.** Failure paths tested: expired deadline, bad path, zero amounts, slippage breach, non-existent pair.

### 6.3 Gas and Efficiency

- **NFR-G1.** Gas snapshots recorded with `forge snapshot` for main flows.
- **NFR-G2.** Zap overhead vs manual swap + addLiquidity documented (not required to beat it, only to understand it).

### 6.4 Code Quality

- **NFR-C1.** Solidity 0.8.x, custom errors, NatSpec on all external functions.
- **NFR-C2.** Interfaces separated from implementations; small, readable functions.
- **NFR-C3.** `forge fmt` clean; consistent naming.
- **NFR-C4.** OpenZeppelin used for ERC20/ERC4626, SafeERC20, Ownable, Pausable, ReentrancyGuard.

### 6.5 Documentation

- **NFR-D1.** README with architecture diagram, how to run fork tests and the attack write-ups.
- **NFR-D2.** Each contract has a spec section; each attack has a written analysis.

---

## 7. Assumptions and Constraints

| Item | Decision |
| --- | --- |
| **Network** | Ethereum **mainnet fork** via Anvil/Foundry. No testnet (V2 testnet pools are empty). |
| **RPC** | Free-tier Alchemy/Infura key; fork pinned to a fixed block for repeatable tests. |
| **V2 addresses** | Router02, Factory and WETH on mainnet. **Verify every address on Etherscan before use**, never trust memory. |
| **Tokens used** | USDC, WETH, DAI, USDT (to test the non-standard `approve` return), plus one fee-on-transfer token if time allows. |
| **Toolchain** | Foundry, Solidity 0.8.x, OpenZeppelin, Slither. |
| **Developer context** | Solo, part-time, about 4 weeks. Strong in Foundry fuzz/invariant testing; V2 knowledge needs a refresher (Stage 0). |
| **Deployment** | Fork only. Optional: deploy to Sepolia purely to show deployment scripts work. No real funds. |

---

## 8. Definition of Done

The project is complete when **all** are true:

- [ ] All P0 requirements implemented and tested.
- [ ] Coverage targets (NFR-T2) met; `forge test --fork-url ...` passes from a clean clone.
- [ ] At least 3 security-lab attacks demonstrated with fixes (FR-SL-1, 2, 3 at minimum).
- [ ] Slither run with no unresolved high/medium issues.
- [ ] README includes: pitch, architecture diagram, setup instructions, test results and the attack write-ups.
- [ ] I can explain, without notes: the 997/1000 fee math, how a flash swap enforces repayment, how the optimal zap amount is derived and why spot price is a bad oracle.

The last item is the real measure of whether the project achieved its learning goal.

---

## 9. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Scope creep (adding frontend, bots, dashboards) | High | High | Non-goals list in section 2.2. Stages are independently shippable. |
| Zap optimal-amount math is hard | Medium | Medium | Derive on paper first; test against a brute-force search in fuzz tests. |
| Forgot V2 internals | High | Medium | Stage 0 refresher with manual `getAmountOut` vs Router assertions. |
| Fork RPC rate limits or flaky tests | Medium | Low | Pin block number; use Foundry's fork cache. |
| Vault valuation bugs (LP pricing) | Medium | High | Use fair-reserves LP pricing; invariant tests; document known limits. |
| Losing motivation | Medium | High | Short stages, each ending with something visibly working. |

---

## 10. Glossary

| Term | Plain-English meaning |
| --- | --- |
| **Factory** | Contract that creates and lists all V2 pairs. |
| **Pair** | The pool contract for two tokens; holds reserves and mints LP tokens. |
| **Router** | Helper contract users call; handles paths, deadlines and safety checks on top of Pairs. |
| **LP token** | Receipt token proving your share of a pool. |
| **Reserves** | Amount of each token currently in the pool. |
| **x · y = k** | The V2 pricing rule: reserves multiplied together must not decrease after a swap. |
| **Slippage** | Difference between the quoted price and the price you actually get. |
| **Zap** | One-click flow: single token in, LP position out (or reverse). |
| **Flash swap** | Borrow tokens from a pair, use them, and repay (plus fee) in the same transaction. |
| **Spot price** | Current price implied by reserves; cheap to manipulate within one transaction. |
| **TWAP** | Time-weighted average price; much harder to manipulate. |
| **Sandwich attack** | Attacker trades before and after your swap to profit from your slippage. |

---

## 11. Deliverables

1. `contracts/src/`: SwapExecutor, Zap, LPVault, FlashSwap
2. `contracts/test/`: unit, fuzz, invariant and fork tests
3. `contracts/test/attacks/`: security lab (vulnerable + fixed versions)
4. `docs/`: this PRD, architecture, contract specs, threat model, testing strategy, roadmap
5. `README.md`: the portfolio-facing summary

---

**Next document:** Technical Architecture and Tech Stack (components, call-flow diagrams, repo structure, fork setup).