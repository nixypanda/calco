pub mod http;

/// Settings that affect only the HTTP representation of an auth session.
#[derive(Debug, Clone)]
pub struct SessionCookieConfig {
    pub cookie_name: String,
    pub cookie_secure: bool,
}
