package signing

import (
	"testing"
)

func TestBodySHA256Hex_EmptyBody(t *testing.T) {
	const wantEmpty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

	t.Run("nil body", func(t *testing.T) {
		got := BodySHA256Hex(nil)
		if got != wantEmpty {
			t.Fatalf("BodySHA256Hex(nil) = %q, want %q", got, wantEmpty)
		}
	})

	t.Run("empty slice body", func(t *testing.T) {
		got := BodySHA256Hex([]byte{})
		if got != wantEmpty {
			t.Fatalf("BodySHA256Hex([]byte{}) = %q, want %q", got, wantEmpty)
		}
	})
}

func TestBodySHA256Hex_KnownVector(t *testing.T) {
	// sha256("hello") per well-known test vectors.
	const want = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
	got := BodySHA256Hex([]byte("hello"))
	if got != want {
		t.Fatalf("BodySHA256Hex(\"hello\") = %q, want %q", got, want)
	}
}

func TestCanonicalMessage_ExactBytes(t *testing.T) {
	bodyHex := BodySHA256Hex(nil)
	got := CanonicalMessage("POST", "/usage", "123", bodyHex)
	want := "POST\n/usage\n123\n" + bodyHex

	if string(got) != want {
		t.Fatalf("CanonicalMessage() = %q, want %q", got, want)
	}
}

func TestSignVerify_RoundTrip(t *testing.T) {
	pub, priv, err := GenerateKeypair()
	if err != nil {
		t.Fatalf("GenerateKeypair() error = %v", err)
	}

	msg := CanonicalMessage("POST", "/usage", "1700000000", BodySHA256Hex([]byte(`{"a":1}`)))
	sigB64 := Sign(priv, msg)
	pubB64 := PublicKeyB64(pub)

	if err := Verify(pubB64, sigB64, msg); err != nil {
		t.Fatalf("Verify() error = %v, want nil", err)
	}
}

func TestVerify_TamperedMessage(t *testing.T) {
	pub, priv, err := GenerateKeypair()
	if err != nil {
		t.Fatalf("GenerateKeypair() error = %v", err)
	}

	msg := CanonicalMessage("POST", "/usage", "1700000000", BodySHA256Hex([]byte(`{"a":1}`)))
	sigB64 := Sign(priv, msg)
	pubB64 := PublicKeyB64(pub)

	tampered := CanonicalMessage("POST", "/usage", "1700000001", BodySHA256Hex([]byte(`{"a":1}`)))

	if err := Verify(pubB64, sigB64, tampered); err == nil {
		t.Fatal("Verify() error = nil, want error for tampered message")
	}
}

func TestVerify_TamperedSignature(t *testing.T) {
	pub, priv, err := GenerateKeypair()
	if err != nil {
		t.Fatalf("GenerateKeypair() error = %v", err)
	}

	msg := CanonicalMessage("GET", "/board", "1700000000", BodySHA256Hex(nil))
	sigB64 := Sign(priv, msg)
	pubB64 := PublicKeyB64(pub)

	// Flip the signature by re-signing a different message and using that
	// signature against the original message.
	otherMsg := CanonicalMessage("GET", "/board", "1700000002", BodySHA256Hex(nil))
	wrongSig := Sign(priv, otherMsg)

	if err := Verify(pubB64, wrongSig, msg); err == nil {
		t.Fatal("Verify() error = nil, want error for tampered signature")
	}
	_ = sigB64
}

func TestVerify_BadEncoding(t *testing.T) {
	pub, _, err := GenerateKeypair()
	if err != nil {
		t.Fatalf("GenerateKeypair() error = %v", err)
	}
	pubB64 := PublicKeyB64(pub)
	msg := []byte("whatever")

	if err := Verify(pubB64, "not-valid-base64!!", msg); err == nil {
		t.Fatal("Verify() error = nil, want error for invalid signature base64")
	}
	if err := Verify("not-valid-base64!!", "AAAA", msg); err == nil {
		t.Fatal("Verify() error = nil, want error for invalid pubkey base64")
	}
}

func TestVerify_WrongKeySize(t *testing.T) {
	msg := []byte("whatever")
	shortKey := PublicKeyB64([]byte("tooshort"))
	if err := Verify(shortKey, "AAAA", msg); err == nil {
		t.Fatal("Verify() error = nil, want error for wrong-size pubkey")
	}
}
