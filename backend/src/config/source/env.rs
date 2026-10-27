use std::net::{IpAddr, SocketAddr};
use std::str::FromStr;

use axum::http::HeaderValue;

use super::super::{ConfigError, ServerConfig, SessionConfig};

const DATABASE_URL: &str = "DATABASE_URL";
const APP_HOST: &str = "APP_HOST";
const APP_PORT: &str = "APP_PORT";
const SESSION_COOKIE_NAME: &str = "SESSION_COOKIE_NAME";
const SESSION_COOKIE_SECURE: &str = "SESSION_COOKIE_SECURE";
const SESSION_TTL_SECONDS: &str = "SESSION_TTL_SECONDS";
const CORS_ALLOWED_ORIGINS: &str = "CORS_ALLOWED_ORIGINS";

const DEFAULT_APP_HOST: &str = "0.0.0.0";
const DEFAULT_APP_PORT: &str = "3001";
const DEFAULT_SESSION_COOKIE_NAME: &str = "calco_session";
const DEFAULT_SESSION_TTL_SECONDS: &str = "604800";

const TRUE: &str = "true";
const FALSE: &str = "false";

pub(in crate::config) struct EnvSourceConfig {
    pub database_url: String,
    pub server: ServerConfig,
    pub session: SessionConfig,
}

pub(in crate::config) fn load(
    lookup: impl Fn(&str) -> Option<String>,
) -> Result<EnvSourceConfig, ConfigError> {
    let database_url = lookup(DATABASE_URL).ok_or(ConfigError::DatabaseUrlMissing)?;
    let host = lookup(APP_HOST).unwrap_or_else(|| DEFAULT_APP_HOST.into());
    let host = IpAddr::from_str(&host).map_err(|_| ConfigError::InvalidAppHost)?;
    let port = lookup(APP_PORT)
        .unwrap_or_else(|| DEFAULT_APP_PORT.into())
        .parse()
        .map_err(|_| ConfigError::InvalidAppPort)?;
    let cookie_secure = match lookup(SESSION_COOKIE_SECURE).as_deref() {
        None => false,
        Some(TRUE) => true,
        Some(FALSE) => false,
        Some(_) => return Err(ConfigError::InvalidSessionCookieSecure),
    };
    let ttl_seconds: i64 = lookup(SESSION_TTL_SECONDS)
        .unwrap_or_else(|| DEFAULT_SESSION_TTL_SECONDS.into())
        .parse()
        .map_err(|_| ConfigError::InvalidSessionTtl)?;
    if ttl_seconds <= 0 {
        return Err(ConfigError::InvalidSessionTtl);
    }
    let cors_allowed_origins = lookup(CORS_ALLOWED_ORIGINS)
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

    Ok(EnvSourceConfig {
        database_url,
        server: ServerConfig {
            bind_addr: SocketAddr::new(host, port),
            cors_allowed_origins,
        },
        session: SessionConfig {
            cookie_name: lookup(SESSION_COOKIE_NAME)
                .unwrap_or_else(|| DEFAULT_SESSION_COOKIE_NAME.into()),
            cookie_secure,
            ttl_seconds,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::super::super::ConfigError;
    use super::{
        APP_HOST, APP_PORT, CORS_ALLOWED_ORIGINS, DATABASE_URL, SESSION_COOKIE_NAME,
        SESSION_COOKIE_SECURE, SESSION_TTL_SECONDS, load,
    };

    #[test]
    fn database_url_is_required() {
        assert_eq!(
            load(|_| None).err().unwrap(),
            ConfigError::DatabaseUrlMissing
        );
    }

    #[test]
    fn bind_address_uses_defaults_and_accepts_explicit_values() {
        let defaults = load(|name| (name == DATABASE_URL).then(|| "database".into())).unwrap();
        assert_eq!(defaults.server.bind_addr.to_string(), "0.0.0.0:3001");

        let explicit = load(|name| match name {
            DATABASE_URL => Some("database".into()),
            APP_HOST => Some("127.0.0.1".into()),
            APP_PORT => Some("4321".into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(explicit.server.bind_addr.to_string(), "127.0.0.1:4321");
    }

    #[test]
    fn invalid_host_and_port_are_rejected() {
        for (variable, value, expected) in [
            (APP_HOST, "not-an-ip", ConfigError::InvalidAppHost),
            (APP_PORT, "not-a-port", ConfigError::InvalidAppPort),
        ] {
            assert_eq!(
                load(|name| match name {
                    DATABASE_URL => Some("database".into()),
                    name if name == variable => Some(value.into()),
                    _ => None,
                })
                .err()
                .unwrap(),
                expected
            );
        }
    }

    #[test]
    fn session_uses_defaults_and_accepts_explicit_values() {
        let defaults = load(|name| (name == DATABASE_URL).then(|| "database".into())).unwrap();
        assert_eq!(defaults.session.cookie_name, "calco_session");
        assert!(!defaults.session.cookie_secure);
        assert_eq!(defaults.session.ttl_seconds, 604800);

        let explicit = load(|name| match name {
            DATABASE_URL => Some("database".into()),
            SESSION_COOKIE_NAME => Some("custom_session".into()),
            SESSION_COOKIE_SECURE => Some("true".into()),
            SESSION_TTL_SECONDS => Some("60".into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(explicit.session.cookie_name, "custom_session");
        assert!(explicit.session.cookie_secure);
        assert_eq!(explicit.session.ttl_seconds, 60);
    }

    #[test]
    fn invalid_booleans_and_non_positive_ttls_are_rejected() {
        for value in ["TRUE", "1", "yes"] {
            assert_eq!(
                load(|name| match name {
                    DATABASE_URL => Some("database".into()),
                    SESSION_COOKIE_SECURE => Some(value.into()),
                    _ => None,
                })
                .err()
                .unwrap(),
                ConfigError::InvalidSessionCookieSecure
            );
        }
        for value in ["0", "-1", "not-a-number"] {
            assert_eq!(
                load(|name| match name {
                    DATABASE_URL => Some("database".into()),
                    SESSION_TTL_SECONDS => Some(value.into()),
                    _ => None,
                })
                .err()
                .unwrap(),
                ConfigError::InvalidSessionTtl
            );
        }
    }

    #[test]
    fn cors_origins_are_trimmed_and_empty_entries_are_ignored() {
        let config = load(|name| match name {
            DATABASE_URL => Some("database".into()),
            CORS_ALLOWED_ORIGINS => Some(" https://one.example, ,https://two.example ".into()),
            _ => None,
        })
        .unwrap();

        assert_eq!(
            config
                .server
                .cors_allowed_origins
                .iter()
                .map(|origin| origin.to_str().unwrap())
                .collect::<Vec<_>>(),
            ["https://one.example", "https://two.example"]
        );
    }

    #[test]
    fn invalid_cors_header_values_are_rejected() {
        assert_eq!(
            load(|name| match name {
                DATABASE_URL => Some("database".into()),
                CORS_ALLOWED_ORIGINS => Some("https://valid.example,invalid\nvalue".into()),
                _ => None,
            })
            .err()
            .unwrap(),
            ConfigError::InvalidCorsAllowedOrigins
        );
    }
}
