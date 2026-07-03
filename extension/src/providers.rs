//! Provider registry — env-var bootstrap, in-process only.
//!
//! Reads `STEWARDS_PROVIDER_<NAME>_<FIELD>` env vars at postmaster
//! startup and exposes the parsed registry to the bgworker via the
//! `PROVIDER_REGISTRY` `OnceLock`. Also holds the external-resource
//! resolver config in its own `OnceLock`.
//!
//! Extracted from lib.rs (Phase 3c.3.6 module split, 2026-05-08).
//! Items kept `pub(crate)` so the bgworker + dispatch helpers can
//! read them, but not exposed beyond the crate.

use std::sync::OnceLock;

/// The shared blocking reqwest `Client`, built once per bgworker process and
/// reused across every outbound call (chat, embeddings, the resource resolver,
/// the generic `http` tool target, GCP SA token minting). A fresh
/// `Client::builder().build()` per call — the pre-audit shape — pays a new
/// TCP/TLS handshake (and, for HTTP/2, a new connection) every single time;
/// reusing one `Client` gives connection pooling / keep-alive for free.
///
/// No client-level timeout is set here on purpose: every call site's timeout
/// differs (embeddings 120s, chat up to `STEWARDS_CHAT_TIMEOUT_SECONDS`, GCP SA
/// mint 20s, the resolver 30s, the generic http tool 60s). Apply the timeout
/// per request via `RequestBuilder::timeout(..)` — it overrides any client
/// default, so a shared client with no default and per-call timeouts is
/// behaviorally identical to today's per-call `Client::builder().timeout(..)`,
/// minus the rebuilt connection.
static HTTP_CLIENT: OnceLock<reqwest::blocking::Client> = OnceLock::new();

/// The shared blocking HTTP client (see `HTTP_CLIENT`). Callers set their own
/// per-request timeout via `RequestBuilder::timeout(..)`.
///
/// `.build()` with no client-level config is infallible in practice — it only
/// errors if the TLS backend can't initialize or the system proxy config can't
/// load, the same failure mode `reqwest::blocking::Client::new()` treats as
/// fatal (it `.expect()`s internally). Matching that convention rather than
/// threading a `Result` through every call site that only ever handled the
/// "can't happen once TLS works" case anyway.
pub(crate) fn http_client() -> &'static reqwest::blocking::Client {
    HTTP_CLIENT.get_or_init(|| {
        reqwest::blocking::Client::builder()
            .build()
            .expect("reqwest::blocking::Client::builder().build() with no client-level config \
                     (TLS backend / system proxy config init failed — same fatal condition \
                     reqwest::blocking::Client::new() panics on)")
    })
}

/// Snapshot of one provider's metadata, minus the secret. Returned
/// from `stewards.providers_loaded()`.
#[derive(Clone, Debug)]
pub(crate) struct ProviderSummary {
    pub(crate) name: String,
    pub(crate) base_url: String,
    pub(crate) default_model: String,
    pub(crate) kind: String,
    pub(crate) has_api_key: bool,
}

/// How a provider authenticates each request.
#[derive(Clone, Debug)]
pub(crate) enum AuthMode {
    /// Static bearer (OpenAI) / x-api-key (Anthropic) from the env API_KEY, or
    /// none when API_KEY is unset.
    ApiKey,
    /// Google service-account: mint + refresh a Vertex OAuth access token from
    /// the SA key file at this path (gcp_sa.rs). No static key lives in env.
    GoogleSa { credentials_file: String },
}

#[derive(Clone, Debug)]
pub(crate) struct Provider {
    pub(crate) name: String,
    pub(crate) base_url: String,
    pub(crate) default_model: String,
    pub(crate) kind: String,
    pub(crate) api_key: Option<String>,
    pub(crate) auth: AuthMode,
}

impl Provider {
    /// The bearer token to send (Authorization: Bearer …), or None for an
    /// unauthenticated provider. GoogleSa mints/refreshes a Vertex token;
    /// ApiKey returns the static env key. Never logs the secret.
    pub(crate) fn bearer_token(&self) -> Result<Option<String>, String> {
        match &self.auth {
            AuthMode::GoogleSa { credentials_file } => {
                crate::gcp_sa::token_for(&self.name, credentials_file).map(Some)
            }
            AuthMode::ApiKey => Ok(self.api_key.clone()),
        }
    }

    /// Short auth label for logs (never the secret).
    pub(crate) fn auth_label(&self) -> &'static str {
        match &self.auth {
            AuthMode::GoogleSa { .. } => "google_sa",
            AuthMode::ApiKey => "api_key",
        }
    }
}

#[derive(Default, Debug)]
pub(crate) struct ProviderRegistry {
    pub(crate) providers: Vec<Provider>,
}

impl ProviderRegistry {
    /// Parse `STEWARDS_PROVIDER_<NAME>_<FIELD>` env vars into a
    /// registry. Lossy by design: malformed entries are skipped with
    /// a warning rather than aborting the worker.
    pub(crate) fn from_env() -> Self {
        use std::collections::BTreeMap;

        let mut by_name: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();

        for (key, value) in std::env::vars() {
            let Some(rest) = key.strip_prefix("STEWARDS_PROVIDER_") else {
                continue;
            };
            // rest = "<NAME>_<FIELD>", where FIELD is one of
            // BASE_URL | API_KEY | DEFAULT_MODEL | KIND
            let Some((name, field)) = split_provider_key(rest) else {
                continue;
            };
            by_name.entry(name).or_default().insert(field, value);
        }

        let mut providers = Vec::with_capacity(by_name.len());
        for (name_upper, fields) in by_name {
            let Some(base_url) = fields.get("BASE_URL").cloned() else {
                pgrx::log!(
                    "stewards: provider '{}' missing BASE_URL, skipping",
                    name_upper
                );
                continue;
            };
            let auth = match fields.get("AUTH").map(|s| s.to_lowercase()).as_deref() {
                Some("google_sa") => match fields
                    .get("CREDENTIALS_FILE")
                    .cloned()
                    .filter(|s| !s.is_empty())
                {
                    Some(credentials_file) => AuthMode::GoogleSa { credentials_file },
                    None => {
                        pgrx::log!(
                            "stewards: provider '{}' AUTH=google_sa but CREDENTIALS_FILE missing — using api_key",
                            name_upper
                        );
                        AuthMode::ApiKey
                    }
                },
                _ => AuthMode::ApiKey,
            };
            providers.push(Provider {
                name: name_upper.to_lowercase(),
                base_url,
                default_model: fields.get("DEFAULT_MODEL").cloned().unwrap_or_default(),
                kind: fields
                    .get("KIND")
                    .cloned()
                    .unwrap_or_else(|| "openai".to_string()),
                api_key: fields.get("API_KEY").cloned().filter(|s| !s.is_empty()),
                auth,
            });
        }

        Self { providers }
    }

    pub(crate) fn summary(&self) -> Vec<ProviderSummary> {
        self.providers
            .iter()
            .map(|p| ProviderSummary {
                name: p.name.clone(),
                base_url: p.base_url.clone(),
                default_model: p.default_model.clone(),
                kind: p.kind.clone(),
                has_api_key: p.api_key.is_some(),
            })
            .collect()
    }
}

/// Parse `<NAME>_<FIELD>` where FIELD is one of the four known suffixes.
fn split_provider_key(rest: &str) -> Option<(String, String)> {
    const FIELDS: &[&str] = &[
        "BASE_URL",
        "API_KEY",
        "DEFAULT_MODEL",
        "KIND",
        "AUTH",
        "CREDENTIALS_FILE",
    ];
    for field in FIELDS {
        if let Some(stripped) = rest.strip_suffix(field) {
            if let Some(name) = stripped.strip_suffix('_') {
                if !name.is_empty() {
                    return Some((name.to_string(), field.to_string()));
                }
            }
        }
    }
    None
}

/// Lazily initialized once per bgworker process. Worker reads env on
/// startup and never reloads.
pub(crate) static PROVIDER_REGISTRY: OnceLock<ProviderRegistry> = OnceLock::new();

/// External-resource resolver config. Read once from env at postmaster
/// startup: `STEWARDS_RESOLVER_URL` is a URL template — a `{ref}`
/// placeholder is substituted with the url-encoded reference (if the
/// template has no `{ref}`, the encoded ref is appended). The optional
/// `STEWARDS_RESOLVER_TOKEN` is sent as a bearer token. Both Optional so
/// the resolver fails gracefully if env is unset (returns
/// "STEWARDS_RESOLVER_URL not set", stored in resolved_refs.error and
/// visible to callers). Generic on purpose — point it at any HTTP
/// endpoint that resolves a reference string to a JSON document.
#[derive(Debug, Clone, Default)]
pub(crate) struct ResolverConfig {
    pub(crate) url: Option<String>,
    pub(crate) token: Option<String>,
}
pub(crate) static RESOLVER_CONFIG: OnceLock<ResolverConfig> = OnceLock::new();

// ---------------------------------------------------------------------------
// 88: the DB credential overlay — wizard-added providers, live at dispatch.
//
// The env registry above is parsed once at postmaster boot and never reloads,
// which is exactly the first-run wall #256 tears down. The overlay reads
// `stewards.credential_providers` (dials from stewards.config + the newest
// AES-256-GCM ciphertext from stewards.credentials) at RESOLVE time, so a key
// saved in the cockpit is dispatchable the moment the row commits — no
// rebuild, no restart. The master key is env (STEWARDS_MASTER_KEY, 32 bytes
// base64) read once per process; the same .env feeds the Go cockpit that
// encrypts, so the two sides agree by construction.
//
// Precedence: a DB row WINS over an env provider of the same name (a rotated
// key in the wizard must beat a stale key in .env). A credential-only row
// (no dials) merges the DB key over the env base_url/kind — the rotation
// case. Secrets never leave this module: callers get a `Provider` whose
// api_key is already in memory the same way the env path's always was.
//
// All *_spi functions REQUIRE an SPI-legal context: a backend pg_extern, or
// the bgworker inside BackgroundWorker::transaction.
// ---------------------------------------------------------------------------

/// One row of stewards.credential_providers.
pub(crate) struct DbProviderRow {
    pub(crate) provider: String,
    pub(crate) base_url: Option<String>,
    pub(crate) kind: String,
    pub(crate) default_model: String,
    pub(crate) secret_encrypted: Option<Vec<u8>>,
}

/// STEWARDS_MASTER_KEY, parsed once per process. None = unset or malformed
/// (malformed logs once here; the wizard endpoints surface it to the human).
pub(crate) fn master_key() -> Option<[u8; 32]> {
    static MASTER_KEY: OnceLock<Option<[u8; 32]>> = OnceLock::new();
    *MASTER_KEY.get_or_init(|| {
        let raw = match std::env::var("STEWARDS_MASTER_KEY") {
            Ok(v) => v,
            Err(_) => return None,
        };
        let raw = raw.trim();
        if raw.is_empty() {
            return None;
        }
        use base64::Engine as _;
        let bytes = match base64::engine::general_purpose::STANDARD.decode(raw) {
            Ok(b) => b,
            Err(e) => {
                pgrx::log!("stewards: STEWARDS_MASTER_KEY is not valid base64: {}", e);
                return None;
            }
        };
        if bytes.len() != 32 {
            pgrx::log!(
                "stewards: STEWARDS_MASTER_KEY must decode to 32 bytes (got {})",
                bytes.len()
            );
            return None;
        }
        let mut k = [0u8; 32];
        k.copy_from_slice(&bytes);
        Some(k)
    })
}

/// Decrypt one stored credential: AES-256-GCM, layout nonce(12) || ct || tag.
/// (The Go cockpit writes exactly this via gcm.Seal(nonce, nonce, key, nil).)
/// Returns the plaintext key — callers put it straight into Provider.api_key
/// and never log it.
pub(crate) fn decrypt_secret(ciphertext: &[u8]) -> Result<String, String> {
    let key = master_key().ok_or_else(|| {
        "STEWARDS_MASTER_KEY is not set (or not 32 bytes of base64) in the Postgres environment"
            .to_string()
    })?;
    if ciphertext.len() < 13 {
        return Err("credential ciphertext too short (expect 12-byte nonce + data)".to_string());
    }
    use aes_gcm::aead::{Aead, KeyInit};
    let cipher = aes_gcm::Aes256Gcm::new_from_slice(&key)
        .map_err(|e| format!("cipher init: {}", e))?;
    let nonce = aes_gcm::Nonce::from_slice(&ciphertext[..12]);
    let plain = cipher.decrypt(nonce, &ciphertext[12..]).map_err(|_| {
        "credential decrypt failed — STEWARDS_MASTER_KEY does not match the key that encrypted this credential"
            .to_string()
    })?;
    String::from_utf8(plain).map_err(|_| "decrypted credential is not utf-8".to_string())
}

/// Read credential_providers rows (all, or one by name). SPI context required.
/// The to_regclass guard keeps this a clean no-op on a database whose chain
/// predates 88 (the view simply isn't there yet) instead of an SPI error.
pub(crate) fn db_provider_rows_spi(name: Option<&str>) -> Result<Vec<DbProviderRow>, String> {
    let result: Result<Vec<DbProviderRow>, pgrx::spi::Error> = pgrx::Spi::connect(|client| {
        let guard = client.select(
            "SELECT (to_regclass('stewards.credential_providers') IS NOT NULL) AS ok",
            Some(1),
            &[],
        )?;
        let exists = guard
            .into_iter()
            .next()
            .and_then(|r| r.get::<bool>(1).ok().flatten())
            .unwrap_or(false);
        if !exists {
            return Ok(Vec::new());
        }
        let rows = match name {
            Some(n) => client.select(
                "SELECT provider, base_url, kind, default_model, secret_encrypted \
                 FROM stewards.credential_providers WHERE provider = $1",
                None,
                &[n.to_string().into()],
            )?,
            None => client.select(
                "SELECT provider, base_url, kind, default_model, secret_encrypted \
                 FROM stewards.credential_providers",
                None,
                &[],
            )?,
        };
        Ok(rows
            .into_iter()
            .filter_map(|r| {
                let provider: String = r.get(1).ok()??;
                let base_url: Option<String> = r.get(2).ok().flatten();
                let kind: String = r.get::<String>(3).ok().flatten().unwrap_or_else(|| "openai".to_string());
                let default_model: String = r.get::<String>(4).ok().flatten().unwrap_or_default();
                let secret_encrypted: Option<Vec<u8>> = r.get::<Vec<u8>>(5).ok().flatten();
                Some(DbProviderRow {
                    provider,
                    base_url,
                    kind,
                    default_model,
                    secret_encrypted,
                })
            })
            .collect())
    });
    result.map_err(|e| format!("read credential_providers: {}", e))
}

/// Merge a DB row over the env entry of the same name into a dispatchable
/// Provider. Dials: DB wins when it HAS dials; a credential-only row takes
/// the env dials (key rotation). Key: decrypted DB secret wins; with no
/// master key in this process, fall back to the env key (loud in the log)
/// rather than silently dropping auth.
fn merge_row(row: DbProviderRow, env: Option<Provider>) -> Result<Option<Provider>, String> {
    let (base_url, kind, default_model) = if let Some(url) = row.base_url.clone() {
        (url, row.kind.clone(), row.default_model.clone())
    } else if let Some(e) = &env {
        (e.base_url.clone(), e.kind.clone(), e.default_model.clone())
    } else {
        // A credential with no dials and no env provider — nothing to call.
        return Err(format!(
            "provider '{}' has a stored credential but no base_url: add dials via provider_dials_set (or the wizard), or define STEWARDS_PROVIDER_{}_BASE_URL",
            row.provider,
            row.provider.to_uppercase()
        ));
    };
    let api_key = match &row.secret_encrypted {
        Some(ct) if master_key().is_some() => Some(decrypt_secret(ct)?),
        Some(_) => {
            pgrx::log!(
                "stewards: provider '{}' has a stored credential but STEWARDS_MASTER_KEY is not set in the Postgres environment — falling back to the env key (if any)",
                row.provider
            );
            env.as_ref().and_then(|e| e.api_key.clone())
        }
        None => env.as_ref().and_then(|e| e.api_key.clone()),
    };
    Ok(Some(Provider {
        name: row.provider,
        base_url,
        default_model,
        kind,
        api_key,
        // DB providers always auth by static key (or keyless). google_sa
        // stays env-only — its secret is a key FILE, not a string.
        auth: AuthMode::ApiKey,
    }))
}

/// Resolve one provider through the DB overlay. Ok(None) = no DB row (caller
/// falls back to the env registry). Err = a DB row exists but is unusable
/// (bad ciphertext / missing dials) — loud and actionable beats a silent
/// fallback to a key the operator just tried to replace. SPI context required.
pub(crate) fn merged_provider_spi(name: &str) -> Result<Option<Provider>, String> {
    let mut rows = db_provider_rows_spi(Some(name))?;
    let Some(row) = rows.pop() else {
        return Ok(None);
    };
    let env = PROVIDER_REGISTRY
        .get()
        .and_then(|r| r.providers.iter().find(|p| p.name == name).cloned());
    merge_row(row, env)
}

/// The union providers_loaded() reports: DB overlay rows first (they win on
/// name collision), then env providers the overlay doesn't shadow. Secrets
/// are never touched — has_api_key is computed from PRESENCE (a stored
/// ciphertext counts only when this process holds the master key to use it).
/// SPI context required.
pub(crate) fn merged_summaries_spi() -> Vec<ProviderSummary> {
    let env: Vec<Provider> = PROVIDER_REGISTRY
        .get()
        .map(|r| r.providers.clone())
        .unwrap_or_default();
    let db_rows = match db_provider_rows_spi(None) {
        Ok(rows) => rows,
        Err(e) => {
            pgrx::log!("stewards: providers_loaded overlay read failed: {}", e);
            Vec::new()
        }
    };
    let mut out: Vec<ProviderSummary> = Vec::with_capacity(env.len() + db_rows.len());
    for row in &db_rows {
        let env_match = env.iter().find(|p| p.name == row.provider);
        let base_url = row
            .base_url
            .clone()
            .or_else(|| env_match.map(|p| p.base_url.clone()));
        let Some(base_url) = base_url else {
            continue; // credential without dials or env — not dispatchable, not "loaded"
        };
        let has_db_key = row.secret_encrypted.is_some() && master_key().is_some();
        let has_env_key = env_match.map(|p| p.api_key.is_some()).unwrap_or(false);
        out.push(ProviderSummary {
            name: row.provider.clone(),
            base_url,
            default_model: if row.default_model.is_empty() {
                env_match
                    .map(|p| p.default_model.clone())
                    .unwrap_or_default()
            } else {
                row.default_model.clone()
            },
            kind: if row.base_url.is_some() {
                row.kind.clone()
            } else {
                env_match
                    .map(|p| p.kind.clone())
                    .unwrap_or_else(|| row.kind.clone())
            },
            has_api_key: has_db_key || has_env_key,
        });
    }
    for p in &env {
        if db_rows.iter().any(|r| r.provider == p.name) {
            continue; // shadowed by the overlay row already emitted
        }
        out.push(ProviderSummary {
            name: p.name.clone(),
            base_url: p.base_url.clone(),
            default_model: p.default_model.clone(),
            kind: p.kind.clone(),
            // Matches the pre-88 summary(): google_sa deliberately reports
            // has_api_key=false (documented in wiring-up-models.md).
            has_api_key: p.api_key.is_some(),
        });
    }
    out
}
