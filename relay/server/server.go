// Package server wires the relay's HTTP endpoints to the store, implementing
// the wire protocol defined in relay/PROTOCOL.md.
package server

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"

	"claudeometer-relay/signing"
	"claudeometer-relay/store"
)

const (
	maxClockSkewSeconds = 300
	maxBodyBytes        = 1 << 20 // 1 MiB
)

// Server holds the relay's HTTP dependencies.
type Server struct {
	store   *store.Store
	version string
	now     func() time.Time
}

// New builds a Server. version is surfaced at /health.
func New(st *store.Store, version string) *Server {
	return &Server{store: st, version: version, now: time.Now}
}

// Handler returns the routed http.Handler for the relay.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("POST /enroll", s.handleEnroll)
	mux.HandleFunc("POST /usage", s.withAuth(s.handleUsage))
	mux.HandleFunc("GET /board", s.withAuth(s.handleBoard))
	mux.HandleFunc("POST /borrow/request", s.withAuth(s.handleBorrowRequest))
	mux.HandleFunc("GET /borrow/inbox", s.withAuth(s.handleBorrowInbox))
	mux.HandleFunc("POST /borrow/decision", s.withAuth(s.handleBorrowDecision))
	mux.HandleFunc("GET /borrow/pickup/{requestId}", s.withAuth(s.handleBorrowPickup))
	mux.HandleFunc("POST /borrow/revoke", s.withAuth(s.handleBorrowRevoke))
	return mux
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ok",
		"service": "claudeometer-relay",
		"version": s.version,
	})
}

// --- enroll (unauthenticated, self-signed) ---

type enrollRequest struct {
	DisplayName      string `json:"displayName"`
	SigningPubKey    string `json:"signingPubKey"`
	EncryptionPubKey string `json:"encryptionPubKey"`
	DeviceID         string `json:"deviceId"`
}

func (s *Server) handleEnroll(w http.ResponseWriter, r *http.Request) {
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	ts, ok := s.checkTimestamp(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "invalid or stale timestamp")
		return
	}
	var req enrollRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}
	if req.DisplayName == "" || req.SigningPubKey == "" || req.DeviceID == "" {
		writeErr(w, http.StatusBadRequest, "displayName, signingPubKey and deviceId are required")
		return
	}
	// Proof of key possession: the request is signed by the private key
	// matching the signingPubKey it presents.
	if err := verifySig(r, ts, body, req.SigningPubKey); err != nil {
		writeErr(w, http.StatusUnauthorized, "bad signature")
		return
	}

	// Idempotent: same device + signing key returns the existing user.
	existing, err := s.store.FindUser(req.DeviceID, req.SigningPubKey)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, map[string]string{"userId": existing.UserID})
		return
	case !errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusInternalServerError, "lookup failed")
		return
	}

	now := s.now().Unix()
	u := &store.User{
		UserID:           uuid.NewString(),
		DisplayName:      req.DisplayName,
		SigningPubKey:    req.SigningPubKey,
		EncryptionPubKey: req.EncryptionPubKey,
		DeviceID:         req.DeviceID,
		CreatedAt:        now,
		LastSeen:         now,
	}
	if err := s.store.CreateUser(u); err != nil {
		writeErr(w, http.StatusInternalServerError, "create failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"userId": u.UserID})
}

// --- usage (authed) ---

type usageRequest struct {
	FiveHourPct     float64 `json:"fiveHourPct"`
	SevenDayPct     float64 `json:"sevenDayPct"`
	ResetAt         *int64  `json:"resetAt"`
	AvailableToLend bool    `json:"availableToLend"`
}

func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request, u *store.User) {
	body, _ := io.ReadAll(r.Body)
	var req usageRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}
	usage := store.Usage{
		FiveHourPct:     req.FiveHourPct,
		SevenDayPct:     req.SevenDayPct,
		ResetAt:         req.ResetAt,
		AvailableToLend: req.AvailableToLend,
	}
	if err := s.store.UpsertUsage(u.UserID, usage, s.now().Unix()); err != nil {
		writeErr(w, http.StatusInternalServerError, "save usage failed")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- board (authed) ---

func (s *Server) handleBoard(w http.ResponseWriter, _ *http.Request, _ *store.User) {
	board, err := s.store.ListBoard()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "board failed")
		return
	}
	if board == nil {
		board = []store.BoardRow{}
	}
	// Annotate rows with who is currently borrowing from whom, so the board
	// reflects that a borrower is on someone else's quota (not their own).
	if actives, aerr := s.store.ListActiveBorrows(s.now().Unix()); aerr == nil {
		byID := make(map[string]*store.BoardRow, len(board))
		for i := range board {
			byID[board[i].UserID] = &board[i]
		}
		for _, a := range actives {
			if r := byID[a.RequesterID]; r != nil {
				name, ends := a.LenderName, a.EndsAt
				r.BorrowingFrom = &name
				r.BorrowingUntil = &ends
			}
			if r := byID[a.LenderID]; r != nil {
				r.LendingTo = append(r.LendingTo, a.RequesterName)
			}
		}
	}
	writeJSON(w, http.StatusOK, board)
}

// --- borrow handshake (authed) ---

type borrowRequestRequest struct {
	LenderID string `json:"lenderId"`
	Hours    int    `json:"hours"`
}

func (s *Server) handleBorrowRequest(w http.ResponseWriter, r *http.Request, u *store.User) {
	body, _ := io.ReadAll(r.Body)
	var req borrowRequestRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}
	if req.Hours < 1 || req.Hours > 4 {
		writeErr(w, http.StatusBadRequest, "hours must be between 1 and 4")
		return
	}
	if req.LenderID == u.UserID {
		writeErr(w, http.StatusBadRequest, "cannot borrow from self")
		return
	}
	if _, err := s.store.GetUserByID(req.LenderID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "unknown lender")
		} else {
			writeErr(w, http.StatusInternalServerError, "lookup failed")
		}
		return
	}

	id := uuid.NewString()
	if err := s.store.CreateBorrowRequest(id, u.UserID, req.LenderID, req.Hours, s.now().Unix()); err != nil {
		writeErr(w, http.StatusInternalServerError, "create request failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"requestId": id})
}

func (s *Server) handleBorrowInbox(w http.ResponseWriter, _ *http.Request, u *store.User) {
	incoming, err := s.store.ListIncoming(u.UserID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "list incoming failed")
		return
	}
	outgoing, err := s.store.ListOutgoing(u.UserID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "list outgoing failed")
		return
	}
	if incoming == nil {
		incoming = []store.IncomingRequest{}
	}
	if outgoing == nil {
		outgoing = []store.OutgoingRequest{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"incoming": incoming,
		"outgoing": outgoing,
	})
}

type borrowDecisionRequest struct {
	RequestID  string `json:"requestId"`
	Approve    bool   `json:"approve"`
	Ciphertext string `json:"ciphertext"`
}

func (s *Server) handleBorrowDecision(w http.ResponseWriter, r *http.Request, u *store.User) {
	body, _ := io.ReadAll(r.Body)
	var req borrowDecisionRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}
	br, err := s.store.GetBorrowRequest(req.RequestID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "unknown request")
		} else {
			writeErr(w, http.StatusInternalServerError, "lookup failed")
		}
		return
	}
	if br.LenderID != u.UserID {
		writeErr(w, http.StatusForbidden, "not the lender for this request")
		return
	}
	if br.Status != "pending" {
		writeErr(w, http.StatusConflict, "request is not pending")
		return
	}

	now := s.now().Unix()
	if req.Approve {
		if req.Ciphertext == "" {
			writeErr(w, http.StatusBadRequest, "ciphertext required to approve")
			return
		}
		if err := s.store.ApproveBorrow(br.ID, br.RequesterID, req.Ciphertext, now, now+600); err != nil {
			writeErr(w, http.StatusInternalServerError, "approve failed")
			return
		}
	} else {
		if err := s.store.RejectBorrow(br.ID, now); err != nil {
			writeErr(w, http.StatusInternalServerError, "reject failed")
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleBorrowPickup(w http.ResponseWriter, r *http.Request, u *store.User) {
	requestID := r.PathValue("requestId")
	br, err := s.store.GetBorrowRequest(requestID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "unknown request")
		} else {
			writeErr(w, http.StatusInternalServerError, "lookup failed")
		}
		return
	}
	if br.RequesterID != u.UserID {
		writeErr(w, http.StatusForbidden, "not the requester for this request")
		return
	}
	if br.Status != "approved" {
		writeErr(w, http.StatusConflict, "request is not approved")
		return
	}

	ciphertext, err := s.store.PickupMailbox(br.ID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "mailbox entry gone or expired")
		} else {
			writeErr(w, http.StatusInternalServerError, "pickup failed")
		}
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"ciphertext": ciphertext})
}

type borrowRevokeRequest struct {
	RequestID string `json:"requestId"`
}

func (s *Server) handleBorrowRevoke(w http.ResponseWriter, r *http.Request, u *store.User) {
	body, _ := io.ReadAll(r.Body)
	var req borrowRevokeRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}
	br, err := s.store.GetBorrowRequest(req.RequestID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "unknown request")
		} else {
			writeErr(w, http.StatusInternalServerError, "lookup failed")
		}
		return
	}
	if br.LenderID != u.UserID && br.RequesterID != u.UserID {
		writeErr(w, http.StatusForbidden, "not a party to this request")
		return
	}
	if err := s.store.RevokeBorrow(br.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, "revoke failed")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- auth middleware ---

// authedHandler is a handler that has already resolved the calling user.
type authedHandler func(http.ResponseWriter, *http.Request, *store.User)

func (s *Server) withAuth(next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, ok := readBody(w, r)
		if !ok {
			return
		}
		ts, ok := s.checkTimestamp(r)
		if !ok {
			writeErr(w, http.StatusUnauthorized, "invalid or stale timestamp")
			return
		}
		userID := r.Header.Get("X-User-Id")
		if userID == "" {
			writeErr(w, http.StatusUnauthorized, "missing X-User-Id")
			return
		}
		u, err := s.store.GetUserByID(userID)
		if err != nil {
			if errors.Is(err, store.ErrNotFound) {
				writeErr(w, http.StatusUnauthorized, "unknown user")
			} else {
				writeErr(w, http.StatusInternalServerError, "lookup failed")
			}
			return
		}
		if err := verifySig(r, ts, body, u.SigningPubKey); err != nil {
			writeErr(w, http.StatusUnauthorized, "bad signature")
			return
		}
		// Restore the body we consumed so the handler can decode it.
		r.Body = io.NopCloser(bytes.NewReader(body))
		next(w, r, u)
	}
}

// checkTimestamp validates the X-Timestamp header against the replay window.
func (s *Server) checkTimestamp(r *http.Request) (string, bool) {
	ts := r.Header.Get("X-Timestamp")
	tsi, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return "", false
	}
	delta := s.now().Unix() - tsi
	if delta > maxClockSkewSeconds || delta < -maxClockSkewSeconds {
		return "", false
	}
	return ts, true
}

// verifySig rebuilds the canonical message for r and verifies X-Signature
// against pubKeyB64 (PROTOCOL.md signing scheme).
func verifySig(r *http.Request, ts string, body []byte, pubKeyB64 string) error {
	msg := signing.CanonicalMessage(r.Method, r.URL.Path, ts, signing.BodySHA256Hex(body))
	return signing.Verify(pubKeyB64, r.Header.Get("X-Signature"), msg)
}

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "cannot read body")
		return nil, false
	}
	return body, true
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("server: encode response: %v", err)
	}
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
