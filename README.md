# King Vaults

**Treasury management infrastructure for King Protocol - deploy idle backing assets into vetted yield-generating vaults**

## Overview

King Vaults enables King Protocol to deploy idle backing assets from the core vault into third-party yield-generating vaults, creating sustainable revenue for King Stakers and King Protocol DAO.

### The Solution

- Abstract `KingVault` contract with common treasury logic
- Concrete implementations: `KingBoringVault` (Veda) and `KingTokenizedVault` (ERC-4626)
- Only core vault can deposit/withdraw
- Launch: 2 Veda instances + 1 Concrete instance

### Key Features

- **Security First**: Formal audit, UUPS upgradeable pattern, multi-sig governance
- **Fully Backed Guarantee**: Every KING remains 1:1 backed by assets with double accounting
- **Transparent Treasury Management**: Clear on-chain tracking of deployed assets and real-time TVL
- **Controlled Governance**: Phase I team-controlled, future DAO transition planned

### Current Phase

**Phase I - Smart Contract Development**
- Timeline: ~2-3 weeks to mainnet launch (post-audit)
- Target Yield: ~20% APY on $12M in deployable assets
- Integrations: Veda Finance (KingBoringVault adapter) + Concrete (ERC-4626)

## Security

King Vaults implements defense-in-depth security practices:

- **CEI Pattern**: All state-changing functions follow Checks-Effects-Interactions pattern to prevent reentrancy
- **Reentrancy Protection**: 10+ attack simulation tests with malicious contracts validate reentrancy protections
- **Comprehensive Testing**: 500+ tests covering security edge cases, access control, input validation, and attack vectors
- **UUPS Upgradeable**: Safe upgrade pattern with multi-sig ownership controls
- **Static Analysis**: Slither security analysis integrated into development workflow
- **Access Controls**: Role-based permissions with owner and kingVault authorization

### Security Test Coverage

- Reentrancy attack simulations (`test/security/KingBoringVault.reentrancy.t.sol`)
- Input validation and boundary testing (`test/security/KingBoringVault.security.t.sol`)
- Access control verification across all privileged functions
- State consistency validation after complex operation sequences
- Pause mechanism and emergency withdrawal testing

## Documentation

- [Product Overview](./product/PRODUCT.md) - Complete product foundation
- [Mission & Vision](./product/mission.md) - Product purpose and stakeholder map
- [Roadmap](./product/roadmap.md) - Phase I milestones and launch plan
- [Tech Stack](./product/tech-stack.md) - Architecture and technical decisions
- [Foundry Book](https://book.getfoundry.sh/) - Development framework documentation

## Deployment

King Vaults uses a secure, hardware-wallet-friendly deployment automation system. See the [Deployment Guide](./docs/deployment-guide.md) for complete instructions.

### Quick Start

1. **Set up environment variables** (credentials are NOT stored in config files):
   ```shell
   # Copy example file
   cp .env.example .env

   # Edit .env with your credentials
   # For Ethereum Mainnet (Chain ID: 1)
   RPC_URL_1=https://mainnet.infura.io/v3/YOUR_INFURA_KEY
   ETHERSCAN_API_KEY_1=YOUR_ETHERSCAN_API_KEY

   # Load environment variables
   source .env
   ```

2. **Configure vaults** in `config/vaults.toml`:
   ```toml
   [[vaults]]
   id = "boring-vault-sethfi"
   network = 1  # Ethereum Mainnet
   # ... set all addresses
   ```

3. **Simulate deployment** (dry run):
   ```shell
   forge script script/DeployKingBoringVault.s.sol \
     --sig "deploy(string)" "boring-vault-sethfi"
   ```

4. **Deploy with Ledger** (mainnet):
   ```shell
   forge script script/DeployKingBoringVault.s.sol \
     --sig "deploy(string)" "boring-vault-sethfi" \
     --ledger --broadcast --verify
   ```

5. **Deploy with named account** (testnet):
   ```shell
   forge script script/DeployKingBoringVault.s.sol \
     --sig "deploy(string)" "boring-vault-sethfi" \
     --account deployer --broadcast --verify
   ```

### Key Features

- **Zero private key exposure** - Uses Ledger or Foundry keystore only
- **Simulation mode** - Test deployments before broadcasting
- **TOML configuration** - Manage multiple vaults in one file
- **Profit distribution** - Automatically configured during deployment
- **Etherscan verification** - Built-in contract verification

## Development

### Build

```shell
$ forge build
```

### Test

```shell
# Run all tests
$ forge test

# Run security tests only
$ forge test --match-path "test/security/*"

# Run reentrancy attack simulations
$ forge test --match-path "test/security/KingBoringVault.reentrancy.t.sol"

# Run with gas reporting
$ forge test --gas-report

# Check contract sizes
$ forge build --sizes
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
