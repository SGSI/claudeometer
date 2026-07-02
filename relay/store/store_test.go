package store

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	t.Cleanup(func() {
		if err := s.Close(); err != nil {
			t.Errorf("Close() error = %v", err)
		}
	})
	return s
}

func TestCreateAndGetUser(t *testing.T) {
	s := newTestStore(t)

	u := &User{
		UserID:           "user-1",
		DisplayName:      "Sanket",
		SigningPubKey:    "signing-pub-1",
		EncryptionPubKey: "encryption-pub-1",
		DeviceID:         "device-1",
		CreatedAt:        1000,
		LastSeen:         1000,
	}
	if err := s.CreateUser(u); err != nil {
		t.Fatalf("CreateUser() error = %v", err)
	}

	got, err := s.GetUserByID("user-1")
	if err != nil {
		t.Fatalf("GetUserByID() error = %v", err)
	}
	if got.UserID != u.UserID || got.DisplayName != u.DisplayName ||
		got.SigningPubKey != u.SigningPubKey || got.EncryptionPubKey != u.EncryptionPubKey ||
		got.DeviceID != u.DeviceID || got.CreatedAt != u.CreatedAt || got.LastSeen != u.LastSeen {
		t.Fatalf("GetUserByID() = %+v, want %+v", got, u)
	}
}

func TestGetUserByID_NotFound(t *testing.T) {
	s := newTestStore(t)

	_, err := s.GetUserByID("does-not-exist")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetUserByID() error = %v, want ErrNotFound", err)
	}
}

func TestFindUser_IdempotentReEnroll(t *testing.T) {
	s := newTestStore(t)

	u := &User{
		UserID:           "user-1",
		DisplayName:      "Sanket",
		SigningPubKey:    "signing-pub-1",
		EncryptionPubKey: "encryption-pub-1",
		DeviceID:         "device-1",
		CreatedAt:        1000,
		LastSeen:         1000,
	}
	if err := s.CreateUser(u); err != nil {
		t.Fatalf("CreateUser() error = %v", err)
	}

	found, err := s.FindUser("device-1", "signing-pub-1")
	if err != nil {
		t.Fatalf("FindUser() error = %v", err)
	}
	if found.UserID != u.UserID {
		t.Fatalf("FindUser() userID = %q, want %q", found.UserID, u.UserID)
	}

	// A different signing key for the same device should NOT match — the
	// pairing of deviceId + signingPubKey identifies a distinct enrollment.
	_, err = s.FindUser("device-1", "some-other-key")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("FindUser() with unknown key error = %v, want ErrNotFound", err)
	}

	// A different device entirely should not match either.
	_, err = s.FindUser("device-2", "signing-pub-1")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("FindUser() with unknown device error = %v, want ErrNotFound", err)
	}
}

func TestUpsertUsage_ThenBoard(t *testing.T) {
	s := newTestStore(t)

	u := &User{
		UserID:        "user-1",
		DisplayName:   "Sanket",
		SigningPubKey: "signing-pub-1",
		DeviceID:      "device-1",
		CreatedAt:     1000,
		LastSeen:      1000,
	}
	if err := s.CreateUser(u); err != nil {
		t.Fatalf("CreateUser() error = %v", err)
	}

	resetAt := int64(1893456000)
	usage := Usage{
		FiveHourPct:     62.0,
		SevenDayPct:     20.0,
		ResetAt:         &resetAt,
		AvailableToLend: true,
	}
	if err := s.UpsertUsage("user-1", usage, 2000); err != nil {
		t.Fatalf("UpsertUsage() error = %v", err)
	}

	board, err := s.ListBoard()
	if err != nil {
		t.Fatalf("ListBoard() error = %v", err)
	}
	if len(board) != 1 {
		t.Fatalf("ListBoard() len = %d, want 1", len(board))
	}
	row := board[0]
	if row.UserID != "user-1" || row.DisplayName != "Sanket" {
		t.Fatalf("ListBoard() row = %+v, want userID/displayName user-1/Sanket", row)
	}
	if row.FiveHourPct == nil || *row.FiveHourPct != 62.0 {
		t.Fatalf("ListBoard() FiveHourPct = %v, want 62.0", row.FiveHourPct)
	}
	if row.SevenDayPct == nil || *row.SevenDayPct != 20.0 {
		t.Fatalf("ListBoard() SevenDayPct = %v, want 20.0", row.SevenDayPct)
	}
	if row.ResetAt == nil || *row.ResetAt != resetAt {
		t.Fatalf("ListBoard() ResetAt = %v, want %d", row.ResetAt, resetAt)
	}
	if row.AvailableToLend == nil || !*row.AvailableToLend {
		t.Fatalf("ListBoard() AvailableToLend = %v, want true", row.AvailableToLend)
	}
	if row.PostedAt == nil || *row.PostedAt != 2000 {
		t.Fatalf("ListBoard() PostedAt = %v, want 2000", row.PostedAt)
	}

	// UpsertUsage should have bumped users.last_seen too.
	got, err := s.GetUserByID("user-1")
	if err != nil {
		t.Fatalf("GetUserByID() error = %v", err)
	}
	if got.LastSeen != 2000 {
		t.Fatalf("GetUserByID() LastSeen = %d, want 2000", got.LastSeen)
	}
}

func TestListBoard_UserWithNoUsage(t *testing.T) {
	s := newTestStore(t)

	u := &User{
		UserID:        "user-no-usage",
		DisplayName:   "Ghost",
		SigningPubKey: "signing-pub-2",
		DeviceID:      "device-2",
		CreatedAt:     1000,
		LastSeen:      1000,
	}
	if err := s.CreateUser(u); err != nil {
		t.Fatalf("CreateUser() error = %v", err)
	}

	board, err := s.ListBoard()
	if err != nil {
		t.Fatalf("ListBoard() error = %v", err)
	}
	if len(board) != 1 {
		t.Fatalf("ListBoard() len = %d, want 1", len(board))
	}
	row := board[0]
	if row.UserID != "user-no-usage" {
		t.Fatalf("ListBoard() userID = %q, want user-no-usage", row.UserID)
	}
	if row.FiveHourPct != nil || row.SevenDayPct != nil || row.ResetAt != nil ||
		row.AvailableToLend != nil || row.PostedAt != nil {
		t.Fatalf("ListBoard() usage fields = %+v, want all nil", row)
	}
	if row.LastSeen != 1000 {
		t.Fatalf("ListBoard() LastSeen = %d, want 1000", row.LastSeen)
	}
}

func TestUpsertUsage_ReUpsertOverwrites(t *testing.T) {
	s := newTestStore(t)

	u := &User{
		UserID:        "user-1",
		DisplayName:   "Sanket",
		SigningPubKey: "signing-pub-1",
		DeviceID:      "device-1",
		CreatedAt:     1000,
		LastSeen:      1000,
	}
	if err := s.CreateUser(u); err != nil {
		t.Fatalf("CreateUser() error = %v", err)
	}

	first := Usage{FiveHourPct: 10, SevenDayPct: 5, AvailableToLend: false}
	if err := s.UpsertUsage("user-1", first, 1500); err != nil {
		t.Fatalf("UpsertUsage() first error = %v", err)
	}

	resetAt := int64(1893456000)
	second := Usage{FiveHourPct: 99.5, SevenDayPct: 42.0, ResetAt: &resetAt, AvailableToLend: true}
	if err := s.UpsertUsage("user-1", second, 3000); err != nil {
		t.Fatalf("UpsertUsage() second error = %v", err)
	}

	board, err := s.ListBoard()
	if err != nil {
		t.Fatalf("ListBoard() error = %v", err)
	}
	if len(board) != 1 {
		t.Fatalf("ListBoard() len = %d, want 1", len(board))
	}
	row := board[0]
	if row.FiveHourPct == nil || *row.FiveHourPct != 99.5 {
		t.Fatalf("ListBoard() FiveHourPct = %v, want 99.5", row.FiveHourPct)
	}
	if row.SevenDayPct == nil || *row.SevenDayPct != 42.0 {
		t.Fatalf("ListBoard() SevenDayPct = %v, want 42.0", row.SevenDayPct)
	}
	if row.ResetAt == nil || *row.ResetAt != resetAt {
		t.Fatalf("ListBoard() ResetAt = %v, want %d", row.ResetAt, resetAt)
	}
	if row.AvailableToLend == nil || !*row.AvailableToLend {
		t.Fatalf("ListBoard() AvailableToLend = %v, want true", row.AvailableToLend)
	}
	if row.PostedAt == nil || *row.PostedAt != 3000 {
		t.Fatalf("ListBoard() PostedAt = %v, want 3000", row.PostedAt)
	}
}

func TestUpdateLastSeen(t *testing.T) {
	s := newTestStore(t)

	u := &User{
		UserID:        "user-1",
		DisplayName:   "Sanket",
		SigningPubKey: "signing-pub-1",
		DeviceID:      "device-1",
		CreatedAt:     1000,
		LastSeen:      1000,
	}
	if err := s.CreateUser(u); err != nil {
		t.Fatalf("CreateUser() error = %v", err)
	}

	if err := s.UpdateLastSeen("user-1", 5000); err != nil {
		t.Fatalf("UpdateLastSeen() error = %v", err)
	}

	got, err := s.GetUserByID("user-1")
	if err != nil {
		t.Fatalf("GetUserByID() error = %v", err)
	}
	if got.LastSeen != 5000 {
		t.Fatalf("GetUserByID() LastSeen = %d, want 5000", got.LastSeen)
	}
}

func TestOpen_MigrationIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.db")

	s1, err := Open(path)
	if err != nil {
		t.Fatalf("Open() first error = %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	// Reopening the same DB file must not fail (CREATE TABLE IF NOT EXISTS).
	s2, err := Open(path)
	if err != nil {
		t.Fatalf("Open() second error = %v", err)
	}
	defer s2.Close()
}

// --- borrow handshake (M3) ---

// seedBorrowUsers creates a requester and a lender user for borrow-handshake
// tests and returns their ids.
func seedBorrowUsers(t *testing.T, s *Store) (requesterID, lenderID string) {
	t.Helper()
	requester := &User{
		UserID:           "requester-1",
		DisplayName:      "Alice",
		SigningPubKey:    "alice-signing-pub",
		EncryptionPubKey: "alice-encryption-pub",
		DeviceID:         "alice-device",
		CreatedAt:        1000,
		LastSeen:         1000,
	}
	lender := &User{
		UserID:        "lender-1",
		DisplayName:   "Bob",
		SigningPubKey: "bob-signing-pub",
		DeviceID:      "bob-device",
		CreatedAt:     1000,
		LastSeen:      1000,
	}
	if err := s.CreateUser(requester); err != nil {
		t.Fatalf("CreateUser(requester) error = %v", err)
	}
	if err := s.CreateUser(lender); err != nil {
		t.Fatalf("CreateUser(lender) error = %v", err)
	}
	return requester.UserID, lender.UserID
}

func TestCreateAndGetBorrowRequest(t *testing.T) {
	s := newTestStore(t)
	requesterID, lenderID := seedBorrowUsers(t, s)

	if err := s.CreateBorrowRequest("req-1", requesterID, lenderID, 2, 1000); err != nil {
		t.Fatalf("CreateBorrowRequest() error = %v", err)
	}

	got, err := s.GetBorrowRequest("req-1")
	if err != nil {
		t.Fatalf("GetBorrowRequest() error = %v", err)
	}
	if got.ID != "req-1" || got.RequesterID != requesterID || got.LenderID != lenderID ||
		got.Hours != 2 || got.Status != "pending" || got.CreatedAt != 1000 || got.DecidedAt != nil {
		t.Fatalf("GetBorrowRequest() = %+v, want pending req-1", got)
	}
}

func TestGetBorrowRequest_NotFound(t *testing.T) {
	s := newTestStore(t)
	_, err := s.GetBorrowRequest("does-not-exist")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetBorrowRequest() error = %v, want ErrNotFound", err)
	}
}

func TestListIncomingAndOutgoing(t *testing.T) {
	s := newTestStore(t)
	requesterID, lenderID := seedBorrowUsers(t, s)

	if err := s.CreateBorrowRequest("req-1", requesterID, lenderID, 3, 1000); err != nil {
		t.Fatalf("CreateBorrowRequest() error = %v", err)
	}

	incoming, err := s.ListIncoming(lenderID)
	if err != nil {
		t.Fatalf("ListIncoming() error = %v", err)
	}
	if len(incoming) != 1 {
		t.Fatalf("ListIncoming() len = %d, want 1", len(incoming))
	}
	ir := incoming[0]
	if ir.RequestID != "req-1" || ir.RequesterID != requesterID || ir.RequesterName != "Alice" ||
		ir.RequesterEncryptionPubKey != "alice-encryption-pub" || ir.Hours != 3 || ir.CreatedAt != 1000 {
		t.Fatalf("ListIncoming() row = %+v, want joined requester name/pubkey", ir)
	}

	outgoing, err := s.ListOutgoing(requesterID)
	if err != nil {
		t.Fatalf("ListOutgoing() error = %v", err)
	}
	if len(outgoing) != 1 {
		t.Fatalf("ListOutgoing() len = %d, want 1", len(outgoing))
	}
	or := outgoing[0]
	if or.RequestID != "req-1" || or.LenderID != lenderID || or.LenderName != "Bob" ||
		or.Hours != 3 || or.Status != "pending" || or.DecidedAt != nil {
		t.Fatalf("ListOutgoing() row = %+v, want joined lender name", or)
	}
}

func TestApproveThenPickup_OneShot(t *testing.T) {
	s := newTestStore(t)
	requesterID, lenderID := seedBorrowUsers(t, s)

	if err := s.CreateBorrowRequest("req-1", requesterID, lenderID, 2, 1000); err != nil {
		t.Fatalf("CreateBorrowRequest() error = %v", err)
	}

	now := time.Now().Unix()
	ttl := now + 600
	if err := s.ApproveBorrow("req-1", requesterID, "ciphertext-blob", now, ttl); err != nil {
		t.Fatalf("ApproveBorrow() error = %v", err)
	}

	br, err := s.GetBorrowRequest("req-1")
	if err != nil {
		t.Fatalf("GetBorrowRequest() error = %v", err)
	}
	if br.Status != "approved" || br.DecidedAt == nil || *br.DecidedAt != now {
		t.Fatalf("GetBorrowRequest() after approve = %+v, want approved/decidedAt=%d", br, now)
	}

	// Outgoing should reflect the approved status.
	outgoing, err := s.ListOutgoing(requesterID)
	if err != nil {
		t.Fatalf("ListOutgoing() error = %v", err)
	}
	if len(outgoing) != 1 || outgoing[0].Status != "approved" {
		t.Fatalf("ListOutgoing() = %+v, want status approved", outgoing)
	}

	// Pending list no longer includes it (it's no longer pending).
	incoming, err := s.ListIncoming(lenderID)
	if err != nil {
		t.Fatalf("ListIncoming() error = %v", err)
	}
	if len(incoming) != 0 {
		t.Fatalf("ListIncoming() len = %d, want 0 after approval", len(incoming))
	}

	ciphertext, err := s.PickupMailbox("req-1")
	if err != nil {
		t.Fatalf("PickupMailbox() error = %v", err)
	}
	if ciphertext != "ciphertext-blob" {
		t.Fatalf("PickupMailbox() ciphertext = %q, want %q", ciphertext, "ciphertext-blob")
	}

	br, err = s.GetBorrowRequest("req-1")
	if err != nil {
		t.Fatalf("GetBorrowRequest() error = %v", err)
	}
	if br.Status != "picked_up" {
		t.Fatalf("GetBorrowRequest() status = %q, want picked_up", br.Status)
	}

	// Second pickup: the mailbox row was deleted, so this is one-shot.
	_, err = s.PickupMailbox("req-1")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("PickupMailbox() second call error = %v, want ErrNotFound", err)
	}
}

func TestRejectBorrow(t *testing.T) {
	s := newTestStore(t)
	requesterID, lenderID := seedBorrowUsers(t, s)

	if err := s.CreateBorrowRequest("req-1", requesterID, lenderID, 2, 1000); err != nil {
		t.Fatalf("CreateBorrowRequest() error = %v", err)
	}

	if err := s.RejectBorrow("req-1", 2000); err != nil {
		t.Fatalf("RejectBorrow() error = %v", err)
	}

	br, err := s.GetBorrowRequest("req-1")
	if err != nil {
		t.Fatalf("GetBorrowRequest() error = %v", err)
	}
	if br.Status != "rejected" || br.DecidedAt == nil || *br.DecidedAt != 2000 {
		t.Fatalf("GetBorrowRequest() after reject = %+v, want rejected/decidedAt=2000", br)
	}
}

func TestRejectBorrow_NotFound(t *testing.T) {
	s := newTestStore(t)
	err := s.RejectBorrow("does-not-exist", 2000)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("RejectBorrow() error = %v, want ErrNotFound", err)
	}
}

func TestRevokeBorrow_DeletesMailbox(t *testing.T) {
	s := newTestStore(t)
	requesterID, lenderID := seedBorrowUsers(t, s)

	if err := s.CreateBorrowRequest("req-1", requesterID, lenderID, 2, 1000); err != nil {
		t.Fatalf("CreateBorrowRequest() error = %v", err)
	}

	now := time.Now().Unix()
	if err := s.ApproveBorrow("req-1", requesterID, "ciphertext-blob", now, now+600); err != nil {
		t.Fatalf("ApproveBorrow() error = %v", err)
	}

	if err := s.RevokeBorrow("req-1"); err != nil {
		t.Fatalf("RevokeBorrow() error = %v", err)
	}

	br, err := s.GetBorrowRequest("req-1")
	if err != nil {
		t.Fatalf("GetBorrowRequest() error = %v", err)
	}
	if br.Status != "revoked" {
		t.Fatalf("GetBorrowRequest() status = %q, want revoked", br.Status)
	}

	// The mailbox row must be gone: pickup now reports ErrNotFound.
	_, err = s.PickupMailbox("req-1")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("PickupMailbox() after revoke error = %v, want ErrNotFound", err)
	}
}

func TestRevokeBorrow_NotFound(t *testing.T) {
	s := newTestStore(t)
	err := s.RevokeBorrow("does-not-exist")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("RevokeBorrow() error = %v, want ErrNotFound", err)
	}
}
