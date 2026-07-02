// Command borrowsmoke runs a two-user M3 borrow handshake against a running
// relay (request → inbox → approve → pickup → one-shot check), for verifying a
// deployment. The ciphertext is a dummy (the relay is zero-knowledge).
//
//	go run ./cmd/borrowsmoke http://your-relay:8080
package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"claudeometer-relay/signing"
)

func main() {
	base := "http://localhost:8080"
	if len(os.Args) > 1 {
		base = os.Args[1]
	}
	ts := strconv.FormatInt(time.Now().Unix(), 10)

	aPub, aPriv, _ := signing.GenerateKeypair()
	bPub, bPriv, _ := signing.GenerateKeypair()
	aID := enroll(base, "borrower-A-"+ts, "borrow-dev-A-"+ts, "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=", aPub, aPriv)
	bID := enroll(base, "lender-B-"+ts, "borrow-dev-B-"+ts, "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI=", bPub, bPriv)
	fmt.Printf("A=%s  B=%s\n", aID, bID)

	var reqResp struct {
		RequestID string `json:"requestId"`
	}
	reqBody, _ := json.Marshal(map[string]any{"lenderId": bID, "hours": 2})
	doReq(base, "POST", "/borrow/request", reqBody, aID, aPriv, 200, &reqResp)
	fmt.Println("A requested 2h; requestId:", reqResp.RequestID)

	var inbox struct {
		Incoming []map[string]any `json:"incoming"`
	}
	doReq(base, "GET", "/borrow/inbox", nil, bID, bPriv, 200, &inbox)
	if len(inbox.Incoming) == 0 {
		log.Fatal("B inbox empty — expected the incoming request")
	}
	fmt.Printf("B inbox incoming=%d requesterEncKey=%v\n", len(inbox.Incoming), inbox.Incoming[0]["requesterEncryptionPubKey"])

	decBody, _ := json.Marshal(map[string]any{"requestId": reqResp.RequestID, "approve": true, "ciphertext": "ZHVtbXktc2VhbGVkLWJsb2I="})
	doReq(base, "POST", "/borrow/decision", decBody, bID, bPriv, 204, nil)
	fmt.Println("B approved")

	var pick struct {
		Ciphertext string `json:"ciphertext"`
	}
	doReq(base, "GET", "/borrow/pickup/"+reqResp.RequestID, nil, aID, aPriv, 200, &pick)
	fmt.Println("A picked up ciphertext:", pick.Ciphertext)

	second := doReqStatus(base, "GET", "/borrow/pickup/"+reqResp.RequestID, nil, aID, aPriv)
	fmt.Println("second pickup status (want 404/409):", second)
	if second < 400 {
		log.Fatal("one-shot pickup violated — second pickup succeeded")
	}
	fmt.Println("BORROW SMOKE OK")
}

func enroll(base, name, deviceID, encKeyB64 string, pub ed25519.PublicKey, priv ed25519.PrivateKey) string {
	body, _ := json.Marshal(map[string]string{
		"displayName":      name,
		"signingPubKey":    signing.PublicKeyB64(pub),
		"encryptionPubKey": encKeyB64,
		"deviceId":         deviceID,
	})
	var resp struct {
		UserID string `json:"userId"`
	}
	doReq(base, "POST", "/enroll", body, "", priv, 200, &resp)
	return resp.UserID
}

func doReq(base, method, path string, body []byte, userID string, priv ed25519.PrivateKey, wantStatus int, out any) {
	code, data := send(base, method, path, body, userID, priv)
	if code != wantStatus {
		log.Fatalf("%s %s: want %d, got %d: %s", method, path, wantStatus, code, data)
	}
	if out != nil {
		if err := json.Unmarshal(data, out); err != nil {
			log.Fatalf("%s %s: decode: %v (%s)", method, path, err, data)
		}
	}
}

func doReqStatus(base, method, path string, body []byte, userID string, priv ed25519.PrivateKey) int {
	code, _ := send(base, method, path, body, userID, priv)
	return code
}

func send(base, method, path string, body []byte, userID string, priv ed25519.PrivateKey) (int, []byte) {
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	msg := signing.CanonicalMessage(method, path, ts, signing.BodySHA256Hex(body))
	req, err := http.NewRequest(method, base+path, bytes.NewReader(body))
	if err != nil {
		log.Fatal(err)
	}
	req.Header.Set("X-Timestamp", ts)
	req.Header.Set("X-Signature", signing.Sign(priv, msg))
	if userID != "" {
		req.Header.Set("X-User-Id", userID)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}
