import { Clarinet, Tx, Chain, Account, types } from 'https://deno.land/x/clarinet@v1.7.1/index.ts';
import { assertEquals, assertExists } from 'https://deno.land/std@0.170.0/testing/asserts.ts';

Clarinet.test({
    name: "Can create NFT listing",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const owner = accounts.get('wallet_1')!;
        
        let block = chain.mineBlock([
            Tx.contractCall('rental-manager', 'create-listing', [
                types.principal(`${owner.address}.rental-nft`),
                types.uint(1),
                types.uint(1000000), // 1 STX per hour
                types.uint(86400),   // Max 24 hours
                types.uint(3600),    // Min 1 hour
                types.uint(10000000) // 10 STX collateral
            ], owner.address)
        ]);
        
        block.receipts[0].result.expectOk().expectUint(1);
    }
});

Clarinet.test({
    name: "Protocol fee is 5%",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const user = accounts.get('wallet_1')!;
        
        let fee = chain.callReadOnlyFn(
            'rental-manager',
            'calculate-fee',
            [types.uint(100000000)], // 100 STX
            user.address
        );
        
        assertEquals(fee.result, 'u5000000'); // 5 STX (5%)
    }
});

Clarinet.test({
    name: "Can calculate rental price",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const owner = accounts.get('wallet_1')!;
        
        // Create listing first
        chain.mineBlock([
            Tx.contractCall('rental-manager', 'create-listing', [
                types.principal(`${owner.address}.rental-nft`),
                types.uint(1),
                types.uint(1000000), // 1 STX per hour
                types.uint(86400),
                types.uint(3600),
                types.uint(10000000)
            ], owner.address)
        ]);
        
        let price = chain.callReadOnlyFn(
            'rental-manager',
            'calculate-rental-price',
            [types.uint(1), types.uint(5)], // 5 hours
            owner.address
        );
        
        assertEquals(price.result, 'u5000000'); // 5 STX
    }
});

Clarinet.test({
    name: "Minimum duration is enforced",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const owner = accounts.get('wallet_1')!;
        
        // Try to create listing with duration less than MIN_DURATION (1 hour)
        let block = chain.mineBlock([
            Tx.contractCall('rental-manager', 'create-listing', [
                types.principal(`${owner.address}.rental-nft`),
                types.uint(1),
                types.uint(1000000),
                types.uint(86400),
                types.uint(1800), // 30 minutes - too short
                types.uint(10000000)
            ], owner.address)
        ]);
        
        block.receipts[0].result.expectErr().expectUint(21003); // ERR_INVALID_DURATION
    }
});

Clarinet.test({
    name: "Get protocol stats",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const user = accounts.get('wallet_1')!;
        
        let stats = chain.callReadOnlyFn(
            'rental-manager',
            'get-protocol-stats',
            [],
            user.address
        );
        
        const data = stats.result.expectTuple();
        assertEquals(data['total-listings'], types.uint(0));
        assertEquals(data['total-rentals'], types.uint(0));
    }
});

Clarinet.test({
    name: "Can delist NFT",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const owner = accounts.get('wallet_1')!;
        
        // Create listing
        chain.mineBlock([
            Tx.contractCall('rental-manager', 'create-listing', [
                types.principal(`${owner.address}.rental-nft`),
                types.uint(1),
                types.uint(1000000),
                types.uint(86400),
                types.uint(3600),
                types.uint(10000000)
            ], owner.address)
        ]);
        
        // Delist
        let block = chain.mineBlock([
            Tx.contractCall('rental-manager', 'delist-nft', [
                types.uint(1)
            ], owner.address)
        ]);
        
        block.receipts[0].result.expectOk().expectBool(true);
    }
});

Clarinet.test({
    name: "Only owner can delist",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const owner = accounts.get('wallet_1')!;
        const attacker = accounts.get('wallet_2')!;
        
        // Create listing
        chain.mineBlock([
            Tx.contractCall('rental-manager', 'create-listing', [
                types.principal(`${owner.address}.rental-nft`),
                types.uint(1),
                types.uint(1000000),
                types.uint(86400),
                types.uint(3600),
                types.uint(10000000)
            ], owner.address)
        ]);
        
        // Attacker tries to delist
        let block = chain.mineBlock([
            Tx.contractCall('rental-manager', 'delist-nft', [
                types.uint(1)
            ], attacker.address)
        ]);
        
        block.receipts[0].result.expectErr().expectUint(21001);
    }
});
