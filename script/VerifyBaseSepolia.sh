#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )"
cd "$DIR"

if [ -f .env ]; then
  export $(grep -v '^#' .env | grep -E '^ETHERSCAN_API_KEY=|^BASESCAN_API_KEY=' | xargs)
fi

API_KEY="${ETHERSCAN_API_KEY:-$BASESCAN_API_KEY}"

if [ -z "$API_KEY" ]; then
  echo "Error: Neither ETHERSCAN_API_KEY nor BASESCAN_API_KEY is set in .env or environment."
  echo "Please obtain a free API key at https://basescan.org/myapikey and add to .env:"
  echo "BASESCAN_API_KEY=your_key_here"
  exit 1
fi

echo "Verifying all contracts on BaseScan (Chain 84532)..."

CHAIN_ID=84532
VERIFIER_URL="https://api-sepolia.basescan.org/api"
FORGE_BIN="$HOME/.foundry/bin/forge"

echo "=== 1. Verifying UniswapV2Router02 ==="
$FORGE_BIN verify-contract 0xdEb6081F07acbcB5120E2D0a4225A0e30A19543e src/periphery/UniswapV2Router02.sol:UniswapV2Router02   --chain-id $CHAIN_ID   --verifier etherscan   --verifier-url $VERIFIER_URL   --etherscan-api-key $API_KEY   --constructor-args 0000000000000000000000007ae58f10f7849ca6f5fb71b7f45cb416c9204b1e000000000000000000000000420000000000000000000000000000000000000696e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f || true

sleep 3

echo "=== 2. Verifying SushiRouter (Venue B) ==="
$FORGE_BIN verify-contract 0x5540ac46a74D2C1c055428cc83E0f4C165b52aad src/periphery/UniswapV2Router02.sol:UniswapV2Router02   --chain-id $CHAIN_ID   --verifier etherscan   --verifier-url $VERIFIER_URL   --etherscan-api-key $API_KEY   --constructor-args 0000000000000000000000007ae58f10f7849ca6f5fb71b7f45cb416c9204b1e000000000000000000000000420000000000000000000000000000000000000696e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f || true

sleep 3

echo "=== 3. Verifying SwapExecutor ==="
$FORGE_BIN verify-contract 0x3b9822F6a5a85b02A484946466E4c10AE8DdB46b src/SwapExecutor.sol:SwapExecutor   --chain-id $CHAIN_ID   --verifier etherscan   --verifier-url $VERIFIER_URL   --etherscan-api-key $API_KEY   --constructor-args 000000000000000000000000deb6081f07acbcb5120e2d0a4225a0e30a19543e || true

sleep 3

echo "=== 4. Verifying Zap ==="
$FORGE_BIN verify-contract 0xe0C3452F0eECaBD975Bc770dF83b1bDeFf6bfC19 src/Zap.sol:Zap   --chain-id $CHAIN_ID   --verifier etherscan   --verifier-url $VERIFIER_URL   --etherscan-api-key $API_KEY   --constructor-args 000000000000000000000000deb6081f07acbcb5120e2d0a4225a0e30a19543e || true

sleep 3

echo "=== 5. Verifying TwapOracle ==="
$FORGE_BIN verify-contract 0x83Ba06204136b0df38a2906673364600f0B0b7D0 src/oracle/TwapOracle.sol:TwapOracle   --chain-id $CHAIN_ID   --verifier etherscan   --verifier-url $VERIFIER_URL   --etherscan-api-key $API_KEY   --constructor-args 000000000000000000000000000000000000000000000000000000000000070800000000000000000000000000000000000000000000000000000000000002580000000000000000000000000000000000000000000000000000000000015180 || true

sleep 3

echo "=== 6. Verifying LPVault ==="
$FORGE_BIN verify-contract 0x89EC41722e401cE1dFBE459644f68a3d7180AcA6 src/LPVault.sol:LPVault   --chain-id $CHAIN_ID   --verifier etherscan   --verifier-url $VERIFIER_URL   --etherscan-api-key $API_KEY   --constructor-args 0000000000000000000000000b9ab53880be6ff805ebf8fbce515e5715cce1be000000000000000000000000036cbd53842c5426634e7929541ec2318f3dcf7e0000000000000000000000004200000000000000000000000000000000000006000000000000000000000000e0c3452f0eecabd975bc770df83b1bdeff6bfc1900000000000000000000000083ba06204136b0df38a2906673364600f0b0b7d000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000001a5a61706c696e6520555344432d57455448204c50205661756c7400000000000000000000000000000000000000000000000000000000000000000000000000067a76555344430000000000000000000000000000000000000000000000000000 || true

sleep 3

echo "=== 7. Verifying FlashSwap ==="
$FORGE_BIN verify-contract 0x867741F11BC22dc9d898c1c8998B4D8721384536 src/FlashSwap.sol:FlashSwap   --chain-id $CHAIN_ID   --verifier etherscan   --verifier-url $VERIFIER_URL   --etherscan-api-key $API_KEY   --constructor-args 0000000000000000000000007ae58f10f7849ca6f5fb71b7f45cb416c9204b1e0000000000000000000000005540ac46a74d2c1c055428cc83e0f4c165b52aad || true

echo "=== All Verifications Finished! ==="
