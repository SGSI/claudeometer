package server

import (
	"encoding/json"
	"net/http"
	"testing"

	"claudeometer-relay/signing"
)

func TestCreateAndDiscoverTeams(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)

	body, _ := json.Marshal(createTeamRequest{Name: "Growth", Password: "pw", Visibility: "public"})
	if rec := call(t, s, "POST", "/teams", body, aID, aPriv); rec.Code != http.StatusOK {
		t.Fatalf("create: %d %s", rec.Code, rec.Body.String())
	}
	priv, _ := json.Marshal(createTeamRequest{Name: "Secret", Password: "pw", Visibility: "private"})
	call(t, s, "POST", "/teams", priv, aID, aPriv)

	rec := call(t, s, "GET", "/teams", nil, aID, aPriv)
	var list []map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &list)
	if len(list) != 1 || list[0]["name"] != "Growth" {
		t.Fatalf("discover = %v, want only public Growth", list)
	}
}

func TestCreateTeamDuplicateNameConflict(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Alice", "dev-a", aPub, aPriv)
	body, _ := json.Marshal(createTeamRequest{Name: "Growth", Password: "pw", Visibility: "public"})
	call(t, s, "POST", "/teams", body, aID, aPriv)
	dup, _ := json.Marshal(createTeamRequest{Name: "growth", Password: "pw", Visibility: "public"})
	if rec := call(t, s, "POST", "/teams", dup, aID, aPriv); rec.Code != http.StatusConflict {
		t.Fatalf("dup create: %d, want 409", rec.Code)
	}
}

func TestJoinByPasswordAndWrongPassword(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Owner", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Joiner", "dev-b", bPub, bPriv)
	body, _ := json.Marshal(createTeamRequest{Name: "Priv", Password: "secret", Visibility: "private"})
	call(t, s, "POST", "/teams", body, aID, aPriv)

	wrong, _ := json.Marshal(joinTeamRequest{Password: "nope"})
	if rec := call(t, s, "POST", "/teams/Priv/join", wrong, bID, bPriv); rec.Code != http.StatusForbidden {
		t.Fatalf("wrong pw join: %d, want 403", rec.Code)
	}
	right, _ := json.Marshal(joinTeamRequest{Password: "secret"})
	if rec := call(t, s, "POST", "/teams/Priv/join", right, bID, bPriv); rec.Code != http.StatusOK {
		t.Fatalf("right pw join: %d %s", rec.Code, rec.Body.String())
	}
}

func TestLeaveLastMemberDeletesTeam(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Solo", "dev-a", aPub, aPriv)
	body, _ := json.Marshal(createTeamRequest{Name: "Only", Password: "pw", Visibility: "public"})
	call(t, s, "POST", "/teams", body, aID, aPriv)
	if rec := call(t, s, "POST", "/teams/Only/leave", nil, aID, aPriv); rec.Code != http.StatusNoContent {
		t.Fatalf("leave: %d %s", rec.Code, rec.Body.String())
	}
	rec := call(t, s, "GET", "/teams", nil, aID, aPriv)
	var list []map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &list)
	if len(list) != 0 {
		t.Fatalf("team should be gone, discover = %v", list)
	}
}

func TestMyTeamsListsMembershipsWithRole(t *testing.T) {
	s := newTestServer(t)
	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(t, s, "Owner", "dev-a", aPub, aPriv)
	bID := enroll(t, s, "Member", "dev-b", bPub, bPriv)
	body, _ := json.Marshal(createTeamRequest{Name: "Growth", Password: "pw", Visibility: "public"})
	call(t, s, "POST", "/teams", body, aID, aPriv)
	jp, _ := json.Marshal(joinTeamRequest{Password: "pw"})
	call(t, s, "POST", "/teams/Growth/join", jp, bID, bPriv)

	rec := call(t, s, "GET", "/my-teams", nil, aID, aPriv)
	var mine []map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &mine)
	if len(mine) != 1 || mine[0]["name"] != "Growth" || mine[0]["role"] != "owner" {
		t.Fatalf("owner my-teams = %v, want [{Growth, owner}]", mine)
	}
	rec = call(t, s, "GET", "/my-teams", nil, bID, bPriv)
	_ = json.Unmarshal(rec.Body.Bytes(), &mine)
	if len(mine) != 1 || mine[0]["role"] != "member" {
		t.Fatalf("member my-teams = %v, want [{Growth, member}]", mine)
	}
}

func TestOwnerApprovesJoinRequest(t *testing.T) {
	s := newTestServer(t)
	oPub, oPriv, _ := signing.GenerateKeypair()
	jPub, jPriv, _ := signing.GenerateKeypair()
	mPub, mPriv, _ := signing.GenerateKeypair()
	oID := enroll(t, s, "Owner", "dev-o", oPub, oPriv)
	jID := enroll(t, s, "Joiner", "dev-j", jPub, jPriv)
	mID := enroll(t, s, "Member", "dev-m", mPub, mPriv)

	body, _ := json.Marshal(createTeamRequest{Name: "Pub", Password: "pw", Visibility: "public"})
	call(t, s, "POST", "/teams", body, oID, oPriv)
	// A non-owner member joins by password.
	jp, _ := json.Marshal(joinTeamRequest{Password: "pw"})
	call(t, s, "POST", "/teams/Pub/join", jp, mID, mPriv)
	// Joiner asks to join (no password) → pending request.
	if rec := call(t, s, "POST", "/teams/Pub/join", []byte(`{}`), jID, jPriv); rec.Code != http.StatusAccepted {
		t.Fatalf("ask-to-join: %d, want 202", rec.Code)
	}

	rec := call(t, s, "GET", "/teams/Pub/requests", nil, oID, oPriv)
	var reqs []map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &reqs)
	if len(reqs) != 1 {
		t.Fatalf("pending = %d, want 1", len(reqs))
	}
	id := reqs[0]["id"].(string)

	dec, _ := json.Marshal(decideJoinRequest{Approve: true})
	// Non-owner member cannot approve.
	if rec = call(t, s, "POST", "/teams/Pub/requests/"+id, dec, mID, mPriv); rec.Code != http.StatusForbidden {
		t.Fatalf("member approve: %d, want 403", rec.Code)
	}
	// Owner approves.
	if rec = call(t, s, "POST", "/teams/Pub/requests/"+id, dec, oID, oPriv); rec.Code != http.StatusNoContent {
		t.Fatalf("owner approve: %d %s", rec.Code, rec.Body.String())
	}
}
