package server

import (
	"encoding/json"
	"net/http"
	"testing"

	"claudeometer-relay/signing"
	"claudeometer-relay/store"
)

// After A borrows from B and picks up, the board must show Alice borrowing from
// Bob and Bob lending to Alice — so a borrower isn't mistaken for a heavy user
// of their own quota.
func TestBoardShowsActiveBorrow(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enrollWithEncryptionKey(t, s, "Alice", "dev-a", "alice-enc", aPub, aPriv)
	bID := enrollWithEncryptionKey(t, s, "Bob", "dev-b", "bob-enc", bPub, bPriv)

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 2})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	if rec.Code != http.StatusOK {
		t.Fatalf("request: %d %s", rec.Code, rec.Body.String())
	}
	var rr struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &rr)

	decBody, _ := json.Marshal(borrowDecisionRequest{RequestID: rr.RequestID, Approve: true, Ciphertext: "ZHVtbXk="})
	if rec = call(t, s, "POST", "/borrow/decision", decBody, bID, bPriv); rec.Code != http.StatusNoContent {
		t.Fatalf("decision: %d %s", rec.Code, rec.Body.String())
	}
	if rec = call(t, s, "GET", "/borrow/pickup/"+rr.RequestID, nil, aID, aPriv); rec.Code != http.StatusOK {
		t.Fatalf("pickup: %d %s", rec.Code, rec.Body.String())
	}

	rec = call(t, s, "GET", "/board", nil, aID, aPriv)
	if rec.Code != http.StatusOK {
		t.Fatalf("board: %d %s", rec.Code, rec.Body.String())
	}
	var board []store.BoardRow
	if err := json.Unmarshal(rec.Body.Bytes(), &board); err != nil {
		t.Fatalf("board decode: %v", err)
	}
	var alice, bob *store.BoardRow
	for i := range board {
		switch board[i].UserID {
		case aID:
			alice = &board[i]
		case bID:
			bob = &board[i]
		}
	}
	if alice == nil || alice.BorrowingFrom == nil || *alice.BorrowingFrom != "Bob" || alice.BorrowingUntil == nil {
		t.Fatalf("Alice row should show borrowingFrom=Bob: %+v", alice)
	}
	if bob == nil || len(bob.LendingTo) != 1 || bob.LendingTo[0] != "Alice" {
		t.Fatalf("Bob row should show lendingTo=[Alice]: %+v", bob)
	}
}
