package server

import (
	"encoding/json"
	"net/http"
	"testing"

	"claudeometer-relay/signing"
)

type boardRowJSON struct {
	UserID         string   `json:"userId"`
	DisplayName    string   `json:"displayName"`
	BorrowingFrom  *string  `json:"borrowingFrom"`
	BorrowingUntil *int64   `json:"borrowingUntil"`
	LendingTo      []string `json:"lendingTo"`
}

func decodeBoard(t *testing.T, body []byte) []boardRowJSON {
	t.Helper()
	var rows []boardRowJSON
	if err := json.Unmarshal(body, &rows); err != nil {
		t.Fatalf("decode board: %v (%s)", err, string(body))
	}
	return rows
}

func findRow(rows []boardRowJSON, name string) *boardRowJSON {
	for i := range rows {
		if rows[i].DisplayName == name {
			return &rows[i]
		}
	}
	return nil
}

func TestBoardTeamScopedRequiresMembership(t *testing.T) {
	s := newTestServer(t)
	oPub, oPriv, _ := signing.GenerateKeypair()
	xPub, xPriv, _ := signing.GenerateKeypair()
	oID := enroll(t, s, "Owner", "dev-o", oPub, oPriv)
	outsiderID := enroll(t, s, "Outsider", "dev-x", xPub, xPriv)
	_ = s.store.CreateTeam("T", "h", "private", oID, 1)

	if rec := call(t, s, "GET", "/board?team=T", nil, outsiderID, xPriv); rec.Code != http.StatusForbidden {
		t.Fatalf("non-member team board: %d, want 403", rec.Code)
	}
}

func TestBoardRedactsCrossTeamBorrow(t *testing.T) {
	s := newTestServer(t)
	mePub, mePriv, _ := signing.GenerateKeypair()
	fPub, fPriv, _ := signing.GenerateKeypair()
	tPub, tPriv, _ := signing.GenerateKeypair()
	meID := enroll(t, s, "Me", "dev-me", mePub, mePriv)
	fID := enroll(t, s, "Fred", "dev-f", fPub, fPriv)
	tID := enroll(t, s, "Tam", "dev-t", tPub, tPriv)
	_ = tPriv

	// Me is in both teams; Fred only in product; Tam only in tech.
	_ = s.store.CreateTeam("tech", "h", "private", meID, 1)
	_ = s.store.AddMember("tech", tID, "member", 1)
	_ = s.store.CreateTeam("product", "h", "private", meID, 1)
	_ = s.store.AddMember("product", fID, "member", 1)

	// Me borrows from Fred (shared via product) and is now actively on Fred's quota.
	activeBorrow(t, s, meID, mePriv, fID, fPriv)

	// On the product board, Fred is visible → named.
	rec := call(t, s, "GET", "/board?team=product", nil, meID, mePriv)
	prod := decodeBoard(t, rec.Body.Bytes())
	if me := findRow(prod, "Me"); me == nil || me.BorrowingFrom == nil || *me.BorrowingFrom != "Fred" {
		t.Fatalf("product board Me.borrowingFrom = %v, want Fred", me)
	}
	if fred := findRow(prod, "Fred"); fred == nil || len(fred.LendingTo) != 1 || fred.LendingTo[0] != "Me" {
		t.Fatalf("product board Fred.lendingTo = %v, want [Me]", fred)
	}

	// On the tech board, Fred is NOT a member → redacted, and never appears.
	rec = call(t, s, "GET", "/board?team=tech", nil, meID, mePriv)
	tech := decodeBoard(t, rec.Body.Bytes())
	if findRow(tech, "Fred") != nil {
		t.Fatalf("tech board must not include Fred")
	}
	me := findRow(tech, "Me")
	if me == nil || me.BorrowingFrom == nil || *me.BorrowingFrom != "another team" {
		t.Fatalf("tech board Me.borrowingFrom = %v, want \"another team\"", me)
	}
	if me.BorrowingUntil != nil {
		t.Fatalf("tech board must not leak borrowingUntil for a redacted borrow")
	}
}

func TestBoardUnionDefault(t *testing.T) {
	s := newTestServer(t)
	mePub, mePriv, _ := signing.GenerateKeypair()
	fPub, fPriv, _ := signing.GenerateKeypair()
	oPub, oPriv, _ := signing.GenerateKeypair()
	meID := enroll(t, s, "Me", "dev-me", mePub, mePriv)
	fID := enroll(t, s, "Fred", "dev-f", fPub, fPriv)
	oID := enroll(t, s, "Off", "dev-o", oPub, oPriv)
	_ = fPriv
	_ = oPriv

	_ = s.store.CreateTeam("product", "h", "private", meID, 1)
	_ = s.store.AddMember("product", fID, "member", 1)
	_ = s.store.CreateTeam("other", "h", "private", oID, 1) // Me is not in this team

	rec := call(t, s, "GET", "/board", nil, meID, mePriv)
	rows := decodeBoard(t, rec.Body.Bytes())
	if findRow(rows, "Me") == nil || findRow(rows, "Fred") == nil {
		t.Fatalf("union board missing Me/Fred: %+v", rows)
	}
	if findRow(rows, "Off") != nil {
		t.Fatalf("union board must not include Off (no shared team)")
	}
}
