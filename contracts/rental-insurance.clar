;; rental-insurance.clar
;; Insurance and protection system for NFT rentals
;; Uses Clarity 4 epoch 3.3 with Chainhook integration

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u14001))
(define-constant ERR_INVALID_POLICY (err u14002))
(define-constant ERR_CLAIM_EXISTS (err u14003))

(define-data-var policy-counter uint u0)
(define-data-var claim-counter uint u0)
(define-data-var total-premiums-collected uint u0)
(define-data-var total-claims-paid uint u0)

(define-map insurance-policies
    uint
    {
        rental-id: uint,
        nft-owner: principal,
        renter: principal,
        coverage-amount: uint,
        premium-paid: uint,
        created-at: uint,
        expires-at: uint,
        active: bool,
        claimed: bool
    }
)

(define-map insurance-claims
    uint
    {
        policy-id: uint,
        filed-by: principal,
        claim-amount: uint,
        incident-type: (string-ascii 32),
        evidence-hash: (buff 32),
        filed-at: uint,
        approved: bool,
        processed: bool,
        payout-amount: uint,
        processed-at: uint
    }
)

(define-map policy-by-rental
    uint
    (list 10 uint)
)

(define-public (create-insurance-policy
    (rental-id uint)
    (nft-owner principal)
    (renter principal)
    (coverage-amount uint)
    (premium-paid uint)
    (duration uint))
    (let
        (
            (policy-id (+ (var-get policy-counter) u1))
            (expires-at (+ stacks-block-time duration))
        )
        (map-set insurance-policies policy-id {
            rental-id: rental-id,
            nft-owner: nft-owner,
            renter: renter,
            coverage-amount: coverage-amount,
            premium-paid: premium-paid,
            created-at: stacks-block-time,
            expires-at: expires-at,
            active: true,
            claimed: false
        })
        (var-set policy-counter policy-id)
        (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium-paid))
        
        (print {
            event: "insurance-policy-created",
            policy-id: policy-id,
            rental-id: rental-id,
            coverage-amount: coverage-amount,
            premium: premium-paid,
            expires-at: expires-at,
            timestamp: stacks-block-time
        })
        (ok policy-id)
    )
)

(define-public (file-claim
    (policy-id uint)
    (claim-amount uint)
    (incident-type (string-ascii 32))
    (evidence-hash (buff 32)))
    (let
        (
            (policy (unwrap! (map-get? insurance-policies policy-id) ERR_INVALID_POLICY))
            (claim-id (+ (var-get claim-counter) u1))
        )
        (asserts! (get active policy) ERR_INVALID_POLICY)
        (asserts! (not (get claimed policy)) ERR_CLAIM_EXISTS)
        (asserts! (<= claim-amount (get coverage-amount policy)) ERR_INVALID_POLICY)
        
        (map-set insurance-claims claim-id {
            policy-id: policy-id,
            filed-by: tx-sender,
            claim-amount: claim-amount,
            incident-type: incident-type,
            evidence-hash: evidence-hash,
            filed-at: stacks-block-time,
            approved: false,
            processed: false,
            payout-amount: u0,
            processed-at: u0
        })
        (var-set claim-counter claim-id)
        
        (print {
            event: "insurance-claim-filed",
            claim-id: claim-id,
            policy-id: policy-id,
            filed-by: tx-sender,
            claim-amount: claim-amount,
            incident-type: incident-type,
            timestamp: stacks-block-time
        })
        (ok claim-id)
    )
)

(define-public (process-claim (claim-id uint) (approved bool) (payout-amount uint))
    (let
        (
            (claim (unwrap! (map-get? insurance-claims claim-id) ERR_INVALID_POLICY))
            (policy (unwrap! (map-get? insurance-policies (get policy-id claim)) ERR_INVALID_POLICY))
        )
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (asserts! (not (get processed claim)) ERR_CLAIM_EXISTS)
        
        (map-set insurance-claims claim-id
            (merge claim {
                approved: approved,
                processed: true,
                payout-amount: payout-amount,
                processed-at: stacks-block-time
            }))
        
        (if approved
            (begin
                (map-set insurance-policies (get policy-id claim)
                    (merge policy { claimed: true, active: false }))
                (var-set total-claims-paid (+ (var-get total-claims-paid) payout-amount)))
            true)
        
        (print {
            event: "insurance-claim-processed",
            claim-id: claim-id,
            approved: approved,
            payout-amount: payout-amount,
            timestamp: stacks-block-time
        })
        (ok true)
    )
)

(define-read-only (get-policy (policy-id uint))
    (map-get? insurance-policies policy-id)
)

(define-read-only (get-claim (claim-id uint))
    (map-get? insurance-claims claim-id)
)

(define-read-only (get-insurance-stats)
    {
        total-policies: (var-get policy-counter),
        total-premiums: (var-get total-premiums-collected),
        total-claims: (var-get claim-counter),
        total-payouts: (var-get total-claims-paid)
    }
)
