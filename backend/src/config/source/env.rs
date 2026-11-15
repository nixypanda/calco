use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::str::FromStr;

use axum::http::HeaderValue;
use url::Url;

use super::super::{ConfigError, ServerConfig, SessionConfig, default_mcp_allowed_hosts};

const DATABASE_URL: &str = "DATABASE_URL";
const APP_HOST: &str = "APP_HOST";
const APP_PORT: &str = "APP_PORT";
const SESSION_COOKIE_NAME: &str = "SESSION_COOKIE_NAME";
const SESSION_COOKIE_SECURE: &str = "SESSION_COOKIE_SECURE";
const SESSION_TTL_SECONDS: &str = "SESSION_TTL_SECONDS";
const CORS_ALLOWED_ORIGINS: &str = "CORS_ALLOWED_ORIGINS";
const MCP_ALLOWED_HOSTS: &str = "MCP_ALLOWED_HOSTS";

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
        .map(|origins| parse_cors_allowed_origins(&origins))
        .transpose()?
        .unwrap_or_default();
    let mcp_allowed_hosts = match lookup(MCP_ALLOWED_HOSTS) {
        Some(hosts) => parse_mcp_allowed_hosts(&hosts)?,
        None => default_mcp_allowed_hosts(),
    };

    Ok(EnvSourceConfig {
        database_url,
        server: ServerConfig {
            bind_addr: SocketAddr::new(host, port),
            cors_allowed_origins,
            mcp_allowed_hosts,
        },
        session: SessionConfig {
            cookie_name: lookup(SESSION_COOKIE_NAME)
                .unwrap_or_else(|| DEFAULT_SESSION_COOKIE_NAME.into()),
            cookie_secure,
            ttl_seconds,
        },
    })
}

fn parse_cors_allowed_origins(raw: &str) -> Result<Vec<HeaderValue>, ConfigError> {
    raw.split(',')
        .map(str::trim)
        .filter(|origin| !origin.is_empty())
        .map(parse_cors_origin)
        .collect()
}

fn parse_cors_origin(raw: &str) -> Result<HeaderValue, ConfigError> {
    let Some((_, authority)) = raw.split_once("://") else {
        return Err(ConfigError::InvalidCorsAllowedOrigins);
    };
    let authority = authority.split(['/', '?', '#']).next().unwrap_or_default();
    if authority.is_empty() || authority.contains('@') || authority.ends_with(':') {
        return Err(ConfigError::InvalidCorsAllowedOrigins);
    }

    let url = Url::parse(raw).map_err(|_| ConfigError::InvalidCorsAllowedOrigins)?;

    if !matches!(url.scheme(), "http" | "https")
        || url.username() != ""
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.host_str().is_some_and(|host| !host.is_empty())
        || url.port() == Some(0)
    {
        return Err(ConfigError::InvalidCorsAllowedOrigins);
    }

    let origin = url.origin().ascii_serialization();
    if origin == "null" {
        return Err(ConfigError::InvalidCorsAllowedOrigins);
    }

    HeaderValue::from_str(&origin).map_err(|_| ConfigError::InvalidCorsAllowedOrigins)
}

fn parse_mcp_allowed_hosts(raw: &str) -> Result<Vec<String>, ConfigError> {
    let mut hosts = Vec::new();

    for entry in raw.split(',') {
        let normalized =
            normalize_mcp_allowed_host(entry.trim()).ok_or(ConfigError::InvalidMcpAllowedHosts)?;
        if hosts.iter().any(|host| host == &normalized) {
            return Err(ConfigError::InvalidMcpAllowedHosts);
        }
        hosts.push(normalized);
    }

    if hosts.is_empty() {
        return Err(ConfigError::InvalidMcpAllowedHosts);
    }

    Ok(hosts)
}

fn normalize_mcp_allowed_host(entry: &str) -> Option<String> {
    if entry.is_empty() || entry.contains('*') {
        return None;
    }

    let (host, port) = if let Some(rest) = entry.strip_prefix('[') {
        let (host, suffix) = rest.split_once(']')?;
        if host.parse::<Ipv6Addr>().is_err() {
            return None;
        }
        let port = if suffix.is_empty() {
            None
        } else {
            Some(suffix.strip_prefix(':')?)
        };
        (host, port)
    } else {
        let (host, port) = match entry.split_once(':') {
            Some((host, port)) => {
                if host.contains(':') || port.contains(':') {
                    return None;
                }
                (host, Some(port))
            }
            None => (entry, None),
        };
        (host, port)
    };

    let host = if let Ok(address) = host.parse::<Ipv6Addr>() {
        format!("[{address}]")
    } else if let Ok(address) = host.parse::<Ipv4Addr>() {
        address.to_string()
    } else if is_valid_mcp_hostname(host) {
        host.to_ascii_lowercase()
    } else {
        return None;
    };

    match port {
        Some(port) => {
            let port: u16 = port.parse().ok()?;
            if port == 0 {
                return None;
            }
            Some(format!("{host}:{port}"))
        }
        None => Some(host),
    }
}

fn is_valid_mcp_hostname(host: &str) -> bool {
    if host.is_empty() || host.len() > 253 {
        return false;
    }

    host.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && label
                .as_bytes()
                .first()
                .is_some_and(|byte| byte.is_ascii_alphanumeric())
            && label
                .as_bytes()
                .last()
                .is_some_and(|byte| byte.is_ascii_alphanumeric())
            && label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    })
}

#[cfg(test)]
mod tests {
    use rstest::rstest;

    use super::super::super::ConfigError;
    use super::{
        APP_HOST, APP_PORT, CORS_ALLOWED_ORIGINS, DATABASE_URL, SESSION_COOKIE_SECURE,
        SESSION_TTL_SECONDS, load,
    };

    #[test]
    fn database_url_is_required() {
        assert_eq!(
            load(|_| None).err().unwrap(),
            ConfigError::DatabaseUrlMissing
        );
    }

    #[rstest]
    #[case::invalid_host(APP_HOST, "not-an-ip", ConfigError::InvalidAppHost)]
    #[case::invalid_port(APP_PORT, "not-a-port", ConfigError::InvalidAppPort)]
    fn invalid_host_and_port_are_rejected(
        #[case] variable: &str,
        #[case] value: &str,
        #[case] expected: ConfigError,
    ) {
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

    #[rstest]
    #[case::uppercase_true(SESSION_COOKIE_SECURE, "TRUE", ConfigError::InvalidSessionCookieSecure)]
    #[case::numeric_one(SESSION_COOKIE_SECURE, "1", ConfigError::InvalidSessionCookieSecure)]
    #[case::yes(SESSION_COOKIE_SECURE, "yes", ConfigError::InvalidSessionCookieSecure)]
    #[case::zero_ttl(SESSION_TTL_SECONDS, "0", ConfigError::InvalidSessionTtl)]
    #[case::negative_ttl(SESSION_TTL_SECONDS, "-1", ConfigError::InvalidSessionTtl)]
    #[case::non_numeric_ttl(SESSION_TTL_SECONDS, "not-a-number", ConfigError::InvalidSessionTtl)]
    fn invalid_booleans_and_non_positive_ttls_are_rejected(
        #[case] variable: &str,
        #[case] value: &str,
        #[case] expected: ConfigError,
    ) {
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

    #[rstest]
    #[case::invalid_header_value("https://valid.example,invalid\nvalue")]
    fn invalid_cors_header_values_are_rejected(#[case] origins: &str) {
        assert_eq!(
            load(|name| match name {
                DATABASE_URL => Some("database".into()),
                CORS_ALLOWED_ORIGINS => Some(origins.into()),
                _ => None,
            })
            .err()
            .unwrap(),
            ConfigError::InvalidCorsAllowedOrigins
        );
    }

    #[test]
    fn cors_origins_are_normalized() {
        let origins =
            loaded_cors_origins(" HTTPS://Example.COM:443/, http://Example.COM:80/ ").unwrap();

        assert_eq!(origins, ["https://example.com", "http://example.com"]);
    }

    #[test]
    fn cors_origins_preserve_non_default_ports() {
        let origins = loaded_cors_origins("https://Example.COM:8443").unwrap();

        assert_eq!(origins, ["https://example.com:8443"]);
    }

    #[test]
    fn cors_origins_preserve_bracketed_ipv6() {
        let origins = loaded_cors_origins("http://[::1]:8080/").unwrap();

        assert_eq!(origins, ["http://[::1]:8080"]);
    }

    #[rstest]
    #[case::wildcard("*")]
    #[case::null("null")]
    #[case::credentials("https://user:pass@example.com")]
    #[case::path("https://example.com/path")]
    #[case::query("https://example.com?query=1")]
    #[case::fragment("https://example.com#fragment")]
    #[case::non_http_scheme("ftp://example.com")]
    #[case::port_zero("https://example.com:0")]
    #[case::empty_port("https://example.com:")]
    #[case::empty_userinfo("https://@example.com")]
    #[case::malformed("not a url")]
    fn invalid_cors_origins_are_rejected(#[case] origin: &str) {
        assert_eq!(
            loaded_cors_origins(origin).err().unwrap(),
            ConfigError::InvalidCorsAllowedOrigins
        );
    }

    fn loaded_cors_origins(origins: &str) -> Result<Vec<String>, ConfigError> {
        load(|name| match name {
            DATABASE_URL => Some("database".into()),
            CORS_ALLOWED_ORIGINS => Some(origins.into()),
            _ => None,
        })
        .map(|config| {
            config
                .server
                .cors_allowed_origins
                .iter()
                .map(|origin| origin.to_str().unwrap().to_owned())
                .collect()
        })
    }
}
