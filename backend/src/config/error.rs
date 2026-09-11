/// Startup-configuration failures contain field names, never operator values
/// or configuration-file paths.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ConfigError {
    #[error("DATABASE_URL must be set")]
    DatabaseUrlMissing,
    #[error("APP_HOST must be a valid IP address")]
    InvalidAppHost,
    #[error("APP_PORT must be a valid port number")]
    InvalidAppPort,
    #[error("SESSION_COOKIE_SECURE must be either true or false")]
    InvalidSessionCookieSecure,
    #[error("SESSION_TTL_SECONDS must be a positive integer")]
    InvalidSessionTtl,
    #[error("CORS_ALLOWED_ORIGINS contains an invalid header value")]
    InvalidCorsAllowedOrigins,
    #[error("CALCO_CONFIG_FILE could not be read")]
    ConfigFileUnreadable,
    #[error("CALCO_CONFIG_FILE contains invalid TOML")]
    InvalidToml,
}
