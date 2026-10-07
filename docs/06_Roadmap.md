# V2 Zap & Vault: Roadmap

**Version:** 1.0 | **Depends on:** all previous docs | **This is the doc you work from day to day.**

---

## 1. Overview

**Total effort:** about 60 to 70 focused hours. At 2 hours per weekday plus a longer weekend session (\~14 to 16 h/week), that is **4 weeks plus a 1-week buffer.**

```text
Day 0   Setup
Stage 0 Refresher            (3 days)   learn V2 by asserting on it
Stage 1 SwapExecutor         (4 days)   + sandwich attack
Stage 2 Zap                  (6 days)   the hardest math
Stage 3 TwapOracle + Vault   (7 days)   + oracle attack + inflation attack
Stage 4 FlashSwap            (4 days)   + unsafe-callback attack
Stage 5 Polish and publish   (4 days)   README, CI, resume
Buffer                       (5 days)
```

### Why this order

- **Each stage ends with something working and demonstrable.** You can stop after any stage and still own a presentable repo.
- **Dependencies are respected.** The Vault needs the Zap and the Oracle; the oracle attack needs the Oracle and a flash swap source; so those come later.
- **Each attack is built right after the contract it targets,** while the contract's details are fresh. The attack teaches you why the contract is written the way it is.
- **Difficulty rises gradually:** wrapper → math → accounting and oracle → callbacks.

---

## 2. Day 0: Setup (2 to 3 hours)

- [Done] `forge init v2-zap-vault`; remove the default Counter files.
- [Done] Install: `forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts`; add `remappings.txt`.
- [Done] Create the folder structure from the architecture doc (§8), with empty placeholder files.
- [Done] Set `foundry.toml` (solc 0.8.24, optimizer, fuzz/invariant profiles, `ci` profile).
- [Done] Get an RPC key; create `.env` and `.env.example`; **pick and write down `FORK_BLOCK`**; add `.env` to `.gitignore`.
- [Done] Write `Constants.sol` and **verify every address on Etherscan.**
- [Done] Write `ForkBase.t.sol` (doc 05, §3.1).
- [Done] Smoke test: one test that forks and reads `USDC/WETH` reserves.
- [Done] Copy the 6 docs into `docs/`. Initial commit. Create the GitHub repo.
- [ ] Add a minimal CI workflow (fmt + build + the smoke test). Add the RPC secret.

**Exit:** `forge test` passes locally and in CI on a fork.

---

## 3. Stage 0: V2 Refresher (3 days, \~8 h)

**Goal:** rebuild your V2 mental model by writing tests. No production contracts yet.

| Day | Tasks | Tests (doc 05, §10) |
| --- | --- | --- |
| 1 | Factory, pair address, `token0/token1`, reserves, spot price with decimals. Manual `getAmountOut` vs Router. | R-T01, R-T02, R-T03 |
| 2 | Real swap and `k` check. Price impact at several sizes. Add and remove liquidity on a fresh pair, first-mint formula. | R-T04, R-T05, R-T06, R-T07 |
| 3 | Tiny flash swap: repay exactly, then 1 wei short. `sync` and cumulative price, hand-computed TWAP. | R-T08, R-T09 |

**Study alongside (read, don't binge):** the V2 `UniswapV2Pair.swap` function and the `getAmountOut` / `getAmountIn` functions in the V2 library. Read them *after* the matching test, to confirm what you observed.

**Exit gate:**

- [ ] R-T01 to R-T09 pass.
- [ ] You can explain out loud, without notes: the 997/1000 fee, why `k` grows with each swap, and why repaying 1 wei short reverts a flash swap.

*If you can't explain them, repeat day 2 or 3. This gate is the point of Stage 0.*

---

## 4. Stage 1: SwapExecutor (4 days, \~10 h)

**Covers:** FR-SW-1 to 10 · **Spec:** doc 03 §1, §2 · **Tests:** SW-T01 to T14, SW-F01 to F03

| Day | Tasks |
| --- | --- |
| 1 | Interfaces (`src/interfaces/`). `V2Library` (`sortTokens`, `getAmountOut`, `getAmountIn`, `getReservesSorted`) with differential test against the Router. |
| 2 | `SwapExecutor`: `swapExactIn`, path validation, balance-delta pull, approval hygiene. Tests SW-T01, T02, T04, T07, T08, T10, T14. |
| 3 | `swapExactOut` with refund; ETH variants and `receive()`; USDT test; pause and rescue. Tests SW-T03, T05, T06, T09, T11, T12, T13. |
| 4 | Fuzz tests SW-F01 to F03. **Attack 02 (sandwich)** from doc 04, with and without `minOut`. Coverage and Slither pass. |

**Deliverables:** `SwapExecutor.sol`, `V2Library.sol`, interfaces, `01`-style attack file `02_SandwichNoSlippage.t.sol`.

**Exit gate:**

- [ ] All SW tests green; coverage ≥ 95% line on this contract.
- [ ] Executor balances are zero after every fuzz run.
- [ ] Sandwich test prints victim loss with `minOut = 0` and shows it blocked with a tolerance.
- [ ] Commit tag: `stage-1-complete`.

---

## 5. Stage 2: Zap (6 days, \~14 h)

**Covers:** FR-ZP-1 to 10 · **Spec:** doc 03 §3 · **Tests:** ZP-T01 to T14, ZP-F01 to F03

| Day | Tasks |
| --- | --- |
| 1 | **Derive the zap formula on paper** (swap `s`, add `a − s`, match the new ratio). Implement `ZapMath`. Test ZP-T04 (vs brute force) and overflow bounds ZP-F03. |
| 2 | Pair validation helper. `zapIn` for token input. Tests ZP-T01, T02, T08, T09, T10. |
| 3 | Dust refund, `minLpOut`, deadline, events. Tests ZP-T11, T12. |
| 4 | `zapInETH`; `zapOut` and `zapOutETH`. Tests ZP-T03, T05, T06, T07. |
| 5 | Multi-pair fuzz (ZP-F01, F02); USDT pair test ZP-T14. |
| 6 | **Zap sandwich test ZP-T13** (feeds the README). Coverage, Slither, gas snapshot, and the zap-vs-manual gas comparison (NFR-G2). |

**Hard-part warning:** the optimal-swap math is where people stall. Budget day 1 fully for it, and do not skip the brute-force differential test; it is your proof the formula is right.

**Exit gate:**

- [ ] All ZP tests green; coverage targets met.
- [ ] Dust ratio fuzz bound holds (I-ZP-3).
- [ ] You can derive or at least explain why the swap amount is not simply half.
- [ ] Commit tag: `stage-2-complete`.

---

## 6. Stage 3: TwapOracle and LPVault (7 days, \~18 h)

**Covers:** FR-VT-1 to 9, FR-SL-1, 2, 5 · **Spec:** doc 03 §4, §5, §7 · **Tests:** OR-T01 to T10, OR-F01, VT-T01 to T13, VT-I01 to I06, VT-F01

This is the longest stage; it is split into three parts so you always have a working piece.

### Part A: TwapOracle (days 1 to 2)

| Day | Tasks |
| --- | --- |
| 1 | `currentCumulativePrices` (with the counterfactual term), ring buffer, `update`. Tests OR-T04, T05, T09. |
| 2 | `consult` with `MIN_WINDOW`, `MAX_AGE`, direction handling. Tests OR-T01 to T03, T06, T08, OR-F01. |

### Part B: Oracle attack (day 3)

- Create the thin `COL/USDC` pair; write `VulnerableLender` and `FixedLender`.
- **Attack 01** per doc 04 (flash-swap capital from the deep pair, manipulate the thin pair, borrow, repay).
- Print spot vs TWAP, profit and bad debt. Show the fixed lender resists.
- Test OR-T07 (sustained manipulation) to document the residual risk.

### Part C: LPVault (days 4 to 7)

| Day | Tasks |
| --- | --- |
| 4 | Constructor checks, `totalAssets()` with fair-reserves + TWAP. Test the valuation in isolation, including VT-T07 against a 30% manipulation. |
| 5 | Value-based `deposit` + `depositWithMin`; offset 6; unsupported `withdraw` / `mint`. Tests VT-T01, T02, T08, T10, T11. |
| 6 | `redeem` + `redeemWithMin`; pause on deposits only. Tests VT-T03, T04, T09, T12. |
| 7 | Handler and invariant suite VT-I01 to I06, fuzz VT-F01. **Attack 04 (inflation)**: naive vs fixed, VT-T05, T06. |

**Exit gate:**

- [ ] OR and VT suites green; invariants hold at CI settings (1000 runs, depth 100).
- [ ] Oracle attack: vulnerable lender drained, fixed lender safe, numbers printed.
- [ ] Inflation attack: naive vault loses, fixed vault protected.
- [ ] You can explain "why mint on value added, not on assets deposited" and "why fair-reserves valuation."
- [ ] Commit tag: `stage-3-complete`.

**Likely trouble:** the oracle's warm-up in tests (you must `warp` and `update` before consulting); LP valuation decimals (use the `consult(pair, O, rO)` trick from the spec to avoid scaling bugs).

---

## 7. Stage 4: FlashSwap (4 days, \~10 h)

**Covers:** FR-FS-1 to 5, FR-SL-4 · **Spec:** doc 03 §6 · **Tests:** FS-T01 to T10, FS-F01

| Day | Tasks |
| --- | --- |
| 1 | Repay math with `getAmountIn`; `executeArb` borrow flow; `_activePair` handling. Test FS-T02. |
| 2 | `uniswapV2Call`: caller, initiator, decode, sell on Sushi, repay, forward profit. Test FS-T01 with an engineered price gap. |
| 3 | Failure paths and checks: FS-T03 to T10. Fuzz FS-F01. |
| 4 | **Attack 03 (unsafe callback)**: `NaiveFlashReceiver` and `Drainer`, variants A and B; confirm the real contract reverts both (FS-T05 to T07). |

**Exit gate:**

- [ ] All FS tests green; k never decreases after a flash swap (I-FS-4).
- [ ] Both callback attack variants succeed against the naive receiver and fail against `FlashSwap`.
- [ ] Commit tag: `stage-4-complete`.

---

## 8. Stage 5: Polish and Publish (4 days, \~10 h)

| Day | Tasks |
| --- | --- |
| 1 | Full verification run: coverage report, Slither with triage file, fuzz and invariants at CI settings, gas snapshot. Fix gaps. |
| 2 | **README**: pitch, architecture diagram, setup and run instructions, test summary (coverage and results), gas notes, limitations (doc 04 §7). |
| 3 | **Attack write-ups** in README using the template (doc 04 §9), pasting the *real* numbers from your tests. Add a short "How to run each attack" section. |
| 4 | Optional deploy script to a local fork or Sepolia as a demo. Final CI green. Tag `v1.0`. Update resume and portfolio. Write a short post (LinkedIn or X). |

**Final exit gate = PRD Definition of Done (doc 01, §8):**

- [ ] All P0 requirements implemented and tested.
- [ ] Coverage targets met; clean-clone `forge test` passes with the documented env vars.
- [ ] At least attacks 01, 02, 03 shown with fixes (04 also, if done).
- [ ] Slither has no unresolved high/medium.
- [ ] README complete.
- [ ] You can answer the interview questions in §10 without notes.

---

## 9. Scope-Cut Ladder (if you fall behind)

Cut from the **top** of this list first. Never cut the bottom rows.

| Order | Cut | Impact |
| --- | --- | --- |
| 1 | Stretch goals (mutation testing, Halmos, gas comparison table) | None to the core |
| 2 | Fee-on-transfer mock tests, ERC-777 hook test | Slightly fewer edge cases |
| 3 | Sepolia deployment and demo script | Fine; fork-only is acceptable |
| 4 | `swapExactInForETH` / ETH variants beyond one direction; `zapOutETH` | Smaller API |
| 5 | Attack 04 (vault inflation) | Keep the vault's offset code; skip the PoC |
| 6 | Optional features in SwapExecutor (`quoteExactOut`, pair pre-check) | Minor |
| **Never cut** | Zap (including `zapOut`), TwapOracle, fair-reserves valuation, flash swap callback checks, attacks 01 to 03 | These are the portfolio |

**Rule:** if a stage runs more than **50% over its estimate,** stop and apply the ladder before starting the next stage.

---

## 10. Interview Readiness: Questions You Should Be Able to Answer

Practise these at each stage's end; they match what a client or reviewer will ask.

1. Walk me through `swapExactTokensForTokens` from Router to Pair. Where is the fee applied?
2. Why does `k` increase after a swap? Who benefits?
3. What is `getAmountOut` and why 997/1000?
4. Why can't a zap swap exactly half? Explain the optimal swap amount idea.
5. What does a flash swap enforce, and in which tokens can you repay?
6. Why is the V2 spot price a bad oracle? How does a TWAP fix it, and what can still go wrong?
7. Why must a callback check both `msg.sender` and `sender`?
8. What is a sandwich attack, and what exactly does `amountOutMin` do about it?
9. What is the first-depositor inflation attack, and how do virtual shares stop it?
10. Why mint vault shares based on value added instead of assets deposited?
11. How do you handle USDT-style tokens, ETH vs WETH, and leftover approvals?
12. What would change if the client wanted V3 or V4 instead? (Concentrated liquidity and ticks; NFT positions in V3; hooks and the singleton PoolManager in V4. You touched V4 at Pedals Up, so connect the two.)

---

## 11. Working Rhythm and Rules

**Daily loop (about 2 hours):** read spec section (10 min) → write or extend the tests (40 min) → implement (50 min) → run the suite, commit (20 min).

**Rules**

1. **Tests before code,** straight from the spec test IDs.
2. **One feature per commit.** Use messages like `feat(zap): add zapIn with dust refund` and `test(zap): ZP-T13 sandwich`.
3. **Never leave `master` red.** Work on a branch per stage; merge after the exit gate.
4. **Stuck for 45 minutes?** Run with `-vvvv`, read the trace, write a smaller failing test. If still stuck after another 30 minutes, ask for help with the trace and the test.
5. **Update docs when you deviate.** If implementation changes a spec, fix the spec doc the same day. Reviewers read both.
6. **Write the README as you go,** one paragraph per finished stage. Otherwise Stage 5 becomes a mountain.

---

## 12. Master Checklist

- [ ] Day 0: setup, CI smoke test green
- [ ] Stage 0: R-T01 to R-T09, explanation gate passed
- [ ] Stage 1: SwapExecutor + sandwich attack
- [ ] Stage 2: Zap
- [ ] Stage 3A: TwapOracle
- [ ] Stage 3B: Oracle attack (attack 01)
- [ ] Stage 3C: LPVault + inflation attack (attack 04)
- [ ] Stage 4: FlashSwap + callback attack (attack 03)
- [ ] Stage 5: verification, README, write-ups, `v1.0` tag
- [ ] Resume bullet added; portfolio site updated; post published

---

## 13. After v1.0: Where This Leads

- **Add a V3 or V4 module** (a position-manager or hook-based integration) as a second repo or a `src/v3/` folder. The V2 base makes this much faster.
- **Pair it with ClearSwap:** the sandwich demo here plus your MEV-resistant batch-auction DEX tells a coherent story: *attack on V2, mitigation in ClearSwap*.
- **Use it in client conversations:** "I've built and tested Uniswap integrations against real mainnet state, including known attack patterns."

**Suggested resume bullet:**

> *Built Uniswap V2 integration contracts (swap executor, single-sided zap, ERC-4626 LP vault with TWAP/fair-reserves valuation, flash-swap executor), tested on a mainnet fork with fuzz and invariant suites; authored exploit PoCs for spot-oracle manipulation, sandwich, unsafe flash callbacks and vault inflation, with mitigations.*

---

**This completes the documentation set (01 to 06). Next step: Day 0 setup and Stage 0.**
