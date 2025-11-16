#!/bin/bash
# End-to-end deployment testing script
# Tests deployment automation on local fork

set -e  # Exit on error

echo "=== E2E Deployment Test ==="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT=$(git rev-parse --show-toplevel)
cd "$PROJECT_ROOT"

# Test vault ID
TEST_VAULT="boring-vault-sethfi"

# Step 1: Test simulation mode
echo "=== Step 1: Testing Simulation Mode ==="
forge script script/DeployKingBoringVault.s.sol \
  --sig "deploy(string)" "$TEST_VAULT" \
  || { echo -e "${RED}Simulation failed${NC}"; exit 1; }

echo -e "${GREEN}Simulation test passed${NC}"
echo ""

# Step 2: Test on local Anvil fork
echo "=== Step 2: Testing on Local Fork ==="

# Start Anvil in background
anvil --fork-url "$MAINNET_RPC_URL" &
ANVIL_PID=$!

# Wait for Anvil to start
sleep 2

# Test deployment
forge script script/DeployKingBoringVault.s.sol \
  --sig "deploy(string)" "$TEST_VAULT" \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast \
  || { echo -e "${RED}Deployment failed${NC}"; kill $ANVIL_PID; exit 1; }

echo -e "${GREEN}Local deployment test passed${NC}"
echo ""

# Step 3: Verify deployment
echo "=== Step 3: Verifying Deployment ==="

# Extract deployed proxy address
PROXY_ADDR=$(cat broadcast/DeployKingBoringVault.s.sol/31337/run-latest.json | jq -r '.transactions[-1].contractAddress')

echo "Deployed proxy: $PROXY_ADDR"

if [ "$PROXY_ADDR" = "null" ] || [ -z "$PROXY_ADDR" ]; then
    echo -e "${RED}Failed to extract proxy address${NC}"
    kill $ANVIL_PID
    exit 1
fi

echo -e "${GREEN}Deployment verification passed${NC}"
echo ""

# Step 4: Test storage layout generation
echo "=== Step 4: Testing Storage Layout Generation ==="

forge inspect src/vaults/KingBoringVault.sol:KingBoringVault \
  storage-layout --pretty > test-layout.txt \
  || { echo -e "${RED}Storage layout generation failed${NC}"; kill $ANVIL_PID; exit 1; }

if [ ! -s test-layout.txt ]; then
    echo -e "${RED}Storage layout file is empty${NC}"
    kill $ANVIL_PID
    exit 1
fi

echo -e "${GREEN}Storage layout generation passed${NC}"
echo ""

# Cleanup
echo "=== Cleanup ==="
kill $ANVIL_PID
rm -f test-layout.txt
echo "Anvil stopped"
echo ""

echo -e "${GREEN}=== All E2E Tests Passed ===${NC}"
