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
