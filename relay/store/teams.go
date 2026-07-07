package store

import (
	"database/sql"
	"errors"
	"fmt"
)

// Team mirrors a row of the teams table (minus the password hash, returned
// separately by GetTeam so it never rides along with team metadata).
type Team struct {
	Name       string
	Visibility string
	CreatedBy  string
	CreatedAt  int64
}

// TeamSummary is one entry of the public-team discovery list.
type TeamSummary struct {
	Name        string
	MemberCount int
}

// JoinRequest is one pending ask-to-join for a public team.
type JoinRequest struct {
	ID        string
	TeamName  string
	UserID    string
	CreatedAt int64
}

// Team membership methods take the *canonical* team name (as stored). Handlers
// resolve a user-typed name to canonical via GetTeam (which looks up
// case-insensitively) before calling these.

// CreateTeam inserts a team and makes createdBy its owner, atomically. Returns
// ErrNameTaken if the name (compared normalized) is already used.
func (s *Store) CreateTeam(name, passwordHash, visibility, createdBy string, now int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("store: create team: begin: %w", err)
	}
	defer tx.Rollback()

	_, err = tx.Exec(
		`INSERT INTO teams (name, name_norm, password_hash, visibility, created_by, created_at)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		name, normalizeName(name), passwordHash, visibility, createdBy, now,
	)
	if err != nil {
		if isUniqueViolation(err, "name_norm") || isUniqueViolation(err, "teams.name") {
			return ErrNameTaken
		}
		return fmt.Errorf("store: create team: %w", err)
	}
	if _, err = tx.Exec(
		`INSERT INTO memberships (team_name, user_id, role, joined_at) VALUES (?, ?, 'owner', ?)`,
		name, createdBy, now,
	); err != nil {
		return fmt.Errorf("store: create team: owner membership: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("store: create team: commit: %w", err)
	}
	return nil
}

// GetTeam looks up a team case-insensitively and returns its metadata plus the
// stored password hash. Returns ErrNotFound if none.
func (s *Store) GetTeam(name string) (*Team, string, error) {
	var t Team
	var hash string
	err := s.db.QueryRow(
		`SELECT name, visibility, created_by, created_at, password_hash FROM teams WHERE name_norm = ?`,
		normalizeName(name),
	).Scan(&t.Name, &t.Visibility, &t.CreatedBy, &t.CreatedAt, &hash)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, "", ErrNotFound
		}
		return nil, "", fmt.Errorf("store: get team: %w", err)
	}
	return &t, hash, nil
}

// ListPublicTeams returns public teams with their member counts, name-sorted.
func (s *Store) ListPublicTeams() ([]TeamSummary, error) {
	rows, err := s.db.Query(
		`SELECT t.name, COUNT(m.user_id)
		 FROM teams t LEFT JOIN memberships m ON m.team_name = t.name
		 WHERE t.visibility = 'public'
		 GROUP BY t.name ORDER BY t.name`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list public teams: %w", err)
	}
	defer rows.Close()
	var out []TeamSummary
	for rows.Next() {
		var ts TeamSummary
		if err := rows.Scan(&ts.Name, &ts.MemberCount); err != nil {
			return nil, err
		}
		out = append(out, ts)
	}
	return out, rows.Err()
}

// AddMember adds a membership (idempotent — a repeat is a no-op).
func (s *Store) AddMember(team, user, role string, now int64) error {
	if _, err := s.db.Exec(
		`INSERT OR IGNORE INTO memberships (team_name, user_id, role, joined_at) VALUES (?, ?, ?, ?)`,
		team, user, role, now,
	); err != nil {
		return fmt.Errorf("store: add member: %w", err)
	}
	return nil
}

// RemoveMember deletes a membership and returns how many members remain in the
// team (so the caller can auto-delete an emptied team).
func (s *Store) RemoveMember(team, user string) (int, error) {
	if _, err := s.db.Exec(`DELETE FROM memberships WHERE team_name = ? AND user_id = ?`, team, user); err != nil {
		return 0, fmt.Errorf("store: remove member: %w", err)
	}
	var remaining int
	if err := s.db.QueryRow(`SELECT COUNT(1) FROM memberships WHERE team_name = ?`, team).Scan(&remaining); err != nil {
		return 0, fmt.Errorf("store: remaining members: %w", err)
	}
	return remaining, nil
}

// IsMember reports whether user belongs to team.
func (s *Store) IsMember(team, user string) (bool, error) {
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(1) FROM memberships WHERE team_name = ? AND user_id = ?`, team, user).Scan(&n); err != nil {
		return false, fmt.Errorf("store: is member: %w", err)
	}
	return n > 0, nil
}

// MemberRole returns user's role in team, or ErrNotFound if not a member.
func (s *Store) MemberRole(team, user string) (string, error) {
	var role string
	err := s.db.QueryRow(`SELECT role FROM memberships WHERE team_name = ? AND user_id = ?`, team, user).Scan(&role)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", fmt.Errorf("store: member role: %w", err)
	}
	return role, nil
}

// Membership is one of a user's team memberships (name + their role in it).
type Membership struct {
	TeamName string
	Role     string
}

// ListUserMemberships returns the caller's teams with their role in each,
// name-sorted — used by GET /my-teams to populate the client's team switcher.
func (s *Store) ListUserMemberships(user string) ([]Membership, error) {
	rows, err := s.db.Query(
		`SELECT team_name, role FROM memberships WHERE user_id = ? ORDER BY team_name`, user)
	if err != nil {
		return nil, fmt.Errorf("store: list user memberships: %w", err)
	}
	defer rows.Close()
	var out []Membership
	for rows.Next() {
		var m Membership
		if err := rows.Scan(&m.TeamName, &m.Role); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ListUserTeams returns the canonical names of the teams user belongs to.
func (s *Store) ListUserTeams(user string) ([]string, error) {
	rows, err := s.db.Query(`SELECT team_name FROM memberships WHERE user_id = ? ORDER BY team_name`, user)
	if err != nil {
		return nil, fmt.Errorf("store: list user teams: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// DeleteTeam removes a team and its memberships/join-requests, atomically.
func (s *Store) DeleteTeam(name string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("store: delete team: begin: %w", err)
	}
	defer tx.Rollback()
	for _, q := range []string{
		`DELETE FROM memberships WHERE team_name = ?`,
		`DELETE FROM join_requests WHERE team_name = ?`,
		`DELETE FROM teams WHERE name = ?`,
	} {
		if _, err := tx.Exec(q, name); err != nil {
			return fmt.Errorf("store: delete team: %w", err)
		}
	}
	return tx.Commit()
}

// CreateJoinRequest records a pending ask-to-join, unless the user already has
// one pending for this team (idempotent — no duplicate pending rows).
func (s *Store) CreateJoinRequest(id, team, user string, now int64) error {
	_, err := s.db.Exec(
		`INSERT INTO join_requests (id, team_name, user_id, status, created_at)
		 SELECT ?, ?, ?, 'pending', ?
		 WHERE NOT EXISTS (
		   SELECT 1 FROM join_requests WHERE team_name = ? AND user_id = ? AND status = 'pending')`,
		id, team, user, now, team, user,
	)
	if err != nil {
		return fmt.Errorf("store: create join request: %w", err)
	}
	return nil
}

// ListPendingJoinRequests returns a team's pending ask-to-join requests, oldest first.
func (s *Store) ListPendingJoinRequests(team string) ([]JoinRequest, error) {
	rows, err := s.db.Query(
		`SELECT id, team_name, user_id, created_at FROM join_requests
		 WHERE team_name = ? AND status = 'pending' ORDER BY created_at`,
		team,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list join requests: %w", err)
	}
	defer rows.Close()
	var out []JoinRequest
	for rows.Next() {
		var jr JoinRequest
		if err := rows.Scan(&jr.ID, &jr.TeamName, &jr.UserID, &jr.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, jr)
	}
	return out, rows.Err()
}

// SharesTeam reports whether users a and b belong to at least one common team.
func (s *Store) SharesTeam(a, b string) (bool, error) {
	var n int
	err := s.db.QueryRow(
		`SELECT COUNT(1) FROM memberships m1 JOIN memberships m2
		 ON m1.team_name = m2.team_name
		 WHERE m1.user_id = ? AND m2.user_id = ?`,
		a, b,
	).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("store: shares team: %w", err)
	}
	return n > 0, nil
}

// IsLending reports whether userID is currently lending (a picked-up borrow,
// still within its window) as the lender.
func (s *Store) IsLending(userID string, now int64) (bool, error) {
	return s.hasActiveBorrow("lender_id", userID, now)
}

// IsBorrowing reports whether userID currently holds an active borrow as the requester.
func (s *Store) IsBorrowing(userID string, now int64) (bool, error) {
	return s.hasActiveBorrow("requester_id", userID, now)
}

func (s *Store) hasActiveBorrow(column, userID string, now int64) (bool, error) {
	var n int
	err := s.db.QueryRow(
		`SELECT COUNT(1) FROM borrow_requests
		 WHERE `+column+` = ? AND status = 'picked_up'
		   AND ? < decided_at + hours * 3600`,
		userID, now,
	).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("store: has active borrow: %w", err)
	}
	return n > 0, nil
}

// TeamMemberIDs returns the set of user ids belonging to team.
func (s *Store) TeamMemberIDs(team string) (map[string]bool, error) {
	return s.idSet(`SELECT user_id FROM memberships WHERE team_name = ?`, team)
}

// VisibleUserIDs returns the set of user ids the viewer may see: everyone who
// shares at least one team with the viewer, plus the viewer themselves (so a
// user in no team still sees their own row).
func (s *Store) VisibleUserIDs(viewer string) (map[string]bool, error) {
	set, err := s.idSet(
		`SELECT DISTINCT m2.user_id FROM memberships m1
		 JOIN memberships m2 ON m1.team_name = m2.team_name
		 WHERE m1.user_id = ?`,
		viewer,
	)
	if err != nil {
		return nil, err
	}
	set[viewer] = true
	return set, nil
}

func (s *Store) idSet(query string, arg string) (map[string]bool, error) {
	rows, err := s.db.Query(query, arg)
	if err != nil {
		return nil, fmt.Errorf("store: id set: %w", err)
	}
	defer rows.Close()
	set := make(map[string]bool)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		set[id] = true
	}
	return set, rows.Err()
}

// DecideJoinRequest approves or rejects a pending request. On approve the user
// becomes a member. Idempotent: deciding an already-decided request is a no-op.
// Returns the request's team and user for the caller to act on.
func (s *Store) DecideJoinRequest(id, decidedBy string, approve bool, now int64) (string, string, error) {
	var team, user, status string
	err := s.db.QueryRow(`SELECT team_name, user_id, status FROM join_requests WHERE id = ?`, id).
		Scan(&team, &user, &status)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", "", ErrNotFound
		}
		return "", "", fmt.Errorf("store: decide join request: %w", err)
	}
	if status != "pending" {
		return team, user, nil // already decided
	}

	newStatus := "rejected"
	if approve {
		newStatus = "approved"
	}
	tx, err := s.db.Begin()
	if err != nil {
		return "", "", fmt.Errorf("store: decide join request: begin: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(
		`UPDATE join_requests SET status = ?, decided_by = ?, decided_at = ? WHERE id = ?`,
		newStatus, decidedBy, now, id,
	); err != nil {
		return "", "", fmt.Errorf("store: decide join request: update: %w", err)
	}
	if approve {
		if _, err := tx.Exec(
			`INSERT OR IGNORE INTO memberships (team_name, user_id, role, joined_at) VALUES (?, ?, 'member', ?)`,
			team, user, now,
		); err != nil {
			return "", "", fmt.Errorf("store: decide join request: add member: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return "", "", fmt.Errorf("store: decide join request: commit: %w", err)
	}
	return team, user, nil
}
