# V2 Zap & Vault: Contract Specifications

**Version:** 1.0 | **Depends on:** 01-PRD, 02-Architecture | **Feeds:** 04-Threat Model, 05-Testing, 06-Roadmap

**How to use this doc.** Each contract has the same sections: Purpose, Dependencies, State, External API, Logic, Events and Errors, Invariants, Security notes, Tests. You should be able to write the contract from its section without guessing. Requirement IDs (FR-…, NFR-…) link back to the PRD.

---

## 0. Shared Conventions

### 0.1 Solidity and style

- `pragma solidity 0.8.24;` custom errors only, no `require` strings. NatSpec on every external function.
- Checks → Effects → Interactions. `nonReentrant` on every function that moves tokens or ETH.
- Deadline check: `if (block.timestamp > deadline) revert DeadlineExpired();`
- All token movement through `SafeERC20`. All approvals through `forceApprove(spender, exactAmount)`, then reset to `0` after the external call.
- Amounts that arrive from a transfer are measured by **balance delta**, not trusted from the argument.

### 0.2 Minimal interfaces to write (`src/interfaces/`)

```solidity
interface IUniswapV2Factory {
    function getPair(address a, address b) external view returns (address);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 tsLast);
    function totalSupply() external view returns (uint256);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function swap(uint256 a0Out, uint256 a1Out, address to, bytes calldata data) external;
    // plus ERC20: balanceOf, approve, transfer, transferFrom
}

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint256 a0, uint256 a1, bytes calldata data) external;
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory);
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
    function swapTokensForExactTokens(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
    function swapExactETHForTokens(uint256, address[] calldata, address, uint256) external payable returns (uint256[] memory);
    function swapExactTokensForETH(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
    function addLiquidity(address, address, uint256, uint256, uint256, uint256, address, uint256)
        external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function removeLiquidity(address, address, uint256, uint256, uint256, address, uint256)
        external returns (uint256 amountA, uint256 amountB);
}

interface IWETH { function deposit() external payable; function withdraw(uint256) external; }
```

Copy the signatures **exactly**. A wrong parameter order compiles fine and fails only on the fork.

### 0.3 Shared errors

```solidity
error DeadlineExpired();
error ZeroAmount();
error ZeroAddress();
error InvalidPath();
error PairNotFound();
error SlippageExceeded(uint256 actual, uint256 limit);
error InvalidRecipient();
```

### 0.4 Roles

- `owner` (OpenZeppelin `Ownable`): may `pause`, `unpause` and `rescue`. Nothing else. No fees, no parameter changes, no upgrades.

---

## 1. V2Library (`src/libraries/V2Library.sol`)

Pure helpers so we never depend on the 0.5/0.6 official library.

| Function | Definition |
| --- | --- |
| `sortTokens(a, b)` | Returns `(token0, token1)`; reverts `InvalidPath` if equal or zero |
| `getAmountOut(amountIn, rIn, rOut)` | `amountIn*997*rOut / (rIn*1000 + amountIn*997)`; reverts on zero input or reserves |
| `getAmountIn(amountOut, rIn, rOut)` | `(rIn*amountOut*1000) / ((rOut - amountOut)*997) + 1` |
| `getReservesSorted(factory, tokenA, tokenB)` | Looks up the pair via `Factory.getPair`, returns `(reserveA, reserveB, pair)` ordered to match the arguments; reverts `PairNotFound` |

**Tests:** `getAmountOut` result must equal `Router.getAmountsOut` for fuzzed inputs on real pairs (this is your Stage 0 assertion).

---

## 2. SwapExecutor (`src/SwapExecutor.sol`)

### 2.1 Purpose

A safe wrapper over Router swaps. Adds input validation, uniform slippage and deadline handling, ETH support, approval hygiene, pause and events. (FR-SW-1 to FR-SW-10)

### 2.2 Dependencies and immutables

`router` (`IUniswapV2Router02`), `weth` (read from `router.WETH()` in the constructor). Inherits `Ownable`, `Pausable`, `ReentrancyGuard`.

### 2.3 State

No storage besides the inherited ones. **The contract must hold zero tokens and zero ETH after every call.**

### 2.4 External API

```solidity
function swapExactIn(address[] calldata path, uint256 amountIn, uint256 minOut,
                     address to, uint256 deadline) external returns (uint256[] memory amounts);

function swapExactOut(address[] calldata path, uint256 amountOut, uint256 maxIn,
                      address to, uint256 deadline) external returns (uint256[] memory amounts);

function swapExactETHIn(address[] calldata path, uint256 minOut,
                        address to, uint256 deadline) external payable returns (uint256[] memory);   // path[0] == WETH

function swapExactInForETH(address[] calldata path, uint256 amountIn, uint256 minOut,
                          address to, uint256 deadline) external returns (uint256[] memory);          // path[last] == WETH

function quoteExactIn(address[] calldata path, uint256 amountIn) external view returns (uint256[] memory);
function quoteExactOut(address[] calldata path, uint256 amountOut) external view returns (uint256[] memory);

function pause() external onlyOwner;
function unpause() external onlyOwner;
function rescueToken(address token, address to, uint256 amount) external onlyOwner;
function rescueETH(address payable to, uint256 amount) external onlyOwner;
receive() external payable;   // only accepts ETH from `weth`, else revert
```

### 2.5 Logic

**`swapExactIn`**

1. `whenNotPaused`, `nonReentrant`. Validate: `amountIn > 0`, deadline, path (below), `to != address(0)` and `to != address(this)`.
2. `before = IERC20(path[0]).balanceOf(this)`; `safeTransferFrom(msg.sender, this, amountIn)`; `received = balanceOf(this) - before`.
3. `forceApprove(router, received)`.
4. `amounts = router.swapExactTokensForTokens(received, minOut, path, to, deadline)`.
5. `forceApprove(router, 0)`. Emit `Swapped`.

**`swapExactOut`**

1. Same validation. Pull `maxIn` from the user (balance delta).
2. Approve router for `maxIn`. Call `swapTokensForExactTokens(amountOut, maxIn, path, to, deadline)`. Router reverts if the required input exceeds `maxIn`.
3. `spent = amounts[0]`. **Refund `received - spent` to `msg.sender`**. Reset approval to 0. Emit `Swapped` with `spent`.

**ETH variants.** `swapExactETHIn` passes `msg.value` straight to `router.swapExactETHForTokens{value: msg.value}`. `swapExactInForETH` sends ETH directly to `to` through the Router (`to` must be able to receive ETH).

**Path validation (`_validatePath`)**

- `path.length >= 2` and `<= MAX_HOPS` (constant `4`).
- No `address(0)` entries; no two adjacent equal tokens.
- For ETH variants, check the WETH position as noted above.
- Existence of each pair is checked by the Router; we additionally pre-check with `Factory.getPair` so the error is our own `PairNotFound` rather than an opaque revert (optional, P1).

### 2.6 Events and errors

```solidity
event Swapped(address indexed user, address indexed to, address tokenIn, address tokenOut,
              uint256 amountIn, uint256 amountOut);
error InvalidPath(); error DeadlineExpired(); error ZeroAmount(); error InvalidRecipient();
error UnexpectedETH();           // receive() called by non-WETH
error ETHValueMismatch();        // msg.value == 0 on ETH-in
```

### 2.7 Invariants

- **I-SW-1:** after any call, `balanceOf(this)` for every token and `address(this).balance` equal their pre-call values (stateless).
- **I-SW-2:** `router` allowance from the executor is `0` after every call.
- **I-SW-3:** `swapExactIn` output `>= minOut`; `swapExactOut` input `<= maxIn`.
- **I-SW-4:** user's net token loss equals `amounts[0]` (exact-out) or `amountIn` (exact-in).

### 2.8 Security notes

- `to == address(this)` blocked so funds cannot be parked in the contract.
- `rescue*` exists only for accidental transfers; since the contract is stateless, any balance is by definition not a user's.
- Fee-on-transfer **input** tokens are handled by the balance delta; fee-on-transfer **path** tokens are unsupported (documented limitation, P2).

### 2.9 Tests (fork)

| ID | Test | Asserts |
| --- | --- | --- |
| SW-T01 | exact-in USDC→WETH | output ≥ minOut; user balances change correctly; executor balances zero |
| SW-T02 | exact-in output equals `getAmountsOut` quote | quote parity |
| SW-T03 | exact-out WETH→USDC | exact `amountOut` received; unused input refunded |
| SW-T04 | multi-hop USDC→DAI→WETH | each intermediate leaves zero balance in executor |
| SW-T05 | ETH→USDC and USDC→ETH | WETH wrap/unwrap works; no ETH stuck |
| SW-T06 | USDT as input token | works with no bool return (SafeERC20 proof) |
| SW-T07 | expired deadline | reverts `DeadlineExpired` |
| SW-T08 | `minOut` too high | reverts (Router's slippage error surfaces) |
| SW-T09 | `maxIn` too low (exact-out) | reverts |
| SW-T10 | invalid paths: length 1, duplicate adjacent, zero address, non-existent pair | each reverts with the right error |
| SW-T11 | paused | swaps revert; unpause restores |
| SW-T12 | direct ETH sent to executor | reverts `UnexpectedETH` |
| SW-T13 | rescue by non-owner / by owner | access control |
| SW-T14 | allowance to Router is zero after call | I-SW-2 |
| SW-F01 | **fuzz** amountIn for USDC→WETH, 1 to 1M USDC | no unexpected revert; invariants I-SW-1..3 |
| SW-F02 | **fuzz** exact-out amounts | refund math always correct |
| SW-F03 | **fuzz** vs manual `V2Library.getAmountOut` | exact equality with actual swap output |

---

## 3. Zap and ZapMath (`src/Zap.sol`, `src/libraries/ZapMath.sol`)

### 3.1 Purpose

Turn **one token into an LP position** and back, in one transaction, with minimal dust. (FR-ZP-1 to FR-ZP-10)

### 3.2 The core math

User has `a` of token X. Pair reserve of X is `r`. We swap `s` of X for Y, then add `(a - s)` of X plus the received Y as liquidity. We want the added amounts to match the **post-swap** pool ratio so nothing is left over.

With the 0.3% fee, solving the condition gives:

```text
s = ( sqrt( r * ( a * 3_988_000 + r * 3_988_009 ) ) - r * 1997 ) / 1994
```

```solidity
library ZapMath {
    function optimalSwapAmount(uint256 reserveIn, uint256 amountIn) internal pure returns (uint256) {
        // use OpenZeppelin Math.sqrt; compute inside the sqrt with Math.mulDiv-safe intermediate
        return (Math.sqrt(reserveIn * (amountIn * 3988000 + reserveIn * 3988009)) - reserveIn * 1997) / 1994;
    }
}
```

**Overflow note:** `reserveIn * (...)` can approach 2^256 for huge reserves with 18-decimal tokens. Check bounds in a test (ZP-F03), and if needed split the multiplication with `Math.mulDiv`.

**Rounding:** the result is rounded down, so a tiny dust amount remains. That is expected, and we refund it.

### 3.3 Dependencies and immutables

`router`, `factory` (`router.factory()`), `weth`. Inherits `Ownable`, `Pausable`, `ReentrancyGuard`. No storage.

### 3.4 External API

```solidity
function zapIn(address pair, address tokenIn, uint256 amountIn, uint256 minLpOut,
               address to, uint256 deadline) external returns (uint256 lpOut);

function zapInETH(address pair, uint256 minLpOut, address to, uint256 deadline)
               external payable returns (uint256 lpOut);              // pair must contain WETH

function zapOut(address pair, uint256 lpAmount, address tokenOut, uint256 minOut,
                address to, uint256 deadline) external returns (uint256 amountOut);

function zapOutETH(address pair, uint256 lpAmount, uint256 minOut,
                   address payable to, uint256 deadline) external returns (uint256 amountOut);

function quoteZapIn(address pair, address tokenIn, uint256 amountIn)
                   external view returns (uint256 swapAmount);       // helper for UIs and tests

function pause() / unpause() / rescueToken() / rescueETH()  // owner, same as SwapExecutor
receive() external payable;                                   // only from weth
```

### 3.5 Logic: `zapIn`

1. Guards: `whenNotPaused`, `nonReentrant`, deadline, `amountIn > 0`, `to` valid.
2. **Pair validation:** `t0 = pair.token0()`, `t1 = pair.token1()`; require `factory.getPair(t0, t1) == pair` else `PairNotFound`. Require `tokenIn ∈ {t0, t1}` else `InvalidToken`. `tokenOut = the other`.
3. Pull `amountIn` (balance delta → `received`).
4. `(rIn, rOut) = reserves ordered for tokenIn`. Require both `> 0` else `EmptyPool`.
5. `s = ZapMath.optimalSwapAmount(rIn, received)`.
6. Approve router for `s`; `router.swapExactTokensForTokens(s, 0, [tokenIn, tokenOut], this, deadline)`; measure `gotOut` by delta. (`amountOutMin = 0` is acceptable *inside* an atomic zap because the final `minLpOut` check protects the user; see 3.8.)
7. Approve router for `received - s` of tokenIn and `gotOut` of tokenOut; call `router.addLiquidity(tokenIn, tokenOut, received - s, gotOut, 0, 0, to, deadline)`; the LP goes **directly to `to`**.
8. `require(liquidity >= minLpOut)` else `SlippageExceeded`.
9. **Refund dust:** send any remaining tokenIn and tokenOut balance (delta since step 3) to `msg.sender`. Reset approvals to 0. Emit `ZappedIn`.

**`zapInETH`:** wrap `msg.value` into WETH, then follow the same path with `tokenIn = WETH`.

### 3.6 Logic: `zapOut`

1. Same pair validation; `tokenOut ∈ {t0, t1}`.
2. Pull LP tokens from the user. Approve router for LP.
3. `router.removeLiquidity(t0, t1, lpAmount, 0, 0, this, deadline)` gives `(a0, a1)`.
4. Swap the **other** token's whole amount into `tokenOut`: `swapExactTokensForTokens(otherAmt, 0, [other, tokenOut], this, deadline)`.
5. `amountOut = a_tokenOut + swapped`. Require `>= minOut`.
6. Send `amountOut` to `to`. Reset approvals. Emit `ZappedOut`.

**`zapOutETH`:** same, with `tokenOut = WETH`, then unwrap and send ETH.

### 3.7 Events and errors

```solidity
event ZappedIn(address indexed user, address indexed pair, address tokenIn,
               uint256 amountIn, uint256 lpOut, uint256 dust0, uint256 dust1);
event ZappedOut(address indexed user, address indexed pair, address tokenOut,
                uint256 lpIn, uint256 amountOut);
error InvalidToken(); error EmptyPool(); error UnexpectedETH();
// plus shared: PairNotFound, SlippageExceeded, DeadlineExpired, ZeroAmount, InvalidRecipient
```

### 3.8 Slippage model (important to understand)

- Intermediate steps use `min = 0`. An attacker who sandwiches the zap worsens the price; the user then receives **fewer LP tokens than expected**, and `minLpOut` reverts the whole zap.
- That means **`minLpOut` is only as good as the number the caller computes.** The caller must derive it from a fair value (TWAP or off-chain), not from the current spot, or the check is useless. This is also a point to cover in the threat model doc.

### 3.9 Invariants

- **I-ZP-1:** after any call, Zap's balance of every token and ETH is unchanged (stateless).
- **I-ZP-2:** router allowances are `0` after every call.
- **I-ZP-3:** leftover dust returned to the user is `< 0.1%` of `amountIn` (value) for pools with reasonable depth.
- **I-ZP-4:** LP received `>= minLpOut`.
- **I-ZP-5:** `zapOut(zapIn(x))` returns at most `x` minus fees (no value is created).

### 3.10 Tests (fork)

| ID | Test | Asserts |
| --- | --- | --- |
| ZP-T01 | zapIn USDC into USDC/WETH | LP received > 0; dust small; Zap balance zero |
| ZP-T02 | zapIn WETH (other side of the pair) | symmetric behaviour |
| ZP-T03 | zapInETH | wrapping works; LP minted to `to` |
| ZP-T04 | `optimalSwapAmount` vs brute force | search over `s` to find the true best; the formula is within 1 wei-level of it |
| ZP-T05 | zapOut to USDC | token received ≥ minOut; Zap balances zero |
| ZP-T06 | zapOutETH | ETH arrives at `to` |
| ZP-T07 | round trip in/out | I-ZP-5; loss ≈ 2 × swap fee, within tolerance |
| ZP-T08 | pair not from factory (fake address) | reverts `PairNotFound` |
| ZP-T09 | token not in pair | reverts `InvalidToken` |
| ZP-T10 | empty pool (create fresh pair on the fork) | reverts `EmptyPool` |
| ZP-T11 | `minLpOut` too high | reverts `SlippageExceeded` |
| ZP-T12 | expired deadline / paused | reverts |
| ZP-T13 | **sandwich the zap**: attacker moves price before the call | zap reverts with a reasonable `minLpOut`; with `minLpOut = 0` the user loses value (feeds attack docs) |
| ZP-T14 | USDT in a USDT pair | works |
| ZP-F01 | **fuzz** amountIn (1e6 to 1e12 USDC units) | dust ratio bound; I-ZP-1, 2, 4 |
| ZP-F02 | **fuzz** across several real pairs (USDC/WETH, DAI/WETH, USDT/WETH) | no reverts for valid input |
| ZP-F03 | **fuzz** huge reserves and amounts in `ZapMath` | no overflow; result `<= amountIn` |

---

## 4. TwapOracle (`src/oracle/TwapOracle.sol`)

### 4.1 Purpose

Give other contracts a manipulation-resistant price for any V2 pair, using the pair's built-in cumulative prices. Used by LPVault and by the fixed lender in the security lab.

### 4.2 How V2 supports it

Each pair keeps `price0CumulativeLast` and `price1CumulativeLast`, updated on the **first** interaction of each block with the pre-trade price (in UQ112x112 format) multiplied by elapsed seconds. The average price between two points in time is:

```text
TWAP = (cumulativeNow - cumulativeThen) / (timeNow - timeThen)
```

The pair's stored value lags until the next interaction, so for "now" we add the missing term: `price(from current reserves) × (block.timestamp − tsLast)`. Cumulative values are **designed to overflow**, so subtract in `unchecked`.

### 4.3 Immutables and state

```solidity
uint32 public immutable MIN_WINDOW;    // minimum TWAP length, e.g. 30 minutes
uint32 public immutable MIN_SPACING;   // min gap between stored observations, e.g. 10 minutes
uint32 public immutable MAX_AGE;       // oldest observation still accepted, e.g. 24 hours
uint8  public constant  MAX_OBS = 8;   // ring buffer length

struct Observation { uint32 timestamp; uint256 price0Cumulative; uint256 price1Cumulative; }
mapping(address pair => Observation[MAX_OBS]) private _obs;
mapping(address pair => uint8) private _head;      // next write index
mapping(address pair => uint8) private _count;     // number stored
```

### 4.4 External API

```solidity
function update(address pair) external;
function consult(address pair, address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);
function currentCumulativePrices(address pair) public view returns (uint256 p0, uint256 p1, uint32 ts);
function observationCount(address pair) external view returns (uint8);
```

- **`update`** (permissionless): compute `currentCumulativePrices`; if `count == 0` or `ts - latest.timestamp >= MIN_SPACING`, write to the ring buffer and emit `Updated`. Otherwise do nothing (or revert `TooSoon`; pick one and test it).
- **`consult`**: find the **most recent** observation at least `MIN_WINDOW` old. If none exists, revert `InsufficientHistory`. If it is older than `MAX_AGE`, revert `StaleOracle`. Compute the average over `[obs.timestamp, now]` for the correct side (`tokenIn == token0` → use `price0`), then `amountOut = amountIn × avg >> 112` using `Math.mulDiv`.

### 4.5 Errors and events

```solidity
event Updated(address indexed pair, uint32 timestamp);
error InsufficientHistory(); error StaleOracle(); error InvalidToken(); error TooSoon();
```

### 4.6 Invariants and limits

- **I-OR-1:** `consult` never returns a value derived from a window shorter than `MIN_WINDOW`.
- **I-OR-2:** a single-block manipulation (flash swap in the same tx) changes `consult` by at most `(attack size / window)` in proportion. Test that this is small.
- **Known limit (document it):** a TWAP can still be moved by an attacker who holds a manipulated price **across many blocks** (costly). Window length is the knob.
- **Warm-up:** the oracle needs history before it works; the Vault's first deposit requires `update` calls spanning `MIN_WINDOW`.

### 4.7 Tests (fork)

| ID | Test | Asserts |
| --- | --- | --- |
| OR-T01 | update then `vm.warp` 30 min then consult | result close to spot (±0.5%) on a quiet pair |
| OR-T02 | consult before enough history | reverts `InsufficientHistory` |
| OR-T03 | consult after `MAX_AGE` without update | reverts `StaleOracle` |
| OR-T04 | update spacing | second update inside `MIN_SPACING` has no effect (or `TooSoon`) |
| OR-T05 | ring buffer wrap past 8 observations | consult still correct |
| OR-T06 | **manipulation**: big swap moves spot 20%, then consult at the same block | TWAP moves only a few percent or less |
| OR-T07 | **sustained manipulation** over several warped blocks | document the cost vs shift |
| OR-T08 | both directions (`token0→token1` and reverse) | consistent with reserve ratio |
| OR-T09 | cumulative overflow arithmetic | `unchecked` subtraction yields correct deltas (use a mock pair with a near-max cumulative) |
| OR-F01 | **fuzz** swap sizes between updates | `consult` stays within bound of the expected time-weighted average |

---

## 5. LPVault (`src/LPVault.sol`)

### 5.1 Purpose

Users deposit **one token** (e.g. USDC) and receive shares in an auto-zapped LP position. Pool fees accrue inside the LP tokens, so share value rises over time. (FR-VT-1 to FR-VT-9)

### 5.2 Inheritance and immutables

`ERC4626` (OpenZeppelin v5), `Ownable`, `Pausable`, `ReentrancyGuard`. Immutables: `pair`, `asset` (deposit token D, passed to `ERC4626` constructor), `otherToken` (O), `zap`, `oracle`. Constructor checks that `asset` and `otherToken` are the two tokens of `pair` and that the pair is registered in the Factory.

### 5.3 Share accounting

**`totalAssets()`** = value of the vault's LP tokens, **in units of D**, using fair-reserves valuation at TWAP price:

```text
L   = pair.balanceOf(vault)                          // vault LP tokens
S   = pair.totalSupply()
rD, rO = reserves ordered (D, O)
vO  = oracle.consult(pair, O, rO)                    // value of reserve rO in D units (TWAP)

fairPoolValue_D = 2 * sqrt( rD * vO )                // manipulation-resistant pool value in D
totalAssets     = fairPoolValue_D * L / S  +  IERC20(D).balanceOf(vault)
```

Why this works: the raw reserve of D can be pushed around inside one transaction, but `rD × rO` (the product, close to `k`) moves very little under a swap, and the price comes from the TWAP, not from the reserves. This is the "fair LP pricing" technique used by lending protocols that accept LP tokens as collateral.

**Share decimals offset.** Override `_decimalsOffset()` to return `6` (OpenZeppelin virtual shares). That blunts the first-depositor inflation attack (FR-VT-6).

### 5.4 Deposit: value-based minting (key design point)

OpenZeppelin's default `deposit` mints shares from the **asset amount**. That is wrong here, because the zap loses some value to swap fees and price impact. If shares were minted on the full `assets`, **existing holders would absorb that loss**.

So we override and mint on the **value actually added**:

```text
deposit(assets, receiver, minShares):
  1. require !paused, nonReentrant, assets > 0
  2. totalBefore = totalAssets()
  3. pull `assets` of D from the user
  4. approve Zap; lpOut = zap.zapIn(pair, D, assets, 0, address(this), deadline); reset approval
  5. totalAfter  = totalAssets()          // idle D should be 0 again; LP balance increased
  6. valueAdded  = totalAfter - totalBefore
  7. shares      = valueAdded * (totalSupply() + 10**offset) / (totalBefore + 1)   // virtual-share formula
  8. require shares >= minShares, else SlippageExceeded
  9. _mint(receiver, shares); emit Deposit(...)
```

The depositor therefore pays the zap cost, and existing holders are unaffected. `previewDeposit` is an **estimate** (it cannot know the exact zap loss), and this deviation from strict ERC-4626 must be documented in the README.

### 5.5 Withdraw: share-based redemption

```text
redeem(shares, receiver, owner, minAssets):
  1. require nonReentrant (withdrawals stay open even when paused: FR-VT-9)
  2. spend allowance if msg.sender != owner
  3. lpToBurn = L * shares / totalSupply()        // proportional share of LP tokens
  4. _burn(owner, shares)
  5. approve Zap for lpToBurn; assetsOut = zap.zapOut(pair, lpToBurn, D, 0, receiver, deadline)
  6. require assetsOut >= minAssets, else SlippageExceeded
```

- **`withdraw(assets, …)` (exact-assets variant)** reverts with `ExactWithdrawUnsupported()`. We cannot guarantee an exact output after swap slippage. This is a documented ERC-4626 deviation; `redeem` is the supported exit.
- Burning shares **before** the external calls follows Checks-Effects-Interactions.

### 5.6 External API summary

```solidity
function deposit(uint256 assets, address receiver) public override returns (uint256);          // minShares = 0 convenience
function depositWithMin(uint256 assets, address receiver, uint256 minShares, uint256 deadline) external returns (uint256);
function redeem(uint256 shares, address receiver, address owner) public override returns (uint256);
function redeemWithMin(uint256 shares, address receiver, address owner, uint256 minAssets, uint256 deadline) external returns (uint256);
function totalAssets() public view override returns (uint256);
function lpBalance() external view returns (uint256);
function pause() / unpause() external onlyOwner;           // pauses deposits ONLY
```

Overrides `maxDeposit` to return `0` while paused. **`mint` is disabled** (`revert MintUnsupported()`), same reason as `withdraw`.

### 5.7 Events and errors

Standard ERC-4626 `Deposit` and `Withdraw` events, plus:

```solidity
error ExactWithdrawUnsupported(); error MintUnsupported();
error SlippageExceeded(uint256, uint256); error OracleNotReady();   // wraps oracle revert for clarity
```

### 5.8 Invariants (Foundry invariant suite)

- **I-VT-1 (solvency):** `totalAssets() × 1 ≥ Σ convertToAssets(userShares)` up to rounding, so claims never exceed assets.
- **I-VT-2 (no value leak on deposit):** after a deposit, the **per-share value** `totalAssets()/totalSupply()` does not decrease (within 1 wei rounding).
- **I-VT-3 (no stranded funds):** idle `D` and `O` in the vault are `~0` after each call.
- **I-VT-4:** `Zap` and the vault have zero router allowance after each call.
- **I-VT-5:** shares `totalSupply() == 0` iff `lpBalance() == 0` (barring dust/virtual-share offset).
- **I-VT-6 (monotonic yield):** with only swap activity in the pool (no deposits), per-share value never decreases over time (fees accumulate).

### 5.9 Handler design for invariant testing

`VaultHandler` exposes bounded actions: `deposit(actorSeed, amount)`, `redeem(actorSeed, shareFraction)`, `swapInPool(direction, amount)` (generates fees), `warp(seconds)` + `oracle.update`. Track ghost variables: total deposited, total redeemed, per-actor shares.

### 5.10 Tests (fork)

| ID | Test | Asserts |
| --- | --- | --- |
| VT-T01 | first deposit | shares > 0; LP held by vault; idle assets 0 |
| VT-T02 | second user deposit | per-share value not diluted (I-VT-2) |
| VT-T03 | redeem all | user gets ≈ deposit minus costs; vault LP back to 0 |
| VT-T04 | fee accrual | do 100 swaps in the pool via `vm.prank`; per-share value rises |
| VT-T05 | **first-depositor inflation attack**: attacker deposits 1 wei, donates LP, victim deposits | attack unprofitable thanks to offset (FR-SL-5) |
| VT-T06 | donation of LP tokens directly to vault | share price rises but no one can steal; document |
| VT-T07 | `totalAssets()` under manipulation: attacker swaps 30% of pool in the same block | `totalAssets()` changes by \< 1%; contrast with a naive spot-based version (attack demo) |
| VT-T08 | oracle without history | deposit reverts `OracleNotReady` |
| VT-T09 | paused | deposit reverts; redeem still works |
| VT-T10 | `withdraw` and `mint` | revert with documented errors |
| VT-T11 | `depositWithMin` too strict | reverts `SlippageExceeded` |
| VT-T12 | share allowance flow for `redeem` by operator | works; wrong operator reverts |
| VT-T13 | USDT-asset vault variant (optional) | works with non-standard token |
| VT-I01…I06 | invariant suite I-VT-1 to I-VT-6 | as defined above |
| VT-F01 | **fuzz** deposit sizes and orderings | I-VT-2, I-VT-3 |

---

## 6. FlashSwap (`src/FlashSwap.sol`)

### 6.1 Purpose

Show correct use of V2 flash swaps through one concrete strategy: **borrow token X from a Uniswap V2 pair, sell it on another V2-style venue (SushiSwap), repay Uniswap in the other token, keep the profit.** (FR-FS-1 to FR-FS-5)

### 6.2 Key concept

A flash swap lets `pair.swap()` send tokens first and ask questions later. If the pair's invariant is not satisfied at the end of the same call, the **entire transaction reverts**. You may repay in **either** token, as long as the fee-adjusted `k` check passes.

Repayment amount when borrowing `x` of token A and repaying in token B (using the pair's reserves before the call, `rB`, `rA`):

```text
repayB = getAmountIn(x, rB, rA)  = (rB * x * 1000) / ((rA - x) * 997) + 1
```

(Repaying in the same token borrowed: `repay = x * 1000 / 997 + 1`, which is about 0.3009% more.)

### 6.3 Immutables and state

```solidity
IUniswapV2Factory public immutable factory;    // the "borrow" venue (Uniswap V2)
IUniswapV2Router02 public immutable sellRouter;// the "sell" venue (SushiSwap router)
address private _activePair;                   // set only during execute()
```

Inherits `IUniswapV2Callee`, `ReentrancyGuard`. No owner functions needed; the contract holds nothing between calls.

### 6.4 External API

```solidity
function executeArb(address borrowPair, address borrowToken, uint256 borrowAmount,
                    uint256 minProfit, address profitRecipient) external nonReentrant returns (uint256 profit);

function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external override;
```

### 6.5 Logic

**`executeArb`**

1. Validate pair with the factory; `borrowToken ∈ pair`; `borrowAmount > 0`; `borrowAmount < reserve` of that token.
2. Compute `repayToken` (the other token) and `repayAmount = getAmountIn(...)` from current reserves.
3. Set `_activePair = borrowPair`.
4. Encode `data = abi.encode(borrowToken, repayToken, borrowAmount, repayAmount, minProfit, profitRecipient)` (non-empty data is what triggers the callback).
5. Call `pair.swap(out0, out1, address(this), data)`, borrowing to this contract.
6. After it returns, set `_activePair = address(0)` and return `profit`.

**`uniswapV2Call`** (the dangerous function, so validate hard)

1. **`require(msg.sender == _activePair)`** else `UnauthorizedCaller`. Cross-check with `factory.getPair(token0, token1) == msg.sender`.
2. **`require(sender == address(this))`** else `UnauthorizedSender`. This blocks anyone else initiating a flash swap that routes through our callback.
3. Decode data. Verify the received `borrowToken` balance equals `borrowAmount`.
4. Approve `sellRouter`; `swapExactTokensForTokens(borrowAmount, 0, [borrowToken, repayToken], this, now)`; measure `gotRepayToken`.
5. `require(gotRepayToken >= repayAmount + minProfit)` else `Unprofitable(got, needed)`.
6. `safeTransfer(repayToken, msg.sender (pair), repayAmount)`.
7. Send remaining `repayToken` (the profit) to `profitRecipient`. Reset approvals.

### 6.6 Events and errors

```solidity
event FlashSwapExecuted(address indexed pair, address borrowToken, uint256 borrowed,
                        uint256 repaid, uint256 profit, address indexed recipient);
error UnauthorizedCaller(); error UnauthorizedSender(); error Unprofitable(uint256 got, uint256 needed);
error InvalidBorrow(); error PairNotFound();
```

### 6.7 Invariants

- **I-FS-1:** `_activePair == address(0)` outside of `executeArb`.
- **I-FS-2:** contract balances unchanged after a call (profit is forwarded).
- **I-FS-3:** if the strategy is unprofitable, the **whole transaction reverts** and the pair's reserves are unchanged.
- **I-FS-4:** after a successful flash swap, `reserve0 × reserve1` of the pair has **not decreased**.

### 6.8 Testing on a fork (how to get an opportunity)

Real arbitrage gaps are taken by bots instantly, so the test **creates** one: a helper swaps a large amount on the Sushi pair to push its price away from Uniswap's, then calls `executeArb`. That is a legitimate test technique (on a fork we control the state).

| ID | Test | Asserts |
| --- | --- | --- |
| FS-T01 | engineered price gap, `executeArb` | profit > 0; recipient received it; I-FS-2 |
| FS-T02 | repayment math | `repayAmount` equals `Router.getAmountsIn` on the borrow venue |
| FS-T03 | no price gap | reverts `Unprofitable`; pair reserves unchanged (I-FS-3) |
| FS-T04 | `minProfit` too high | reverts |
| FS-T05 | direct call to `uniswapV2Call` from an EOA | reverts `UnauthorizedCaller` |
| FS-T06 | **fake pair** contract calls the callback | reverts (pair not from factory) |
| FS-T07 | real pair, but flash swap started by an attacker (`sender != this`) | reverts `UnauthorizedSender` |
| FS-T08 | borrow amount ≥ reserve | reverts `InvalidBorrow` |
| FS-T09 | k after swap | I-FS-4 |
| FS-T10 | repay in same token borrowed (variant) | repay ≈ `x*1000/997 + 1` works |
| FS-F01 | **fuzz** borrow amount and gap size | profitable cases never lose funds; unprofitable cases revert |

---

## 7. Security Lab Mocks (`test/attacks/mocks/`)

Short specs here; full attack narratives belong in the threat-model doc.

### 7.1 VulnerableLender

- Accepts one collateral token (WETH) and lends one stable token (USDC) at a fixed LTV (e.g. 75%).
- **Valuation (the bug):** `price = reserveUSDC * 1e18 / reserveWETH` read directly from `getReserves()`.
- API: `depositCollateral(amount)`, `borrow(amount)`, `positionOf(user)`. No liquidation logic needed.

### 7.2 FixedLender

Identical, but valuation uses `TwapOracle.consult(pair, WETH, collateral)`.

### 7.3 Attack contracts

| Attack | Contract | Mechanism |
| --- | --- | --- |
| Spot oracle manipulation | `OracleAttacker` | flash swap USDC from a **different, deep pair** → buy the collateral token on the **thin target pair** (spot price spikes) → deposit and borrow at the inflated price → repay the flash swap. (A pair cannot be swapped inside its own callback: its lock blocks it and reserves update only after the callback.) Full write-up in 04-Threat-Model. |
| Sandwich | test-only attacker EOA logic | front-run swap pushes price → victim swaps with `minOut = 0` → back-run restores |
| Unsafe callback | `NaiveFlashReceiver` (no caller check) and `Drainer` | attacker calls the callback directly or initiates a flash swap with `sender` spoofing |

Each has a `Fixed…` counterpart and a test showing the attack **fails** against it.

---

## 8. Requirement Traceability

| Requirement | Contract | Tests |
| --- | --- | --- |
| FR-SW-1 to 10 | SwapExecutor | SW-T01 to T14, SW-F01 to F03 |
| FR-ZP-1 to 10 | Zap, ZapMath | ZP-T01 to T14, ZP-F01 to F03 |
| FR-VT-1 to 9 | LPVault, TwapOracle | VT-T01 to T13, VT-I01 to I06, OR-T01 to T10 |
| FR-FS-1 to 5 | FlashSwap | FS-T01 to T10, FS-F01 |
| FR-SL-1, 2 | VulnerableLender, FixedLender, TwapOracle | attack tests 01 + OR-T06 |
| FR-SL-3 | (SwapExecutor with and without min) | attack test 02, ZP-T13 |
| FR-SL-4 | NaiveFlashReceiver | attack test 03, FS-T05 to T07 |
| FR-SL-5 | LPVault | VT-T05, attack test 04 |
| NFR-S1 to S7 | all | invariants I-SW-2, I-ZP-2, I-VT-4, Slither in CI |
| NFR-T1 to T6 | all | fork base, coverage report, failure-path tests |

---

## 9. Decisions Still Open (decide at build time)

| # | Question | Default if undecided |
| --- | --- | --- |
| Q1 | `TwapOracle.update` inside `MIN_SPACING`: silently no-op or revert `TooSoon`? | No-op (friendlier to keepers) |
| Q2 | Oracle parameters | `MIN_WINDOW = 30 min`, `MIN_SPACING = 10 min`, `MAX_AGE = 24 h` |
| Q3 | Vault deposit asset | USDC in a USDC/WETH vault |
| Q4 | Pre-check pairs in SwapExecutor with `Factory.getPair` for cleaner errors | Yes (P1) |
| Q5 | `ExactWithdrawUnsupported` vs implementing `withdraw` with a buffer | Unsupported, documented |
| Q6 | Fee-on-transfer token support | Out of scope; documented limitation |

---

**Next document:** 04 Security and Threat Model (trust assumptions, full write-up of each attack: Attack → Root cause → Exploit → Fix → Test, and a checklist of integration pitfalls).