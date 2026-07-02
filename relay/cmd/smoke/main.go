// Command smoke runs a signed enroll → usage → board round-trip against a
// running relay, for manually verifying a deployment.
//
//	go run ./cmd/smoke http://your-relay:8080
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

	pub, priv, err := signing.GenerateKeypair()
	if err != nil {
		log.Fatalf("keygen: %v", err)
	}

	enrollBody, _ := json.Marshal(map[string]string{
		"displayName":      "smoke-" + strconv.FormatInt(time.Now().Unix(), 10),
		"signingPubKey":    signing.PublicKeyB64(pub),
		"encryptionPubKey": "",
		"deviceId":         "smoke-device",
	})
	var enrollResp struct {
		UserID string `json:"userId"`
	}
	do(base, "POST", "/enroll", enrollBody, "", priv, &enrollResp)
	fmt.Println("enrolled userId:", enrollResp.UserID)

	usageBody, _ := json.Marshal(map[string]any{
		"fiveHourPct":     42.5,
		"sevenDayPct":     12.0,
		"resetAt":         time.Now().Add(time.Hour).Unix(),
		"availableToLend": true,
	})
	do(base, "POST", "/usage", usageBody, enrollResp.UserID, priv, nil)
	fmt.Println("usage posted")

	var board []map[string]any
	do(base, "GET", "/board", nil, enrollResp.UserID, priv, &board)
	fmt.Printf("board (%d rows):\n", len(board))
	for _, row := range board {
		fmt.Printf("  %v  5h=%v lend=%v\n", row["displayName"], row["fiveHourPct"], row["availableToLend"])
	}
	fmt.Println("SMOKE OK")
}

func do(base, method, path string, body []byte, userID string, priv ed25519.PrivateKey, out any) {
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	msg := signing.CanonicalMessage(method, path, ts, signing.BodySHA256Hex(body))

	req, err := http.NewRequest(method, base+path, bytes.NewReader(body))
	if err != nil {
		log.Fatalf("%s %s: %v", method, path, err)
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
	if resp.StatusCode >= 300 {
		log.Fatalf("%s %s: status %d: %s", method, path, resp.StatusCode, data)
	}
	if out != nil {
		if err := json.Unmarshal(data, out); err != nil {
			log.Fatalf("%s %s: decode: %v (body %s)", method, path, err, data)
		}
	}
}
