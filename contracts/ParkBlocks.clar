;; ParkBlocks - Time-Bound NFT Parking Reservation Contract
;; Enables decentralized parking spot reservations using NFTs with automatic expiration

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-token-owner (err u101))
(define-constant err-token-not-found (err u102))
(define-constant err-reservation-expired (err u103))
(define-constant err-invalid-duration (err u104))
(define-constant err-spot-not-available (err u105))
(define-constant err-invalid-spot-id (err u106))
(define-constant err-payment-failed (err u107))
(define-constant err-invalid-time (err u108))

;; Data Variables
(define-data-var last-token-id uint u0)
(define-data-var base-fee uint u1000000) ;; 1 STX in micro-STX
(define-data-var max-reservation-duration uint u144) ;; ~24 hours in blocks

;; Data Maps
(define-map token-metadata 
  uint 
  {
    spot-id: uint,
    start-block: uint,
    end-block: uint,
    fee-paid: uint,
    active: bool
  }
)

(define-map parking-spots
  uint
  {
    location: (string-ascii 100),
    available: bool,
    hourly-rate: uint
  }
)

(define-map user-reservations
  principal
  (list 50 uint)
)

;; NFT Definition
(define-non-fungible-token parking-reservation uint)

;; Private Functions

(define-private (is-valid-spot-id (spot-id uint))
  (match (map-get? parking-spots spot-id)
    spot-info true
    false
  )
)

(define-private (is-spot-available (spot-id uint) (start-block uint) (end-block uint))
  (let ((spot-info (unwrap! (map-get? parking-spots spot-id) false)))
    (get available spot-info)
  )
)

(define-private (calculate-fee (spot-id uint) (duration-blocks uint))
  (let (
    (spot-info (unwrap! (map-get? parking-spots spot-id) u0))
    (hourly-rate (get hourly-rate spot-info))
    (hours (/ duration-blocks u6)) ;; Approximate blocks per hour
  )
    (if (> hours u0)
      (* hourly-rate hours)
      (var-get base-fee)
    )
  )
)

(define-private (update-user-reservations (user principal) (token-id uint))
  (let ((current-reservations (default-to (list) (map-get? user-reservations user))))
    (map-set user-reservations user (unwrap! (as-max-len? (append current-reservations token-id) u50) false))
  )
)

;; Public Functions

(define-public (initialize-parking-spot (spot-id uint) (location (string-ascii 100)) (hourly-rate uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> spot-id u0) err-invalid-spot-id)
    (asserts! (> (len location) u0) err-invalid-spot-id)
    (asserts! (> hourly-rate u0) err-invalid-spot-id)
    (ok (map-set parking-spots spot-id {
      location: location,
      available: true,
      hourly-rate: hourly-rate
    }))
  )
)

(define-public (mint-reservation (spot-id uint) (duration-blocks uint))
  (let (
    (token-id (+ (var-get last-token-id) u1))
    (start-block stacks-block-height)
    (end-block (+ stacks-block-height duration-blocks))
    (fee (calculate-fee spot-id duration-blocks))
  )
    ;; Validations
    (asserts! (is-valid-spot-id spot-id) err-invalid-spot-id)
    (asserts! (> duration-blocks u0) err-invalid-duration)
    (asserts! (<= duration-blocks (var-get max-reservation-duration)) err-invalid-duration)
    (asserts! (is-spot-available spot-id start-block end-block) err-spot-not-available)
    
    ;; Process payment
    (try! (stx-transfer? fee tx-sender contract-owner))
    
    ;; Mint NFT
    (try! (nft-mint? parking-reservation token-id tx-sender))
    
    ;; Store metadata
    (map-set token-metadata token-id {
      spot-id: spot-id,
      start-block: start-block,
      end-block: end-block,
      fee-paid: fee,
      active: true
    })
    
    ;; Update state
    (var-set last-token-id token-id)
    (update-user-reservations tx-sender token-id)
    
    (ok token-id)
  )
)

(define-public (check-in (token-id uint))
  (let ((metadata (unwrap! (map-get? token-metadata token-id) err-token-not-found)))
    (asserts! (is-eq (nft-get-owner? parking-reservation token-id) (some tx-sender)) err-not-token-owner)
    (asserts! (<= (get start-block metadata) stacks-block-height) err-invalid-time)
    (asserts! (> (get end-block metadata) stacks-block-height) err-reservation-expired)
    (asserts! (get active metadata) err-reservation-expired)
    
    (ok true)
  )
)

(define-public (cancel-reservation (token-id uint))
  (let ((metadata (unwrap! (map-get? token-metadata token-id) err-token-not-found)))
    (asserts! (is-eq (nft-get-owner? parking-reservation token-id) (some tx-sender)) err-not-token-owner)
    (asserts! (get active metadata) err-reservation-expired)
    (asserts! (> (get start-block metadata) stacks-block-height) err-invalid-time)
    
    ;; Deactivate reservation
    (map-set token-metadata token-id (merge metadata { active: false }))
    
    ;; Partial refund (50% if cancelled before start)
    (let ((refund (/ (get fee-paid metadata) u2)))
      (try! (as-contract (stx-transfer? refund contract-owner tx-sender)))
    )
    
    (ok true)
  )
)

(define-public (extend-reservation (token-id uint) (additional-blocks uint))
  (let ((metadata (unwrap! (map-get? token-metadata token-id) err-token-not-found)))
    (asserts! (is-eq (nft-get-owner? parking-reservation token-id) (some tx-sender)) err-not-token-owner)
    (asserts! (get active metadata) err-reservation-expired)
    (asserts! (> (get end-block metadata) stacks-block-height) err-reservation-expired)
    (asserts! (> additional-blocks u0) err-invalid-duration)
    
    (let (
      (new-end-block (+ (get end-block metadata) additional-blocks))
      (extension-fee (calculate-fee (get spot-id metadata) additional-blocks))
    )
      ;; Process payment for extension
      (try! (stx-transfer? extension-fee tx-sender contract-owner))
      
      ;; Update metadata
      (map-set token-metadata token-id (merge metadata {
        end-block: new-end-block,
        fee-paid: (+ (get fee-paid metadata) extension-fee)
      }))
      
      (ok new-end-block)
    )
  )
)

(define-public (update-spot-availability (spot-id uint) (available bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-some (map-get? parking-spots spot-id)) err-invalid-spot-id)
    (match (map-get? parking-spots spot-id)
      spot-info (ok (map-set parking-spots spot-id {
        location: (get location spot-info),
        available: available,
        hourly-rate: (get hourly-rate spot-info)
      }))
      err-invalid-spot-id
    )
  )
)

(define-public (update-base-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> new-fee u0) err-invalid-time)
    (ok (var-set base-fee new-fee))
  )
)

;; Read-only Functions

(define-read-only (get-reservation-metadata (token-id uint))
  (map-get? token-metadata token-id)
)

(define-read-only (get-parking-spot-info (spot-id uint))
  (map-get? parking-spots spot-id)
)

(define-read-only (is-reservation-active (token-id uint))
  (match (map-get? token-metadata token-id)
    metadata (and 
      (get active metadata)
      (> (get end-block metadata) stacks-block-height)
    )
    false
  )
)

(define-read-only (get-user-reservations (user principal))
  (default-to (list) (map-get? user-reservations user))
)

(define-read-only (get-current-block-height)
  stacks-block-height
)

(define-read-only (get-last-token-id)
  (var-get last-token-id)
)

(define-read-only (get-base-fee)
  (var-get base-fee)
)