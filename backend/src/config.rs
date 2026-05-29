use std::net::SocketAddr;

#[derive(Clone)]
pub struct AppConfig {
    pub database_url: String,
    pub bind_addr: SocketAddr,
    pub session_cookie_name: String,
    pub session_cookie_secure: bool,
    pub session_ttl_seconds: i64,
}

impl AppConfig {
    pub fn from_env() -> Self {
        let host = std::env::var("APP_HOST").unwrap_or_else(|_| "0.0.0.0".into());
        let port = std::env::var("APP_PORT")
            .unwrap_or_else(|_| "3001".into())
            .parse()
            .expect("APP_PORT must be a valid port number");
        Self {
            database_url: std::env::var("DATABASE_URL")
                .expect("DATABASE_URL must be set"),
            bind_addr: SocketAddr::new(host.parse().unwrap(), port),
            session_cookie_name: std::env::var("SESSION_COOKIE_NAME")
                .unwrap_or_else(|_| "calco_session".into()),
            session_cookie_secure: std::env::var("SESSION_COOKIE_SECURE")
                .ok()
                .map(|v| v == "true")
                .unwrap_or(false),
            session_ttl_seconds: std::env::var("SESSION_TTL_SECONDS")
                .unwrap_or_else(|_| "604800".into())
                .parse()
                .expect("SESSION_TTL_SECONDS must be a valid i64"),
        }
    }
}
