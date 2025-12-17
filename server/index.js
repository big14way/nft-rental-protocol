/**
 * NFT Rental Chainhook Event Server
 * Handles events from Hiro Chainhooks for the NFT Rental Protocol
 */

const express = require('express');
const cors = require('cors');
const Database = require('better-sqlite3');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 3002;
const AUTH_TOKEN = process.env.AUTH_TOKEN || 'YOUR_AUTH_TOKEN';

const db = new Database('rental_events.db');

// Create tables
db.exec(`
  CREATE TABLE IF NOT EXISTS listings (
    listing_id INTEGER PRIMARY KEY,
    owner TEXT NOT NULL,
    nft_contract TEXT,
    token_id INTEGER,
    price_per_hour INTEGER,
    collateral INTEGER,
    status TEXT DEFAULT 'available',
    total_rentals INTEGER DEFAULT 0,
    total_earnings INTEGER DEFAULT 0,
    created_at INTEGER
  );

  CREATE TABLE IF NOT EXISTS rentals (
    rental_id INTEGER PRIMARY KEY,
    listing_id INTEGER,
    renter TEXT NOT NULL,
    owner TEXT,
    price INTEGER,
    duration_hours INTEGER,
    collateral INTEGER,
    start_time INTEGER,
    end_time INTEGER,
    returned INTEGER DEFAULT 0,
    on_time INTEGER,
    created_at INTEGER
  );

  CREATE TABLE IF NOT EXISTS users (
    address TEXT PRIMARY KEY,
    listings_created INTEGER DEFAULT 0,
    rentals_made INTEGER DEFAULT 0,
    rentals_completed INTEGER DEFAULT 0,
    total_spent INTEGER DEFAULT 0,
    total_earned INTEGER DEFAULT 0,
    fees_paid INTEGER DEFAULT 0,
    first_seen INTEGER,
    last_seen INTEGER
  );

  CREATE TABLE IF NOT EXISTS fees (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rental_id INTEGER,
    fee_type TEXT,
    amount INTEGER,
    timestamp INTEGER
  );

  CREATE TABLE IF NOT EXISTS daily_stats (
    date TEXT PRIMARY KEY,
    listings_created INTEGER DEFAULT 0,
    rentals_started INTEGER DEFAULT 0,
    rentals_completed INTEGER DEFAULT 0,
    volume INTEGER DEFAULT 0,
    fees_collected INTEGER DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT,
    data TEXT,
    block_height INTEGER,
    tx_id TEXT,
    timestamp INTEGER
  );
`);

app.use(cors());
app.use(express.json({ limit: '10mb' }));

const authMiddleware = (req, res, next) => {
  const authHeader = req.headers.authorization;
  if (!authHeader || authHeader !== `Bearer ${AUTH_TOKEN}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
};

const extractEventData = (payload) => {
  const events = [];
  if (payload.apply && Array.isArray(payload.apply)) {
    for (const block of payload.apply) {
      const blockHeight = block.block_identifier?.index;
      if (block.transactions && Array.isArray(block.transactions)) {
        for (const tx of block.transactions) {
          const txId = tx.transaction_identifier?.hash;
          if (tx.metadata?.receipt?.events) {
            for (const event of tx.metadata.receipt.events) {
              if (event.type === 'SmartContractEvent' || event.type === 'print_event') {
                const printData = event.data?.value || event.contract_event?.value;
                if (printData) events.push({ data: printData, blockHeight, txId });
              }
            }
          }
        }
      }
    }
  }
  return events;
};

const updateDailyStats = (date, field, increment = 1) => {
  const existing = db.prepare('SELECT * FROM daily_stats WHERE date = ?').get(date);
  if (existing) {
    db.prepare(`UPDATE daily_stats SET ${field} = ${field} + ? WHERE date = ?`).run(increment, date);
  } else {
    db.prepare(`INSERT INTO daily_stats (date, ${field}) VALUES (?, ?)`).run(date, increment);
  }
};

const processEvent = (eventData, blockHeight, txId) => {
  const today = new Date().toISOString().split('T')[0];
  const timestamp = eventData.timestamp || Math.floor(Date.now() / 1000);

  db.prepare(`INSERT INTO events (event_type, data, block_height, tx_id, timestamp) VALUES (?, ?, ?, ?, ?)`)
    .run(eventData.event, JSON.stringify(eventData), blockHeight, txId, timestamp);

  switch (eventData.event) {
    case 'listing-created':
      db.prepare(`INSERT OR REPLACE INTO listings (listing_id, owner, nft_contract, token_id, price_per_hour, collateral, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)`)
        .run(eventData['listing-id'], eventData.owner, eventData['nft-contract'], eventData['token-id'], eventData['price-per-hour'], eventData.collateral, timestamp);
      updateDailyStats(today, 'listings_created');
      console.log(`📝 Listing #${eventData['listing-id']} created`);
      break;

    case 'rental-started':
      db.prepare(`INSERT INTO rentals (rental_id, listing_id, renter, owner, price, duration_hours, collateral, start_time, end_time, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(eventData['rental-id'], eventData['listing-id'], eventData.renter, eventData.owner, eventData.price, eventData['duration-hours'], eventData.collateral, timestamp, eventData['end-time'], timestamp);
      db.prepare(`UPDATE listings SET status = 'rented', total_rentals = total_rentals + 1 WHERE listing_id = ?`).run(eventData['listing-id']);
      updateDailyStats(today, 'rentals_started');
      updateDailyStats(today, 'volume', eventData.price);
      console.log(`🎮 Rental #${eventData['rental-id']} started - ${eventData['duration-hours']}hrs @ ${eventData.price}`);
      break;

    case 'rental-ended':
      db.prepare(`UPDATE rentals SET returned = 1, on_time = ? WHERE rental_id = ?`).run(eventData['on-time'] ? 1 : 0, eventData['rental-id']);
      db.prepare(`UPDATE listings SET status = 'available' WHERE listing_id = ?`).run(eventData['listing-id']);
      updateDailyStats(today, 'rentals_completed');
      console.log(`✅ Rental #${eventData['rental-id']} ended - On time: ${eventData['on-time']}`);
      break;

    case 'fee-collected':
      db.prepare(`INSERT INTO fees (rental_id, fee_type, amount, timestamp) VALUES (?, ?, ?, ?)`)
        .run(eventData['rental-id'], eventData['fee-type'], eventData.amount, timestamp);
      updateDailyStats(today, 'fees_collected', eventData.amount);
      console.log(`💵 Fee: ${eventData.amount} (${eventData['fee-type']})`);
      break;

    case 'collateral-claimed':
      console.log(`⚠️ Collateral claimed: ${eventData.amount} for rental #${eventData['rental-id']}`);
      break;
  }
};

// API Routes
app.post('/api/rental-events', authMiddleware, (req, res) => {
  try {
    const events = extractEventData(req.body);
    for (const { data, blockHeight, txId } of events) {
      if (data && data.event) processEvent(data, blockHeight, txId);
    }
    res.status(200).json({ success: true, processed: events.length });
  } catch (error) {
    console.error('Error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Analytics endpoints
app.get('/api/stats', (req, res) => {
  res.json({
    totalListings: db.prepare('SELECT COUNT(*) as c FROM listings').get().c,
    activeListings: db.prepare("SELECT COUNT(*) as c FROM listings WHERE status = 'available'").get().c,
    totalRentals: db.prepare('SELECT COUNT(*) as c FROM rentals').get().c,
    activeRentals: db.prepare('SELECT COUNT(*) as c FROM rentals WHERE returned = 0').get().c,
    totalVolume: db.prepare('SELECT COALESCE(SUM(price), 0) as s FROM rentals').get().s,
    totalFees: db.prepare('SELECT COALESCE(SUM(amount), 0) as s FROM fees').get().s
  });
});

app.get('/api/stats/daily', (req, res) => {
  const days = parseInt(req.query.days) || 30;
  res.json(db.prepare('SELECT * FROM daily_stats ORDER BY date DESC LIMIT ?').all(days));
});

app.get('/api/listings', (req, res) => {
  const limit = parseInt(req.query.limit) || 20;
  res.json(db.prepare('SELECT * FROM listings ORDER BY created_at DESC LIMIT ?').all(limit));
});

app.get('/api/rentals', (req, res) => {
  const limit = parseInt(req.query.limit) || 20;
  res.json(db.prepare('SELECT * FROM rentals ORDER BY created_at DESC LIMIT ?').all(limit));
});

app.get('/health', (req, res) => res.json({ status: 'healthy' }));

app.listen(PORT, () => {
  console.log(`🎮 NFT Rental Chainhook Server on port ${PORT}`);
});

module.exports = app;
