use std::net::{IpAddr, SocketAddr};
use std::str::FromStr;

use axum::http::HeaderValue;

use super::ConfigError;

/// Typed environment-owned server, database, session, and CORS settings.
#[derive(Debug, Clone)]
pub struct EnvironmentConfig {
    pub database_url: String,
    pub bind_addr: SocketAddr,
    pub session: SessionEnvironmentConfig,
    pub cors_allowed_origins: Vec<HeaderValue>,
}

/// Session settings remain environment-owned rather than part of the TOML file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionEnvironmentConfig {
    pub cookie_name: String,
    pub cookie_secure: bool,
    pub ttl_seconds: i64,
}

impl EnvironmentConfig {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(|name| std::env::var(name).ok())
    }

    pub(super) fn from_lookup(
        lookup: impl Fn(&str) -> Option<String>,
    ) -> Result<Self, ConfigError> {
        let database_url = lookup("DATABASE_URL").ok_or(ConfigError::DatabaseUrlMissing)?;
        let host = lookup("APP_HOST").unwrap_or_else(|| "0.0.0.0".into());
        let host = IpAddr::from_str(&host).map_err(|_| ConfigError::InvalidAppHost)?;
        let port = lookup("APP_PORT")
            .unwrap_or_else(|| "3001".into())
            .parse()
            .map_err(|_| ConfigError::InvalidAppPort)?;
        let cookie_secure = match lookup("SESSION_COOKIE_SECURE").as_deref() {
            None => false,
            Some("true") => true,
            Some("false") => false,
            Some(_) => return Err(ConfigError::InvalidSessionCookieSecure),
        };
        let ttl_seconds: i64 = lookup("SESSION_TTL_SECONDS")
            .unwrap_or_else(|| "604800".into())
            .parse()
            .map_err(|_| ConfigError::InvalidSessionTtl)?;
        if ttl_seconds <= 0 {
            return Err(ConfigError::InvalidSessionTtl);
        }
        let cors_allowed_origins = lookup("CORS_ALLOWED_ORIGINS")
            .map(|origins| {
                origins
                    .split(',')
                    .map(str::trim)
                    .filter(|origin| !origin.is_empty())
                    .map(HeaderValue::from_str)
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()
            .map_err(|_| ConfigError::InvalidCorsAllowedOrigins)?
            .unwrap_or_default();

        Ok(Self {
            database_url,
            bind_addr: SocketAddr::new(host, port),
            session: SessionEnvironmentConfig {
                cookie_name: lookup("SESSION_COOKIE_NAME")
                    .unwrap_or_else(|| "calco_session".into()),
                cookie_secure,
                ttl_seconds,
            },
            cors_allowed_origins,
        })
    }
}
