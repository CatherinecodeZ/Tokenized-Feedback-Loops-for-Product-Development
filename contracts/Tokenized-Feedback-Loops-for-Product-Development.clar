(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-IDEA-NOT-FOUND (err u102))
(define-constant ERR-ALREADY-VOTED (err u103))
(define-constant ERR-INSUFFICIENT-FUNDS (err u104))
(define-constant ERR-NOT-IMPLEMENTED (err u105))

(define-data-var treasury-balance uint u0)
(define-data-var idea-counter uint u0)

(define-map ideas 
    uint 
    {
        author: principal,
        title: (string-ascii 100),
        description: (string-ascii 500),
        stake: uint,
        votes: uint,
        implemented: bool,
        rewards-claimed: bool
    }
)

(define-map user-votes 
    { user: principal, idea-id: uint } 
    bool
)

(define-map user-balances 
    principal 
    uint
)

(define-map dev-teams 
    principal 
    bool
)

(define-public (submit-idea (title (string-ascii 100)) (description (string-ascii 500)) (stake uint))
    (let ((idea-id (+ (var-get idea-counter) u1)))
        (asserts! (>= stake u100) ERR-INVALID-AMOUNT)
        (try! (stx-transfer? stake tx-sender (as-contract tx-sender)))
        (var-set treasury-balance (+ (var-get treasury-balance) stake))
        (var-set idea-counter idea-id)
        (map-set ideas idea-id {
            author: tx-sender,
            title: title,
            description: description,
            stake: stake,
            votes: u0,
            implemented: false,
            rewards-claimed: false
        })
        (ok idea-id)
    )
)

(define-public (vote-for-idea (idea-id uint))
    (let ((vote-key { user: tx-sender, idea-id: idea-id })
          (idea (unwrap! (map-get? ideas idea-id) ERR-IDEA-NOT-FOUND)))
        (asserts! (not (default-to false (map-get? user-votes vote-key))) ERR-ALREADY-VOTED)
        (map-set user-votes vote-key true)
        (map-set ideas idea-id (merge idea { votes: (+ (get votes idea) u1) }))
        (ok true)
    )
)

(define-public (mark-implemented (idea-id uint))
    (let ((idea (unwrap! (map-get? ideas idea-id) ERR-IDEA-NOT-FOUND)))
        (asserts! (is-dev-team tx-sender) ERR-NOT-AUTHORIZED)
        (map-set ideas idea-id (merge idea { implemented: true }))
        (ok true)
    )
)

(define-public (claim-rewards (idea-id uint))
    (let ((idea (unwrap! (map-get? ideas idea-id) ERR-IDEA-NOT-FOUND)))
        (asserts! (is-eq (get author idea) tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (get implemented idea) ERR-NOT-IMPLEMENTED)
        (asserts! (not (get rewards-claimed idea)) ERR-ALREADY-VOTED)
        (let ((reward (* (get votes idea) u10)))
            (try! (as-contract (stx-transfer? reward (as-contract tx-sender) tx-sender)))
            (map-set ideas idea-id (merge idea { rewards-claimed: true }))
            (ok reward)
        )
    )
)

(define-public (register-dev-team (team principal))
    (begin
        (asserts! (is-eq tx-sender (contract-owner)) ERR-NOT-AUTHORIZED)
        (map-set dev-teams team true)
        (ok true)
    )
)

(define-read-only (get-idea (idea-id uint))
    (map-get? ideas idea-id)
)

(define-read-only (get-user-vote (user principal) (idea-id uint))
    (default-to false (map-get? user-votes { user: user, idea-id: idea-id }))
)

(define-read-only (is-dev-team (account principal))
    (default-to false (map-get? dev-teams account))
)

(define-read-only (get-treasury-balance)
    (var-get treasury-balance)
)

(define-private (contract-owner)
    tx-sender
)