# KingTokenizedVault Monitoring Guide

## Overview

This guide provides monitoring strategies, key metrics, alert thresholds, and incident response procedures for KingTokenizedVault deployments. Proper monitoring is essential for ensuring vault security, performance, and user experience.

## Key Performance Metrics

### 1. Total Value Locked (TVL)

**What it measures**: Principal deposits in ETH value

**How to monitor**:
```bash
# Get TVL in ETH (18 decimals)
cast call $VAULT_PROXY "tvl()(uint256)"
```

**Alert Thresholds**:
- **Critical**: 50%+ drop in 24 hours (possible security incident)
- **Warning**: 25%+ drop in 24 hours (investigate user withdrawals)
- **Info**: 10%+ change in 1 hour (normal volatility)

**What to check**:
- Large withdrawal transactions
- Unusual asset transfers
- Price oracle accuracy

---

### 2. Vault Shares Balance

**What it measures**: Total ERC-4626 shares held by the vault

**How to monitor**:
```bash
# Get total shares
cast call $VAULT_PROXY "getVaultShares()(uint256)"
```

**Alert Thresholds**:
- **Critical**: Shares = 0 with TVL > 0 (accounting error)
- **Warning**: Shares decrease without corresponding withdrawal
- **Info**: Normal fluctuations during operations

**What to check**:
- Recent depositToVault transactions
- Recent withdrawFromVault transactions
- Share-to-asset conversion rate

---

### 3. Share Value Appreciation

**What it measures**: Current value of shares vs. principal

**How to monitor**:
```bash
# Get current profit in ETH
cast call $VAULT_PROXY "calculateProfit()(uint256)"

# Get share conversion rate
cast call $ERC4626_VAULT "convertToAssets(uint256)(uint256)" 1000000000000000000
```

**Alert Thresholds**:
- **Critical**: Share value < principal (loss of funds)
- **Warning**: Share value unchanged for 7+ days (no yield generation)
- **Info**: Regular profit > 1% (successful yield farming)

**What to check**:
- ERC-4626 vault performance
- Asset price movements
- Yield strategy health

---

### 4. Available Balance

**What it measures**: Assets available for withdrawal to King vault

**How to monitor**:
```bash
# Get available balance for specific asset
cast call $VAULT_PROXY "availableForWithdraw(address)(uint256)" $ASSET_ADDRESS
```

**Alert Thresholds**:
- **Critical**: Available < queued withdrawals (liquidity crisis)
- **Warning**: Available < 10% of TVL (low liquidity)
- **Info**: Available > 50% of TVL (idle capital)

**What to check**:
- Deployment ratio (deployed vs. idle)
- Pending withdrawal requests
- ERC-4626 vault liquidity

---

### 5. Pending Shares (Async Mode Only)

**What it measures**: Shares locked in pending withdrawals

**How to monitor**:
```bash
# Get withdrawal request details
cast call $VAULT_PROXY \
  "getWithdrawalRequest(address)(address,uint256,uint256,uint64,bool)" \
  $ASSET_ADDRESS
```

**Alert Thresholds**:
- **Critical**: Pending > 24 hours past deadline (stuck withdrawal)
- **Warning**: Pending > 50% of total shares (high lock-up)
- **Info**: Multiple pending requests for same asset

**What to check**:
- Withdrawal deadlines
- ERC-4626 vault withdrawal queue status
- Need to call completeWithdrawal()

---

### 6. Gas Costs

**What it measures**: Transaction costs for operations

**How to monitor**:
```bash
# Check recent transaction gas usage
cast tx $TX_HASH | grep gasUsed
```

**Operations to track**:
- `depositToVault()`: ~100-150k gas (atomic), ~150-200k gas (async)
- `withdrawFromVault()`: ~150-200k gas (atomic), ~100-150k gas (async queue)
- `completeWithdrawal()`: ~150-200k gas (async only)
- `harvestProfits()`: ~200-300k gas
- `distributeProfits()`: ~100-150k gas

**Alert Thresholds**:
- **Critical**: Gas usage 3x+ normal (contract issue)
- **Warning**: Gas usage 2x+ normal (inefficiency)
- **Info**: Gas price spike (network congestion)

---

### 7. Slippage Events

**What it measures**: Actual vs. expected shares/assets received

**How to monitor**:
```bash
# Monitor for SlippageExceeded events
cast logs --from-block $START_BLOCK \
  --address $VAULT_PROXY \
  --event "SlippageExceeded(uint256,uint256)"
```

**Alert Thresholds**:
- **Critical**: Multiple slippage events in 1 hour
- **Warning**: Single slippage event
- **Info**: Slippage within 10% of limit

**What to check**:
- ERC-4626 vault price manipulation
- Current maxSlippageBPS setting
- Market volatility

---

## Dashboard Setup

### Recommended Tools

1. **Dune Analytics**: On-chain data visualization
2. **Tenderly**: Transaction monitoring and alerts
3. **OpenZeppelin Defender**: Automated monitoring and incident response
4. **Custom scripts**: Using cast/web3/ethers

### Essential Dashboard Panels

#### Panel 1: TVL Overview
```sql
-- Dune Analytics query example
SELECT
  block_time,
  tvl_eth / 1e18 as tvl_eth,
  tvl_usd
FROM king_vault_metrics
WHERE vault_address = {{vault_proxy}}
ORDER BY block_time DESC
```

#### Panel 2: Share Performance
- Share balance over time
- Share-to-asset conversion rate
- Calculated profit (ETH)
- Profit percentage

#### Panel 3: Operations Log
- Recent deposits
- Recent withdrawals
- Profit harvests
- Profit distributions

#### Panel 4: Health Metrics
- Available balance ratio
- Pending shares ratio (async mode)
- Slippage events
- Failed transactions

---

## Monitoring Strategy by Mode

### Atomic Mode Monitoring

**Focus areas**:
1. Immediate transaction success/failure
2. Slippage protection effectiveness
3. Gas cost optimization
4. Share conversion rate accuracy

**Key metrics**:
- Transaction success rate
- Average gas per operation
- Slippage events frequency
- Share value drift

**Monitoring frequency**:
- Real-time: Transaction failures, slippage events
- Hourly: Gas costs, share value
- Daily: TVL, profit calculation
- Weekly: Performance review

---

### Async Mode Monitoring

**Focus areas**:
1. Withdrawal queue management
2. Deadline tracking
3. Two-phase transaction completion
4. Locked share ratio

**Key metrics**:
- Pending withdrawal count
- Average time to completion
- Deadline expiration events
- Cancellation frequency

**Monitoring frequency**:
- Real-time: New withdrawal requests, deadline approaching
- Every 4 hours: Pending withdrawal status
- Daily: Queue depth, completion rate
- Weekly: Average completion time

---

## Alert Configuration

### Critical Alerts (Immediate Response Required)

```yaml
# Example alert configuration (OpenZeppelin Defender)
alerts:
  - name: "TVL Crash"
    condition: "tvl_drop_percent_24h > 50"
    severity: "CRITICAL"
    notification: ["pagerduty", "slack", "email"]

  - name: "Withdrawal Slippage"
    condition: "event.SlippageExceeded"
    severity: "CRITICAL"
    notification: ["pagerduty", "slack"]

  - name: "Shares Lost"
    condition: "vault_shares == 0 AND tvl > 0"
    severity: "CRITICAL"
    notification: ["pagerduty", "slack", "sms"]

  - name: "Share Value Loss"
    condition: "profit < 0"
    severity: "CRITICAL"
    notification: ["pagerduty", "slack"]
```

### Warning Alerts (Review Within 1 Hour)

```yaml
alerts:
  - name: "Low Liquidity"
    condition: "available_balance_ratio < 0.1"
    severity: "WARNING"
    notification: ["slack", "email"]

  - name: "Stale Withdrawal"
    condition: "pending_withdrawal_hours > 24"
    severity: "WARNING"
    notification: ["slack", "email"]

  - name: "No Yield"
    condition: "profit_unchanged_days > 7"
    severity: "WARNING"
    notification: ["email"]

  - name: "High Gas Cost"
    condition: "gas_usage_multiplier > 2"
    severity: "WARNING"
    notification: ["slack"]
```

### Info Alerts (Daily Review)

```yaml
alerts:
  - name: "Large Deposit"
    condition: "deposit_amount_eth > 100"
    severity: "INFO"
    notification: ["slack"]

  - name: "Profit Available"
    condition: "calculate_profit > threshold"
    severity: "INFO"
    notification: ["slack"]

  - name: "Config Changed"
    condition: "event.MaxSlippageUpdated OR event.WithdrawalDurationUpdated"
    severity: "INFO"
    notification: ["slack"]
```

---

## Incident Response Procedures

### Incident 1: TVL Crash (50%+ drop)

**Immediate Actions**:
1. Pause vault: `cast send $VAULT_PROXY "pause()" --account $OWNER`
2. Check recent transactions on Etherscan
3. Verify price oracle accuracy
4. Check ERC-4626 vault health

**Investigation**:
- Was there a legitimate large withdrawal?
- Price oracle manipulation?
- ERC-4626 vault compromise?
- Accounting bug in our contract?

**Resolution**:
- If legitimate: Unpause, update documentation
- If bug: Deploy fix, upgrade contract
- If external: Coordinate with ERC-4626 vault team

---

### Incident 2: Slippage Event

**Immediate Actions**:
1. Review transaction details
2. Check current share conversion rate
3. Compare with expected rate
4. Verify maxSlippageBPS setting

**Investigation**:
- Market volatility or manipulation?
- ERC-4626 vault issues?
- Incorrect slippage configuration?

**Resolution**:
- Adjust maxSlippageBPS if needed
- Wait for better market conditions
- Consider pausing high-risk operations

---

### Incident 3: Stuck Withdrawal (Async Mode)

**Immediate Actions**:
1. Check withdrawal request details
2. Verify ERC-4626 vault withdrawal queue
3. Check if deadline expired

**Investigation**:
- Is ERC-4626 vault processing withdrawals?
- Is our contract waiting for external event?
- Did we miss calling completeWithdrawal()?

**Resolution**:
- Call completeWithdrawal() if ready
- Cancel and re-queue if expired
- Coordinate with ERC-4626 vault if stuck

---

### Incident 4: Share Value Loss

**Immediate Actions**:
1. **PAUSE IMMEDIATELY**: `cast send $VAULT_PROXY "pause()"`
2. Calculate exact loss amount
3. Check ERC-4626 vault status
4. Review all recent transactions

**Investigation**:
- ERC-4626 vault exploit or failure?
- Price oracle manipulation?
- Accounting error in our contract?
- Malicious transaction?

**Resolution**:
- Coordinate with ERC-4626 vault team
- Assess recovery options
- Consider emergency withdrawal
- File incident report

---

## Automation Scripts

### Daily Health Check

```bash
#!/bin/bash
# daily-health-check.sh

VAULT=$1

echo "=== KingTokenizedVault Health Check ==="
echo "Vault: $VAULT"
echo ""

# TVL
echo "TVL (ETH):"
cast call $VAULT "tvl()(uint256)" | awk '{print $1/1e18}'

# Shares
echo "Vault Shares:"
cast call $VAULT "getVaultShares()(uint256)"

# Profit
echo "Profit (ETH):"
cast call $VAULT "calculateProfit()(uint256)" | awk '{print $1/1e18}'

# Available balance (for main asset)
echo "Available Balance:"
cast call $VAULT "availableForWithdraw(address)(uint256)" $ASSET

# Is paused?
echo "Paused:"
cast call $VAULT "paused()(bool)"
```

### Withdrawal Monitor (Async Mode)

```bash
#!/bin/bash
# withdrawal-monitor.sh

VAULT=$1
ASSET=$2

# Get withdrawal request
REQUEST=$(cast call $VAULT \
  "getWithdrawalRequest(address)(address,uint256,uint256,uint64,bool)" \
  $ASSET)

if [ -z "$REQUEST" ]; then
  echo "No pending withdrawal"
  exit 0
fi

# Parse deadline
DEADLINE=$(echo $REQUEST | awk '{print $4}')
NOW=$(date +%s)

if [ $NOW -gt $DEADLINE ]; then
  echo "WARNING: Withdrawal expired!"
  echo "Deadline: $DEADLINE"
  echo "Current: $NOW"
else
  REMAINING=$((DEADLINE - NOW))
  echo "Withdrawal pending"
  echo "Time remaining: $REMAINING seconds"
fi
```

---

## Best Practices

1. **Set up redundant monitoring**: Use multiple tools (Defender, Tenderly, custom scripts)
2. **Test alerts**: Regularly verify alert delivery and response procedures
3. **Document incidents**: Keep detailed logs of all incidents and resolutions
4. **Review metrics weekly**: Look for trends and potential issues
5. **Automate responses**: Where safe, automate common responses (e.g., calling completeWithdrawal)
6. **Keep runbooks updated**: Maintain up-to-date incident response procedures
7. **Monitor dependencies**: Track ERC-4626 vault health, price oracles, etc.
8. **Set realistic thresholds**: Avoid alert fatigue with appropriate threshold settings
9. **Regular audits**: Periodically audit monitoring coverage and effectiveness
10. **Team training**: Ensure team members know how to respond to alerts

---

## Additional Resources

- [OpenZeppelin Defender Documentation](https://docs.openzeppelin.com/defender/)
- [Tenderly Monitoring Guide](https://docs.tenderly.co/monitoring/intro-to-monitoring)
- [Dune Analytics for DeFi](https://dune.com/docs/)
- [Deployment Guide](./deployment-guide-tokenized-vault.md)
