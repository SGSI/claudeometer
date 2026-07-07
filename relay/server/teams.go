package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/google/uuid"

	"claudeometer-relay/store"
)

type createTeamRequest struct {
	Name       string `json:"name"`
	Password   string `json:"password"`
	Visibility string `json:"visibility"`
}

type joinTeamRequest struct {
	Password string `json:"password"`
}

type decideJoinRequest struct {
	Approve bool `json:"approve"`
}

// handleCreateTeam creates a team (private|public) and makes the caller its owner.
func (s *Server) handleCreateTeam(w http.ResponseWriter, r *http.Request, u *store.User) {
	body, _ := io.ReadAll(r.Body)
	var req createTeamRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" {
		writeErr(w, http.StatusBadRequest, "team name required")
		return
	}
	if req.Visibility != "private" && req.Visibility != "public" {
		writeErr(w, http.StatusBadRequest, "visibility must be private or public")
		return
	}
	if req.Password == "" {
		writeErr(w, http.StatusBadRequest, "password required")
		return
	}
	hash, err := store.HashPassword(req.Password)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "hash failed")
		return
	}
	if err := s.store.CreateTeam(name, hash, req.Visibility, u.UserID, s.now().Unix()); err != nil {
		if errors.Is(err, store.ErrNameTaken) {
			writeErr(w, http.StatusConflict, "team name already taken")
			return
		}
		writeErr(w, http.StatusInternalServerError, "create team failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"name": name})
}

// handleMyTeams returns the caller's own team memberships (name + role), so the
// client can populate its team switcher — including teams joined server-side
// (e.g. the KC-Tech migration).
func (s *Server) handleMyTeams(w http.ResponseWriter, _ *http.Request, u *store.User) {
	memberships, err := s.store.ListUserMemberships(u.UserID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "list memberships failed")
		return
	}
	out := make([]map[string]any, 0, len(memberships))
	for _, m := range memberships {
		out = append(out, map[string]any{"name": m.TeamName, "role": m.Role})
	}
	writeJSON(w, http.StatusOK, out)
}

// handleListTeams returns the public-team discovery list (private teams never appear).
func (s *Server) handleListTeams(w http.ResponseWriter, _ *http.Request, _ *store.User) {
	teams, err := s.store.ListPublicTeams()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "list teams failed")
		return
	}
	out := make([]map[string]any, 0, len(teams))
	for _, t := range teams {
		out = append(out, map[string]any{"name": t.Name, "memberCount": t.MemberCount})
	}
	writeJSON(w, http.StatusOK, out)
}

// handleJoinTeam joins by password (instant), or for a public team without a
// correct password records an ask-to-join. Private teams reject opaquely so
// their existence isn't revealed.
func (s *Server) handleJoinTeam(w http.ResponseWriter, r *http.Request, u *store.User) {
	teamName := r.PathValue("name")
	body, _ := io.ReadAll(r.Body)
	var req joinTeamRequest
	_ = json.Unmarshal(body, &req) // body may be empty for ask-to-join

	team, hash, err := s.store.GetTeam(teamName)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusForbidden, "cannot join")
			return
		}
		writeErr(w, http.StatusInternalServerError, "lookup failed")
		return
	}
	if ok, _ := s.store.IsMember(team.Name, u.UserID); ok {
		writeJSON(w, http.StatusOK, map[string]string{"status": "member"})
		return
	}
	if req.Password != "" && store.CheckPassword(hash, req.Password) {
		if err := s.store.AddMember(team.Name, u.UserID, "member", s.now().Unix()); err != nil {
			writeErr(w, http.StatusInternalServerError, "join failed")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "member"})
		return
	}
	if team.Visibility == "public" {
		if err := s.store.CreateJoinRequest(uuid.NewString(), team.Name, u.UserID, s.now().Unix()); err != nil {
			writeErr(w, http.StatusInternalServerError, "request failed")
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]string{"status": "pending"})
		return
	}
	writeErr(w, http.StatusForbidden, "cannot join")
}

// handleLeaveTeam removes the caller; an emptied team is auto-deleted.
func (s *Server) handleLeaveTeam(w http.ResponseWriter, r *http.Request, u *store.User) {
	team, _, err := s.store.GetTeam(r.PathValue("name"))
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		writeErr(w, http.StatusInternalServerError, "lookup failed")
		return
	}
	remaining, err := s.store.RemoveMember(team.Name, u.UserID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "leave failed")
		return
	}
	if remaining == 0 {
		if err := s.store.DeleteTeam(team.Name); err != nil {
			writeErr(w, http.StatusInternalServerError, "cleanup failed")
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleListJoinRequests returns a team's pending ask-to-join requests (owner only).
func (s *Server) handleListJoinRequests(w http.ResponseWriter, r *http.Request, u *store.User) {
	team, ok := s.requireOwner(w, r.PathValue("name"), u)
	if !ok {
		return
	}
	reqs, err := s.store.ListPendingJoinRequests(team.Name)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "list failed")
		return
	}
	out := make([]map[string]any, 0, len(reqs))
	for _, jr := range reqs {
		name := jr.UserID
		if usr, err := s.store.GetUserByID(jr.UserID); err == nil {
			name = usr.DisplayName
		}
		out = append(out, map[string]any{"id": jr.ID, "userName": name, "createdAt": jr.CreatedAt})
	}
	writeJSON(w, http.StatusOK, out)
}

// handleDecideJoinRequest approves/rejects a pending request (owner only).
func (s *Server) handleDecideJoinRequest(w http.ResponseWriter, r *http.Request, u *store.User) {
	_, ok := s.requireOwner(w, r.PathValue("name"), u)
	if !ok {
		return
	}
	body, _ := io.ReadAll(r.Body)
	var req decideJoinRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}
	if _, _, err := s.store.DecideJoinRequest(r.PathValue("id"), u.UserID, req.Approve, s.now().Unix()); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "unknown request")
			return
		}
		writeErr(w, http.StatusInternalServerError, "decide failed")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// requireOwner resolves a team by name and asserts the caller is its owner,
// writing the appropriate error and returning ok=false otherwise.
func (s *Server) requireOwner(w http.ResponseWriter, teamName string, u *store.User) (*store.Team, bool) {
	team, _, err := s.store.GetTeam(teamName)
	if err != nil {
		writeErr(w, http.StatusNotFound, "unknown team")
		return nil, false
	}
	role, err := s.store.MemberRole(team.Name, u.UserID)
	if err != nil || role != "owner" {
		writeErr(w, http.StatusForbidden, "owner only")
		return nil, false
	}
	return team, true
}
