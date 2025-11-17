# KingTokenizedVault Deployment Guide

## Overview

This guide covers deploying and upgrading KingTokenizedVault contracts using the automated deployment scripts. KingTokenizedVault integrates with ERC-4626 compliant vaults (like Concrete) and supports both atomic and async withdrawal modes.

## Prerequisites

1. **Foundry installed**: `curl -L https://foundry.paradigm.xyz | bash && foundryup`
2. **Environment variables**: RPC URL and Etherscan API key configured (see Setup)
3. **Configuration file**: `config/vaults.toml` with your vault parameters
4. **Authentication**: Either Ledger hardware wallet or Foundry named account
5. **ERC-4626 Vault**: Deployed and verified ERC-4626 vault address

## Understanding Withdrawal Modes

KingTokenizedVault supports two withdrawal modes (set at deployment, immutable):

### Atomic Mode (`is_atomic = true`)
- Withdrawals complete immediately in a single transaction
- Uses ERC-4626's `deposit()` and `redeem()` functions directly
- Suitable for vaults with no withdrawal delays
- Lower complexity, fewer transactions required

### Async Mode (`is_atomic = false`)
- Withdrawals are queued and completed in separate transactions
- Useful for vaults with withdrawal delays or unlock periods
- Includes deadline management and cancellation capability
- Higher complexity, requires multiple transactions

**Choose atomic mode** unless your ERC-4626 vault has withdrawal delays.

## Setup

### 1. Configure Environment Variables

**IMPORTANT**: RPC URLs and Etherscan API keys are loaded from environment variables to keep credentials secure and out of version control.

#### Option A: Using .env file (Recommended)

```bash
# Copy the example file
cp .env.example .env

# Edit .env with your actual credentials
# For Ethereum Mainnet (Chain ID: 1)
RPC_URL_1=https://mainnet.infura.io/v3/YOUR_INFURA_KEY
ETHERSCAN_API_KEY_1=YOUR_ETHERSCAN_API_KEY

# For Sepolia Testnet (Chain ID: 11155111)
RPC_URL_11155111=https://sepolia.infura.io/v3/YOUR_INFURA_KEY
ETHERSCAN_API_KEY_11155111=YOUR_ETHERSCAN_API_KEY

# Load environment variables
source .env
```

#### Option B: Export directly (Session-only)

```bash
# For Ethereum Mainnet (Chain ID: 1)
export RPC_URL_1="https://mainnet.infura.io/v3/YOUR_INFURA_KEY"
export ETHERSCAN_API_KEY_1="YOUR_ETHERSCAN_API_KEY"

# For Sepolia Testnet (Chain ID: 11155111)
export RPC_URL_11155111="https://sepolia.infura.io/v3/YOUR_INFURA_KEY"
export ETHERSCAN_API_KEY_11155111="YOUR_ETHERSCAN_API_KEY"
```

**Environment Variable Naming Convention:**
- RPC URL: `RPC_URL_{chainId}` (e.g., `RPC_URL_1` for mainnet)
- Etherscan API Key: `ETHERSCAN_API_KEY_{chainId}` (e.g., `ETHERSCAN_API_KEY_1` for mainnet)

### 2. Configure Named Account (Recommended for Testnet)

```bash
# Create named account
cast wallet import $KINGPROTOCOL --interactive

# Verify account
cast wallet list
```

### 2. Configure Ledger (Required for Mainnet)

1. Connect Ledger device
2. Open Ethereum app
3. Enable "Contract data" in settings
4. Enable "Blind signing" if required

### 3. Update Configuration

Edit `config/vaults.toml`:

```toml
[[vaults]]
id = "tokenized-vault-concrete-atomic"
network = 1  # Mainnet
type = "KingTokenizedVault"
name = "King Concrete Vault"
symbol = "kingCON"
decimals = 18

# Core addresses
owner = "0x..." # Protocol owner (can upgrade, configure)
king_vault = "0x..." # King Protocol core vault
price_provider = "0x..." # Price oracle for TVL calculations

# ERC-4626 integration (immutable - cannot be changed after deployment)
vault_address = "0x..." # ERC-4626 vault contract address
is_atomic = true # Withdrawal mode: true = atomic, false = async

# Assets to support (must match ERC-4626 vault's underlying asset)
assets = [
    "0x...", # Underlying asset of ERC-4626 vault
]

# Profit distribution
profit_recipients = ["0x..."]
profit_percents_bps = [10000] # 100% = 10000 BPS
```

### 4. Verify ERC-4626 Vault Compatibility

Before deployment, verify the target vault:

```bash
# Check vault address
cast call $VAULT_ADDRESS "asset()(address)"

# Check conversion rate
cast call $VAULT_ADDRESS "convertToAssets(uint256)(uint256)" 1000000000000000000

# Test withdrawal support (atomic mode only)
cast call $VAULT_ADDRESS "maxRedeem(address)(uint256)" $YOUR_ADDRESS
```

## Deployment

### Simulation (Dry Run)

Always simulate first to verify configuration:

```bash
forge script script/DeployKingTokenizedVault.s.sol \
  --sig "deploy(string)" "tokenized-vault-concrete-atomic" \
  --account $KINGPROTOCOL
```

**Review simulation output carefully:**
- Verify all addresses are correct
- Check withdrawal mode (Atomic/Async)
- Confirm asset addresses match ERC-4626 vault
- Verify profit distribution totals 100%

### Execute Deployment (Testnet)

Deploy to testnet first:

```bash
forge script script/DeployKingTokenizedVault.s.sol \
  --sig "deploy(string)" "tokenized-vault-concrete-atomic" \
  --account $KINGPROTOCOL --broadcast --verify
```

### Execute Deployment (Mainnet)

After successful testnet deployment and testing:

```bash
# With Ledger (RECOMMENDED for mainnet)
forge script script/DeployKingTokenizedVault.s.sol \
  --sig "deploy(string)" "tokenized-vault-concrete-atomic" \
  --ledger --broadcast --verify

# With named account (use with caution on mainnet)
forge script script/DeployKingTokenizedVault.s.sol \
  --sig "deploy(string)" "tokenized-vault-concrete-atomic" \
  --account $KINGPROTOCOL --broadcast --verify
```

## Post-Deployment Configuration

After deployment, configure the vault:

### 1. Set Slippage Tolerance (Optional)

Default is 0.5% (50 BPS). Adjust if needed:

```bash
# Set to 1% (100 BPS)
cast send $VAULT_PROXY \
  "setMaxSlippage(uint16)" 100 \
  --account $KINGPROTOCOL
```

### 2. Set Withdrawal Duration (Async Mode Only)

Default is 7 days. Adjust if needed:

```bash
# Set to 3 days
cast send $VAULT_PROXY \
  "setWithdrawalDuration(uint64)" 259200 \
  --account $KINGPROTOCOL
```

### 3. Verify Deployment

```bash
# Check owner
cast call $VAULT_PROXY "owner()(address)"

# Check ERC-4626 vault (immutable)
cast call $VAULT_PROXY "vault()(address)"

# Check withdrawal mode (immutable)
cast call $VAULT_PROXY "isAtomic()(bool)"

# Check TVL
cast call $VAULT_PROXY "tvl()(uint256)"
```

## Operational Workflows

### Atomic Mode Workflow

1. **Deposit from King Vault** → `deposit()`
2. **Deploy to ERC-4626** → `depositToVault(asset, amount)`
3. **Withdraw from ERC-4626** → `withdrawFromVault(asset, shares, false)`
4. **Return to King Vault** → King vault calls `withdraw()`

### Async Mode Workflow

1. **Deposit from King Vault** → `deposit()`
2. **Deploy to ERC-4626** → `depositToVault(asset, amount)`
3. **Queue withdrawal** → `withdrawFromVault(asset, shares, false)`
4. **Complete withdrawal** → `completeWithdrawal(asset)`
5. **Return to King Vault** → King vault calls `withdraw()`

### Profit Harvesting (Both Modes)

1. **Calculate profit** → `calculateProfit()` (view function)
2. **Harvest profits** → `harvestProfits()`
3. **Complete if async** → `completeWithdrawal(asset)` (async only)
4. **Distribute** → `distributeProfits()`

## Upgrades

### 1. Generate Storage Layout (Before Changes)

```bash
forge inspect src/vaults/KingTokenizedVault.sol:KingTokenizedVault \
  storage-layout --pretty > storage-layout-old.txt
```

### 2. Make Code Changes

Edit contract implementation as needed.

### 3. Validate Storage Compatibility

```bash
# Generate new layout and simulate upgrade
forge script script/UpgradeKingTokenizedVault.s.sol \
  --sig "upgrade(string)" "tokenized-vault-concrete-atomic" \
  --account $KINGPROTOCOL

# Compare layouts
diff storage-layout-old.txt storage-layout-new.txt
```

**IMPORTANT**: No differences should appear unless you intentionally added new storage variables at the END.

### 4. Execute Upgrade

After validating storage compatibility:

```bash
# With Ledger (recommended for mainnet)
forge script script/UpgradeKingTokenizedVault.s.sol \
  --sig "upgrade(string)" "tokenized-vault-concrete-atomic" \
  --ledger --broadcast
```

## Troubleshooting

### "Vault type mismatch"

The vault ID you specified is not configured with `type = "KingTokenizedVault"` in config. Check:
- Vault ID spelling matches exactly
- Type is set to "KingTokenizedVault" (not "KingBoringVault")

### "Invalid ERC-4626 vault address"

The vault address is zero or invalid. Verify:
- `vault_address` is set in config
- Address is a valid ERC-4626 contract
- Contract implements required functions (`asset()`, `deposit()`, `redeem()`)

### "Slippage exceeded"

Actual shares/assets received were less than expected. Solutions:
- Increase `maxSlippageBPS` via `setMaxSlippage()`
- Wait for better market conditions
- Check for vault-specific issues (fees, delays)

### "Withdrawal not queued" (Async Mode)

Attempting to complete a non-existent withdrawal. Verify:
- You called `withdrawFromVault()` first
- Using correct asset address
- Withdrawal wasn't already completed or cancelled

### "Invalid withdrawal mode"

Calling async-specific functions in atomic mode (or vice versa). Remember:
- `completeWithdrawal()` only works in async mode
- `cancelWithdrawal()` only works in async mode
- Withdrawal mode is immutable (set at deployment)

### Ledger not detected

1. Ensure device is unlocked
2. Ethereum app is open
3. "Contract data" enabled in settings
4. Try different USB port/cable

## Security Best Practices

1. **Always simulate first** - Never broadcast without reviewing simulation output
2. **Verify addresses** - Double-check all addresses in config before mainnet deployment
3. **Verify ERC-4626 vault** - Ensure target vault is audited and trusted
4. **Test withdrawal mode** - Deploy in testnet and test full lifecycle
5. **Storage validation** - ALWAYS compare storage layouts before upgrades
6. **Test on testnet** - Deploy to Sepolia first, verify everything works
7. **Use Ledger for mainnet** - Hardware wallet provides best security
8. **Backup config** - Keep secure backups of `config/vaults.toml`
9. **Monitor slippage** - Set conservative limits initially
10. **Emergency procedures** - Know how to pause and upgrade in emergencies

## Examples

### Deploy Atomic Mode to Mainnet

```bash
forge script script/DeployKingTokenizedVault.s.sol \
  --sig "deploy(string)" "tokenized-vault-concrete-atomic" \
  --ledger --broadcast --verify
```

### Deploy Async Mode to Testnet

```bash
forge script script/DeployKingTokenizedVault.s.sol \
  --sig "deploy(string)" "tokenized-vault-concrete-async" \
  --account $KINGPROTOCOL --broadcast --verify
```

### Upgrade on Mainnet

```bash
# 1. Simulate and review storage
forge script script/UpgradeKingTokenizedVault.s.sol \
  --sig "upgrade(string)" "tokenized-vault-concrete-atomic" \
  --ledger

# 2. Review diff
diff storage-layout-old.txt storage-layout-new.txt

# 3. Execute if safe
forge script script/UpgradeKingTokenizedVault.s.sol \
  --sig "upgrade(string)" "tokenized-vault-concrete-atomic" \
  --ledger --broadcast
```

### Complete Async Withdrawal

```bash
# Owner calls completeWithdrawal after queueing
cast send $VAULT_PROXY \
  "completeWithdrawal(address)" $ASSET_ADDRESS \
  --account $KINGPROTOCOL
```

### Harvest and Distribute Profits

```bash
# 1. Harvest profits (queues withdrawal in async mode)
cast send $VAULT_PROXY "harvestProfits()" --account $KINGPROTOCOL

# 2. Complete withdrawal (async mode only)
cast send $VAULT_PROXY \
  "completeWithdrawal(address)" $ASSET_ADDRESS \
  --account $KINGPROTOCOL

# 3. Distribute to recipients
cast send $VAULT_PROXY "distributeProfits()" --account $KINGPROTOCOL
```

## Post-Deployment Checklist

- [ ] Save implementation and proxy addresses
- [ ] Verify contracts on Etherscan (if --verify used)
- [ ] Test deposit from King vault
- [ ] Test depositToVault to ERC-4626
- [ ] Test withdrawal flow (full cycle)
- [ ] Verify profit calculation accuracy
- [ ] Test pause/unpause functionality
- [ ] Configure monitoring alerts
- [ ] Update project documentation
- [ ] Notify team of deployment details

## Additional Resources

- [ERC-4626 Standard](https://eips.ethereum.org/EIPS/eip-4626)
- [UUPS Proxy Pattern](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable)
- [Foundry Book](https://book.getfoundry.sh/)
- [Monitoring Guide](./monitoring-guide-tokenized-vault.md)
