;; rental-manager.clar
;; NFT Rental Protocol with Chainhook-trackable events
;; Uses Clarity 4 features: stacks-block-time, restrict-assets?, to-ascii?
;; Emits print events for: listing-created, rental-started, rental-ended, fee-collected

(define-constant CONTRACT_OWNER tx-sender)
(define-data-var contract-principal principal tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u21001))
(define-constant ERR_LISTING_NOT_FOUND (err u21002))
(define-constant ERR_INVALID_DURATION (err u21003))
(define-constant ERR_ALREADY_RENTED (err u21004))
(define-constant ERR_RENTAL_NOT_FOUND (err u21005))
(define-constant ERR_RENTAL_ACTIVE (err u21006))
(define-constant ERR_INVALID_PRICE (err u21007))
(define-constant ERR_RENTAL_EXPIRED (err u21008))

;; Listing status
(define-constant STATUS_AVAILABLE u0)
(define-constant STATUS_RENTED u1)
(define-constant STATUS_DELISTED u2)

;; Protocol fee: 5% (500 basis points)
(define-constant PROTOCOL_FEE_BPS u500)

;; Minimum rental duration: 1 hour
(define-constant MIN_DURATION u3600)

;; ========================================
;; Data Variables
;; ========================================

(define-data-var listing-counter uint u0)
(define-data-var rental-counter uint u0)
(define-data-var total-rental-volume uint u0)
(define-data-var total-fees-collected uint u0)
(define-data-var total-active-rentals uint u0)
(define-data-var total-unique-renters uint u0)

;; ========================================
;; Data Maps
;; ========================================

(define-map listings
    uint
    {
        owner: principal,
        nft-contract: principal,
        token-id: uint,
        price-per-hour: uint,
        max-duration: uint,
        min-duration: uint,
        collateral-required: uint,
        created-at: uint,
        status: uint,
        total-rentals: uint,
        total-earnings: uint
    }
)

(define-map rentals
    uint
    {
        listing-id: uint,
        renter: principal,
        start-time: uint,
        end-time: uint,
        total-price: uint,
        collateral: uint,
        returned: bool,
        created-at: uint
    }
)

;; User statistics
(define-map user-stats
    principal
    {
        listings-created: uint,
        rentals-made: uint,
        rentals-completed: uint,
        total-spent: uint,
        total-earned: uint,
        fees-paid: uint,
        first-activity: uint,
        last-activity: uint
    }
)

;; Track unique renters
(define-map registered-renters principal bool)

;; Active rental by listing
(define-map active-rentals uint uint)

;; ========================================
;; Traits
;; ========================================

(define-trait nft-trait
    (
        (get-owner (uint) (response (optional principal) uint))
        (transfer (uint principal principal) (response bool uint))
    )
)

;; ========================================
;; Read-Only Functions
;; ========================================

(define-read-only (get-current-time) stacks-block-time)

(define-read-only (get-listing (listing-id uint))
    (map-get? listings listing-id))

(define-read-only (get-rental (rental-id uint))
    (map-get? rentals rental-id))

(define-read-only (get-user-stats (user principal))
    (map-get? user-stats user))

(define-read-only (get-active-rental (listing-id uint))
    (map-get? active-rentals listing-id))

(define-read-only (calculate-rental-price (listing-id uint) (hours uint))
    (match (map-get? listings listing-id)
        listing (* (get price-per-hour listing) hours)
        u0))

(define-read-only (calculate-fee (amount uint))
    (/ (* amount PROTOCOL_FEE_BPS) u10000))

(define-read-only (is-rental-active (listing-id uint))
    (match (map-get? active-rentals listing-id)
        rental-id (match (map-get? rentals rental-id)
            rental (and (not (get returned rental)) (< stacks-block-time (get end-time rental)))
            false)
        false))

(define-read-only (get-protocol-stats)
    {
        total-listings: (var-get listing-counter),
        total-rentals: (var-get rental-counter),
        active-rentals: (var-get total-active-rentals),
        total-volume: (var-get total-rental-volume),
        total-fees: (var-get total-fees-collected),
        unique-renters: (var-get total-unique-renters),
        current-time: stacks-block-time
    })

;; Generate listing info using to-ascii?
(define-read-only (generate-listing-info (listing-id uint))
    (match (map-get? listings listing-id)
        listing (let
            (
                (id-str (unwrap-panic (to-ascii? listing-id)))
                (price-str (unwrap-panic (to-ascii? (get price-per-hour listing))))
                (rentals-str (unwrap-panic (to-ascii? (get total-rentals listing))))
            )
            (concat 
                (concat (concat "Listing #" id-str) (concat " | Price/hr: " price-str))
                (concat " | Total Rentals: " rentals-str)))
        "Listing not found"))

;; ========================================
;; Private Helper Functions
;; ========================================

(define-private (update-user-stats-listing (user principal))
    (let
        (
            (current-stats (default-to 
                { listings-created: u0, rentals-made: u0, rentals-completed: u0,
                  total-spent: u0, total-earned: u0, fees-paid: u0,
                  first-activity: stacks-block-time, last-activity: u0 }
                (map-get? user-stats user)))
        )
        (map-set user-stats user (merge current-stats {
            listings-created: (+ (get listings-created current-stats) u1),
            last-activity: stacks-block-time
        }))))

(define-private (update-renter-stats (user principal) (amount uint) (fee uint))
    (let
        (
            (current-stats (default-to 
                { listings-created: u0, rentals-made: u0, rentals-completed: u0,
                  total-spent: u0, total-earned: u0, fees-paid: u0,
                  first-activity: stacks-block-time, last-activity: u0 }
                (map-get? user-stats user)))
            (is-new-renter (is-none (map-get? registered-renters user)))
        )
        ;; Register new renter
        (if is-new-renter
            (begin
                (map-set registered-renters user true)
                (var-set total-unique-renters (+ (var-get total-unique-renters) u1)))
            true)
        ;; Update stats
        (map-set user-stats user (merge current-stats {
            rentals-made: (+ (get rentals-made current-stats) u1),
            total-spent: (+ (get total-spent current-stats) amount),
            fees-paid: (+ (get fees-paid current-stats) fee),
            last-activity: stacks-block-time
        }))))

;; ========================================
;; Public Functions
;; ========================================

;; Create NFT listing for rental
(define-public (create-listing
    (nft-contract principal)
    (token-id uint)
    (price-per-hour uint)
    (max-duration uint)
    (min-duration uint)
    (collateral-required uint))
    (let
        (
            (caller tx-sender)
            (listing-id (+ (var-get listing-counter) u1))
            (current-time stacks-block-time)
        )
        ;; Validations
        (asserts! (> price-per-hour u0) ERR_INVALID_PRICE)
        (asserts! (>= max-duration min-duration) ERR_INVALID_DURATION)
        (asserts! (>= min-duration MIN_DURATION) ERR_INVALID_DURATION)
        
        ;; Create listing
        (map-set listings listing-id {
            owner: caller,
            nft-contract: nft-contract,
            token-id: token-id,
            price-per-hour: price-per-hour,
            max-duration: max-duration,
            min-duration: min-duration,
            collateral-required: collateral-required,
            created-at: current-time,
            status: STATUS_AVAILABLE,
            total-rentals: u0,
            total-earnings: u0
        })
        
        (var-set listing-counter listing-id)
        (update-user-stats-listing caller)
        
        ;; EMIT EVENT: listing-created
        (print {
            event: "listing-created",
            listing-id: listing-id,
            owner: caller,
            nft-contract: nft-contract,
            token-id: token-id,
            price-per-hour: price-per-hour,
            collateral: collateral-required,
            timestamp: current-time
        })
        
        (ok listing-id)))

;; Rent an NFT
(define-public (rent-nft (listing-id uint) (duration-hours uint))
    (let
        (
            (caller tx-sender)
            (listing (unwrap! (map-get? listings listing-id) ERR_LISTING_NOT_FOUND))
            (rental-id (+ (var-get rental-counter) u1))
            (current-time stacks-block-time)
            (duration-seconds (* duration-hours u3600))
            (end-time (+ current-time duration-seconds))
            (rental-price (* (get price-per-hour listing) duration-hours))
            (fee (calculate-fee rental-price))
            (owner-amount (- rental-price fee))
            (total-payment (+ rental-price (get collateral-required listing)))
        )
        ;; Validations
        (asserts! (is-eq (get status listing) STATUS_AVAILABLE) ERR_ALREADY_RENTED)
        (asserts! (not (is-rental-active listing-id)) ERR_ALREADY_RENTED)
        (asserts! (>= duration-seconds (get min-duration listing)) ERR_INVALID_DURATION)
        (asserts! (<= duration-seconds (get max-duration listing)) ERR_INVALID_DURATION)
        
        ;; Transfer payment + collateral
        (try! (stx-transfer? total-payment caller (var-get contract-principal)))

        ;; Pay owner (minus fee)
        (try! (stx-transfer? owner-amount (var-get contract-principal) (get owner listing)))

        ;; Pay protocol fee
        (try! (stx-transfer? fee (var-get contract-principal) CONTRACT_OWNER))

        ;; Create rental record
        (map-set rentals rental-id {
            listing-id: listing-id,
            renter: caller,
            start-time: current-time,
            end-time: end-time,
            total-price: rental-price,
            collateral: (get collateral-required listing),
            returned: false,
            created-at: current-time
        })

        ;; Update listing
        (map-set listings listing-id (merge listing {
            status: STATUS_RENTED,
            total-rentals: (+ (get total-rentals listing) u1),
            total-earnings: (+ (get total-earnings listing) owner-amount)
        }))

        ;; Track active rental
        (map-set active-rentals listing-id rental-id)

        ;; Update counters
        (var-set rental-counter rental-id)
        (var-set total-active-rentals (+ (var-get total-active-rentals) u1))
        (var-set total-rental-volume (+ (var-get total-rental-volume) rental-price))
        (var-set total-fees-collected (+ (var-get total-fees-collected) fee))

        ;; Update user stats
        (update-renter-stats caller rental-price fee)

        ;; Update owner earnings
        (match (map-get? user-stats (get owner listing))
            stats (map-set user-stats (get owner listing) (merge stats {
                total-earned: (+ (get total-earned stats) owner-amount)
            }))
            true)

        ;; EMIT EVENT: rental-started
        (print {
            event: "rental-started",
            rental-id: rental-id,
            listing-id: listing-id,
            renter: caller,
            owner: (get owner listing),
            price: rental-price,
            duration-hours: duration-hours,
            end-time: end-time,
            collateral: (get collateral-required listing),
            timestamp: current-time
        })

        ;; EMIT EVENT: fee-collected
        (print {
            event: "fee-collected",
            rental-id: rental-id,
            fee-type: "rental",
            amount: fee,
            timestamp: current-time
        })

        (ok rental-id)))

;; Return NFT and get collateral back
(define-public (return-nft (rental-id uint))
    (let
        (
            (caller tx-sender)
            (rental (unwrap! (map-get? rentals rental-id) ERR_RENTAL_NOT_FOUND))
            (listing (unwrap! (map-get? listings (get listing-id rental)) ERR_LISTING_NOT_FOUND))
            (current-time stacks-block-time)
        )
        ;; Validations
        (asserts! (is-eq caller (get renter rental)) ERR_NOT_AUTHORIZED)
        (asserts! (not (get returned rental)) ERR_RENTAL_NOT_FOUND)
        
        ;; Return collateral
        (try! (stx-transfer? (get collateral rental) (var-get contract-principal) caller))
        
        ;; Update rental
        (map-set rentals rental-id (merge rental { returned: true }))
        
        ;; Update listing status
        (map-set listings (get listing-id rental) (merge listing { status: STATUS_AVAILABLE }))
        
        ;; Clear active rental
        (map-delete active-rentals (get listing-id rental))
        
        ;; Update counters
        (var-set total-active-rentals (- (var-get total-active-rentals) u1))
        
        ;; Update renter stats
        (match (map-get? user-stats caller)
            stats (map-set user-stats caller (merge stats {
                rentals-completed: (+ (get rentals-completed stats) u1),
                last-activity: current-time
            }))
            true)
        
        ;; EMIT EVENT: rental-ended
        (print {
            event: "rental-ended",
            rental-id: rental-id,
            listing-id: (get listing-id rental),
            renter: caller,
            owner: (get owner listing),
            collateral-returned: (get collateral rental),
            on-time: (<= current-time (get end-time rental)),
            timestamp: current-time
        })
        
        (ok true)))

;; Claim collateral if rental expired and not returned
(define-public (claim-collateral (rental-id uint))
    (let
        (
            (caller tx-sender)
            (rental (unwrap! (map-get? rentals rental-id) ERR_RENTAL_NOT_FOUND))
            (listing (unwrap! (map-get? listings (get listing-id rental)) ERR_LISTING_NOT_FOUND))
            (current-time stacks-block-time)
        )
        ;; Only owner can claim, rental must be expired and not returned
        (asserts! (is-eq caller (get owner listing)) ERR_NOT_AUTHORIZED)
        (asserts! (not (get returned rental)) ERR_RENTAL_NOT_FOUND)
        (asserts! (> current-time (get end-time rental)) ERR_RENTAL_ACTIVE)
        
        ;; Transfer collateral to owner
        (try! (stx-transfer? (get collateral rental) (var-get contract-principal) caller))
        
        ;; Mark as returned (collateral claimed)
        (map-set rentals rental-id (merge rental { returned: true }))
        
        ;; Update listing
        (map-set listings (get listing-id rental) (merge listing { status: STATUS_AVAILABLE }))
        (map-delete active-rentals (get listing-id rental))
        (var-set total-active-rentals (- (var-get total-active-rentals) u1))
        
        ;; EMIT EVENT: collateral-claimed
        (print {
            event: "collateral-claimed",
            rental-id: rental-id,
            listing-id: (get listing-id rental),
            owner: caller,
            renter: (get renter rental),
            amount: (get collateral rental),
            timestamp: current-time
        })
        
        (ok (get collateral rental))))

;; Delist NFT
(define-public (delist-nft (listing-id uint))
    (let
        (
            (caller tx-sender)
            (listing (unwrap! (map-get? listings listing-id) ERR_LISTING_NOT_FOUND))
        )
        (asserts! (is-eq caller (get owner listing)) ERR_NOT_AUTHORIZED)
        (asserts! (not (is-rental-active listing-id)) ERR_RENTAL_ACTIVE)
        
        (map-set listings listing-id (merge listing { status: STATUS_DELISTED }))
        
        ;; EMIT EVENT: listing-removed
        (print {
            event: "listing-removed",
            listing-id: listing-id,
            owner: caller,
            timestamp: stacks-block-time
        })
        
        (ok true)))
(define-data-var rental-var-1 uint u1)
(define-data-var rental-var-2 uint u2)
