package server

import (
	"encoding/json"
	"net/http"
	"testing"

	"claudeometer-relay/signing"
)

// A requester may have only one pending request to a given lender at a time.
// A second request while the first is still pending is rejected with 409; once
// the lender decides (here: rejects) the first, the requester can ask again.
func TestBorrowRequestRejectsDuplicatePending(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)
	shareTeam(t, s, aID, bID)

	reqBody, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 2})

	// First request succeeds.
	rec := call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	if rec.Code != http.StatusOK {
		t.Fatalf("first request: got %d %s, want 200", rec.Code, rec.Body.String())
	}
	var first struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &first)

	// Second request while the first is pending is rejected.
	rec = call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	if rec.Code != http.StatusConflict {
		t.Fatalf("duplicate request: got %d %s, want 409", rec.Code, rec.Body.String())
	}

	// Bob rejects the first request.
	decBody, _ := json.Marshal(borrowDecisionRequest{RequestID: first.RequestID, Approve: false})
	if rec = call(t, s, "POST", "/borrow/decision", decBody, bID, bPriv); rec.Code != http.StatusNoContent {
		t.Fatalf("reject: got %d %s, want 204", rec.Code, rec.Body.String())
	}

	// With no pending request, Alice can ask again.
	rec = call(t, s, "POST", "/borrow/request", reqBody, aID, aPriv)
	if rec.Code != http.StatusOK {
		t.Fatalf("request after rejection: got %d %s, want 200", rec.Code, rec.Body.String())
	}
}

// A pending request to one lender must not block requesting a different lender.
func TestBorrowRequestPendingIsPerLender(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	cPub, cPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Bob", "dev-b", bPub, bPriv)
	cID := enroll(t, s, "Carol", "dev-c", cPub, cPriv)
	shareTeam(t, s, aID, bID, cID)
	_ = bPriv
	_ = cPriv

	toB, _ := json.Marshal(borrowRequestRequest{LenderID: bID, Hours: 2})
	if rec := call(t, s, "POST", "/borrow/request", toB, aID, aPriv); rec.Code != http.StatusOK {
		t.Fatalf("request to Bob: got %d %s, want 200", rec.Code, rec.Body.String())
	}
	toC, _ := json.Marshal(borrowRequestRequest{LenderID: cID, Hours: 2})
	if rec := call(t, s, "POST", "/borrow/request", toC, aID, aPriv); rec.Code != http.StatusOK {
		t.Fatalf("request to Carol while Bob pending: got %d %s, want 200", rec.Code, rec.Body.String())
	}
}
