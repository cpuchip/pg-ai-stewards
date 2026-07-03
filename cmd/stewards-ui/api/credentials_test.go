// Oracles for the 88/#256 credential wizard's Go half: the AES-256-GCM
// round-trip (layout nonce||ct||tag that providers.rs decrypts), master-key
// parsing, and the test-on-save probe — a live pass when a key is provided
// via env, and the clean failure path always. No test ever prints key
// material; the never-echo rule applies to test output too.

package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"os"
	"strings"
	"testing"
	"time"
)

func TestSecretRoundTrip(t *testing.T) {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		t.Fatal(err)
	}
	const secret = "sk-round-trip-test-000"
	blob, err := encryptSecret(key, secret)
	if err != nil {
		t.Fatalf("encrypt: %v", err)
	}
	// Layout contract with the Rust decrypter: 12-byte nonce prefix, then
	// ciphertext+16-byte tag — so the blob is plaintext+28 bytes.
	if len(blob) != len(secret)+12+16 {
		t.Fatalf("blob layout: got %d bytes, want %d (nonce12 + ct + tag16)", len(blob), len(secret)+28)
	}
	plain, err := decryptSecret(key, blob)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if plain != secret {
		t.Fatal("round-trip mismatch")
	}
	// Tampered ciphertext must fail authentication.
	blob[len(blob)-1] ^= 1
	if _, err := decryptSecret(key, blob); err == nil {
		t.Fatal("tampered ciphertext must not decrypt")
	}
	blob[len(blob)-1] ^= 1
	// Wrong key must fail.
	wrong := make([]byte, 32)
	if _, err := decryptSecret(wrong, blob); err == nil {
		t.Fatal("wrong key must not decrypt")
	}
}

func TestWizardMasterKeyParsing(t *testing.T) {
	t.Setenv("STEWARDS_MASTER_KEY", "")
	if _, err := wizardMasterKey(); err == nil {
		t.Fatal("empty master key must error (wizard disabled, never plaintext)")
	}
	t.Setenv("STEWARDS_MASTER_KEY", base64.StdEncoding.EncodeToString(make([]byte, 16)))
	if _, err := wizardMasterKey(); err == nil {
		t.Fatal("a 16-byte key must be rejected (AES-256 needs 32)")
	}
	t.Setenv("STEWARDS_MASTER_KEY", base64.StdEncoding.EncodeToString(make([]byte, 32)))
	if _, err := wizardMasterKey(); err != nil {
		t.Fatalf("a 32-byte base64 key must parse: %v", err)
	}
}

// The failure path must return a clean error (no panic, no key echo) when the
// provider is unreachable — the wizard shows exactly this string to the human.
func TestProbeFailurePathClean(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	const fakeKey = "sk-never-echo-this-value"
	_, err := probeProviderModels(ctx, "http://127.0.0.1:9", "openai", fakeKey)
	if err == nil {
		t.Fatal("unreachable provider must fail")
	}
	if strings.Contains(err.Error(), fakeKey) {
		t.Fatal("probe error must never contain key material")
	}
}

// Live test-on-save proof against opencode zen (read-only GET /models).
// Runs only when STEWARDS_TEST_OPENCODE_ZEN_KEY is set (never committed,
// never printed) — CI and keyless machines skip cleanly.
func TestProbeOpencodeZenLive(t *testing.T) {
	key := os.Getenv("STEWARDS_TEST_OPENCODE_ZEN_KEY")
	if key == "" {
		t.Skip("STEWARDS_TEST_OPENCODE_ZEN_KEY not set — skipping live probe")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	models, err := probeProviderModels(ctx, "https://opencode.ai/zen/v1", "openai", key)
	if err != nil {
		t.Fatalf("live probe failed: %v", err)
	}
	if len(models) == 0 {
		t.Fatal("live probe returned no models")
	}
	t.Logf("live probe ok: %d models listed", len(models))
}
