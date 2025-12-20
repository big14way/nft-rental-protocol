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
(define-constant ERR_EXTENSION_NOT_ALLOWED (err u21009))
(define-constant ERR_INVALID_EXTENSION (err u21010))
(define-constant ERR_INVALID_DISCOUNT (err u21011))
(define-constant ERR_DISCOUNT_EXISTS (err u21012))

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
(define-data-var total-extensions uint u0)
(define-data-var extension-enabled bool true)
(define-data-var total-discounted-rentals uint u0)
(define-data-var total-discount-savings uint u0)

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

;; Duration-based discounts per listing
(define-map duration-discounts
    { listing-id: uint, tier: uint }
    {
        min-hours: uint,
        discount-bps: uint,
        created-at: uint
    }
)

;; Track discount tier count per listing
(define-map discount-tier-count uint uint)

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

;; ========================================
;; Rental Extension Functions
;; ========================================

;; Extend an active rental
(define-public (extend-rental (rental-id uint) (extension-hours uint))
    (let ((rental (unwrap! (map-get? rentals rental-id) ERR_RENTAL_NOT_FOUND))
          (listing (unwrap! (map-get? listings (get listing-id rental)) ERR_LISTING_NOT_FOUND))
          (extension-duration (* extension-hours u3600))
          (extension-price (* (get price-per-hour listing) extension-hours))
          (current-time stacks-block-time))

        ;; Validations
        (asserts! (var-get extension-enabled) ERR_EXTENSION_NOT_ALLOWED)
        (asserts! (is-eq tx-sender (get renter rental)) ERR_NOT_AUTHORIZED)
        (asserts! (not (get returned rental)) ERR_RENTAL_NOT_FOUND)
        (asserts! (< current-time (get end-time rental)) ERR_RENTAL_EXPIRED)
        (asserts! (> extension-hours u0) ERR_INVALID_EXTENSION)

        ;; Check extension doesn't exceed max duration
        (let ((new-total-duration (+ (- (get end-time rental) (get start-time rental)) extension-duration)))
            (asserts! (<= new-total-duration (get max-duration listing)) ERR_INVALID_EXTENSION))

        ;; Calculate fees
        (let ((protocol-fee (/ (* extension-price PROTOCOL_FEE_BPS) u10000))
              (owner-payment (- extension-price protocol-fee))
              (new-end-time (+ (get end-time rental) extension-duration)))

            ;; Transfer extension payment
            (try! (stx-transfer? extension-price tx-sender (var-get contract-principal)))
            (try! (stx-transfer? owner-payment (var-get contract-principal) (get owner listing)))

            ;; Update rental
            (map-set rentals rental-id (merge rental {
                end-time: new-end-time,
                total-price: (+ (get total-price rental) extension-price)
            }))

            ;; Update listing stats
            (map-set listings (get listing-id rental) (merge listing {
                total-earnings: (+ (get total-earnings listing) extension-price)
            }))

            ;; Update stats
            (var-set total-rental-volume (+ (var-get total-rental-volume) extension-price))
            (var-set total-fees-collected (+ (var-get total-fees-collected) protocol-fee))
            (var-set total-extensions (+ (var-get total-extensions) u1))

            ;; Emit Chainhook event
            (print {
                event: "rental-extended",
                rental-id: rental-id,
                listing-id: (get listing-id rental),
                renter: tx-sender,
                extension-hours: extension-hours,
                extension-price: extension-price,
                new-end-time: new-end-time,
                protocol-fee: protocol-fee,
                timestamp: current-time
            })

            (ok {
                new-end-time: new-end-time,
                extension-price: extension-price,
                fee: protocol-fee
            }))))

;; Toggle extension feature (admin only)
(define-public (toggle-extension-feature)
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (var-set extension-enabled (not (var-get extension-enabled)))
        (print { event: "extension-feature-toggled", enabled: (var-get extension-enabled), by: tx-sender })
        (ok (var-get extension-enabled))))

;; Get extension statistics
(define-read-only (get-extension-stats)
    {
        total-extensions: (var-get total-extensions),
        extension-enabled: (var-get extension-enabled)
    })

;; Check if rental can be extended
(define-read-only (can-extend-rental (rental-id uint))
    (match (map-get? rentals rental-id)
        rental (match (map-get? listings (get listing-id rental))
            listing (let ((current-time stacks-block-time))
                {
                    can-extend: (and (var-get extension-enabled)
                                    (not (get returned rental))
                                    (< current-time (get end-time rental))),
                    time-remaining: (if (> (get end-time rental) current-time)
                                      (- (get end-time rental) current-time)
                                      u0),
                    max-additional-hours: (let ((current-duration (- (get end-time rental) (get start-time rental)))
                                               (max-duration (get max-duration listing)))
                                             (if (> max-duration current-duration)
                                               (/ (- max-duration current-duration) u3600)
                                               u0))
                })
            { can-extend: false, time-remaining: u0, max-additional-hours: u0 })
        { can-extend: false, time-remaining: u0, max-additional-hours: u0 }))

;; Calculate extension price
(define-read-only (calculate-extension-price (rental-id uint) (extension-hours uint))
    (match (map-get? rentals rental-id)
        rental (match (map-get? listings (get listing-id rental))
            listing (let ((extension-price (* (get price-per-hour listing) extension-hours))
                         (protocol-fee (/ (* extension-price PROTOCOL_FEE_BPS) u10000)))
                (ok {
                    total-price: extension-price,
                    protocol-fee: protocol-fee,
                    owner-payment: (- extension-price protocol-fee)
                }))
            (err ERR_LISTING_NOT_FOUND))
        (err ERR_RENTAL_NOT_FOUND)))

;; ========================================
;; Duration Discount Functions
;; ========================================

;; Add duration-based discount tier to listing
(define-public (add-duration-discount (listing-id uint) (min-hours uint) (discount-bps uint))
    (let ((listing (unwrap! (map-get? listings listing-id) ERR_LISTING_NOT_FOUND))
          (tier-count (default-to u0 (map-get? discount-tier-count listing-id)))
          (tier-id (+ tier-count u1)))
        ;; Validations
        (asserts! (is-eq tx-sender (get owner listing)) ERR_NOT_AUTHORIZED)
        (asserts! (> min-hours u0) ERR_INVALID_DISCOUNT)
        (asserts! (> discount-bps u0) ERR_INVALID_DISCOUNT)
        (asserts! (<= discount-bps u5000) ERR_INVALID_DISCOUNT) ;; Max 50% discount
        (asserts! (< tier-count u5) ERR_DISCOUNT_EXISTS) ;; Max 5 tiers per listing

        ;; Create discount tier
        (map-set duration-discounts { listing-id: listing-id, tier: tier-id } {
            min-hours: min-hours,
            discount-bps: discount-bps,
            created-at: stacks-block-time
        })

        ;; Update tier count
        (map-set discount-tier-count listing-id tier-id)

        ;; Emit event
        (print {
            event: "duration-discount-added",
            listing-id: listing-id,
            tier: tier-id,
            min-hours: min-hours,
            discount-bps: discount-bps,
            timestamp: stacks-block-time
        })

        (ok tier-id)))

;; Calculate applicable discount for duration
(define-read-only (calculate-discount (listing-id uint) (duration-hours uint))
    (let ((tier-count (default-to u0 (map-get? discount-tier-count listing-id))))
        (if (is-eq tier-count u0)
            { listing-id: listing-id, duration-hours: duration-hours, best-discount: u0 }
            (fold find-best-discount (list u1 u2 u3 u4 u5)
                { listing-id: listing-id, duration-hours: duration-hours, best-discount: u0 }))))

(define-private (find-best-discount (tier uint) (acc { listing-id: uint, duration-hours: uint, best-discount: uint }))
    (match (map-get? duration-discounts { listing-id: (get listing-id acc), tier: tier })
        discount-tier (if (>= (get duration-hours acc) (get min-hours discount-tier))
                         (if (> (get discount-bps discount-tier) (get best-discount acc))
                             (merge acc { best-discount: (get discount-bps discount-tier) })
                             acc)
                         acc)
        acc))

;; Rent with duration discount
(define-public (rent-nft-with-discount (listing-id uint) (duration-hours uint))
    (let ((caller tx-sender)
          (listing (unwrap! (map-get? listings listing-id) ERR_LISTING_NOT_FOUND))
          (rental-id (+ (var-get rental-counter) u1))
          (current-time stacks-block-time)
          (duration-seconds (* duration-hours u3600))
          (end-time (+ current-time duration-seconds))
          (base-price (* (get price-per-hour listing) duration-hours))
          (discount-bps (get best-discount (calculate-discount listing-id duration-hours)))
          (discount-amount (/ (* base-price discount-bps) u10000))
          (discounted-price (- base-price discount-amount))
          (fee (calculate-fee discounted-price))
          (owner-amount (- discounted-price fee))
          (total-payment (+ discounted-price (get collateral-required listing))))
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
            total-price: discounted-price,
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
        (var-set total-rental-volume (+ (var-get total-rental-volume) discounted-price))
        (var-set total-fees-collected (+ (var-get total-fees-collected) fee))

        ;; Track discount stats if discount was applied
        (if (> discount-amount u0)
            (begin
                (var-set total-discounted-rentals (+ (var-get total-discounted-rentals) u1))
                (var-set total-discount-savings (+ (var-get total-discount-savings) discount-amount))
                true)
            true)

        ;; Update user stats
        (update-renter-stats caller discounted-price fee)

        ;; Update owner earnings
        (match (map-get? user-stats (get owner listing))
            stats (map-set user-stats (get owner listing) (merge stats {
                total-earned: (+ (get total-earned stats) owner-amount)
            }))
            true)

        ;; EMIT EVENT: rental-started-with-discount
        (print {
            event: "rental-started-with-discount",
            rental-id: rental-id,
            listing-id: listing-id,
            renter: caller,
            owner: (get owner listing),
            base-price: base-price,
            discount-bps: discount-bps,
            discount-amount: discount-amount,
            final-price: discounted-price,
            duration-hours: duration-hours,
            end-time: end-time,
            collateral: (get collateral-required listing),
            timestamp: current-time
        })

        ;; EMIT EVENT: fee-collected
        (print {
            event: "fee-collected",
            rental-id: rental-id,
            fee-type: "discounted-rental",
            amount: fee,
            timestamp: current-time
        })

        (ok { rental-id: rental-id, discount-saved: discount-amount, final-price: discounted-price })))

;; Remove duration discount tier
(define-public (remove-duration-discount (listing-id uint) (tier uint))
    (let ((listing (unwrap! (map-get? listings listing-id) ERR_LISTING_NOT_FOUND)))
        (asserts! (is-eq tx-sender (get owner listing)) ERR_NOT_AUTHORIZED)
        (asserts! (is-some (map-get? duration-discounts { listing-id: listing-id, tier: tier })) ERR_INVALID_DISCOUNT)

        (map-delete duration-discounts { listing-id: listing-id, tier: tier })

        (print {
            event: "duration-discount-removed",
            listing-id: listing-id,
            tier: tier,
            timestamp: stacks-block-time
        })

        (ok true)))

;; Get all discount tiers for a listing
(define-read-only (get-discount-tiers (listing-id uint))
    (let ((tier-count (default-to u0 (map-get? discount-tier-count listing-id))))
        {
            tier-1: (map-get? duration-discounts { listing-id: listing-id, tier: u1 }),
            tier-2: (map-get? duration-discounts { listing-id: listing-id, tier: u2 }),
            tier-3: (map-get? duration-discounts { listing-id: listing-id, tier: u3 }),
            tier-4: (map-get? duration-discounts { listing-id: listing-id, tier: u4 }),
            tier-5: (map-get? duration-discounts { listing-id: listing-id, tier: u5 }),
            total-tiers: tier-count
        }))

;; Get discount statistics
(define-read-only (get-discount-stats)
    {
        total-discounted-rentals: (var-get total-discounted-rentals),
        total-savings: (var-get total-discount-savings)
    })

;; Preview rental price with discount
(define-read-only (preview-rental-price (listing-id uint) (duration-hours uint))
    (match (map-get? listings listing-id)
        listing (let ((base-price (* (get price-per-hour listing) duration-hours))
                     (discount-bps (get best-discount (calculate-discount listing-id duration-hours)))
                     (discount-amount (/ (* base-price discount-bps) u10000))
                     (discounted-price (- base-price discount-amount))
                     (fee (calculate-fee discounted-price)))
            (ok {
                base-price: base-price,
                discount-bps: discount-bps,
                discount-amount: discount-amount,
                final-price: discounted-price,
                protocol-fee: fee,
                total-with-collateral: (+ discounted-price (get collateral-required listing)),
                savings-percent: (if (> base-price u0) (/ (* discount-bps u100) u10000) u0)
            }))
        (err ERR_LISTING_NOT_FOUND)))

;; Insurance pool for damaged NFTs
(define-data-var insurance-pool-balance uint u0)
(define-map rental-insurance uint { premium-paid: uint, coverage-amount: uint, claimed: bool })

(define-public (purchase-insurance (listing-id uint) (rental-id uint) (coverage uint))
    (let ((premium (/ coverage u20)))
        (try! (stx-transfer? premium tx-sender (var-get contract-principal)))
        (var-set insurance-pool-balance (+ (var-get insurance-pool-balance) premium))
        (map-set rental-insurance rental-id { premium-paid: premium, coverage-amount: coverage, claimed: false })
        (print { event: "insurance-purchased", rental-id: rental-id, premium: premium, coverage: coverage, timestamp: stacks-block-time })
        (ok true)))

(define-read-only (get-insurance (rental-id uint))
    (map-get? rental-insurance rental-id))
