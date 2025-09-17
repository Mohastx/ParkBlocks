;; ParkBlocks - Time-Bound NFT Parking Reservation Contract with Dynamic Pricing
;; Enables decentralized parking spot reservations using NFTs with automatic expiration and surge pricing

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
(define-constant err-oracle-only (err u109))
(define-constant err-invalid-multiplier (err u110))
(define-constant err-invalid-demand (err u111))

;; Data Variables
(define-data-var last-token-id uint u0)
(define-data-var base-fee uint u1000000) ;; 1 STX in micro-STX
(define-data-var max-reservation-duration uint u144) ;; ~24 hours in blocks
(define-data-var oracle-address (optional principal) none)
(define-data-var max-surge-multiplier uint u300) ;; 3.0x max surge (300%)
(define-data-var peak-hours-start uint u7) ;; 7 AM
(define-data-var peak-hours-end uint u19) ;; 7 PM
(define-data-var time-multiplier uint u150) ;; 1.5x during peak hours (150%)

;; Data Maps
(define-map token-metadata 
  uint 
  {
    spot-id: uint,
    start-block: uint,
    end-block: uint,
    fee-paid: uint,
    active: bool,
    price-at-booking: uint
  }
)

(define-map parking-spots
  uint
  {
    location: (string-ascii 100),
    available: bool,
    hourly-rate: uint,
    popularity-score: uint,
    location-multiplier: uint
  }
)

(define-map user-reservations
  principal
  (list 50 uint)
)

(define-map demand-data
  uint ;; spot-id
  {
    current-reservations: uint,
    total-historical-bookings: uint,
    last-booking-block: uint,
    demand-multiplier: uint
  }
)

(define-map time-pricing
  uint ;; hour (0-23)
  {
    multiplier: uint,
    is-peak: bool
  }
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

(define-private (get-current-hour)
  ;; Simplified hour calculation based on block height
  ;; In production, this would use oracle data for accurate time
  (mod (/ stacks-block-height u6) u24)
)

(define-private (calculate-time-multiplier (hour uint))
  (let ((time-data (map-get? time-pricing hour)))
    (match time-data
      data (get multiplier data)
      (if (and (>= hour (var-get peak-hours-start)) 
               (<= hour (var-get peak-hours-end)))
        (var-get time-multiplier)
        u100) ;; 1.0x for off-peak
    )
  )
)

(define-private (calculate-demand-multiplier (spot-id uint))
  (let ((demand-info (default-to 
    { current-reservations: u0, total-historical-bookings: u0, last-booking-block: u0, demand-multiplier: u100 }
    (map-get? demand-data spot-id))))
    
    (let ((current-demand (get current-reservations demand-info))
          (time-since-last (- stacks-block-height (get last-booking-block demand-info))))
      
      ;; Calculate surge based on current active reservations and recent activity
      (if (> current-demand u0)
        (let ((surge-factor (+ u100 (* current-demand u25)))) ;; 25% increase per active reservation
          (if (<= surge-factor (var-get max-surge-multiplier))
            surge-factor
            (var-get max-surge-multiplier)))
        u100) ;; Base rate when no current demand
    )
  )
)

(define-private (get-location-multiplier (spot-id uint))
  (let ((spot-info (unwrap! (map-get? parking-spots spot-id) u100)))
    (get location-multiplier spot-info)
  )
)

(define-private (calculate-dynamic-fee (spot-id uint) (duration-blocks uint))
  (let (
    (spot-info (unwrap! (map-get? parking-spots spot-id) u0))
    (base-hourly-rate (get hourly-rate spot-info))
    (duration-hours (/ duration-blocks u6))
    (hours (if (> duration-hours u0) duration-hours u1)) ;; Minimum 1 hour
    (current-hour (get-current-hour))
    (time-mult (calculate-time-multiplier current-hour))
    (demand-mult (calculate-demand-multiplier spot-id))
    (location-mult (get-location-multiplier spot-id))
  )
    (let (
      (base-cost (* base-hourly-rate hours))
      (time-adjusted (/ (* base-cost time-mult) u100))
      (demand-adjusted (/ (* time-adjusted demand-mult) u100))
      (final-cost (/ (* demand-adjusted location-mult) u100))
    )
      final-cost
    )
  )
)

(define-private (update-demand-data (spot-id uint))
  (let ((current-demand (default-to 
    { current-reservations: u0, total-historical-bookings: u0, last-booking-block: u0, demand-multiplier: u100 }
    (map-get? demand-data spot-id))))
    
    (map-set demand-data spot-id {
      current-reservations: (+ (get current-reservations current-demand) u1),
      total-historical-bookings: (+ (get total-historical-bookings current-demand) u1),
      last-booking-block: stacks-block-height,
      demand-multiplier: (calculate-demand-multiplier spot-id)
    })
  )
)

(define-private (decrease-demand-counter (spot-id uint))
  (let ((current-demand (default-to 
    { current-reservations: u0, total-historical-bookings: u0, last-booking-block: u0, demand-multiplier: u100 }
    (map-get? demand-data spot-id))))
    
    (if (> (get current-reservations current-demand) u0)
      (map-set demand-data spot-id {
        current-reservations: (- (get current-reservations current-demand) u1),
        total-historical-bookings: (get total-historical-bookings current-demand),
        last-booking-block: (get last-booking-block current-demand),
        demand-multiplier: (calculate-demand-multiplier spot-id)
      })
      true
    )
  )
)

(define-private (update-user-reservations (user principal) (token-id uint))
  (let ((current-reservations (default-to (list) (map-get? user-reservations user))))
    (map-set user-reservations user (unwrap! (as-max-len? (append current-reservations token-id) u50) false))
  )
)

;; Public Functions

(define-public (set-oracle-address (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (not (is-eq oracle 'SP000000000000000000002Q6VF78)) err-invalid-spot-id)
    (ok (var-set oracle-address (some oracle)))
  )
)

(define-public (initialize-parking-spot (spot-id uint) (location (string-ascii 100)) (hourly-rate uint) (location-multiplier uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> spot-id u0) err-invalid-spot-id)
    (asserts! (> (len location) u0) err-invalid-spot-id)
    (asserts! (> hourly-rate u0) err-invalid-spot-id)
    (asserts! (and (>= location-multiplier u50) (<= location-multiplier u300)) err-invalid-multiplier)
    
    (map-set parking-spots spot-id {
      location: location,
      available: true,
      hourly-rate: hourly-rate,
      popularity-score: u0,
      location-multiplier: location-multiplier
    })
    
    ;; Initialize demand data
    (map-set demand-data spot-id {
      current-reservations: u0,
      total-historical-bookings: u0,
      last-booking-block: u0,
      demand-multiplier: u100
    })
    
    (ok true)
  )
)

(define-public (set-time-pricing (hour uint) (multiplier uint) (is-peak bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (< hour u24) err-invalid-time)
    (asserts! (and (>= multiplier u50) (<= multiplier u300)) err-invalid-multiplier)
    
    (ok (map-set time-pricing hour {
      multiplier: multiplier,
      is-peak: is-peak
    }))
  )
)

(define-public (update-demand-oracle (spot-id uint) (demand-level uint))
  (begin
    (asserts! (is-some (var-get oracle-address)) err-oracle-only)
    (asserts! (is-eq tx-sender (unwrap! (var-get oracle-address) err-oracle-only)) err-oracle-only)
    (asserts! (is-valid-spot-id spot-id) err-invalid-spot-id)
    (asserts! (<= demand-level u500) err-invalid-demand) ;; Max 5x multiplier
    
    (let ((current-demand (default-to 
      { current-reservations: u0, total-historical-bookings: u0, last-booking-block: u0, demand-multiplier: u100 }
      (map-get? demand-data spot-id))))
      
      (ok (map-set demand-data spot-id {
        current-reservations: (get current-reservations current-demand),
        total-historical-bookings: (get total-historical-bookings current-demand),
        last-booking-block: (get last-booking-block current-demand),
        demand-multiplier: demand-level
      }))
    )
  )
)

(define-public (get-current-price (spot-id uint) (duration-blocks uint))
  (begin
    (asserts! (is-valid-spot-id spot-id) err-invalid-spot-id)
    (asserts! (> duration-blocks u0) err-invalid-duration)
    (ok (calculate-dynamic-fee spot-id duration-blocks))
  )
)

(define-public (mint-reservation (spot-id uint) (duration-blocks uint))
  (let (
    (token-id (+ (var-get last-token-id) u1))
    (start-block stacks-block-height)
    (end-block (+ stacks-block-height duration-blocks))
    (dynamic-fee (calculate-dynamic-fee spot-id duration-blocks))
  )
    ;; Validations
    (asserts! (is-valid-spot-id spot-id) err-invalid-spot-id)
    (asserts! (> duration-blocks u0) err-invalid-duration)
    (asserts! (<= duration-blocks (var-get max-reservation-duration)) err-invalid-duration)
    (asserts! (is-spot-available spot-id start-block end-block) err-spot-not-available)
    
    ;; Process payment with dynamic pricing
    (try! (stx-transfer? dynamic-fee tx-sender contract-owner))
    
    ;; Mint NFT
    (try! (nft-mint? parking-reservation token-id tx-sender))
    
    ;; Store metadata with price paid
    (map-set token-metadata token-id {
      spot-id: spot-id,
      start-block: start-block,
      end-block: end-block,
      fee-paid: dynamic-fee,
      active: true,
      price-at-booking: dynamic-fee
    })
    
    ;; Update demand and state
    (update-demand-data spot-id)
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
    
    ;; Decrease demand counter
    (decrease-demand-counter (get spot-id metadata))
    
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
      (extension-fee (calculate-dynamic-fee (get spot-id metadata) additional-blocks))
    )
      ;; Process payment for extension with current dynamic pricing
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

(define-public (expire-reservation (token-id uint))
  (let ((metadata (unwrap! (map-get? token-metadata token-id) err-token-not-found)))
    (asserts! (<= (get end-block metadata) stacks-block-height) err-invalid-time)
    (asserts! (get active metadata) err-reservation-expired)
    
    ;; Mark as expired
    (map-set token-metadata token-id (merge metadata { active: false }))
    
    ;; Decrease demand counter
    (decrease-demand-counter (get spot-id metadata))
    
    (ok true)
  )
)

(define-public (update-spot-availability (spot-id uint) (available bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-some (map-get? parking-spots spot-id)) err-invalid-spot-id)
    (match (map-get? parking-spots spot-id)
      spot-info (ok (map-set parking-spots spot-id (merge spot-info { available: available })))
      err-invalid-spot-id
    )
  )
)

(define-public (update-location-multiplier (spot-id uint) (new-multiplier uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-some (map-get? parking-spots spot-id)) err-invalid-spot-id)
    (asserts! (and (>= new-multiplier u50) (<= new-multiplier u300)) err-invalid-multiplier)
    
    (match (map-get? parking-spots spot-id)
      spot-info (ok (map-set parking-spots spot-id (merge spot-info { location-multiplier: new-multiplier })))
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

(define-read-only (get-demand-data (spot-id uint))
  (map-get? demand-data spot-id)
)

(define-read-only (get-time-pricing (hour uint))
  (map-get? time-pricing hour)
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

(define-read-only (get-current-time-multiplier)
  (calculate-time-multiplier (get-current-hour))
)

(define-read-only (get-spot-demand-multiplier (spot-id uint))
  (calculate-demand-multiplier spot-id)
)

(define-read-only (get-pricing-breakdown (spot-id uint) (duration-blocks uint))
  (match (map-get? parking-spots spot-id)
    spot-info
      (let (
        (base-hourly-rate (get hourly-rate spot-info))
        (duration-hours (/ duration-blocks u6))
        (hours (if (> duration-hours u0) duration-hours u1))
        (current-hour (get-current-hour))
        (time-mult (calculate-time-multiplier current-hour))
        (demand-mult (calculate-demand-multiplier spot-id))
        (location-mult (get-location-multiplier spot-id))
        (final-fee (calculate-dynamic-fee spot-id duration-blocks))
      )
        (ok {
          base-rate: base-hourly-rate,
          hours: hours,
          time-multiplier: time-mult,
          demand-multiplier: demand-mult,
          location-multiplier: location-mult,
          final-price: final-fee,
          current-hour: current-hour
        }))
    err-invalid-spot-id
  )
)

(define-read-only (get-last-token-id)
  (var-get last-token-id)
)

(define-read-only (get-base-fee)
  (var-get base-fee)
)

(define-read-only (get-oracle-address)
  (var-get oracle-address)
)