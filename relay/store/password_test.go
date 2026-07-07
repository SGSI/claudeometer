package store

import "testing"

func TestHashAndCheckPassword(t *testing.T) {
	const sample = "correct-horse-battery-staple"
	h, err := HashPassword(sample)
	if err != nil {
		t.Fatalf("HashPassword() error = %v", err)
	}
	if h == sample || h == "" {
		t.Fatalf("hash must not be plaintext/empty, got %q", h)
	}
	if !CheckPassword(h, sample) {
		t.Fatalf("CheckPassword() = false for correct password")
	}
	if CheckPassword(h, "wrong") {
		t.Fatalf("CheckPassword() = true for wrong password")
	}
}
