(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-IDEA-NOT-FOUND (err u102))
(define-constant ERR-ALREADY-VOTED (err u103))
(define-constant ERR-INSUFFICIENT-FUNDS (err u104))
(define-constant ERR-NOT-IMPLEMENTED (err u105))
(define-constant ERR-MILESTONE-NOT-FOUND (err u106))
(define-constant ERR-MILESTONE-COMPLETED (err u107))
(define-constant ERR-INVALID-MILESTONE (err u108))
(define-constant ERR-IDEA-NOT-EXPIRED (err u109))

(define-constant IDEA-EXPIRATION-BLOCKS u100)

(define-constant REPUTATION-IDEA-SUBMIT u10)
(define-constant REPUTATION-VOTE-CAST u5)
(define-constant REPUTATION-IDEA-IMPLEMENTED u50)
(define-constant REPUTATION-MILESTONE-COMPLETE u25)
(define-constant REPUTATION-VOTE-ACCURATE u15)

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
        rewards-claimed: bool,
        tags: (list 3 (string-ascii 20)),
        submission-block: uint
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

(define-map idea-milestones
    { idea-id: uint, milestone-id: uint }
    {
        title: (string-ascii 100),
        description: (string-ascii 300),
        reward-percentage: uint,
        completed: bool,
        completed-by: (optional principal),
        completion-block: (optional uint)
    }
)

(define-map milestone-counter
    uint
    uint
)

(define-map user-reputation
    principal
    {
        total-score: uint,
        ideas-submitted: uint,
        votes-cast: uint,
        ideas-implemented: uint,
        milestones-completed: uint,
        accurate-votes: uint,
        last-updated: uint
    }
)
(define-map tag-ideas (string-ascii 20) (list 10002 uint))
(define-public (submit-idea (title (string-ascii 100)) (description (string-ascii 500)) (stake uint) (tags (list 3 (string-ascii 20))))
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
            rewards-claimed: false,
            tags: tags,
            submission-block: stacks-block-height
        })
        (update-tags tags idea-id)
        (unwrap-panic (update-reputation tx-sender REPUTATION-IDEA-SUBMIT u1 u0 u0 u0 u0))
        (ok idea-id)
    )
)

(define-public (vote-for-idea (idea-id uint))
    (let ((vote-key { user: tx-sender, idea-id: idea-id })
          (idea (unwrap! (map-get? ideas idea-id) ERR-IDEA-NOT-FOUND)))
        (asserts! (not (default-to false (map-get? user-votes vote-key))) ERR-ALREADY-VOTED)
        (map-set user-votes vote-key true)
        (map-set ideas idea-id (merge idea { votes: (+ (get votes idea) u1) }))
        (unwrap-panic (update-reputation tx-sender REPUTATION-VOTE-CAST u0 u1 u0 u0 u0))
        (ok true)
    )
)

(define-public (mark-implemented (idea-id uint))
    (let ((idea (unwrap! (map-get? ideas idea-id) ERR-IDEA-NOT-FOUND)))
        (asserts! (is-dev-team tx-sender) ERR-NOT-AUTHORIZED)
        (map-set ideas idea-id (merge idea { implemented: true }))
        (unwrap-panic (update-reputation (get author idea) REPUTATION-IDEA-IMPLEMENTED u0 u0 u1 u0 u0))
        (unwrap-panic (reward-accurate-voters idea-id))
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

(define-public (withdraw-stake-if-expired (idea-id uint))
    (let ((idea (unwrap! (map-get? ideas idea-id) ERR-IDEA-NOT-FOUND)))
        (asserts! (is-eq (get author idea) tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (not (get implemented idea)) ERR-NOT-IMPLEMENTED)
        (asserts! (>= stacks-block-height (+ (get submission-block idea) IDEA-EXPIRATION-BLOCKS)) ERR-IDEA-NOT-EXPIRED)
        (let ((stake-amount (get stake idea)))
            (try! (as-contract (stx-transfer? stake-amount (as-contract tx-sender) tx-sender)))
            (var-set treasury-balance (- (var-get treasury-balance) stake-amount))
            (map-set ideas idea-id (merge idea { stake: u0 }))
            (ok stake-amount)
        )
    )
)

(define-public (create-milestone (idea-id uint) (title (string-ascii 100)) (description (string-ascii 300)) (reward-percentage uint))
    (let ((milestone-id (+ (default-to u0 (map-get? milestone-counter idea-id)) u1))
          (idea (unwrap! (map-get? ideas idea-id) ERR-IDEA-NOT-FOUND)))
        (asserts! (is-dev-team tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (<= reward-percentage u100) ERR-INVALID-AMOUNT)
        (map-set milestone-counter idea-id milestone-id)
        (map-set idea-milestones { idea-id: idea-id, milestone-id: milestone-id } {
            title: title,
            description: description,
            reward-percentage: reward-percentage,
            completed: false,
            completed-by: none,
            completion-block: none
        })
        (ok milestone-id)
    )
)

(define-public (complete-milestone (idea-id uint) (milestone-id uint))
    (let ((milestone-key { idea-id: idea-id, milestone-id: milestone-id })
          (milestone (unwrap! (map-get? idea-milestones milestone-key) ERR-MILESTONE-NOT-FOUND))
          (idea (unwrap! (map-get? ideas idea-id) ERR-IDEA-NOT-FOUND)))
        (asserts! (is-dev-team tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (not (get completed milestone)) ERR-MILESTONE-COMPLETED)
        (map-set idea-milestones milestone-key (merge milestone {
            completed: true,
            completed-by: (some tx-sender),
            completion-block: (some stacks-block-height)
        }))
        (let ((milestone-reward (/ (* (get stake idea) (get reward-percentage milestone)) u100)))
            (try! (as-contract (stx-transfer? milestone-reward (as-contract tx-sender) (get author idea))))
            (unwrap-panic (update-reputation tx-sender REPUTATION-MILESTONE-COMPLETE u0 u0 u0 u1 u0))
            (ok milestone-reward)
        )
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

(define-read-only (get-milestone (idea-id uint) (milestone-id uint))
    (map-get? idea-milestones { idea-id: idea-id, milestone-id: milestone-id })
)

(define-read-only (get-milestone-count (idea-id uint))
    (default-to u0 (map-get? milestone-counter idea-id))
)

(define-read-only (get-completed-milestones (idea-id uint))
    (let ((total-milestones (get-milestone-count idea-id)))
        (fold check-milestone-completion (list u1 u2 u3 u4 u5 u6 u7 u8 u9 u10) { idea-id: idea-id, completed: u0, total: total-milestones })
    )
)

(define-read-only (get-user-reputation (user principal))
    (default-to { total-score: u0, ideas-submitted: u0, votes-cast: u0, ideas-implemented: u0, milestones-completed: u0, accurate-votes: u0, last-updated: u0 }
                (map-get? user-reputation user))
)

(define-read-only (get-reputation-score (user principal))
    (get total-score (get-user-reputation user))
)

(define-read-only (calculate-reputation-multiplier (user principal))
    (let ((score (get-reputation-score user)))
        (if (>= score u500) u300
        (if (>= score u250) u200
        (if (>= score u100) u150
        (if (>= score u50) u125
            u100))))
    )
)
(define-read-only (get-ideas-by-tag (tag (string-ascii 20)))
    (default-to (list) (map-get? tag-ideas tag))
)
(define-private (check-milestone-completion (milestone-id uint) (acc { idea-id: uint, completed: uint, total: uint }))
    (if (<= milestone-id (get total acc))
        (let ((milestone (map-get? idea-milestones { idea-id: (get idea-id acc), milestone-id: milestone-id })))
            (if (and (is-some milestone) (get completed (unwrap-panic milestone)))
                (merge acc { completed: (+ (get completed acc) u1) })
                acc
            )
        )
        acc
    )
)

(define-private (update-reputation (user principal) (score-change uint) (idea-delta uint) (vote-delta uint) (impl-delta uint) (milestone-delta uint) (accurate-delta uint))
    (let ((current-rep (get-user-reputation user)))
        (map-set user-reputation user {
            total-score: (+ (get total-score current-rep) score-change),
            ideas-submitted: (+ (get ideas-submitted current-rep) idea-delta),
            votes-cast: (+ (get votes-cast current-rep) vote-delta),
            ideas-implemented: (+ (get ideas-implemented current-rep) impl-delta),
            milestones-completed: (+ (get milestones-completed current-rep) milestone-delta),
            accurate-votes: (+ (get accurate-votes current-rep) accurate-delta),
            last-updated: stacks-block-height
        })
        (ok true)
    )
)

(define-private (reward-accurate-voters (idea-id uint))
    (ok true)
)
(define-private (update-tag (tag (string-ascii 20)) (idea-id uint))
    (let ((current (default-to (list) (map-get? tag-ideas tag))))
        (if (< (len current) u10002)
            (map-set tag-ideas tag (unwrap-panic (as-max-len? (append current idea-id) u10002)))
            true
        )
    )
)
(define-private (update-tags (tags (list 3 (string-ascii 20))) (idea-id uint))
    (begin
        (if (> (len tags) u0) (update-tag (unwrap-panic (element-at tags u0)) idea-id) true)
        (if (> (len tags) u1) (update-tag (unwrap-panic (element-at tags u1)) idea-id) true)
        (if (> (len tags) u2) (update-tag (unwrap-panic (element-at tags u2)) idea-id) true)
        true
    )
)
(define-private (contract-owner)
    tx-sender
)
