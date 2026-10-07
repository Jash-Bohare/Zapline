# V2 Zap & Vault: Testing Strategy

**Version:** 1.0 | **Depends on:** 02-Architecture, 03-Contract Specs, 04-Threat Model | **Feeds:** 06-Roadmap

**Purpose.** The per-contract test lists (SW-T01…, ZP-T01…, etc.) live in the specs doc. This doc covers everything **cross-cutting**: how the fork is set up, how to write each kind of test, targets, tooling, CI, and the Stage 0 refresher tests.

---

## 1. Principles

1. **Test on real state.** Every test runs on a pinned mainnet fork. No mock Uniswap.
2. **Spec first.** Write the test from its spec ID, watch it fail, then write the code.
3. **Assert behaviour, not implementation.** Check balances, reserves and events, not internal calls.
4. **Compare with ground truth.** When possible, assert equality with the Router's own answer (`getAmountsOut`, `getAmountsIn`). The Router is your oracle.
5. **Every failure path has a test.** For each custom error, one test triggers it.
6. **Attacks are tests too.** Each security-lab attack is a runnable test that prints numbers.
7. **Deterministic.** Pinned block, fixed seeds in CI, no dependence on current prices.

---

## 2. Test Types

| Type | Folder | Purpose | Style |
| --- | --- | --- | --- |
| Stage 0 refresher | `test/unit-fork/V2Refresher.t.sol` | Relearn V2 by asserting on it | Plain tests |
| Unit-on-fork | `test/unit-fork/` | Each function, success and failure paths | `test_…` |
| Fuzz | `test/fuzz/` | Stateless properties over random inputs | `testFuzz_…` |
| Invariant | `test/invariant/` | Stateful properties over random call sequences | `invariant_…` + handlers |
| Attack PoCs | `test/attacks/` | Exploit vulnerable version, show fixed version resists | `test_Attack_…`, `test_Fixed_…` |
| Gas | whole suite | Regression tracking | `forge snapshot` |
| Static analysis | n/a | Catch classes of bug automatically | Slither |

"Unit" here means one function tested in isolation, but against real V2 contracts. There are no pure mocks of V2.

---

## 3. Fork Infrastructure

### 3.1 `Constants.sol` and `ForkBase.t.sol`

```solidity
abstract contract ForkBase is Test {
    IUniswapV2Factory  factory = IUniswapV2Factory(Constants.V2_FACTORY);
    IUniswapV2Router02 router  = IUniswapV2Router02(Constants.V2_ROUTER);
    IERC20 usdc = IERC20(Constants.USDC);
    IERC20 weth = IERC20(Constants.WETH);
    // dai, usdt similarly

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address attacker = makeAddr("attacker");
    address owner = makeAddr("owner");

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        vm.label(address(router), "V2Router"); // labels make traces readable
        // label factory, tokens, pairs
    }

    function fund(address who, IERC20 token, uint256 amount) internal { deal(address(token), who, amount); }
    function pairOf(address a, address b) internal view returns (IUniswapV2Pair) {
        return IUniswapV2Pair(factory.getPair(a, b));
    }
}
```

### 3.2 Rules

- **Pin the block** via `FORK_BLOCK` in `.env` and CI. Never test against "latest".
- **Fork cache** is automatic for pinned blocks; commit nothing from it, but keep it on your machine to avoid rate limits.
- **`deal` and USDT/USDC:** if `deal` fails on a token with unusual storage, use `deal(token, who, amount, true)` (adjusts total supply) or `vm.prank` a known whale. Wrap this in `fund`.
- **Time:** use `vm.warp` and `vm.roll` for TWAP tests. Remember the Pair updates cumulative prices only on interaction, so trigger a `sync()` or swap when a test needs fresh cumulatives.
- **Labels and traces:** run failing tests with `-vvvv`. Use `vm.label` so traces read `V2Router` and not `0x7a25…`.
- **Creating a thin pair** (for the oracle attack): deploy a mock ERC-20 `COL`, then `factory.createPair(COL, USDC)` and seed it with `addLiquidity`.

### 3.3 Token and pair test matrix

| Pair | Decimals | Why it's in the matrix |
| --- | --- | --- |
| USDC / WETH | 6 / 18 | Main pair; deepest liquidity |
| DAI / WETH | 18 / 18 | Equal decimals sanity check |
| USDT / WETH | 6 / 18 | **Non-standard token** (no return value on `approve`/`transfer`) |
| USDC / DAI | 6 / 18 | Stable pair; multi-hop middle leg |
| COL / USDC (mock, created in test) | 18 / 6 | Thin pool for attack demos |
| Fee-on-transfer mock / WETH | 18 / 18 | Optional; documents unsupported behaviour |

---

## 4. Writing Each Test Type

### 4.1 Unit-on-fork

- Naming: `test_<Function>_<Scenario>()` e.g. `test_SwapExactIn_MultiHop()`. Put the spec ID in a comment: `// SW-T04`.
- Revert tests: `vm.expectRevert(SwapExecutor.DeadlineExpired.selector);` and for errors with args use `abi.encodeWithSelector`.
- Event tests: `vm.expectEmit(true, true, false, true);` then emit the expected event, then call.
- Always assert **three things** after a successful action: user balance change, protocol balance (should be zero for stateless contracts), and pair reserves/`k` direction when relevant.

### 4.2 Fuzz tests

- Bound inputs to **realistic ranges** per token decimals, using `bound()`:

  ```solidity
  amountIn = bound(amountIn, 1e6, 5_000_000e6);   // 1 to 5M USDC
  ```
- Prefer `bound` over `vm.assume` (assume discards runs and can starve the fuzzer).
- Use a fuzz seed and print counterexamples; save any failing case as a regular regression test.
- Property ideas: output ≥ min; no residual balances; Router parity; round-trip never creates value; dust below threshold; no overflow in `ZapMath`.

### 4.3 Invariant tests

Use the **handler pattern**: the fuzzer calls only a handler that makes bounded, valid actions.

```solidity
contract VaultHandler is Test {
    LPVault vault; TwapOracle oracle; /* tokens, router */
    address[] actors;
    uint256 public ghostDeposited; uint256 public ghostRedeemed;

    function deposit(uint256 actorSeed, uint256 amount) external { /* bound, prank, deposit, update ghosts */ }
    function redeem(uint256 actorSeed, uint256 fractionBps) external { /* ... */ }
    function poolSwap(bool dir, uint256 amount) external { /* generates fees */ }
    function warp(uint256 secs) external { vm.warp(block.timestamp + bound(secs, 1, 2 hours)); oracle.update(address(pair)); }
}
```

- In the invariant contract: `targetContract(address(handler));` and restrict selectors with `targetSelector`.
- Invariants checked after every call: I-VT-1 to I-VT-6 (specs §5.8).
- Config: `runs = 256`, `depth = 50` locally; CI profile `runs = 1000`, `depth = 100`.
- `fail_on_revert = false` is acceptable only because the handler already bounds inputs; log reverts you did not expect.
- Track **ghost variables** (what should be true) and compare with the real state.

### 4.4 Attack PoCs

- One file per attack, with two clear sections: `test_Attack_<Name>()` against the vulnerable version and `test_Fixed_<Name>()` against the fixed one.
- Print the story with `console.log`: balances before/after, prices, profit.
- Assert the *economic* outcome (attacker profit, victim loss), not just "it reverted".

### 4.5 Differential tests (cheap and powerful)

- `V2Library.getAmountOut` vs `Router.getAmountsOut` over fuzzed inputs on real pairs.
- `ZapMath.optimalSwapAmount` vs a brute-force search for the best split (small ranges, binary search).
- `TwapOracle.consult` vs a manually computed average from recorded reserves.

---

## 5. Coverage Targets

From the PRD: **≥ 95% line, ≥ 85% branch** on `SwapExecutor`, `Zap`, `LPVault`, `FlashSwap`, `TwapOracle`, `ZapMath`, `V2Library`.

```bash
forge coverage --report lcov --no-match-coverage "(test|script|mocks)"
# if "stack too deep" appears under coverage:
forge coverage --ir-minimum --report lcov --no-match-coverage "(test|script|mocks)"
genhtml lcov.info -o coverage/        # optional HTML report
```

Coverage is a **floor, not a goal**. A line covered by a test that asserts nothing is worth nothing. Review uncovered branches by hand; each should be either a test you forgot or dead code to delete.

---

## 6. Failure-Path Matrix (every revert must be hit)

| Contract | Errors to trigger |
| --- | --- |
| SwapExecutor | `DeadlineExpired`, `ZeroAmount`, `InvalidPath` (length, duplicates, zero address, WETH position), `PairNotFound`, `InvalidRecipient`, `UnexpectedETH`, `ETHValueMismatch`, Router slippage revert, `Pausable` revert, `Ownable` revert |
| Zap | `DeadlineExpired`, `ZeroAmount`, `PairNotFound`, `InvalidToken`, `EmptyPool`, `SlippageExceeded`, `InvalidRecipient`, `UnexpectedETH`, paused |
| TwapOracle | `InsufficientHistory`, `StaleOracle`, `InvalidToken`, `TooSoon` (if used) |
| LPVault | `SlippageExceeded`, `OracleNotReady`, `ExactWithdrawUnsupported`, `MintUnsupported`, zero-share revert, paused deposit, insufficient allowance on `redeem` by operator |
| FlashSwap | `UnauthorizedCaller`, `UnauthorizedSender`, `Unprofitable`, `InvalidBorrow`, `PairNotFound` |

Tick each box when its test exists. This table is your checklist for NFR-T6.

---

## 7. Gas Tracking

```bash
forge snapshot                       # writes .gas-snapshot
forge snapshot --check               # fails if gas moved beyond tolerance (use in CI)
forge test --gas-report              # per-function table
```

- Record gas for: `swapExactIn` (1 hop, 2 hops), `zapIn`, `zapOut`, `deposit`, `redeem`, `executeArb`.
- Compare `zapIn` against doing `swap + addLiquidity` manually in a test (NFR-G2) and write one paragraph in the README about the overhead and why it's worth it.

---

## 8. Static Analysis

```bash
slither . --config-file slither.config.json
```

`slither.config.json` should exclude `lib/`, `test/`, `script/`. **Triage rules:**

- High/Medium: fix, or write a justification in `docs/slither-triage.md` with the reason it's a false positive.
- Low/Informational: skim, fix cheap ones, record the rest.
- Typical false positives to expect: "arbitrary `from` in transferFrom" on `msg.sender`-guarded paths, reentrancy warnings where `nonReentrant` is present, divide-before-multiply in intentional rounding.

---

## 9. Continuous Integration

`.github/workflows/ci.yml` (sketch):

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    env:
      MAINNET_RPC_URL: ${{ secrets.MAINNET_RPC_URL }}
      FORK_BLOCK: "<pinned block>"
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - uses: foundry-rs/foundry-toolchain@v1
      - run: forge fmt --check
      - run: forge build --sizes
      - run: FOUNDRY_PROFILE=ci forge test -vv
      - run: forge snapshot --check
      - run: forge coverage --report summary --no-match-coverage "(test|script|mocks)"
      - uses: crytic/slither-action@v0.4.0
```

`foundry.toml` profiles:

```toml
[profile.default]
fuzz = { runs = 256 }
invariant = { runs = 64, depth = 30 }

[profile.ci]
fuzz = { runs = 10000, seed = "0x1" }
invariant = { runs = 1000, depth = 100 }
```

Local quick loop uses `default` (fast). CI uses `ci` (thorough, deterministic seed). Run time: expect minutes, not seconds, because of RPC; the fork cache keeps repeats fast.

---

## 10. Stage 0 Refresher Tests (`V2Refresher.t.sol`)

Goal: relearn V2 by making assertions pass. Do these **before** writing any production contract.

| ID | Test | What you learn |
| --- | --- | --- |
| R-T01 | `factory.getPair(USDC, WETH)` equals the CREATE2-derived address (init code hash) | Factory and deterministic pair addresses |
| R-T02 | Read `token0`, `token1`, `getReserves`; compute spot price with decimals | Ordering and decimal scaling |
| R-T03 | Manual `getAmountOut` equals `Router.getAmountsOut` for 10 amounts | The 997/1000 fee formula |
| R-T04 | Execute a swap; assert new reserves equal old ± amounts and `k_after ≥ k_before` | Invariant and the fee growing `k` |
| R-T05 | Calculate price impact for 1k, 100k, 1M USDC swaps and print | Slippage intuition |
| R-T06 | Add liquidity to a **fresh** pair; check first LP = `sqrt(x·y) − 1000` and later mints are proportional | LP token math, `MINIMUM_LIQUIDITY` |
| R-T07 | Remove liquidity; compare tokens out to share × reserves | Burn math |
| R-T08 | Tiny flash swap on a fork: borrow, repay `x·1000/997 + 1`, assert success; repay 1 wei less and assert revert | Flash-swap repayment rule |
| R-T09 | Warp time, `sync()`, read `price0CumulativeLast`, compute TWAP by hand | Oracle mechanics |

You are done with Stage 0 when you can explain R-T03, R-T04 and R-T08 out loud without notes.

---

## 11. Workflow: How to Build and Test One Contract

1. Read the contract's spec section. List its test IDs.
2. Write the **interface and an empty implementation** so tests compile.
3. Write the happy-path test; watch it fail; implement until green.
4. Write failure-path tests one by one (use the matrix in §6).
5. Add fuzz tests, then invariants.
6. Run coverage; examine misses; add or delete.
7. Run Slither; triage.
8. `forge snapshot`; commit.
9. Update the traceability table in the specs doc.

---

## 12. Definition of "Tested" per Contract

A contract is **done** when:

- [ ] Every test ID in its spec section exists and passes.
- [ ] Every row for it in the failure-path matrix (§6) is ticked.
- [ ] Coverage thresholds are met for it.
- [ ] Fuzz tests run at CI settings without failure.
- [ ] Invariants (if applicable) hold at CI settings.
- [ ] Slither clean or triaged.
- [ ] Gas snapshot committed.

---

## 13. Debugging Tips

| Need | Command or tool |
| --- | --- |
| See the full call trace | `forge test --match-test <name> -vvvv` |
| Step through | `forge test --match-test <name> --debug` |
| Print values | `console.log` / `console2.log` |
| Check storage layout | `forge inspect <Contract> storage-layout` |
| Reproduce a fuzz failure | `forge test --match-test <name> --fuzz-seed <seed>` |
| Flaky fork test | Confirm `FORK_BLOCK` is set; check RPC rate limits |
| Understand a Router revert | Trace it; V2 Router errors are strings like `UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT` |

---

## 14. Optional Stretch Goals

- **Mutation testing** on `ZapMath` and `V2Library` (e.g. Gambit) to prove tests catch subtle changes.
- **Formal-style properties** with Foundry's `symbolic` cheatcodes or Halmos for `ZapMath` bounds.
- **Gas comparison** of the Zap vs the official V2 Router-only flow in a table.

Skip these unless the core is finished.

---

**Next document:** 06 Roadmap (the build order, stage by stage, with checklists, time estimates and exit criteria).