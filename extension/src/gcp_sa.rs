//! Google service-account → OAuth2 access token (synchronous, for the blocking
//! bgworker). Mints a self-signed RS256 JWT from a service-account key file,
//! exchanges it for a scoped access token at the SA's token endpoint, and caches
//! the token per provider until shortly before it expires.
//!
//! This is what lets the substrate talk to Vertex's OpenAI-compat endpoint
//! directly (no external proxy): a Vertex SA is OAuth (hourly-rotating token),
//! not a static api_key, so the `google_sa` provider auth mode fetches a fresh
//! bearer here instead of reading a fixed key from env.
//!
//! KEY SAFETY (non-negotiable): the private key, the signed JWT, and the access
//! token are NEVER logged, printed, or embedded in error strings. Errors carry
//! only the failing step + the provider/credentials *path*, never key material.

use crate::providers::http_client;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Vertex/Google APIs are reachable under the cloud-platform scope.
const SCOPE: &str = "https://www.googleapis.com/auth/cloud-platform";
/// Refresh this many seconds before the token actually expires, so an in-flight
/// request never races the expiry.
const REFRESH_SKEW_SECS: u64 = 300;
/// JWT lifetime (Google accepts up to 1h).
const JWT_TTL_SECS: u64 = 3600;

/// The fields we need out of a service-account JSON key file. Extra fields
/// (project_id, client_id, …) are ignored. We never hold these beyond the mint.
#[derive(Deserialize)]
struct ServiceAccount {
    client_email: String,
    private_key: String,
    token_uri: String,
    #[serde(default)]
    private_key_id: String,
}

/// The self-signed assertion claims (the SA "1-legged" OAuth flow).
#[derive(Serialize)]
struct Claims<'a> {
    iss: &'a str,
    scope: &'a str,
    aud: &'a str,
    iat: u64,
    exp: u64,
}

#[derive(Deserialize)]
struct TokenResp {
    access_token: String,
    expires_in: u64,
}

struct Cached {
    token: String,
    /// unix seconds when the token expires
    expires_at: u64,
}

/// provider_name -> cached token. Initialized lazily, shared across the worker.
static CACHE: OnceLock<Mutex<HashMap<String, Cached>>> = OnceLock::new();

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Return a valid bearer access token for `provider_name`, minting (and caching)
/// a fresh one from the service-account at `credentials_file` when none is cached
/// or the cached one is within the refresh skew of expiry.
pub(crate) fn token_for(provider_name: &str, credentials_file: &str) -> Result<String, String> {
    token_cached(provider_name, |now| mint(credentials_file, now))
}

/// As `token_for`, but the service-account key is JSON *content* (decrypted from
/// the credential store, never a file) — the wizard "drop the SA json" path.
/// Minted + cached per provider identically; the JSON is auth material and is
/// never logged.
pub(crate) fn token_for_json(
    provider_name: &str,
    credentials_json: &str,
) -> Result<String, String> {
    token_cached(provider_name, |now| mint_from_json(credentials_json, now))
}

/// True if `raw` is a Google service-account key JSON — the shape the
/// `GoogleSaJson` auth mode mints tokens from. Requires the three fields the
/// mint actually uses (client_email, private_key, token_uri) present and
/// non-empty, so a plain API-key string (or any other JSON) is never mistaken
/// for a service account. Never logs the content.
pub(crate) fn is_service_account_json(raw: &str) -> bool {
    match serde_json::from_str::<ServiceAccount>(raw) {
        Ok(sa) => {
            !sa.client_email.is_empty() && !sa.private_key.is_empty() && !sa.token_uri.is_empty()
        }
        Err(_) => false,
    }
}

/// Shared cache-or-mint core for the two `token_for*` entry points. `mint_fn`
/// does the network + crypto (called only on a cache miss, outside the lock).
fn token_cached<F>(provider_name: &str, mint_fn: F) -> Result<String, String>
where
    F: FnOnce(u64) -> Result<(String, u64), String>,
{
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let now = now_secs();

    // Fast path: a cached token that is still comfortably fresh.
    {
        let map = cache
            .lock()
            .map_err(|_| "gcp_sa: token cache lock poisoned".to_string())?;
        if let Some(c) = map.get(provider_name) {
            if c.expires_at > now + REFRESH_SKEW_SECS {
                return Ok(c.token.clone());
            }
        }
    }

    // Mint a fresh token (network + crypto) outside the lock.
    let (token, expires_at) = mint_fn(now)?;

    let mut map = cache
        .lock()
        .map_err(|_| "gcp_sa: token cache lock poisoned".to_string())?;
    map.insert(
        provider_name.to_string(),
        Cached {
            token: token.clone(),
            expires_at,
        },
    );
    Ok(token)
}

/// Read the SA file and mint from its contents. Returns (token, unix_expiry).
/// No key material is included in any error.
fn mint(credentials_file: &str, now: u64) -> Result<(String, u64), String> {
    let raw = std::fs::read_to_string(credentials_file).map_err(|e| {
        format!(
            "gcp_sa: cannot read credentials_file '{}': {}",
            credentials_file, e
        )
    })?;
    // The raw text (holding the PEM) is confined to mint_from_json's scope.
    mint_from_json(&raw, now)
}

/// Sign a JWT from the SA JSON and exchange it for an access token. Returns
/// (token, unix_expiry). No key material is included in any error. This is the
/// shared crypto+exchange core for both the file path (`mint`) and the stored-
/// JSON path (`token_for_json`).
fn mint_from_json(raw: &str, now: u64) -> Result<(String, u64), String> {
    // serde_json errors report position/field, not values — safe to surface.
    let sa: ServiceAccount =
        serde_json::from_str(raw).map_err(|e| format!("gcp_sa: malformed SA json: {}", e))?;

    let exp = now + JWT_TTL_SECS;
    let claims = Claims {
        iss: &sa.client_email,
        scope: SCOPE,
        aud: &sa.token_uri,
        iat: now,
        exp,
    };

    let mut header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256);
    if !sa.private_key_id.is_empty() {
        header.kid = Some(sa.private_key_id.clone());
    }
    let key = jsonwebtoken::EncodingKey::from_rsa_pem(sa.private_key.as_bytes())
        .map_err(|e| format!("gcp_sa: invalid SA private key: {}", e))?;
    let assertion = jsonwebtoken::encode(&header, &claims, &key)
        .map_err(|e| format!("gcp_sa: jwt sign failed: {}", e))?;

    let client = http_client();
    let resp = client
        .post(&sa.token_uri)
        .timeout(std::time::Duration::from_secs(20))
        .form(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            ("assertion", assertion.as_str()),
        ])
        .send()
        .map_err(|e| format!("gcp_sa: token request to {}: {}", sa.token_uri, e))?;

    let status = resp.status();
    if !status.is_success() {
        // The body is an OAuth error description (e.g. invalid_grant) — no secret,
        // but cap it so a stray response can't bloat the log.
        let body = resp.text().unwrap_or_default();
        let body = body.chars().take(300).collect::<String>();
        return Err(format!("gcp_sa: token endpoint HTTP {}: {}", status, body));
    }

    let tr: TokenResp = resp
        .json()
        .map_err(|e| format!("gcp_sa: parse token response: {}", e))?;
    Ok((tr.access_token, now + tr.expires_in))
}
