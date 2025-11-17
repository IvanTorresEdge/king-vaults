# KingBoringVault Deployment Guide

## Overview

This guide covers deploying and upgrading KingBoringVault contracts using the automated deployment scripts.

## Prerequisites

1. **Foundry installed**: `curl -L https://foundry.paradigm.xyz | bash && foundryup`
2. **Configuration file**: `config/vaults.toml` with your vault parameters
3. **Authentication**: Either Ledger hardware wallet or Foundry named account

## Setup

### 1. Configure Named Account (Recommended for Testnet)

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
id = "boring-vault-sethfi"
network = 1  # Mainnet
# ... update all addresses ...
```

## Deployment

### Simulation (Dry Run)

Always simulate first:

```bash
forge script script/DeployKingBoringVault.s.sol \
  --sig "deploy(string)" "boring-vault-sethfi" \
  --account $KINGPROTOCOL
```

### Execute Deployment

After verifying simulation output:

```bash
# With named account
forge script script/DeployKingBoringVault.s.sol \
  --sig "deploy(string)" "boring-vault-sethfi" \
  --account $KINGPROTOCOL --broadcast --verify

# With Ledger
forge script script/DeployKingBoringVault.s.sol \
  --sig "deploy(string)" "boring-vault-sethfi" \
  --ledger --broadcast --verify
```

## Upgrades

### 1. Generate Storage Layout (Before Changes)

```bash
forge inspect src/vaults/KingBoringVault.sol:KingBoringVault \
  storage-layout --pretty > storage-layout-old.txt
```

### 2. Make Code Changes

Edit contract implementation as needed.

### 3. Validate Storage Compatibility

```bash
# Generate new layout
forge script script/UpgradeKingBoringVault.s.sol \
  --sig "upgrade(string)" "boring-vault-sethfi" \
  --account $KINGPROTOCOL

# Compare layouts
diff storage-layout-old.txt storage-layout-new.txt
```

**IMPORTANT**: No differences should appear unless you intentionally added new storage variables at the END.

### 4. Execute Upgrade

After validating storage compatibility:

```bash
# With Ledger (recommended for mainnet)
forge script script/UpgradeKingBoringVault.s.sol \
  --sig "upgrade(string)" "boring-vault-sethfi" \
  --ledger --broadcast
```

## Troubleshooting

### "No authentication method specified"

Add either `--ledger` or `--account <name>` to your command.

### "Vault ID not found in config"

Check that `config/vaults.toml` contains your vault ID and spelling matches exactly.

### "Storage layout mismatch"

DO NOT PROCEED with upgrade. Review your changes - you may have:
- Reordered existing storage variables (NEVER do this)
- Changed variable types (dangerous)
- Removed variables (dangerous)

Only ADD new variables at the END of storage.

### Ledger not detected

1. Ensure device is unlocked
2. Ethereum app is open
3. "Contract data" enabled in settings
4. Try different USB port/cable

## Security Best Practices

1. **Always simulate first** - Never broadcast without reviewing simulation output
2. **Verify addresses** - Double-check all addresses in config before mainnet deployment
3. **Storage validation** - ALWAYS compare storage layouts before upgrades
4. **Test on testnet** - Deploy to Sepolia first, verify everything works
5. **Use Ledger for mainnet** - Hardware wallet provides best security
6. **Backup config** - Keep secure backups of `config/vaults.toml`

## Post-Deployment

1. **Save addresses**: Record implementation and proxy addresses
2. **Verify on Etherscan**: Confirm contracts are verified (if --verify used)
3. **Test basic functions**: Call view functions to ensure initialization worked
4. **Update documentation**: Record deployment in project docs

## Examples

### Deploy to Mainnet with Ledger

```bash
forge script script/DeployKingBoringVault.s.sol \
  --sig "deploy(string)" "boring-vault-sethfi" \
  --ledger --broadcast --verify
```

### Upgrade on Mainnet

```bash
# 1. Simulate and review storage
forge script script/UpgradeKingBoringVault.s.sol \
  --sig "upgrade(string)" "boring-vault-sethfi" \
  --ledger

# 2. Review diff
diff storage-layout-old.txt storage-layout-new.txt

# 3. Execute if safe
forge script script/UpgradeKingBoringVault.s.sol \
  --sig "upgrade(string)" "boring-vault-sethfi" \
  --ledger --broadcast
```
