//! POST `/tunnel` client for `api.trycloudflare.com`.
//!
//! Returns the credentials the edge expects on the subsequent
//! `RegisterConnection` RPC: a UUID-shaped `id`, the public
//! `hostname` (`<sub>.trycloudflare.com`), the `account_tag` to
//! quote on RPC, and 32 random bytes of `secret` that double as the
//! `TunnelSecret` in the auth blob.
//!
//! Mirrors `cmd/cloudflared/tunnel/quick_tunnel.go` upstream.
//!
//! **Fork patch**: `build_client_with_dot()` crea un `reqwest::Client`
//! che usa DoH (via hickory) invece del resolver di sistema. Necessario
//! su Android/EMUI 10 dove `api.trycloudflare.com` non si risolve.

use std::sync::Arc;
use std::time::Duration;

use hickory_resolver::config::{
    NameServerConfig, NameServerConfigGroup, Protocol, ResolverConfig, ResolverOpts,
};
use hickory_resolver::TokioAsyncResolver;
use serde::Deserialize;
use tokio::time::sleep;
use tracing::{debug, warn};

use crate::dns_adapter::HickoryDnsAdapter;
use crate::error::{QuickTunnelApiError, TunnelError};

/// Public-facing JSON envelope returned by `POST /tunnel`.
#[derive(Debug, Deserialize)]
pub struct QuickTunnelResponse {
    pub success: bool,
    #[serde(default)]
    pub result: Option<QuickTunnel>,
    #[serde(default)]
    pub errors: Vec<QuickTunnelApiError>,
}

/// The bits the QUIC + capnp-RPC dance needs.
#[derive(Debug, Deserialize)]
pub struct QuickTunnel {
    pub id: String,
    pub name: String,
    pub hostname: String,
    pub account_tag: String,
    #[serde(with = "serde_bytes_b64")]
    pub secret: Vec<u8>,
}

/// Default endpoint (the public trycloudflare API).
pub const DEFAULT_SERVICE_URL: &str = "https://api.trycloudflare.com";

/// User-Agent we send.
pub const DEFAULT_USER_AGENT: &str = "cloudflared/2024.12.0";

/// HTTP-level deadline for the POST.
pub const DEFAULT_HTTP_TIMEOUT: Duration = Duration::from_secs(15);

/// How many times to retry on transient 5xx / network errors.
pub const MAX_RETRIES: u32 = 3;

/// DoH servers we try (Cloudflare, Google, Quad9).
pub const DOH_SERVERS: &[&str] = &[
    "1.1.1.1:443",
    "1.0.0.1:443",
    "8.8.8.8:443",
    "8.8.4.4:443",
    "9.9.9.9:443",
];

/// Build a `reqwest::Client` that uses a custom DoH resolver.
///
/// **Fork patch**: on Android/EMUI 10, the system resolver does not
/// resolve `api.trycloudflare.com` (OEM DNS filter). This function
/// creates a `hickory_resolver::TokioAsyncResolver` configured with
/// DoH over HTTPS, and passes it to `reqwest` via
/// `HickoryDnsAdapter`. Requires the `webpki-roots` feature on
/// `hickory-resolver` so the DoH TLS handshake works without
/// `/etc/ssl/certs/ca-certificates.crt` (which is missing on Android).
pub async fn build_client_with_dot(user_agent: &str) -> Result<reqwest::Client, TunnelError> {
    // Costruisci la lista di name server DoH
    let mut ns_group = NameServerConfigGroup::new();
    for s in DOH_SERVERS {
        if let Ok(addr) = s.parse::<std::net::SocketAddr>() {
            ns_group.push(NameServerConfig {
                socket_addr: addr,
                protocol: Protocol::Https,
                tls_dns_name: Some("cloudflare-dns.com".to_string()),
                bind_addr: None,
                trust_negative_responses: false,
                tls_config: None,
            });
        }
    }

    let resolver_config = ResolverConfig::from_parts(None, vec![], ns_group);
    let mut opts = ResolverOpts::default();
    opts.timeout = Duration::from_secs(10);
    opts.attempts = 2;

    let resolver = TokioAsyncResolver::tokio(resolver_config, opts);
    let adapter = HickoryDnsAdapter::from_arc(Arc::new(resolver));

    let client = reqwest::Client::builder()
        .user_agent(user_agent)
        .timeout(DEFAULT_HTTP_TIMEOUT)
        .dns_resolver(Arc::new(adapter))
        .build()
        .map_err(TunnelError::Api)?;

    Ok(client)
}

/// Fetch a fresh quick-tunnel handshake.
///
/// **Fork patch**: uses `build_client_with_dot()` instead of the
/// default `reqwest::Client::builder()`, so DNS resolution goes
/// through DoH.
pub async fn request_tunnel(
    service_url: &str,
    user_agent: &str,
) -> Result<QuickTunnel, TunnelError> {
    let url = format!("{}/tunnel", service_url.trim_end_matches('/'));
    let client = build_client_with_dot(user_agent).await?;

    let mut backoff = Duration::from_secs(1);
    let mut last_err: Option<TunnelError> = None;

    for attempt in 0..=MAX_RETRIES {
        debug!(attempt, %url, "POST /tunnel");
        match try_once(&client, &url).await {
            Ok(tunnel) => return Ok(tunnel),
            Err(err) => {
                if !err.is_transient() || attempt == MAX_RETRIES {
                    return Err(err);
                }
                warn!(
                    attempt,
                    error = %err,
                    backoff_ms = backoff.as_millis() as u64,
                    "POST /tunnel transient failure; retrying"
                );
                last_err = Some(err);
                sleep(backoff).await;
                backoff = backoff.saturating_mul(2);
            }
        }
    }
    Err(last_err.unwrap_or_else(|| {
        TunnelError::Internal("request_tunnel: retry loop fell through without an error".into())
    }))
}

async fn try_once(client: &reqwest::Client, url: &str) -> Result<QuickTunnel, TunnelError> {
    let resp = client
        .post(url)
        .header("Content-Type", "application/json")
        .send()
        .await?;

    let status = resp.status();
    let body = resp.bytes().await?;

    if status.is_server_error() && !looks_like_json(&body) {
        let snippet_len = 200usize.min(body.len());
        let body_snippet = String::from_utf8_lossy(&body[..snippet_len]).into_owned();
        return Err(TunnelError::ApiNonJson {
            status: status.as_u16(),
            body_snippet,
        });
    }

    if !looks_like_json(&body) {
        let snippet_len = 200usize.min(body.len());
        let body_snippet = String::from_utf8_lossy(&body[..snippet_len]).into_owned();
        return Err(TunnelError::ApiNonJson {
            status: status.as_u16(),
            body_snippet,
        });
    }

    let envelope: QuickTunnelResponse = serde_json::from_slice(&body)
        .map_err(|e| TunnelError::Internal(format!("malformed JSON from /tunnel: {e}")))?;

    if !envelope.success {
        return Err(TunnelError::ApiBusiness(envelope.errors));
    }

    envelope.result.ok_or_else(|| {
        TunnelError::Internal("POST /tunnel returned success=true but no `result` body".into())
    })
}

fn looks_like_json(body: &[u8]) -> bool {
    body.iter()
        .find(|b| !b.is_ascii_whitespace())
        .is_some_and(|b| *b == b'{' || *b == b'[')
}

mod serde_bytes_b64 {
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;
    use serde::{Deserialize, Deserializer};

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s: String = Deserialize::deserialize(d)?;
        STANDARD.decode(s).map_err(serde::de::Error::custom)
    }
}

impl TunnelError {
    pub(crate) fn is_transient(&self) -> bool {
        match self {
            TunnelError::Api(e) => {
                e.is_timeout()
                    || e.is_connect()
                    || e.is_request()
                    || e.status().is_some_and(|s| s.is_server_error())
            }
            TunnelError::ApiNonJson { status, .. } => (500..600).contains(status),
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn sample_ok_body() -> serde_json::Value {
        serde_json::json!({
            "success": true,
            "result": {
                "id": "8f6d3c2a-1111-4d2e-9b9b-aaaaaaaaaaaa",
                "name": "quick-tunnel-abc",
                "hostname": "abc-123.trycloudflare.com",
                "account_tag": "deadbeefcafef00d",
                "secret": "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
            },
            "errors": []
        })
    }

    #[tokio::test]
    async fn happy_path_parses_credentials() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/tunnel"))
            .and(header("Content-Type", "application/json"))
            .respond_with(ResponseTemplate::new(200).set_body_json(sample_ok_body()))
            .expect(1)
            .mount(&server)
            .await;

        let t = request_tunnel(&server.uri(), DEFAULT_USER_AGENT)
            .await
            .expect("happy path");
        assert_eq!(t.hostname, "abc-123.trycloudflare.com");
        assert_eq!(t.account_tag, "deadbeefcafef00d");
        assert_eq!(t.secret.len(), 32);
        assert_eq!(t.secret[0..4], [1, 2, 3, 4]);
    }

    #[tokio::test]
    async fn business_error_does_not_retry() {
        let server = MockServer::start().await;
        let body = serde_json::json!({
            "success": false,
            "errors": [{ "code": 1003, "message": "tunnel quota exceeded" }]
        });
        Mock::given(method("POST"))
            .and(path("/tunnel"))
            .respond_with(ResponseTemplate::new(200).set_body_json(body))
            .expect(1)
            .mount(&server)
            .await;

        let err = request_tunnel(&server.uri(), DEFAULT_USER_AGENT)
            .await
            .expect_err("should fail");
        match err {
            TunnelError::ApiBusiness(errs) => {
                assert_eq!(errs.len(), 1);
                assert_eq!(errs[0].code, 1003);
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[tokio::test]
    async fn html_body_surfaces_snippet() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/tunnel"))
            .respond_with(
                ResponseTemplate::new(429)
                    .set_body_string("<html><body>rate limited</body></html>"),
            )
            .expect(1)
            .mount(&server)
            .await;

        let err = request_tunnel(&server.uri(), DEFAULT_USER_AGENT)
            .await
            .expect_err("should fail");
        match err {
            TunnelError::ApiNonJson {
                status,
                body_snippet,
            } => {
                assert_eq!(status, 429);
                assert!(body_snippet.contains("rate limited"));
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[tokio::test]
    async fn five_xx_retries_then_succeeds() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/tunnel"))
            .respond_with(ResponseTemplate::new(503).set_body_string("service unavailable"))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/tunnel"))
            .respond_with(ResponseTemplate::new(200).set_body_json(sample_ok_body()))
            .expect(1)
            .mount(&server)
            .await;

        let t = request_tunnel(&server.uri(), DEFAULT_USER_AGENT)
            .await
            .expect("retry should succeed");
        assert_eq!(t.hostname, "abc-123.trycloudflare.com");
    }

    #[tokio::test]
    async fn four_xx_does_not_retry() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/tunnel"))
            .respond_with(ResponseTemplate::new(400).set_body_json(serde_json::json!({
                "success": false,
                "errors": [{ "code": 400, "message": "bad request" }]
            })))
            .expect(1)
            .mount(&server)
            .await;

        let err = request_tunnel(&server.uri(), DEFAULT_USER_AGENT)
            .await
            .expect_err("should fail");
        assert!(matches!(err, TunnelError::ApiBusiness(_)));
    }

    #[test]
    fn looks_like_json_handles_leading_whitespace() {
        assert!(looks_like_json(b"  \n  {"));
        assert!(looks_like_json(b"["));
        assert!(!looks_like_json(b"<html>"));
        assert!(!looks_like_json(b""));
    }
}
