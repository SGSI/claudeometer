package server

import (
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"testing"

	"claudeometer-relay/signing"
)

// activeBorrow drives a full request→approve→pickup so the borrower holds an
// active (picked_up, in-window) borrow from the lender.
func activeBorrow(t *testing.T, s *Server, borrowerID string, borrowerPriv ed25519.PrivateKey, lenderID string, lenderPriv ed25519.PrivateKey) {
	t.Helper()
	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: lenderID, Hours: 2})
	rec := call(t, s, "POST", "/borrow/request", reqBody, borrowerID, borrowerPriv)
	if rec.Code != http.StatusOK {
		t.Fatalf("setup request: %d %s", rec.Code, rec.Body.String())
	}
	var rr struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &rr)
	dec, _ := json.Marshal(borrowDecisionRequest{RequestID: rr.RequestID, Approve: true, Ciphertext: "Yg=="})
	if rec = call(t, s, "POST", "/borrow/decision", dec, lenderID, lenderPriv); rec.Code != http.StatusNoContent {
		t.Fatalf("setup approve: %d %s", rec.Code, rec.Body.String())
	}
	if rec = call(t, s, "GET", "/borrow/pickup/"+rr.RequestID, nil, borrowerID, borrowerPriv); rec.Code != http.StatusOK {
		t.Fatalf("setup pickup: %d %s", rec.Code, rec.Body.String())
	}
}

func TestBorrowRequestRequiresSharedTeam(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)
	_ = bPriv // no shared team between A and B

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 2})
	if rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv); rec.Code != http.StatusForbidden {
		t.Fatalf("request without shared team: %d %s, want 403", rec.Code, rec.Body.String())
	}
}

func TestSingleActiveBorrowLock(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	cPub, cPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)
	cID := enroll(t, s, "Carol", "dev-c", cPub, cPriv)
	shareTeam(t, s, aID, bID, cID)

	activeBorrow(t, s, aID, aPriv, bID, bPriv) // A is now actively borrowing from B

	// The borrower can't start a second borrow.
	toC, _ := json.Marshal(borrowRequestRequest{LenderID: cID, Hours: 2})
	if rec := call(t, s, "POST", "/borrow/request", toC, aID, aPriv); rec.Code != http.StatusConflict {
		t.Fatalf("second borrow by active borrower: %d, want 409", rec.Code)
	}
	// The busy lender can't take a new borrower.
	cToB, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 2})
	if rec := call(t, s, "POST", "/borrow/request", cToB, cID, cPriv); rec.Code != http.StatusConflict {
		t.Fatalf("borrow from busy lender: %d, want 409", rec.Code)
	}
}

func TestBorrowPickupRechecksSharedTeam(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)
	shareTeam(t, s, aID, bID)

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 2})
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	var rr struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &rr)
	dec, _ := json.Marshal(borrowDecisionRequest{RequestID: rr.RequestID, Approve: true, Ciphertext: "Yg=="})
	call(t, s, "POST", "/borrow/decision", dec, bID, bPriv)

	// Alice leaves the shared team before picking up → pickup must be refused.
	if _, err := s.store.RemoveMember("shared", aID); err != nil {
		t.Fatalf("remove member: %v", err)
	}
	if rec = call(t, s, "GET", "/borrow/pickup/"+rr.RequestID, nil, aID, aPriv); rec.Code != http.StatusForbidden {
		t.Fatalf("pickup after leaving team: %d, want 403", rec.Code)
	}
}
