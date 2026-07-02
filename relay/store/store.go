// Package store implements SQLite persistence for the Claudeometer relay,
// using the pure-Go modernc.org/sqlite driver (no CGO). Schema and semantics
// follow PROTOCOL.md's "Persistence" section exactly.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

// ErrNotFound is returned by lookup methods when no matching row exists.
var ErrNotFound = errors.New("store: not found")

const schema = `
CREATE TABLE IF NOT EXISTS users (
  user_id TEXT PRIMARY KEY, display_name TEXT NOT NULL,
  signing_pubkey TEXT NOT NULL, encryption_pubkey TEXT,
  device_id TEXT NOT NULL, created_at INTEGER NOT NULL, last_seen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS usage_posts (
  user_id TEXT PRIMARY KEY REFERENCES users(user_id),
  five_hour_pct REAL NOT NULL, seven_day_pct REAL NOT NULL,
  reset_at INTEGER, available_to_lend INTEGER NOT NULL, posted_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS borrow_requests (
  id TEXT PRIMARY KEY,
  requester_id TEXT NOT NULL REFERENCES users(user_id),
  lender_id TEXT NOT NULL REFERENCES users(user_id),
  hours INTEGER NOT NULL,
  status TEXT NOT NULL,          -- pending|approved|rejected|revoked|expired|picked_up
  created_at INTEGER NOT NULL,
  decided_at INTEGER
);
CREATE TABLE IF NOT EXISTS mailbox (
  request_id TEXT PRIMARY KEY REFERENCES borrow_requests(id),
  recipient_id TEXT NOT NULL,
  ciphertext TEXT NOT NULL,      -- opaque base64 E2E sealed blob; relay never reads it
  ttl_expires_at INTEGER NOT NULL
);
`

// Store wraps a SQLite-backed database handle for the relay.
type Store struct {
	db *sql.DB
}

// User mirrors the users table in PROTOCOL.md.
type User struct {
	UserID           string
	DisplayName      string
	SigningPubKey    string
	EncryptionPubKey string
	DeviceID         string
	CreatedAt        int64
	LastSeen         int64
}

// Usage mirrors the usage_posts table (minus user_id and posted_at, which
// are supplied separately by UpsertUsage).
type Usage struct {
	FiveHourPct     float64
	SevenDayPct     float64
	ResetAt         *int64
	AvailableToLend bool
}

// BoardRow is one row of the GET /board response: a user joined with their
// (possibly absent) latest usage post. JSON tags match PROTOCOL.md exactly.
type BoardRow struct {
	UserID          string   `json:"userId"`
	DisplayName     string   `json:"displayName"`
	FiveHourPct     *float64 `json:"fiveHourPct"`
	SevenDayPct     *float64 `json:"sevenDayPct"`
	ResetAt         *int64   `json:"resetAt"`
	AvailableToLend *bool    `json:"availableToLend"`
	LastSeen        int64    `json:"lastSeen"`
	PostedAt        *int64   `json:"postedAt"`
}

// BorrowRequest mirrors a row of the borrow_requests table.
type BorrowRequest struct {
	ID          string
	RequesterID string
	LenderID    string
	Hours       int
	Status      string
	CreatedAt   int64
	DecidedAt   *int64
}

// IncomingRequest is one row of GET /borrow/inbox's "incoming" list: a
// pending request where the caller is the lender, joined with the
// requester's display name and encryption pubkey (so the lender can seal a
// reply to it). JSON tags match PROTOCOL.md exactly.
type IncomingRequest struct {
	RequestID                 string `json:"requestId"`
	RequesterID               string `json:"requesterId"`
	RequesterName             string `json:"requesterName"`
	RequesterEncryptionPubKey string `json:"requesterEncryptionPubKey"`
	Hours                     int    `json:"hours"`
	CreatedAt                 int64  `json:"createdAt"`
}

// OutgoingRequest is one row of GET /borrow/inbox's "outgoing" list: one of
// the caller's own requests, joined with the lender's display name. JSON
// tags match PROTOCOL.md exactly.
type OutgoingRequest struct {
	RequestID  string `json:"requestId"`
	LenderID   string `json:"lenderId"`
	LenderName string `json:"lenderName"`
	Hours      int    `json:"hours"`
	Status     string `json:"status"`
	DecidedAt  *int64 `json:"decidedAt"`
}

// Open opens (creating if necessary) the SQLite database at path, enables
// WAL mode, and runs the schema migration. The returned Store is safe for
// concurrent use by multiple goroutines.
func Open(path string) (*Store, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", path, err)
	}

	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("store: migrate schema: %w", err)
	}

	return &Store{db: db}, nil
}

// Close releases the underlying database handle.
func (s *Store) Close() error {
	return s.db.Close()
}

// CreateUser inserts a new user row. Callers are expected to have already
// generated UserID and set CreatedAt/LastSeen.
func (s *Store) CreateUser(u *User) error {
	_, err := s.db.Exec(
		`INSERT INTO users (user_id, display_name, signing_pubkey, encryption_pubkey, device_id, created_at, last_seen)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		u.UserID, u.DisplayName, u.SigningPubKey, nullableString(u.EncryptionPubKey), u.DeviceID, u.CreatedAt, u.LastSeen,
	)
	if err != nil {
		return fmt.Errorf("store: create user: %w", err)
	}
	return nil
}

// GetUserByID looks up a user by primary key. Returns ErrNotFound if no such
// user exists.
func (s *Store) GetUserByID(id string) (*User, error) {
	row := s.db.QueryRow(
		`SELECT user_id, display_name, signing_pubkey, encryption_pubkey, device_id, created_at, last_seen
		 FROM users WHERE user_id = ?`,
		id,
	)
	return scanUser(row)
}

// FindUser looks up a user by the (deviceId, signingPubKey) pair used to
// make POST /enroll idempotent. Returns ErrNotFound if no such user exists.
func (s *Store) FindUser(deviceID, signingPubKey string) (*User, error) {
	row := s.db.QueryRow(
		`SELECT user_id, display_name, signing_pubkey, encryption_pubkey, device_id, created_at, last_seen
		 FROM users WHERE device_id = ? AND signing_pubkey = ?`,
		deviceID, signingPubKey,
	)
	return scanUser(row)
}

// UpdateLastSeen bumps a user's last_seen timestamp.
func (s *Store) UpdateLastSeen(userID string, ts int64) error {
	res, err := s.db.Exec(`UPDATE users SET last_seen = ? WHERE user_id = ?`, ts, userID)
	if err != nil {
		return fmt.Errorf("store: update last_seen: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: update last_seen: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// UpsertUsage inserts or replaces the caller's usage post and bumps
// users.last_seen to postedAt.
func (s *Store) UpsertUsage(userID string, usage Usage, postedAt int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("store: upsert usage: begin tx: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // rollback is a no-op after commit

	_, err = tx.Exec(
		`INSERT INTO usage_posts (user_id, five_hour_pct, seven_day_pct, reset_at, available_to_lend, posted_at)
		 VALUES (?, ?, ?, ?, ?, ?)
		 ON CONFLICT(user_id) DO UPDATE SET
		   five_hour_pct = excluded.five_hour_pct,
		   seven_day_pct = excluded.seven_day_pct,
		   reset_at = excluded.reset_at,
		   available_to_lend = excluded.available_to_lend,
		   posted_at = excluded.posted_at`,
		userID, usage.FiveHourPct, usage.SevenDayPct, usage.ResetAt, usage.AvailableToLend, postedAt,
	)
	if err != nil {
		return fmt.Errorf("store: upsert usage: %w", err)
	}

	if _, err := tx.Exec(`UPDATE users SET last_seen = ? WHERE user_id = ?`, postedAt, userID); err != nil {
		return fmt.Errorf("store: upsert usage: bump last_seen: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("store: upsert usage: commit: %w", err)
	}
	return nil
}

// ListBoard returns one row per enrolled user, LEFT JOINed against their
// latest usage post so users with no post yet appear with null usage
// fields. Ordered by created_at so results are stable / insertion-ordered.
func (s *Store) ListBoard() ([]BoardRow, error) {
	rows, err := s.db.Query(
		`SELECT u.user_id, u.display_name, u.last_seen,
		        up.five_hour_pct, up.seven_day_pct, up.reset_at, up.available_to_lend, up.posted_at
		 FROM users u
		 LEFT JOIN usage_posts up ON u.user_id = up.user_id
		 ORDER BY u.created_at ASC`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list board: %w", err)
	}
	defer rows.Close()

	var board []BoardRow
	for rows.Next() {
		var (
			row             BoardRow
			fiveHourPct     sql.NullFloat64
			sevenDayPct     sql.NullFloat64
			resetAt         sql.NullInt64
			availableToLend sql.NullBool
			postedAt        sql.NullInt64
		)
		if err := rows.Scan(&row.UserID, &row.DisplayName, &row.LastSeen,
			&fiveHourPct, &sevenDayPct, &resetAt, &availableToLend, &postedAt); err != nil {
			return nil, fmt.Errorf("store: list board: scan: %w", err)
		}
		if fiveHourPct.Valid {
			row.FiveHourPct = &fiveHourPct.Float64
		}
		if sevenDayPct.Valid {
			row.SevenDayPct = &sevenDayPct.Float64
		}
		if resetAt.Valid {
			row.ResetAt = &resetAt.Int64
		}
		if availableToLend.Valid {
			row.AvailableToLend = &availableToLend.Bool
		}
		if postedAt.Valid {
			row.PostedAt = &postedAt.Int64
		}
		board = append(board, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list board: %w", err)
	}
	return board, nil
}

// --- borrow handshake (M3) ---

// CreateBorrowRequest inserts a new pending borrow request.
func (s *Store) CreateBorrowRequest(id, requesterID, lenderID string, hours int, createdAt int64) error {
	_, err := s.db.Exec(
		`INSERT INTO borrow_requests (id, requester_id, lender_id, hours, status, created_at, decided_at)
		 VALUES (?, ?, ?, ?, 'pending', ?, NULL)`,
		id, requesterID, lenderID, hours, createdAt,
	)
	if err != nil {
		return fmt.Errorf("store: create borrow request: %w", err)
	}
	return nil
}

// GetBorrowRequest looks up a borrow request by id. Returns ErrNotFound if
// no such request exists.
func (s *Store) GetBorrowRequest(id string) (*BorrowRequest, error) {
	row := s.db.QueryRow(
		`SELECT id, requester_id, lender_id, hours, status, created_at, decided_at
		 FROM borrow_requests WHERE id = ?`,
		id,
	)
	var br BorrowRequest
	var decidedAt sql.NullInt64
	err := row.Scan(&br.ID, &br.RequesterID, &br.LenderID, &br.Hours, &br.Status, &br.CreatedAt, &decidedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("store: get borrow request: %w", err)
	}
	if decidedAt.Valid {
		br.DecidedAt = &decidedAt.Int64
	}
	return &br, nil
}

// ListIncoming returns the pending requests where lenderID is the lender,
// joined with each requester's display name and encryption pubkey, newest
// first.
func (s *Store) ListIncoming(lenderID string) ([]IncomingRequest, error) {
	rows, err := s.db.Query(
		`SELECT br.id, br.requester_id, u.display_name, u.encryption_pubkey, br.hours, br.created_at
		 FROM borrow_requests br
		 JOIN users u ON u.user_id = br.requester_id
		 WHERE br.status = 'pending' AND br.lender_id = ?
		 ORDER BY br.created_at DESC`,
		lenderID,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list incoming: %w", err)
	}
	defer rows.Close()

	var incoming []IncomingRequest
	for rows.Next() {
		var ir IncomingRequest
		var encPubKey sql.NullString
		if err := rows.Scan(&ir.RequestID, &ir.RequesterID, &ir.RequesterName, &encPubKey, &ir.Hours, &ir.CreatedAt); err != nil {
			return nil, fmt.Errorf("store: list incoming: scan: %w", err)
		}
		ir.RequesterEncryptionPubKey = encPubKey.String
		incoming = append(incoming, ir)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list incoming: %w", err)
	}
	return incoming, nil
}

// ListOutgoing returns requesterID's own requests, joined with each
// lender's display name, newest first.
func (s *Store) ListOutgoing(requesterID string) ([]OutgoingRequest, error) {
	rows, err := s.db.Query(
		`SELECT br.id, br.lender_id, u.display_name, br.hours, br.status, br.decided_at
		 FROM borrow_requests br
		 JOIN users u ON u.user_id = br.lender_id
		 WHERE br.requester_id = ?
		 ORDER BY br.created_at DESC`,
		requesterID,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list outgoing: %w", err)
	}
	defer rows.Close()

	var outgoing []OutgoingRequest
	for rows.Next() {
		var or OutgoingRequest
		var decidedAt sql.NullInt64
		if err := rows.Scan(&or.RequestID, &or.LenderID, &or.LenderName, &or.Hours, &or.Status, &decidedAt); err != nil {
			return nil, fmt.Errorf("store: list outgoing: scan: %w", err)
		}
		if decidedAt.Valid {
			or.DecidedAt = &decidedAt.Int64
		}
		outgoing = append(outgoing, or)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list outgoing: %w", err)
	}
	return outgoing, nil
}

// ApproveBorrow marks a borrow request approved and stores the sealed
// ciphertext in the recipient's mailbox, TTL-bounded by ttlExpiresAt.
// Returns ErrNotFound if no such request exists.
func (s *Store) ApproveBorrow(id, recipientID, ciphertext string, decidedAt, ttlExpiresAt int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("store: approve borrow: begin tx: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // rollback is a no-op after commit

	res, err := tx.Exec(`UPDATE borrow_requests SET status = 'approved', decided_at = ? WHERE id = ?`, decidedAt, id)
	if err != nil {
		return fmt.Errorf("store: approve borrow: update status: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: approve borrow: rows affected: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}

	_, err = tx.Exec(
		`INSERT INTO mailbox (request_id, recipient_id, ciphertext, ttl_expires_at)
		 VALUES (?, ?, ?, ?)
		 ON CONFLICT(request_id) DO UPDATE SET
		   recipient_id = excluded.recipient_id,
		   ciphertext = excluded.ciphertext,
		   ttl_expires_at = excluded.ttl_expires_at`,
		id, recipientID, ciphertext, ttlExpiresAt,
	)
	if err != nil {
		return fmt.Errorf("store: approve borrow: upsert mailbox: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("store: approve borrow: commit: %w", err)
	}
	return nil
}

// RejectBorrow marks a borrow request rejected. Returns ErrNotFound if no
// such request exists.
func (s *Store) RejectBorrow(id string, decidedAt int64) error {
	res, err := s.db.Exec(`UPDATE borrow_requests SET status = 'rejected', decided_at = ? WHERE id = ?`, decidedAt, id)
	if err != nil {
		return fmt.Errorf("store: reject borrow: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: reject borrow: rows affected: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// PickupMailbox reads and consumes the mailbox entry for requestID: it
// returns the opaque ciphertext, flips the request's status to picked_up,
// and deletes the mailbox row so the pickup is one-shot. An entry whose TTL
// has already elapsed is treated as gone (deleted, ErrNotFound returned)
// rather than handed back. Returns ErrNotFound if no mailbox entry exists.
func (s *Store) PickupMailbox(requestID string) (string, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return "", fmt.Errorf("store: pickup mailbox: begin tx: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // rollback is a no-op after commit

	var ciphertext string
	var ttlExpiresAt int64
	err = tx.QueryRow(
		`SELECT ciphertext, ttl_expires_at FROM mailbox WHERE request_id = ?`, requestID,
	).Scan(&ciphertext, &ttlExpiresAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", fmt.Errorf("store: pickup mailbox: %w", err)
	}

	if ttlExpiresAt < time.Now().Unix() {
		if _, err := tx.Exec(`DELETE FROM mailbox WHERE request_id = ?`, requestID); err != nil {
			return "", fmt.Errorf("store: pickup mailbox: delete expired: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return "", fmt.Errorf("store: pickup mailbox: commit: %w", err)
		}
		return "", ErrNotFound
	}

	if _, err := tx.Exec(`UPDATE borrow_requests SET status = 'picked_up' WHERE id = ?`, requestID); err != nil {
		return "", fmt.Errorf("store: pickup mailbox: update status: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM mailbox WHERE request_id = ?`, requestID); err != nil {
		return "", fmt.Errorf("store: pickup mailbox: delete: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return "", fmt.Errorf("store: pickup mailbox: commit: %w", err)
	}
	return ciphertext, nil
}

// RevokeBorrow marks a borrow request revoked and deletes any pending
// mailbox row for it. Returns ErrNotFound if no such request exists.
func (s *Store) RevokeBorrow(id string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("store: revoke borrow: begin tx: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // rollback is a no-op after commit

	res, err := tx.Exec(`UPDATE borrow_requests SET status = 'revoked' WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("store: revoke borrow: update status: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: revoke borrow: rows affected: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}

	if _, err := tx.Exec(`DELETE FROM mailbox WHERE request_id = ?`, id); err != nil {
		return fmt.Errorf("store: revoke borrow: delete mailbox: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("store: revoke borrow: commit: %w", err)
	}
	return nil
}

// rowScanner abstracts *sql.Row so scanUser can be reused for single-row
// queries regardless of which query produced them.
type rowScanner interface {
	Scan(dest ...any) error
}

func scanUser(row rowScanner) (*User, error) {
	var u User
	var encryptionPubKey sql.NullString
	err := row.Scan(&u.UserID, &u.DisplayName, &u.SigningPubKey, &encryptionPubKey, &u.DeviceID, &u.CreatedAt, &u.LastSeen)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("store: scan user: %w", err)
	}
	u.EncryptionPubKey = encryptionPubKey.String
	return &u, nil
}

func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}
