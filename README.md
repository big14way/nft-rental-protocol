# NFT Rental Protocol

Rent NFTs with time-based pricing, collateral protection, and Hiro Chainhook integration for real-time analytics.

## Features

- **Time-based Pricing**: Hourly rental rates
- **Collateral System**: Security deposit returned on NFT return
- **Auto-expiry**: Owners can claim collateral if not returned
- **Real-time Tracking**: Chainhook integration for all events

## Clarity 4 Features

| Feature | Usage |
|---------|-------|
| `stacks-block-time` | Rental duration, expiry tracking |
| `restrict-assets?` | Safe payment transfers |
| `to-ascii?` | Human-readable listing info |

## Fee Structure

| Fee | Rate | Applied |
|-----|------|---------|
| Protocol Fee | 5% | On rental payment |

## Chainhook Events

| Event | Description |
|-------|-------------|
| `listing-created` | NFT listed for rent |
| `rental-started` | Rental begins |
| `rental-ended` | NFT returned |
| `fee-collected` | Protocol fee collected |
| `collateral-claimed` | Owner claims late collateral |

## Quick Start

```bash
# Deploy contracts
cd nft-rental-protocol
clarinet check && clarinet test

# Start Chainhook server
cd server && npm install && npm start

# Register chainhook
chainhook predicates scan ./chainhooks/rental-events.json --testnet
```

## Contract Functions

```clarity
;; List NFT for rent
(create-listing nft-contract token-id price-per-hour max-duration min-duration collateral)

;; Rent an NFT
(rent-nft listing-id duration-hours)

;; Return NFT
(return-nft rental-id)

;; Claim collateral (if expired)
(claim-collateral rental-id)
```

## API Endpoints

```bash
GET /api/stats         # Protocol statistics
GET /api/stats/daily   # Daily metrics
GET /api/listings      # Active listings
GET /api/rentals       # Rental history
```

## Example

```typescript
// List NFT: 1 STX/hour, 10 STX collateral
const listingId = await createListing({
    nftContract: 'ST...rental-nft',
    tokenId: 1,
    pricePerHour: 1000000,
    maxDuration: 86400,  // 24 hours
    minDuration: 3600,   // 1 hour
    collateral: 10000000 // 10 STX
});

// Rent for 5 hours (5 STX + 10 STX collateral = 15 STX)
await rentNft(listingId, 5);

// Return NFT and get 10 STX collateral back
await returnNft(rentalId);
```

## License

MIT License
