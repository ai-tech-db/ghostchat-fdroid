//! Adapter `reqwest::dns::Resolve` per `hickory_resolver::TokioAsyncResolver`.
//!
//! Permette a `reqwest` di usare un resolver DNS custom (DoH, DoT, ecc.)
//! invece del resolver di sistema. Necessario su Android/EMUI 10 dove il
//! resolver di sistema non risolve `api.trycloudflare.com`.
//!
//! Uso:
//!
//! ```ignore
//! let resolver = build_doh_resolver().await?;
//! let client = reqwest::Client::builder()
//!     .dns_resolver(std::sync::Arc::new(HickoryDnsAdapter::new(resolver)))
//!     .build()?;
//! ```

use std::net::SocketAddr;
use std::sync::Arc;


use hickory_resolver::TokioAsyncResolver;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};

/// Adapter che implementa `reqwest::dns::Resolve` per un
/// `hickory_resolver::TokioAsyncResolver`.
///
/// `reqwest` chiamerà `resolve()` per ogni hostname che deve risolvere.
/// Noi deleghiamo a hickory, che usa DoH (o DoT, o UDP, a seconda di
/// come è configurato il resolver).
pub struct HickoryDnsAdapter {
    resolver: Arc<TokioAsyncResolver>,
}

impl HickoryDnsAdapter {
    pub fn new(resolver: TokioAsyncResolver) -> Self {
        Self {
            resolver: Arc::new(resolver),
        }
    }

    pub fn from_arc(resolver: Arc<TokioAsyncResolver>) -> Self {
        Self { resolver }
    }
}

impl Resolve for HickoryDnsAdapter {
    fn resolve(&self, name: Name) -> Resolving {
        let resolver = self.resolver.clone();
        let hostname = name.as_str().to_string();

        Box::pin(async move {
            let lookup = resolver.lookup_ip(hostname.as_str()).await?;
            let addrs: Vec<SocketAddr> = lookup
                .iter()
                .map(|ip| SocketAddr::new(ip, 0))
                .collect();
            let addrs: Addrs = Box::new(addrs.into_iter());
            Ok(addrs)
        })
    }
}

/// Alias per compatibilità: alcuni esempi chiamano questo tipo
/// `DnsAdapter`.
pub type DnsAdapter = HickoryDnsAdapter;
