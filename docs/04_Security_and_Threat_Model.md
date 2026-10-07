# V2 Zap & Vault: Security and Threat Model

**Version:** 1.0 | **Depends on:** 01-PRD, 02-Architecture, 03-Contract Specs | **Feeds:** 05-Testing, README

**Purpose of this doc.** (1) State what we trust and what we don't. (2) List the threats per contract and where each is mitigated. (3) Write out each security-lab attack in full: **Attack → Root cause → Exploit → Fix → Test**. These write-ups become the best part of your README.

---

## 1. Security Goals

| # | Goal |
| --- | --- |
| SG-1 | No user can lose funds because of a bug in our integration code, beyond slippage they explicitly chose. |
| SG-2 | Our contracts hold **no user funds** between transactions (except the Vault's LP tokens, which back shares). |
| SG-3 | No price used for valuation can be moved by a single transaction. |
| SG-4 | Every external callback verifies who is calling and who started the call. |
| SG-5 | The owner can never take user funds. Owner powers are `pause` and `rescue` only. |

---

## 2. Trust Model

### 2.1 What we trust

| Component | Why |
| --- | --- |
| Uniswap V2 Factory, Pair, Router02 | Deployed, battle-tested, immutable. We assume they behave as documented. |
| WETH9 | Canonical, simple. |
| OpenZeppelin v5 | Audited library. |
| Chain finality / EVM semantics | Standard assumption. |

### 2.2 What we do NOT trust

| Component | Why |
| --- | --- |
| **Pool reserves as a price** | One transaction can move them arbitrarily far. |
| **Any caller of a callback** | Anyone can call `uniswapV2Call` directly. |
| **The `sender`/`data` fields of a callback** | Attacker-chosen unless verified. |
| **ERC-20 tokens** | They can lack return values (USDT), charge transfer fees, rebase, or have hooks (ERC-777). |
| **Block builders / mempool observers** | They can reorder, insert and censor transactions (MEV). |
| **Other users' deposits and donations** | Anyone can send tokens directly to our contracts. |
| **Oracle freshness** | A TWAP can be stale or have no history. |

### 2.3 Attacker capabilities (the "adversary model")

The attacker can: call any external function with any arguments; deploy contracts; **borrow unlimited capital for one transaction** (flash loans and flash swaps); reorder transactions around a victim's (sandwich); send tokens directly to any address; and wait across blocks. The attacker **cannot**: break cryptography, change V2 core code, or steal the owner key.

---

## 3. Assets and Entry Points

| Asset | Where it lives | Main risk |
| --- | --- | --- |
| User tokens in flight | SwapExecutor, Zap (during a call only) | Stuck funds, wrong recipient, over-approval |
| Vault LP tokens | LPVault | Mispricing, share inflation, drained by bad redeem logic |
| Borrowed tokens in flash swap | FlashSwap (during a call only) | Unauthorised callback, unprofitable execution |
| Oracle price history | TwapOracle | Manipulation, staleness |
| Admin keys | Owner | Pause abuse (low impact by design) |

---

## 4. Threat Catalogue

Severity = impact if exploited. **Test** column links to the specs doc.

| ID | Component | Threat | Sev. | Mitigation | Test |
| --- | --- | --- | --- | --- | --- |
| T-01 | SwapExecutor | Sandwich because `minOut = 0` or too loose | High | Require caller-supplied `minOut`; document how to compute it; deadline | SW-T08, attack 02 |
| T-02 | SwapExecutor | Output sent to the executor itself (funds parked) | Med | Reject `to == address(this)` | SW-T10 |
| T-03 | SwapExecutor | USDT-style `approve`/`transfer` without return value reverts or silently fails | Med | `SafeERC20`, `forceApprove` | SW-T06, ZP-T14 |
| T-04 | SwapExecutor | Leftover allowance to Router after call | Med | Reset approval to 0 | SW-T14 |
| T-05 | SwapExecutor / Zap | Reentrancy through token hooks (ERC-777 style) | High | `nonReentrant`, CEI | unit test with hook token |
| T-06 | SwapExecutor / Zap | ETH sent directly and trapped | Low | `receive()` only accepts WETH | SW-T12 |
| T-07 | Zap | Sandwich of the zap's internal swap | High | Final `minLpOut`; docs tell caller to derive it from TWAP/fair value | ZP-T13 |
| T-08 | Zap | Fake pair address supplied by caller | High | Validate `factory.getPair(t0,t1) == pair` | ZP-T08 |
| T-09 | Zap | Dust left in contract grows or is stolen | Low | Refund dust every call; stateless invariant | ZP-F01 |
| T-10 | Zap | Overflow in `optimalSwapAmount` for huge inputs | Med | Bounds test; `mulDiv` if needed | ZP-F03 |
| T-11 | Zap | Fee-on-transfer token gives wrong amounts | Med | Balance-delta accounting; FoT *path* tokens documented as unsupported | ZP-T (optional FoT mock) |
| T-12 | TwapOracle | Same-block spot manipulation moves price | High | Windowed TWAP; same-block moves get zero weight | OR-T06 |
| T-13 | TwapOracle | No history or stale data used as valid | High | `InsufficientHistory`, `StaleOracle` reverts | OR-T02, OR-T03 |
| T-14 | TwapOracle | **Multi-block manipulation** of a thin pool | Med | Longer window, deep pools only, documented limit | OR-T07 |
| T-15 | LPVault | Spot-based LP valuation (the classic LP-collateral bug) | High | Fair-reserves + TWAP valuation | VT-T07 |
| T-16 | LPVault | **First-depositor inflation / donation attack** | High | Virtual shares offset 6, value-based minting, `shares > 0` check | VT-T05 |
| T-17 | LPVault | Existing holders absorb zap cost of new depositors | High | Mint on **value added**, not asset amount | VT-T02 |
| T-18 | LPVault | Withdrawals blocked by pause or owner | Med | Pause affects deposits only | VT-T09 |
| T-19 | LPVault | Rounding drains value over many small actions | Med | Round in the vault's favour; invariants I-VT-1/2 | VT-I01, VT-I02 |
| T-20 | LPVault | Owner rescue takes LP tokens | High | Rescue excludes the LP token and share-backing assets | unit test |
| T-21 | FlashSwap | Callback called directly by anyone | High | `msg.sender == _activePair` and factory cross-check | FS-T05, FS-T06 |
| T-22 | FlashSwap | Real pair, but flash swap started by attacker | High | `sender == address(this)` | FS-T07 |
| T-23 | FlashSwap | Repayment under-calculated, tx reverts or leaves bad state | Med | Use `getAmountIn` math; compare with Router | FS-T02 |
| T-24 | FlashSwap | Unprofitable run costs gas for nothing | Low | `minProfit` check reverts | FS-T03, FS-T04 |
| T-25 | All | Owner key compromise | Low | Owner can only pause/rescue; stateless contracts hold nothing | access-control tests |

---

## 5. Attack Write-Ups (Security Lab)

Numbers below are **illustrative**. Your fork tests will print the exact values; paste those into the README.

### Attack 1: Spot-Price Oracle Manipulation (lab test `01_SpotOracleManipulation`)

**Attack.** An attacker drains a lending contract that values collateral using the current V2 spot price.

**Root cause.** `VulnerableLender` computes `price = reserveUSDC / reserveCOL` straight from `getReserves()`. Reserves are the *current state*, and anyone can change them with a large swap in the same transaction.

**Setup (on the fork).**

- Create a thin pair on the real Factory: mock token `COL` / USDC, seeded with 10,000 COL and 100,000 USDC (spot price 10 USDC).
- `VulnerableLender` holds 1,000,000 USDC of lendable liquidity and lends at 75% LTV against COL valued at spot.

**Exploit (one transaction).**

1. Attacker needs capital, so they flash-swap **400,000 USDC from a different, deep pair** (the real USDC/WETH pair). They cannot borrow from the thin pair itself, because the pair's re-entrancy lock blocks a swap on the same pair inside its own callback, and reserves are not updated until the callback ends.
2. Swap 400,000 USDC for COL on the thin pair. Reserves become about 498,800 USDC / 2,005 COL, so spot price is about **249 USDC per COL** (roughly 25× fair). Attacker receives about 7,995 COL.
3. Deposit the 7,995 COL to `VulnerableLender`. At the inflated price the collateral looks like about 1.99M USDC, so the 75% limit is about 1.49M. Borrow the lender's whole 1,000,000 USDC.
4. Repay the flash swap: `400,000 × 1000 / 997 + 1 ≈ 401,205 USDC`.
5. **Profit ≈ 598,795 USDC.** The lender is left holding COL worth far less than the loan (bad debt).

**Fix.** `FixedLender` values collateral with `TwapOracle.consult(pair, COL, amount)`. A swap in the current block receives **zero weight** in the average, because V2's cumulative price updates with the *previous* price. The TWAP cannot move within the attack transaction.

**Test assertions.**

- Vulnerable: attacker USDC balance increases by > 500k; lender USDC balance ≈ 0; `positionOf` shows debt > collateral value at fair price.
- Fixed: the same attack sequence either reverts at `borrow` (limit too low) or leaves attacker net negative after repaying the flash swap.
- Print: spot price before/after, TWAP before/after, attacker profit.

**Lessons for the README.** Spot price is not a price, it is a state variable. A TWAP stops same-block attacks but not sustained ones (see T-14), so production systems also use deep pools or Chainlink.

---

### Attack 2: Sandwich on a Swap Without Slippage Protection (lab test `02_SandwichNoSlippage`)

**Attack.** A searcher inserts one trade before and one after the victim's swap and keeps the difference.

**Root cause.** The victim's call has `minOut = 0` (or a very loose one), so the contract accepts any price.

**Exploit (ordered in one block).**

1. Victim submits `swapExactIn(USDC → WETH, 100,000 USDC, minOut = 0)`.
2. **Front-run:** attacker buys WETH with USDC, pushing the price against the victim.
3. **Victim's swap executes** at the worse price and receives less WETH than a fair quote.
4. **Back-run:** attacker sells the WETH back at the higher price and keeps the USDC difference, minus 2 × 0.3% fees and gas.

**Fix.**

- Caller computes `minOut = fairQuote × (1 − tolerance)` (e.g. 0.5%), where `fairQuote` comes from `quoteExactIn` **taken from a trusted/earlier state**, not read in the same transaction.
- If the attacker must move the price more than the tolerance to profit, the victim's transaction reverts; the profitable window shrinks to about `tolerance − fees`.
- Off-chain complement: private transaction relays (e.g. Flashbots Protect) so the swap never appears in the public mempool.

**Test assertions.**

- With `minOut = 0`: attacker profit > 0 and victim's WETH out is lower than the fair quote by a measurable percentage. Print both.
- With `minOut = fair × 0.995`: either victim reverts, or attacker profit ≤ 0 after fees.
- Bonus: sweep front-run sizes in a fuzz test and show the profit curve is bounded by tolerance.

**Lessons.** Slippage tolerance is a price you charge the attacker. Too loose = free money for them.

---

### Attack 3: Unsafe Flash-Swap Callback (lab test `03_UnsafeFlashCallback`)

**Attack.** An attacker drains a contract whose `uniswapV2Call` trusts its arguments.

**Root cause.** `NaiveFlashReceiver` holds a treasury (e.g. 100 WETH) and its callback does:

```solidity
(address token, address payTo, uint256 amount) = abi.decode(data, (address, address, uint256));
IERC20(token).transfer(payTo, amount);   // assumes payTo is the pair
```

It never checks `msg.sender` (is this really the pair?) or `sender` (who started the flash swap?), and it takes the payee from `data`.

**Exploit variants.**

- **Variant A (direct call):** attacker calls `uniswapV2Call(...)` directly with `data = (WETH, attacker, 100e18)`. No pair is involved at all.
- **Variant B (real pair, hostile initiator):** attacker calls the real pair's `swap(..., to = receiver, data)` with crafted `data`. Now `msg.sender` is the real pair, so a lazy "is the caller a pair?" check passes, but the `sender` is the attacker.

**Fix** (`FlashSwap` as specced):

1. `require(msg.sender == _activePair)`, where `_activePair` is set only inside our own `executeArb`, and cross-check with `factory.getPair(token0, token1)`.
2. `require(sender == address(this))`.
3. Never decode a *payee* from `data`; repay to `msg.sender` (the verified pair).

**Test assertions.** Naive receiver: attacker ends with 100 WETH for both variants. Fixed contract: variant A reverts `UnauthorizedCaller`, variant B reverts `UnauthorizedSender`, and the treasury is intact.

**Lessons.** A callback is a public function that *looks* private. Verify both caller and initiator.

---

### Attack 4: Vault First-Depositor Inflation (lab test `04_VaultInflation`, recommended)

**Attack.** The first depositor steals a later depositor's funds by manipulating the share price.

**Root cause.** In a naive vault, `shares = assets × supply / totalAssets` rounds **down**. If an attacker makes `totalAssets` huge relative to `supply` (by donating tokens directly), a victim's shares round to zero or near zero while their assets are added to the vault.

**Exploit (naive vault with no offset).**

1. Attacker deposits the minimum so that `supply = 1` share.
2. Attacker **donates** a large amount of LP tokens directly to the vault (not via `deposit`). `totalAssets` jumps; `supply` is still 1.
3. Victim deposits value `V`, which is less than the donated amount. `shares = V × 1 / totalAssets` rounds to **0** (or less than they paid for).
4. Attacker redeems their 1 share and receives their own donation plus the victim's deposit.

**Fix** (in `LPVault`).

- OpenZeppelin virtual shares with `_decimalsOffset() = 6`: share math effectively uses `supply + 10^6` and `totalAssets + 1`, so the attacker would have to donate about a million times more to cause rounding to zero, which makes the attack cost far more than it returns.
- Revert if computed `shares == 0`.
- Optionally enforce a minimum first deposit.

**Test assertions.** Naive vault: victim loses ≥ 90% of deposit, attacker net positive. Fixed vault: victim's share value ≥ 99.9% of deposit; attacker net loss.

---

## 6. Integration Pitfalls Checklist

Use this as a code-review list before calling anything "done". Each line has bitten real projects.

| # | Pitfall | What to do |
| --- | --- | --- |
| 1 | Using `getReserves()` as a price in logic that moves money | TWAP or fair-reserves only |
| 2 | `amountOutMin = 0` in a user-facing path | Require a caller-supplied minimum |
| 3 | `deadline = block.timestamp` set inside the contract | Take the deadline from the caller; inside the contract it is always satisfied and protects nothing |
| 4 | Plain `IERC20.approve` / `transfer` | `SafeERC20` everywhere; `forceApprove` for USDT |
| 5 | Infinite approvals to the Router | Approve exact amount, reset to 0 |
| 6 | Trusting `token0 < token1` order from memory | Always sort or read `token0()`/`token1()` |
| 7 | Assuming equal decimals (USDC 6 vs WETH 18) | Never mix raw amounts across tokens without scaling |
| 8 | ETH vs WETH confusion; missing `receive()` | Explicit ETH functions; restrict `receive()` |
| 9 | Trusting a user-supplied pair or router address | Validate pair via Factory; routers immutable |
| 10 | Callbacks without caller and initiator checks | See Attack 3 |
| 11 | Using `balanceOf(this)` as accounting after anyone can donate | Use balance **deltas**, not absolute balances, for per-call accounting |
| 12 | Fee-on-transfer and rebasing tokens | Balance delta; document unsupported cases |
| 13 | Forgetting the 997/1000 fee in repayment math | Compare against Router quotes in tests |
| 14 | Rounding in the user's favour | Round against the caller in share math |
| 15 | `tx.origin` for auth | Never |
| 16 | Reentrancy through token hooks | `nonReentrant` + CEI |
| 17 | Treating `sync`/`skim` as harmless | Remember anyone can call them; reserves can be forced to match balances |
| 18 | Using `block.timestamp` for anything but deadlines and TWAP windows | Avoid |

---

## 7. Residual Risks and Known Limitations (state these honestly in the README)

1. **TWAP is not magic.** A well-funded attacker can hold a manipulated price over many blocks on a **thin** pool. Mitigation: deep pools, long windows, or Chainlink in production.
2. **Zap/Swap protection depends on the caller's `min` values.** If a UI sets them badly, the contract cannot help.
3. **Oracle needs keepers.** Someone must call `update`; the Vault cannot accept deposits until enough history exists.
4. **Unsupported tokens:** fee-on-transfer path tokens, rebasing tokens, tokens with blacklists/pausing can break flows.
5. **Not audited.** This is a portfolio project; no formal audit or formal verification.
6. **Vault deviates from strict ERC-4626** (`withdraw` and `mint` disabled; `previewDeposit` is an estimate).
7. **V2 protocol fee (`feeTo`) minting** can slightly change LP `totalSupply` between observations; effect is small and documented.

---

## 8. Security Verification Plan

| Activity | Tool | Pass condition |
| --- | --- | --- |
| Static analysis | Slither | No unresolved high/medium findings; lows triaged in `docs/slither-triage.md` |
| Fuzzing | Foundry fuzz (1,000+ runs, 10,000+ in CI profile) | No failures |
| Invariants | Foundry invariant suite | All six vault invariants + stateless invariants hold |
| Attack PoCs | `test/attacks/*` | Each vulnerable version is exploited; each fixed version resists |
| Manual review | Pitfalls checklist (section 6) | Every row ticked or justified |
| Access-control review | Role table | Owner can only `pause`/`rescue`; no function can move user funds to owner |

---

## 9. README Template for Each Attack

```text
### <Attack name>
**What happens:** two sentences, plain English.
**Root cause:** the exact line or assumption that is wrong.
**Exploit:** numbered steps with the numbers printed by the test.
**Fix:** the code change, with a diff snippet.
**Proof:** link to test file, and the command to run it.
**Residual risk:** what the fix does NOT cover.
```

---

**Next:** 05 Testing Strategy (in this same batch), then 06 Roadmap.