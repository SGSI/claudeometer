// Package signing implements the Ed25519 canonical-request signing scheme
// shared between the relay (Go) and the Claudeometer client (Swift). See
// PROTOCOL.md for the full spec — every detail here (byte layout, encodings)
// MUST match it exactly.
package signing

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
)

// CanonicalMessage builds the exact byte sequence that gets signed for a
// request: "<METHOD>\n<PATH>\n<TIMESTAMP>\n<BODY_SHA256_HEX>".
func CanonicalMessage(method, path, timestamp, bodySHA256Hex string) []byte {
	return []byte(method + "\n" + path + "\n" + timestamp + "\n" + bodySHA256Hex)
}

// BodySHA256Hex returns the lowercase hex SHA-256 digest of body. For a nil
// or empty body this is the well-known empty-string digest
// (e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855).
func BodySHA256Hex(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

// Verify decodes pubKeyB64 (standard base64 of a raw 32-byte Ed25519 public
// key) and signatureB64 (standard base64 of a raw 64-byte Ed25519 signature)
// and checks the signature over message. It returns a non-nil error on any
// decoding problem or signature mismatch.
func Verify(pubKeyB64, signatureB64 string, message []byte) error {
	pubKeyBytes, err := base64.StdEncoding.DecodeString(pubKeyB64)
	if err != nil {
		return fmt.Errorf("signing: decode public key: %w", err)
	}
	if len(pubKeyBytes) != ed25519.PublicKeySize {
		return fmt.Errorf("signing: public key has invalid size %d, want %d", len(pubKeyBytes), ed25519.PublicKeySize)
	}

	sigBytes, err := base64.StdEncoding.DecodeString(signatureB64)
	if err != nil {
		return fmt.Errorf("signing: decode signature: %w", err)
	}
	if len(sigBytes) != ed25519.SignatureSize {
		return fmt.Errorf("signing: signature has invalid size %d, want %d", len(sigBytes), ed25519.SignatureSize)
	}

	if !ed25519.Verify(ed25519.PublicKey(pubKeyBytes), message, sigBytes) {
		return errors.New("signing: signature verification failed")
	}
	return nil
}

// Sign returns the standard base64 encoding of the Ed25519 signature of
// message under privKey.
func Sign(privKey ed25519.PrivateKey, message []byte) string {
	sig := ed25519.Sign(privKey, message)
	return base64.StdEncoding.EncodeToString(sig)
}

// PublicKeyB64 returns the standard base64 encoding of a raw Ed25519 public
// key, matching the wire format used for signingPubKey / X-User-Id lookups.
func PublicKeyB64(pub ed25519.PublicKey) string {
	return base64.StdEncoding.EncodeToString(pub)
}

// GenerateKeypair creates a fresh Ed25519 keypair. It is used by tests and by
// the smoke-test client to simulate a device enrolling and signing requests.
func GenerateKeypair() (ed25519.PublicKey, ed25519.PrivateKey, error) {
	return ed25519.GenerateKey(rand.Reader)
}
