package server

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"claudeometer-relay/signing"
	"claudeometer-relay/store"
)

// fixedNow anchors the mocked server clock used throughout these tests. It
// is derived from the real wall clock (rather than a hardcoded past epoch)
// because the borrow-handshake mailbox TTL check in store.PickupMailbox
// compares ttl_expires_at against real time.Now(); anchoring to "now" keeps
// that comparison meaningful regardless of when the test suite runs, while
// every existing assertion only uses fixedNow in relative (round-trip)
// terms, so this is a safe, behavior-preserving change.
var fixedNow = time.Now().Unix()

func newTestServer(t *testing.T) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	s := New(st, "test")
	s.now = func() time.Time { return time.Unix(fixedNow, 0) }
	return s
}

// signedRequest builds a request signed per PROTOCOL.md.
func signedRequest(method, path string, body []byte, userID string, priv ed25519.PrivateKey, ts int64) *http.Request {
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	tss := strconv.FormatInt(ts, 10)
	msg := signing.CanonicalMessage(method, path, tss, signing.BodySHA256Hex(body))
	r.Header.Set("X-Timestamp", tss)
	r.Header.Set("X-Signature", signing.Sign(priv, msg))
	if userID != "" {
		r.Header.Set("X-User-Id", userID)
	}
	return r
}

func enroll(t *testing.T, s *Server, name, deviceID string, pub ed25519.PublicKey, priv ed25519.PrivateKey) string {
	t.Helper()
	body, _ := json.Marshal(enrollRequest{
		DisplayName:   name,
		SigningPubKey: signing.PublicKeyB64(pub),
		DeviceID:      deviceID,
	})
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, signedRequest("POST", "/enroll", body, "", priv, fixedNow))
	if rec.Code != http.StatusOK {
		t.Fatalf("enroll: want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		UserID string `json:"userId"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil || resp.UserID == "" {
		t.Fatalf("enroll: bad response %q (err %v)", rec.Body.String(), err)
	}
	return resp.UserID
}

func TestEnrollUsageBoardHappyPath(t *testing.T) {
	s := newTestServer(t)
	pub, priv, _ := signing.GenerateKeypair()
	userID := enroll(t, s, "Sanket", "dev-1", pub, priv)

	reset := fixedNow + 3600
	ubody, _ := json.Marshal(usageRequest{FiveHourPct: 62, SevenDayPct: 20, ResetAt: &reset, AvailableToLend: true})
	urec := httptest.NewRecorder()
	s.Handler().ServeHTTP(urec, signedRequest("POST", "/usage", ubody, userID, priv, fixedNow))
	if urec.Code != http.StatusNoContent {
		t.Fatalf("usage: want 204, got %d: %s", urec.Code, urec.Body.String())
	}

	brec := httptest.NewRecorder()
	s.Handler().ServeHTTP(brec, signedRequest("GET", "/board", nil, userID, priv, fixedNow))
	if brec.Code != http.StatusOK {
		t.Fatalf("board: want 200, got %d: %s", brec.Code, brec.Body.String())
	}
	var board []store.BoardRow
	if err := json.Unmarshal(brec.Body.Bytes(), &board); err != nil {
		t.Fatalf("board decode: %v", err)
	}
	if len(board) != 1 {
		t.Fatalf("board len = %d, want 1", len(board))
	}
	got := board[0]
	if got.DisplayName != "Sanket" ||
		got.FiveHourPct == nil || *got.FiveHourPct != 62 ||
		got.AvailableToLend == nil || !*got.AvailableToLend ||
		got.ResetAt == nil || *got.ResetAt != reset {
		t.Fatalf("board row mismatch: %+v", got)
	}
}

func TestBoardIncludesUserWithNoUsage(t *testing.T) {
	s := newTestServer(t)
	pub, priv, _ := signing.GenerateKeypair()
	userID := enroll(t, s, "Priya", "dev-2", pub, priv)

	brec := httptest.NewRecorder()
	s.Handler().ServeHTTP(brec, signedRequest("GET", "/board", nil, userID, priv, fixedNow))
	var board []store.BoardRow
	_ = json.Unmarshal(brec.Body.Bytes(), &board)
	if len(board) != 1 || board[0].FiveHourPct != nil {
		t.Fatalf("expected 1 row with null usage, got %+v", board)
	}
}

func TestUsageRejectsTamperedSignature(t *testing.T) {
	s := newTestServer(t)
	pub, priv, _ := signing.GenerateKeypair()
	userID := enroll(t, s, "A", "dev-1", pub, priv)
	ubody, _ := json.Marshal(usageRequest{FiveHourPct: 10})
	req := signedRequest("POST", "/usage", ubody, userID, priv, fixedNow)
	req.Header.Set("X-Signature", signing.Sign(priv, []byte("different message")))
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBoardRejectsUnsigned(t *testing.T) {
	s := newTestServer(t)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/board", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

func TestUsageRejectsStaleTimestamp(t *testing.T) {
	s := newTestServer(t)
	pub, priv, _ := signing.GenerateKeypair()
	userID := enroll(t, s, "A", "dev-1", pub, priv)
	ubody, _ := json.Marshal(usageRequest{FiveHourPct: 10})
	// 10 minutes in the past → beyond the 300s replay window.
	req := signedRequest("POST", "/usage", ubody, userID, priv, fixedNow-600)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

func TestUsageRejectsUnknownUser(t *testing.T) {
	s := newTestServer(t)
	_, priv, _ := signing.GenerateKeypair()
	ubody, _ := json.Marshal(usageRequest{FiveHourPct: 10})
	req := signedRequest("POST", "/usage", ubody, "no-such-user", priv, fixedNow)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

func TestEnrollIsIdempotent(t *testing.T) {
	s := newTestServer(t)
	pub, priv, _ := signing.GenerateKeypair()
	id1 := enroll(t, s, "A", "dev-1", pub, priv)
	id2 := enroll(t, s, "A", "dev-1", pub, priv)
	if id1 != id2 {
		t.Fatalf("re-enroll returned different ids: %s vs %s", id1, id2)
	}
}

// --- borrow handshake (M3) ---

// enrollWithEncryptionKey is like enroll but also sets encryptionPubKey, so
// borrow-handshake tests can assert it's surfaced correctly in the inbox.
func enrollWithEncryptionKey(t *testing.T, s *Server, name, deviceID, encryptionPubKey string, pub ed25519.PublicKey, priv ed25519.PrivateKey) string {
	t.Helper()
	body, _ := json.Marshal(enrollRequest{
		DisplayName:      name,
		SigningPubKey:    signing.PublicKeyB64(pub),
		EncryptionPubKey: encryptionPubKey,
		DeviceID:         deviceID,
	})
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, signedRequest("POST", "/enroll", body, "", priv, fixedNow))
	if rec.Code != http.StatusOK {
		t.Fatalf("enroll: want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		UserID string `json:"userId"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil || resp.UserID == "" {
		t.Fatalf("enroll: bad response %q (err %v)", rec.Body.String(), err)
	}
	return resp.UserID
}

// call signs and dispatches a request against s.Handler(), returning the
// recorded response.
func call(t *testing.T, s *Server, method, path string, body []byte, userID string, priv ed25519.PrivateKey) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, signedRequest(method, path, body, userID, priv, fixedNow))
	return rec
}

// borrowInboxResponse mirrors the GET /borrow/inbox wire shape.
type borrowInboxResponse struct {
	Incoming []store.IncomingRequest `json:"incoming"`
	Outgoing []store.OutgoingRequest `json:"outgoing"`
}

func TestBorrowHandshakeHappyPath(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enrollWithEncryptionKey(t, s, "Alice", "dev-a", "alice-encryption-pub", aPub, aPriv)
	bID := enrollWithEncryptionKey(t, s, "Bob", "dev-b", "bob-encryption-pub", bPub, bPriv)

	// A requests 2 hours from B.
	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 2})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	if rec.Code != http.StatusOK {
		t.Fatalf("borrow/request: want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var reqResp struct {
		RequestID string `json:"requestId"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &reqResp); err != nil || reqResp.RequestID == "" {
		t.Fatalf("borrow/request: bad response %q (err %v)", rec.Body.String(), err)
	}
	requestID := reqResp.RequestID

	// B's inbox shows the incoming request with A's encryption pubkey.
	rec = call(t, s, "GET", "/borrow/inbox", nil, bID, bPriv)
	if rec.Code != http.StatusOK {
		t.Fatalf("borrow/inbox (B): want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var bInbox borrowInboxResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &bInbox); err != nil {
		t.Fatalf("borrow/inbox (B) decode: %v", err)
	}
	if len(bInbox.Incoming) != 1 {
		t.Fatalf("B incoming len = %d, want 1", len(bInbox.Incoming))
	}
	inc := bInbox.Incoming[0]
	if inc.RequestID != requestID || inc.RequesterID != aID ||
		inc.RequesterName != "Alice" || inc.RequesterEncryptionPubKey != "alice-encryption-pub" || inc.Hours != 2 {
		t.Fatalf("B incoming row = %+v, want requestId/requesterId/name/pubkey/hours to match", inc)
	}

	// B approves with a dummy base64 ciphertext.
	decBody, _ := json.Marshal(borrowDecisionRequest{RequestID: requestID, Approve: true, Ciphertext: "ZHVtbXktY2lwaGVydGV4dA=="})
	rec = call(t, s, "POST", "/borrow/decision", decBody, bID, bPriv)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("borrow/decision (approve): want 204, got %d: %s", rec.Code, rec.Body.String())
	}

	// A's outgoing now shows status approved.
	rec = call(t, s, "GET", "/borrow/inbox", nil, aID, aPriv)
	if rec.Code != http.StatusOK {
		t.Fatalf("borrow/inbox (A): want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var aInbox borrowInboxResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &aInbox); err != nil {
		t.Fatalf("borrow/inbox (A) decode: %v", err)
	}
	if len(aInbox.Outgoing) != 1 || aInbox.Outgoing[0].Status != "approved" || aInbox.Outgoing[0].LenderName != "Bob" {
		t.Fatalf("A outgoing = %+v, want single approved row for Bob", aInbox.Outgoing)
	}

	// A picks up: gets back the exact ciphertext.
	rec = call(t, s, "GET", "/borrow/pickup/"+requestID, nil, aID, aPriv)
	if rec.Code != http.StatusOK {
		t.Fatalf("borrow/pickup: want 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var pickupResp struct {
		Ciphertext string `json:"ciphertext"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &pickupResp); err != nil {
		t.Fatalf("borrow/pickup decode: %v", err)
	}
	if pickupResp.Ciphertext != "ZHVtbXktY2lwaGVydGV4dA==" {
		t.Fatalf("borrow/pickup ciphertext = %q, want the dummy ciphertext unchanged", pickupResp.Ciphertext)
	}

	// A second pickup is one-shot: the mailbox entry is gone.
	rec = call(t, s, "GET", "/borrow/pickup/"+requestID, nil, aID, aPriv)
	if rec.Code != http.StatusNotFound && rec.Code != http.StatusConflict {
		t.Fatalf("borrow/pickup (second): want 404 or 409, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBorrowDecision_OwnershipEnforced(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 1})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	var reqResp struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &reqResp)

	// The requester (A) is not the lender and must not be able to decide.
	decBody, _ := json.Marshal(borrowDecisionRequest{RequestID: reqResp.RequestID, Approve: true, Ciphertext: "Yg=="})
	rec = call(t, s, "POST", "/borrow/decision", decBody, aID, aPriv)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("borrow/decision by requester: want 403, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBorrowPickup_OwnershipEnforced(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 1})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	var reqResp struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &reqResp)

	decBody, _ := json.Marshal(borrowDecisionRequest{RequestID: reqResp.RequestID, Approve: true, Ciphertext: "Yg=="})
	rec = call(t, s, "POST", "/borrow/decision", decBody, bID, bPriv)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("borrow/decision (approve): want 204, got %d: %s", rec.Code, rec.Body.String())
	}

	// The lender (B) is not the requester and must not be able to pick up.
	rec = call(t, s, "GET", "/borrow/pickup/"+reqResp.RequestID, nil, bID, bPriv)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("borrow/pickup by lender: want 403, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBorrowRequest_HoursOutOfRange(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)
	_ = bPriv

	for _, hours := range []int{0, 5, -1} {
		reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: hours})
		rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("borrow/request hours=%d: want 400, got %d: %s", hours, rec.Code, rec.Body.String())
		}
	}
}

func TestBorrowRequest_FromSelf(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: aID, Hours: 2})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("borrow/request from self: want 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBorrowRequest_UnknownLender(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: "no-such-user", Hours: 2})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("borrow/request unknown lender: want 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBorrowDecision_RequiresCiphertextOnApprove(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 1})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	var reqResp struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &reqResp)

	decBody, _ := json.Marshal(borrowDecisionRequest{RequestID: reqResp.RequestID, Approve: true})
	rec = call(t, s, "POST", "/borrow/decision", decBody, bID, bPriv)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("borrow/decision approve without ciphertext: want 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBorrowDecision_RejectFlow(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 1})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	var reqResp struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &reqResp)

	decBody, _ := json.Marshal(borrowDecisionRequest{RequestID: reqResp.RequestID, Approve: false})
	rec = call(t, s, "POST", "/borrow/decision", decBody, bID, bPriv)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("borrow/decision (reject): want 204, got %d: %s", rec.Code, rec.Body.String())
	}

	rec = call(t, s, "GET", "/borrow/inbox", nil, aID, aPriv)
	var aInbox borrowInboxResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &aInbox)
	if len(aInbox.Outgoing) != 1 || aInbox.Outgoing[0].Status != "rejected" {
		t.Fatalf("A outgoing after reject = %+v, want single rejected row", aInbox.Outgoing)
	}

	// A rejected (decided) request is no longer pending; deciding again 409s.
	decBody2, _ := json.Marshal(borrowDecisionRequest{RequestID: reqResp.RequestID, Approve: false})
	rec = call(t, s, "POST", "/borrow/decision", decBody2, bID, bPriv)
	if rec.Code != http.StatusConflict {
		t.Fatalf("borrow/decision on already-decided request: want 409, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBorrowRevoke_ByEitherParty(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)

	// Revoke by the lender before any decision.
	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 1})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	var reqResp struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &reqResp)

	revBody, _ := json.Marshal(borrowRevokeRequest{RequestID: reqResp.RequestID})
	rec = call(t, s, "POST", "/borrow/revoke", revBody, bID, bPriv)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("borrow/revoke by lender: want 204, got %d: %s", rec.Code, rec.Body.String())
	}
	rec = call(t, s, "GET", "/borrow/pickup/"+reqResp.RequestID, nil, aID, aPriv)
	if rec.Code != http.StatusNotFound && rec.Code != http.StatusConflict {
		t.Fatalf("borrow/pickup after lender revoke: want 404 or 409, got %d: %s", rec.Code, rec.Body.String())
	}

	// Revoke by the requester after approval (mailbox exists, then gone).
	reqBody2, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 1})
	rec = call(t, s, "POST", "/borrow/request", reqBody2, aID, aPriv)
	var reqResp2 struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &reqResp2)

	decBody, _ := json.Marshal(borrowDecisionRequest{RequestID: reqResp2.RequestID, Approve: true, Ciphertext: "Yg=="})
	rec = call(t, s, "POST", "/borrow/decision", decBody, bID, bPriv)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("borrow/decision (approve): want 204, got %d: %s", rec.Code, rec.Body.String())
	}

	revBody2, _ := json.Marshal(borrowRevokeRequest{RequestID: reqResp2.RequestID})
	rec = call(t, s, "POST", "/borrow/revoke", revBody2, aID, aPriv)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("borrow/revoke by requester: want 204, got %d: %s", rec.Code, rec.Body.String())
	}
	rec = call(t, s, "GET", "/borrow/pickup/"+reqResp2.RequestID, nil, aID, aPriv)
	if rec.Code != http.StatusNotFound && rec.Code != http.StatusConflict {
		t.Fatalf("borrow/pickup after requester revoke: want 404 or 409, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBorrowRevoke_OwnershipEnforced(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	cPub, cPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)
	cID := enroll(t, s, "Carol", "dev-c", cPub, cPriv)
	_ = cID

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 1})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	var reqResp struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &reqResp)

	revBody, _ := json.Marshal(borrowRevokeRequest{RequestID: reqResp.RequestID})
	rec = call(t, s, "POST", "/borrow/revoke", revBody, cID, cPriv)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("borrow/revoke by non-party: want 403, got %d: %s", rec.Code, rec.Body.String())
	}
}
