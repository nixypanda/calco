use std::net::SocketAddr;

pub fn bind_address() -> SocketAddr {
    let host = std::env::var("APP_HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port = std::env::var("APP_PORT")
        .unwrap_or_else(|_| "3001".into())
        .parse()
        .expect("APP_PORT must be a valid port number");
    SocketAddr::new(host.parse().unwrap(), port)
}
