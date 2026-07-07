package store

import (
	"errors"
	"testing"
)

func seedUser(t *testing.T, s *Store, id, name string) {
	t.Helper()
	if err := s.CreateUser(&User{UserID: id, DisplayName: name, SigningPubKey: "k-" + id, DeviceID: "d-" + id, CreatedAt: 1, LastSeen: 1}); err != nil {
		t.Fatalf("seed user %s: %v", name, err)
	}
}

func TestCreateTeamAddsOwnerMembership(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "Sanket")
	if err := s.CreateTeam("KC-Tech", "hash", "private", "u1", 100); err != nil {
		t.Fatalf("CreateTeam: %v", err)
	}
	role, err := s.MemberRole("KC-Tech", "u1")
	if err != nil || role != "owner" {
		t.Fatalf("owner membership = (%q,%v), want owner", role, err)
	}
}

func TestCreateTeamDuplicateNameRejected(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "Sanket")
	if err := s.CreateTeam("Growth", "h", "public", "u1", 1); err != nil {
		t.Fatalf("first create: %v", err)
	}
	if err := s.CreateTeam("growth", "h", "public", "u1", 1); !errors.Is(err, ErrNameTaken) {
		t.Fatalf("dup team name err = %v, want ErrNameTaken", err)
	}
}

func TestLeaveReportsRemainingAndListing(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "A")
	seedUser(t, s, "u2", "B")
	if err := s.CreateTeam("T", "h", "public", "u1", 1); err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := s.AddMember("T", "u2", "member", 2); err != nil {
		t.Fatalf("add: %v", err)
	}
	if n, _ := s.RemoveMember("T", "u2"); n != 1 {
		t.Fatalf("remaining after B leaves = %d, want 1", n)
	}
	pub, _ := s.ListPublicTeams()
	if len(pub) != 1 || pub[0].Name != "T" || pub[0].MemberCount != 1 {
		t.Fatalf("ListPublicTeams = %+v, want one T with 1 member", pub)
	}
}

func TestPrivateTeamNotListed(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "A")
	if err := s.CreateTeam("Secret", "h", "private", "u1", 1); err != nil {
		t.Fatalf("create: %v", err)
	}
	pub, _ := s.ListPublicTeams()
	if len(pub) != 0 {
		t.Fatalf("ListPublicTeams = %+v, want empty (private excluded)", pub)
	}
}

func TestGetTeamCaseInsensitive(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "A")
	_ = s.CreateTeam("Growth", "h", "public", "u1", 1)
	tm, _, err := s.GetTeam("growth")
	if err != nil || tm.Name != "Growth" {
		t.Fatalf("GetTeam(growth) = (%+v,%v), want canonical Growth", tm, err)
	}
}

func TestSharesTeam(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "A")
	seedUser(t, s, "u2", "B")
	seedUser(t, s, "u3", "C")
	_ = s.CreateTeam("T", "h", "public", "u1", 1)
	_ = s.AddMember("T", "u2", "member", 2)

	if ok, _ := s.SharesTeam("u1", "u2"); !ok {
		t.Fatalf("u1/u2 co-members should share a team")
	}
	if ok, _ := s.SharesTeam("u1", "u3"); ok {
		t.Fatalf("u1/u3 should not share a team")
	}
}

func TestTeamMemberIDsAndVisible(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "A")
	seedUser(t, s, "u2", "B")
	seedUser(t, s, "u3", "C")
	_ = s.CreateTeam("T1", "h", "public", "u1", 1)
	_ = s.AddMember("T1", "u2", "member", 2)
	_ = s.CreateTeam("T2", "h", "public", "u1", 3)
	_ = s.AddMember("T2", "u3", "member", 4)

	m, _ := s.TeamMemberIDs("T1")
	if len(m) != 2 || !m["u1"] || !m["u2"] {
		t.Fatalf("TeamMemberIDs(T1) = %v, want {u1,u2}", m)
	}
	vis, _ := s.VisibleUserIDs("u1")
	if !vis["u1"] || !vis["u2"] || !vis["u3"] {
		t.Fatalf("VisibleUserIDs(u1) = %v, want u1,u2,u3", vis)
	}
	visB, _ := s.VisibleUserIDs("u2")
	if visB["u3"] {
		t.Fatalf("u2 should not see u3 (no shared team)")
	}
}

func TestListBoardForTeam(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "A")
	seedUser(t, s, "u2", "B")
	seedUser(t, s, "u3", "C")
	_ = s.CreateTeam("T", "h", "public", "u1", 1)
	_ = s.AddMember("T", "u2", "member", 2)

	board, err := s.ListBoardForTeam("T")
	if err != nil {
		t.Fatalf("ListBoardForTeam: %v", err)
	}
	ids := map[string]bool{}
	for _, r := range board {
		ids[r.UserID] = true
	}
	if len(ids) != 2 || !ids["u1"] || !ids["u2"] || ids["u3"] {
		t.Fatalf("board ids = %v, want only u1,u2", ids)
	}
}

func TestActiveBorrowLocks(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "lend", "Lender")
	seedUser(t, s, "borrow", "Borrower")
	// Create → approve → pickup so the borrow is active (picked_up).
	if err := s.CreateBorrowRequest("b1", "borrow", "lend", 2, 100); err != nil {
		t.Fatalf("create borrow: %v", err)
	}
	// ttlExpiresAt is checked against real wall-clock time, so keep it far-future;
	// the borrow-window math (decided_at + hours*3600) is what IsLending compares
	// against the injected `now` below.
	if err := s.ApproveBorrow("b1", "borrow", "ciphertext", 100, 99999999999); err != nil {
		t.Fatalf("approve: %v", err)
	}
	if _, err := s.PickupMailbox("b1"); err != nil {
		t.Fatalf("pickup: %v", err)
	}

	// Within the window (100 + 2*3600 = 7300).
	if ok, _ := s.IsLending("lend", 200); !ok {
		t.Fatalf("lender should be lending at t=200")
	}
	if ok, _ := s.IsBorrowing("borrow", 200); !ok {
		t.Fatalf("borrower should be borrowing at t=200")
	}
	if ok, _ := s.IsBorrowing("lend", 200); ok {
		t.Fatalf("lender is not borrowing")
	}
	// After the window closes.
	if ok, _ := s.IsLending("lend", 8000); ok {
		t.Fatalf("lender should not be lending after the window")
	}
}

func TestJoinRequestLifecycle(t *testing.T) {
	s := newTestStore(t)
	seedUser(t, s, "u1", "Owner")
	seedUser(t, s, "u2", "Asker")
	if err := s.CreateTeam("Pub", "h", "public", "u1", 1); err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := s.CreateJoinRequest("jr1", "Pub", "u2", 5); err != nil {
		t.Fatalf("CreateJoinRequest: %v", err)
	}
	// Duplicate pending request is ignored (still one pending).
	_ = s.CreateJoinRequest("jr2", "Pub", "u2", 6)
	pend, _ := s.ListPendingJoinRequests("Pub")
	if len(pend) != 1 {
		t.Fatalf("pending = %d, want 1", len(pend))
	}
	team, user, err := s.DecideJoinRequest("jr1", "u1", true, 7)
	if err != nil || team != "Pub" || user != "u2" {
		t.Fatalf("DecideJoinRequest = (%q,%q,%v)", team, user, err)
	}
	if ok, _ := s.IsMember("Pub", "u2"); !ok {
		t.Fatalf("approved asker is not a member")
	}
}
