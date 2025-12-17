;; rental-nft.clar
;; Sample SIP-009 NFT for rental protocol testing

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_NOT_FOUND (err u101))

(define-non-fungible-token rental-nft uint)

(define-data-var token-counter uint u0)
(define-data-var base-uri (string-ascii 256) "https://api.example.com/nft/")

(define-map token-metadata
    uint
    {
        name: (string-ascii 64),
        description: (string-ascii 256),
        minted-at: uint
    }
)

(define-read-only (get-last-token-id)
    (ok (var-get token-counter)))

(define-read-only (get-owner (token-id uint))
    (ok (nft-get-owner? rental-nft token-id)))

(define-read-only (get-token-uri (token-id uint))
    (ok (some (concat (var-get base-uri) (unwrap-panic (to-ascii? token-id))))))

(define-read-only (get-token-metadata (token-id uint))
    (map-get? token-metadata token-id))

(define-public (transfer (token-id uint) (sender principal) (recipient principal))
    (begin
        (asserts! (is-eq tx-sender sender) ERR_NOT_AUTHORIZED)
        (nft-transfer? rental-nft token-id sender recipient)))

(define-public (mint (recipient principal) (name (string-ascii 64)) (description (string-ascii 256)))
    (let
        (
            (token-id (+ (var-get token-counter) u1))
        )
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (try! (nft-mint? rental-nft token-id recipient))
        
        (map-set token-metadata token-id {
            name: name,
            description: description,
            minted-at: stacks-block-time
        })
        
        (var-set token-counter token-id)
        
        (print {
            event: "nft-minted",
            token-id: token-id,
            recipient: recipient,
            name: name,
            timestamp: stacks-block-time
        })
        
        (ok token-id)))

(define-public (burn (token-id uint))
    (let
        (
            (owner (unwrap! (nft-get-owner? rental-nft token-id) ERR_NOT_FOUND))
        )
        (asserts! (is-eq tx-sender owner) ERR_NOT_AUTHORIZED)
        (nft-burn? rental-nft token-id owner)))
