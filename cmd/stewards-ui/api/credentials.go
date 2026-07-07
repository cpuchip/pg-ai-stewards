// Credentials + setup-wizard endpoints — /api/credentials/* and the wizard
// half of /api/models/* (#256: easy in-app API key + model add).
//
// This is the encrypting twin of the extension's 88-credentials.sql + the
// providers.rs overlay: the cockpit AES-256-GCM-encrypts a pasted key with
// STEWARDS_MASTER_KEY (same .env var the pg container reads to DECRYPT at
// dispatch), stores only ciphertext via stewards.credential_set(bytea), and
// the provider goes live with no rebuild and no restart.
//
// Two rules stolen verbatim from the n8n/OpenHands/Dify/Airflow pattern:
//   * TEST-ON-SAVE — saving a key fires a real GET /models against the
//     provider; last_verified_at is stamped only on a live pass.
//   * NEVER ECHO THE KEY — list responses carry is_set booleans; no endpoint
//     returns key material, and no error message embeds it.
//
// If STEWARDS_MASTER_KEY is absent the wizard endpoints refuse with a clear
// setup message — plaintext storage is never the fallback.

package api

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

func (d *Deps) registerCredentials(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/credentials", d.credentialsListHandler)
	mux.HandleFunc("POST /api/credentials", d.credentialSaveHandler)
	mux.HandleFunc("DELETE /api/credentials/{name}", d.credentialDeleteHandler)
	mux.HandleFunc("GET /api/credentials/{name}/models", d.credentialModelsHandler)
	// Wizard model verbs: register a picked model (capability + optional
	// pricing), assign/unassign a role alias, fire the real-path probe.
	mux.HandleFunc("POST /api/models/register", d.modelRegisterHandler)
	mux.HandleFunc("POST /api/models/aliases", d.aliasSetHandler)
	mux.HandleFunc("POST /api/models/aliases/delete", d.aliasDeleteHandler)
	mux.HandleFunc("POST /api/models/probe", d.modelProbeHandler)
	// 95 model-role toggles: per-member enable/disable + priority reorder +
	// the "rest all local models" bulk switch (+ its inverse) — thin wrappers
	// over the UPDATEs pick_alias_member (32/95) actually resolves against.
	mux.HandleFunc("POST /api/models/aliases/enabled", d.aliasEnabledHandler)
	mux.HandleFunc("POST /api/models/aliases/priority", d.aliasPriorityHandler)
	mux.HandleFunc("POST /api/models/aliases/rest-local", d.aliasRestLocalHandler)
}

// ---------------------------------------------------------------------------
// crypto — AES-256-GCM, layout nonce(12) || ciphertext || tag(16).
// The Rust decrypter (providers.rs decrypt_secret) assumes exactly this.
// ---------------------------------------------------------------------------

var errNoMasterKey = errors.New(
	"set STEWARDS_MASTER_KEY to enable the setup wizard: 32 bytes of base64 " +
		"(e.g. `openssl rand -base64 32`) in .env, then bring the stack up so " +
		"both the ui and pg containers see it")

// wizardMasterKey parses STEWARDS_MASTER_KEY: base64 (standard alphabet,
// padded), decoding to exactly 32 bytes. Documented in .env.example.
func wizardMasterKey() ([]byte, error) {
	raw := strings.TrimSpace(os.Getenv("STEWARDS_MASTER_KEY"))
	if raw == "" {
		return nil, errNoMasterKey
	}
	key, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("STEWARDS_MASTER_KEY is not valid base64: %w", err)
	}
	if len(key) != 32 {
		return nil, fmt.Errorf("STEWARDS_MASTER_KEY must decode to 32 bytes (got %d)", len(key))
	}
	return key, nil
}

func encryptSecret(key []byte, plaintext string) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize()) // 12
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	// Seal appends ciphertext+tag after the prepended nonce.
	return gcm.Seal(nonce, nonce, []byte(plaintext), nil), nil
}

func decryptSecret(key, blob []byte) (string, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	if len(blob) < gcm.NonceSize()+1 {
		return "", errors.New("credential ciphertext too short")
	}
	plain, err := gcm.Open(nil, blob[:gcm.NonceSize()], blob[gcm.NonceSize():], nil)
	if err != nil {
		return "", errors.New("credential decrypt failed — STEWARDS_MASTER_KEY does not match the key that encrypted it")
	}
	return string(plain), nil
}

// ---------------------------------------------------------------------------
// test-on-save — a real GET /models against the provider.
// ---------------------------------------------------------------------------

var probeClient = &http.Client{Timeout: 20 * time.Second}

// probeProviderModels validates a key the only way that counts: a live,
// read-only models-list call. Returns the model ids on 200. The key travels
// in the auth header and NEVER into an error message.
func probeProviderModels(ctx context.Context, baseURL, kind, apiKey string) ([]string, error) {
	url := strings.TrimRight(baseURL, "/") + "/models"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	if kind == "anthropic" {
		if apiKey != "" {
			req.Header.Set("x-api-key", apiKey)
		}
		req.Header.Set("anthropic-version", "2023-06-01")
	} else if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}
	resp, err := probeClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("provider unreachable: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		snippet := strings.TrimSpace(string(body))
		if len(snippet) > 300 {
			snippet = snippet[:300] + "…"
		}
		return nil, fmt.Errorf("provider returned HTTP %d from GET /models: %s", resp.StatusCode, snippet)
	}
	// OpenAI-compat shape {"data":[{"id":...}]}; some local servers return a
	// bare array. Accept both.
	var wrapped struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	var ids []string
	if err := json.Unmarshal(body, &wrapped); err == nil && len(wrapped.Data) > 0 {
		for _, m := range wrapped.Data {
			if m.ID != "" {
				ids = append(ids, m.ID)
			}
		}
	} else {
		var bare []struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(body, &bare); err == nil {
			for _, m := range bare {
				if m.ID != "" {
					ids = append(ids, m.ID)
				}
			}
		}
	}
	sort.Strings(ids)
	return ids, nil
}

// ---------------------------------------------------------------------------
// GET /api/credentials — wizard state: DB providers + is_set booleans +
// budgets + the honest pg-side decrypt check. Never the key.
// ---------------------------------------------------------------------------

type credentialRow struct {
	Provider       string   `json:"provider"`
	BaseURL        string   `json:"base_url"`
	Kind           string   `json:"kind"`
	DefaultModel   string   `json:"default_model,omitempty"`
	IsSet          bool     `json:"is_set"`
	CredentialName string   `json:"credential_name,omitempty"`
	LastVerifiedAt *string  `json:"last_verified_at,omitempty"`
	Note           string   `json:"note,omitempty"`
	PgDecrypt      string   `json:"pg_decrypt,omitempty"` // 'ok' or the pg-side error; '' for keyless
	BudgetMicro    *int64   `json:"budget_micro,omitempty"`
	BudgetCadence  *string  `json:"budget_cadence,omitempty"`
	BudgetSpent    *int64   `json:"budget_spent_micro,omitempty"`
}

func (d *Deps) credentialsListHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	_, keyErr := wizardMasterKey()
	out := map[string]any{
		"master_key_set": keyErr == nil,
		"items":          []credentialRow{},
	}
	if keyErr != nil && !errors.Is(keyErr, errNoMasterKey) {
		out["master_key_error"] = keyErr.Error()
	}

	rows, err := d.Pool.Query(ctx, `
		SELECT cp.provider,
		       coalesce(cp.base_url, ''),
		       cp.kind,
		       cp.default_model,
		       coalesce(cp.credential_name, ''),
		       (cp.secret_encrypted IS NOT NULL)               AS is_set,
		       to_char(s.last_verified_at, 'YYYY-MM-DD"T"HH24:MI:SSZ'),
		       coalesce(s.note, ''),
		       CASE WHEN cp.secret_encrypted IS NOT NULL
		            THEN stewards.credential_decrypt_check(cp.credential_name)
		            ELSE '' END                                 AS pg_decrypt,
		       cap.cap_micro,
		       cap.refill_cadence,
		       CASE WHEN cap.provider IS NOT NULL
		            THEN stewards.provider_spend_since(cp.provider)
		            ELSE NULL END                               AS spent
		  FROM stewards.credential_providers cp
		  LEFT JOIN stewards.credential_status() s ON s.name = cp.credential_name
		  LEFT JOIN stewards.provider_spend_caps cap ON cap.provider = cp.provider
		 ORDER BY cp.provider`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []credentialRow{}
	for rows.Next() {
		var c credentialRow
		var lastVerified *string
		if err := rows.Scan(&c.Provider, &c.BaseURL, &c.Kind, &c.DefaultModel,
			&c.CredentialName, &c.IsSet, &lastVerified, &c.Note, &c.PgDecrypt,
			&c.BudgetMicro, &c.BudgetCadence, &c.BudgetSpent); err == nil {
			c.LastVerifiedAt = lastVerified
			items = append(items, c)
		}
	}
	out["items"] = items
	writeJSON(w, http.StatusOK, out)
}

// ---------------------------------------------------------------------------
// POST /api/credentials — the wizard's save verb: dials + encrypted key +
// budget in one shot, then TEST-ON-SAVE.
// ---------------------------------------------------------------------------

var providerNameRe = regexp.MustCompile(`^[a-z0-9_]+$`)

type credentialSaveReq struct {
	Provider     string   `json:"provider"`
	Secret       string   `json:"secret"`         // plaintext IN transit (localhost UI), encrypted at rest; "" = keyless
	BaseURL      string   `json:"base_url"`       // "" = keep existing dials / env
	Kind         string   `json:"kind"`           // openai | anthropic; "" = openai (or existing)
	DefaultModel string   `json:"default_model"`  // optional
	Note         string   `json:"note"`           // optional
	BudgetUSDDay *float64 `json:"budget_usd_per_day"` // nil = leave budget alone; <=0 = remove
}

type credentialSaveResp struct {
	Stored       bool     `json:"stored"`
	Verified     bool     `json:"verified"`
	VerifyError  string   `json:"verify_error,omitempty"`
	Models       []string `json:"models,omitempty"`
	PgDecrypt    string   `json:"pg_decrypt,omitempty"`    // 'ok' = the pg dispatcher can use this key
	ProviderLive bool     `json:"provider_live"`           // present in providers_loaded()
	SAKey        bool     `json:"sa_key,omitempty"`        // stored secret is a Google service-account JSON (verified by probing, not a bearer test)
}

// looksLikeServiceAccountJSON reports whether secret is a Google service-account
// key JSON — the shape the Rust dispatcher (gcp_sa) exchanges for an OAuth token.
// Mirrors extension gcp_sa::is_service_account_json: requires the three fields
// the mint uses. Such a key CANNOT be verified by a static-bearer GET /models
// (only the dispatcher mints the token), so test-on-save skips the bearer probe
// for it and points the operator at the model probe / test-chat instead.
func looksLikeServiceAccountJSON(secret string) bool {
	s := strings.TrimSpace(secret)
	if s == "" || s[0] != '{' {
		return false
	}
	var sa struct {
		ClientEmail string `json:"client_email"`
		PrivateKey  string `json:"private_key"`
		TokenURI    string `json:"token_uri"`
	}
	if json.Unmarshal([]byte(s), &sa) != nil {
		return false
	}
	return sa.ClientEmail != "" && sa.PrivateKey != "" && sa.TokenURI != ""
}

func (d *Deps) credentialSaveHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 40*time.Second)
	defer cancel()

	var req credentialSaveReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json: "+err.Error())
		return
	}
	req.Provider = strings.ToLower(strings.TrimSpace(req.Provider))
	if !providerNameRe.MatchString(req.Provider) {
		writeErr(w, http.StatusBadRequest, "provider must match ^[a-z0-9_]+$ (it becomes the substrate's provider id)")
		return
	}
	if req.Kind == "" {
		req.Kind = "openai"
	}
	if req.Kind != "openai" && req.Kind != "anthropic" {
		writeErr(w, http.StatusBadRequest, "kind must be openai or anthropic")
		return
	}

	// The wizard is useless without the master key — refuse loudly rather
	// than store anything less than ciphertext. (Dials-only saves for
	// keyless local providers are still allowed.)
	key, keyErr := wizardMasterKey()
	if req.Secret != "" && keyErr != nil {
		writeErr(w, http.StatusConflict, keyErr.Error())
		return
	}

	// Dials first (they're what test-on-save calls).
	if req.BaseURL != "" {
		if _, err := d.Pool.Exec(ctx,
			`SELECT stewards.provider_dials_set($1, $2, $3, nullif($4, ''))`,
			req.Provider, req.BaseURL, req.Kind, req.DefaultModel); err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
	}

	// Encrypt + store. One credential per provider by convention (the
	// schema allows more; the wizard keeps it simple: name = provider).
	credName := req.Provider
	stored := false
	if req.Secret != "" {
		blob, err := encryptSecret(key, req.Secret)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "encrypt: "+err.Error())
			return
		}
		if _, err := d.Pool.Exec(ctx,
			`SELECT stewards.credential_set($1, $2, $3, nullif($4, ''))`,
			credName, req.Provider, blob, req.Note); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		stored = true
	}

	// Budget (optional): $/day -> micro-dollars, enforced daily cap.
	if req.BudgetUSDDay != nil {
		if *req.BudgetUSDDay > 0 {
			capMicro := int64(math.Round(*req.BudgetUSDDay * 1_000_000))
			if _, err := d.Pool.Exec(ctx,
				`SELECT stewards.provider_budget_set($1, $2, 'daily')`,
				req.Provider, capMicro); err != nil {
				writeErr(w, http.StatusInternalServerError, err.Error())
				return
			}
		} else {
			if _, err := d.Pool.Exec(ctx,
				`SELECT stewards.provider_budget_set($1, NULL)`, req.Provider); err != nil {
				writeErr(w, http.StatusInternalServerError, err.Error())
				return
			}
		}
	}

	// Resolve what test-on-save should call: explicit dials, else whatever
	// the substrate now resolves for this provider (env or prior dials).
	baseURL, kind := req.BaseURL, req.Kind
	if baseURL == "" {
		row := d.Pool.QueryRow(ctx,
			`SELECT base_url, kind FROM stewards.providers_loaded() WHERE name = $1`,
			req.Provider)
		if err := row.Scan(&baseURL, &kind); err != nil || baseURL == "" {
			writeJSON(w, http.StatusOK, credentialSaveResp{
				Stored:      stored,
				Verified:    false,
				VerifyError: "no base_url known for this provider — supply one (or set STEWARDS_PROVIDER_" + strings.ToUpper(req.Provider) + "_BASE_URL)",
			})
			return
		}
	}

	// The probe key: the one just pasted, else the stored one (re-verify).
	probeKey := req.Secret
	if probeKey == "" && keyErr == nil {
		var blob []byte
		if err := d.Pool.QueryRow(ctx,
			`SELECT secret_encrypted FROM stewards.credentials WHERE name = $1`,
			credName).Scan(&blob); err == nil && len(blob) > 0 {
			if plain, err := decryptSecret(key, blob); err == nil {
				probeKey = plain
			}
		}
	}

	resp := credentialSaveResp{Stored: stored}

	// TEST-ON-SAVE — the live read-only probe. A Google service-account key is
	// the exception: it's not a static bearer, it must be exchanged for an OAuth
	// token, which only the Rust dispatcher does (gcp_sa). Sending the JSON as a
	// bearer would spuriously "fail" a perfectly good key — so for an SA JSON we
	// skip the bearer probe and let the operator confirm via the model probe /
	// test-chat, both of which run through the dispatcher that DOES mint.
	if looksLikeServiceAccountJSON(probeKey) {
		resp.SAKey = true
		resp.VerifyError = "service-account key stored & encrypted — verify by probing a model or using test-chat (the dispatcher mints the OAuth token; a static-key test doesn't apply)"
	} else {
		models, probeErr := probeProviderModels(ctx, baseURL, kind, probeKey)
		if probeErr != nil {
			resp.VerifyError = probeErr.Error()
		} else {
			resp.Verified = true
			resp.Models = models
			if stored {
				_, _ = d.Pool.Exec(ctx, `SELECT stewards.credential_mark_verified($1)`, credName)
			}
		}
	}

	// The honest pg-side half: can the DISPATCHER decrypt this, and does the
	// provider now show as loaded (which is what alias resolution gates on)?
	if stored {
		_ = d.Pool.QueryRow(ctx,
			`SELECT stewards.credential_decrypt_check($1)`, credName).Scan(&resp.PgDecrypt)
	}
	_ = d.Pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM stewards.providers_loaded() WHERE name = $1)`,
		req.Provider).Scan(&resp.ProviderLive)

	writeJSON(w, http.StatusOK, resp)
}

// DELETE /api/credentials/{name} — remove the stored key. ?purge=1 also
// removes the provider's dials and budget (the whole wizard-added provider).
func (d *Deps) credentialDeleteHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	name := r.PathValue("name")
	if !providerNameRe.MatchString(name) {
		writeErr(w, http.StatusBadRequest, "bad credential name")
		return
	}
	var deleted *bool
	_ = d.Pool.QueryRow(ctx, `SELECT stewards.credential_delete($1)`, name).Scan(&deleted)
	if r.URL.Query().Get("purge") == "1" {
		_, _ = d.Pool.Exec(ctx,
			`DELETE FROM stewards.config WHERE key LIKE 'provider.' || $1 || '.%'`, name)
		_, _ = d.Pool.Exec(ctx, `SELECT stewards.provider_budget_set($1, NULL)`, name)
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": deleted != nil && *deleted})
}

// GET /api/credentials/{name}/models — the wizard's "list usable models"
// step, re-run on demand: decrypt the stored key, live GET /models.
func (d *Deps) credentialModelsHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	name := r.PathValue("name")
	if !providerNameRe.MatchString(name) {
		writeErr(w, http.StatusBadRequest, "bad credential name")
		return
	}
	var baseURL, kind string
	if err := d.Pool.QueryRow(ctx,
		`SELECT base_url, kind FROM stewards.providers_loaded() WHERE name = $1`,
		name).Scan(&baseURL, &kind); err != nil {
		writeErr(w, http.StatusNotFound, "provider not loaded: "+name)
		return
	}
	apiKey := ""
	var blob []byte
	if err := d.Pool.QueryRow(ctx,
		`SELECT secret_encrypted FROM stewards.credentials WHERE name = $1`,
		name).Scan(&blob); err == nil && len(blob) > 0 {
		key, keyErr := wizardMasterKey()
		if keyErr != nil {
			writeErr(w, http.StatusConflict, keyErr.Error())
			return
		}
		plain, err := decryptSecret(key, blob)
		if err != nil {
			writeErr(w, http.StatusConflict, err.Error())
			return
		}
		apiKey = plain
	}
	// A Google service-account key can't list models via a bearer GET (the JSON
	// isn't a bearer — the dispatcher mints a token), and Vertex's OpenAI-compat
	// endpoint isn't a model catalog anyway: models are named explicitly
	// (google/gemini-…). Return empty + a note instead of a raw header error;
	// the wizard's "+ add model" is how you name one to probe.
	if looksLikeServiceAccountJSON(apiKey) {
		writeJSON(w, http.StatusOK, map[string]any{
			"models": []string{},
			"sa_key": true,
			"note":   "service-account provider — models aren't listable here; use “+ add model” to name one (e.g. google/gemini-3.5-flash), then probe",
		})
		return
	}
	models, err := probeProviderModels(ctx, baseURL, kind, apiKey)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	if len(blob) > 0 {
		_, _ = d.Pool.Exec(ctx, `SELECT stewards.credential_mark_verified($1)`, name)
	}
	writeJSON(w, http.StatusOK, map[string]any{"models": models})
}

// ---------------------------------------------------------------------------
// Wizard model verbs.
// ---------------------------------------------------------------------------

// POST /api/models/register — make a picked model dispatchable: a
// model_capability row (probed_via='manual', defaults usable+streaming) and,
// when prices are supplied, a model_pricing row so the budget math can SEE
// this model's spend (an unpriced model costs $0 on paper and slips any cap).
func (d *Deps) modelRegisterHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	var req struct {
		Provider           string `json:"provider"`
		Model              string `json:"model"`
		APIFormat          string `json:"api_format"` // openai (default) | anthropic
		InputMicroPerMtok  *int64 `json:"input_micro_per_mtok"`
		OutputMicroPerMtok *int64 `json:"output_micro_per_mtok"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Provider == "" || req.Model == "" {
		writeErr(w, http.StatusBadRequest, "provider and model are required")
		return
	}
	if req.APIFormat == "" {
		req.APIFormat = "openai"
	}
	if _, err := d.Pool.Exec(ctx, `
		INSERT INTO stewards.model_capability (provider, model, api_format, probed_via)
		VALUES ($1, $2, $3, 'manual')
		ON CONFLICT (provider, model) DO NOTHING`,
		req.Provider, req.Model, req.APIFormat); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	priced := false
	if req.InputMicroPerMtok != nil && req.OutputMicroPerMtok != nil {
		if _, err := d.Pool.Exec(ctx, `
			INSERT INTO stewards.model_pricing
			       (provider, model, input_micro_per_mtok, output_micro_per_mtok, effective_at, notes)
			VALUES ($1, $2, $3, $4, now(), 'set via the setup wizard')`,
			req.Provider, req.Model, *req.InputMicroPerMtok, *req.OutputMicroPerMtok); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		priced = true
	}
	var hasPricing bool
	_ = d.Pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM stewards.model_pricing WHERE provider = $1 AND model = $2)`,
		req.Provider, req.Model).Scan(&hasPricing)
	writeJSON(w, http.StatusOK, map[string]any{
		"registered": true, "priced_now": priced, "has_pricing": hasPricing,
	})
}

// POST /api/models/aliases — assign a role alias (reason/ingest/critic/vision
// or any logical name) to a provider+model member.
func (d *Deps) aliasSetHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	var req struct {
		Alias    string `json:"alias"`
		Provider string `json:"provider"`
		Model    string `json:"model"`
		Priority *int   `json:"priority"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		req.Alias == "" || req.Provider == "" || req.Model == "" {
		writeErr(w, http.StatusBadRequest, "alias, provider and model are required")
		return
	}
	prio := 0
	if req.Priority != nil {
		prio = *req.Priority
	}
	if _, err := d.Pool.Exec(ctx, `
		INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, notes)
		VALUES ($1, $2, $3, $4, 'set via the setup wizard')
		ON CONFLICT (alias, provider, provider_model)
		DO UPDATE SET priority = EXCLUDED.priority`,
		req.Alias, req.Provider, req.Model, prio); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// POST /api/models/aliases/delete — remove one alias member.
func (d *Deps) aliasDeleteHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	var req struct {
		Alias    string `json:"alias"`
		Provider string `json:"provider"`
		Model    string `json:"model"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		req.Alias == "" || req.Provider == "" || req.Model == "" {
		writeErr(w, http.StatusBadRequest, "alias, provider and model are required")
		return
	}
	ct, err := d.Pool.Exec(ctx, `
		DELETE FROM stewards.model_aliases
		 WHERE alias = $1 AND provider = $2 AND provider_model = $3`,
		req.Alias, req.Provider, req.Model)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": ct.RowsAffected() > 0})
}

// POST /api/models/aliases/enabled — the per-member toggle (95): flip a single
// (alias, provider, model)'s enabled flag. pick_alias_member (95) is the one
// resolver both dispatch (31) and runtime failover (32) share, so this is the
// whole mechanism — no re-dispatch, no restart, just a click.
func (d *Deps) aliasEnabledHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	var req struct {
		Alias    string `json:"alias"`
		Provider string `json:"provider"`
		Model    string `json:"model"`
		Enabled  bool   `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		req.Alias == "" || req.Provider == "" || req.Model == "" {
		writeErr(w, http.StatusBadRequest, "alias, provider and model are required")
		return
	}
	ct, err := d.Pool.Exec(ctx, `
		UPDATE stewards.model_aliases
		   SET enabled = $4
		 WHERE alias = $1 AND provider = $2 AND provider_model = $3`,
		req.Alias, req.Provider, req.Model, req.Enabled)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"updated": ct.RowsAffected() > 0})
}

// POST /api/models/aliases/priority — reorder one member within its role's
// try-chain. A thin wrapper over the UPDATE; the UI's up/down arrows swap two
// adjacent members' priorities with two calls.
func (d *Deps) aliasPriorityHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	var req struct {
		Alias    string `json:"alias"`
		Provider string `json:"provider"`
		Model    string `json:"model"`
		Priority int    `json:"priority"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		req.Alias == "" || req.Provider == "" || req.Model == "" {
		writeErr(w, http.StatusBadRequest, "alias, provider and model are required")
		return
	}
	ct, err := d.Pool.Exec(ctx, `
		UPDATE stewards.model_aliases
		   SET priority = $4
		 WHERE alias = $1 AND provider = $2 AND provider_model = $3`,
		req.Alias, req.Provider, req.Model, req.Priority)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"updated": ct.RowsAffected() > 0})
}

// POST /api/models/aliases/rest-local — Michael's pain point named verbatim:
// "I cant disable the local models we've enabled through lm studio or
// flexllama." One click rests (enabled=false) or wakes (enabled=true) every
// lm_studio/flexllama alias member across EVERY role at once —
// model_aliases_set_local_enabled (95) is the whole mechanism; this is a thin
// wrapper. Reversible (only flips a flag, never deletes), so no confirmation.
func (d *Deps) aliasRestLocalHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	var req struct {
		Enabled bool `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json: "+err.Error())
		return
	}
	var changed int
	if err := d.Pool.QueryRow(ctx,
		`SELECT stewards.model_aliases_set_local_enabled($1)`, req.Enabled).Scan(&changed); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"changed": changed, "enabled": req.Enabled})
}

// POST /api/models/probe — fire the substrate's real-path streaming probe
// (enqueue_model_probe: a tiny chat through the actual dispatch machinery;
// the terminal-transition trigger records the verdict in model_capability).
func (d *Deps) modelProbeHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	var req struct {
		Provider string `json:"provider"`
		Model    string `json:"model"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Provider == "" || req.Model == "" {
		writeErr(w, http.StatusBadRequest, "provider and model are required")
		return
	}
	var workID int64
	if err := d.Pool.QueryRow(ctx,
		`SELECT stewards.enqueue_model_probe($1, $2)`,
		req.Provider, req.Model).Scan(&workID); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"work_queue_id": workID})
}
