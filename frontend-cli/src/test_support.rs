//! Test-only command support shared by auth and category tests.
//!
//! Environment, storage, prompt, confirmation, and HTTP fakes stay together
//! because every test drives commands through the same injected `Runtime`.
//! This module is declared only under `#[cfg(test)]`; no production code
//! depends on it. The executable-level harness in `tests/cli_integration.rs`
//! remains separate because it exercises process isolation instead.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use chrono::NaiveDate;
use rust_decimal::Decimal;
use url::Url;
use uuid::Uuid;

use crate::auth;
use crate::client;
use crate::commands::{DeleteConfirmation, GlobalArgs, Runtime};
use crate::output::{self, CliError};

pub(crate) fn date(raw: &str) -> NaiveDate {
    NaiveDate::parse_from_str(raw, "%Y-%m-%d").expect("test date")
}

pub(crate) fn decimal(raw: &str) -> Decimal {
    Decimal::from_str(raw).expect("test decimal")
}

pub(crate) fn today() -> NaiveDate {
    date("2026-11-15")
}

#[derive(Default)]
pub(crate) struct FakeEnvironment {
    vars: HashMap<String, String>,
}

impl FakeEnvironment {
    pub(crate) fn new(vars: &[(&str, &str)]) -> Self {
        Self {
            vars: vars
                .iter()
                .map(|(name, value)| ((*name).to_string(), (*value).to_string()))
                .collect(),
        }
    }
}

impl auth::Environment for FakeEnvironment {
    fn var(&self, name: &str) -> Option<String> {
        self.vars.get(name).cloned()
    }
}

#[derive(Default)]
pub(crate) struct FakeStores {
    default_base_url: Mutex<Option<Url>>,
    tokens: Mutex<HashMap<String, String>>,
    events: Mutex<Vec<String>>,
    pub(crate) fail_save_token: AtomicBool,
    pub(crate) fail_save_default: AtomicBool,
}

impl FakeStores {
    pub(crate) fn logged_in(base_url: &str, token: &str) -> Self {
        let stores = Self::with_default(base_url);
        let base_url = Url::parse(base_url).unwrap();
        stores
            .tokens
            .lock()
            .unwrap()
            .insert(auth::canonical_url_string(&base_url), token.to_string());
        stores
    }

    pub(crate) fn with_default(base_url: &str) -> Self {
        Self {
            default_base_url: Mutex::new(Some(Url::parse(base_url).unwrap())),
            ..Self::default()
        }
    }

    pub(crate) fn has_token(&self, base_url: &str) -> bool {
        self.token_for(base_url).is_some()
    }

    pub(crate) fn token_for(&self, base_url: &str) -> Option<String> {
        let base_url = Url::parse(base_url).unwrap();
        self.tokens
            .lock()
            .unwrap()
            .get(&auth::canonical_url_string(&base_url))
            .cloned()
    }

    pub(crate) fn default_base_url(&self) -> Option<Url> {
        self.default_base_url.lock().unwrap().clone()
    }

    pub(crate) fn events(&self) -> Vec<String> {
        self.events.lock().unwrap().clone()
    }
}

impl auth::LocalStores for FakeStores {
    fn load_default_base_url(&self) -> Result<Option<Url>, CliError> {
        Ok(self.default_base_url.lock().unwrap().clone())
    }

    fn save_default_base_url(&self, base_url: &Url) -> Result<(), CliError> {
        let key = auth::canonical_url_string(base_url);
        self.events
            .lock()
            .unwrap()
            .push(format!("save_default:{key}"));
        if self.fail_save_default.load(Ordering::SeqCst) {
            return Err(CliError::new(
                output::ErrorOrigin::Config,
                "config_write_failed",
                "fake config failure",
            ));
        }
        *self.default_base_url.lock().unwrap() = Some(base_url.clone());
        Ok(())
    }

    fn load_token(&self, base_url: &Url) -> Result<Option<auth::SecretToken>, CliError> {
        match self
            .tokens
            .lock()
            .unwrap()
            .get(&auth::canonical_url_string(base_url))
        {
            Some(raw) => auth::SecretToken::new(raw.clone()).map(Some),
            None => Ok(None),
        }
    }

    fn save_token(&self, base_url: &Url, token: &auth::SecretToken) -> Result<(), CliError> {
        let key = auth::canonical_url_string(base_url);
        self.events
            .lock()
            .unwrap()
            .push(format!("save_token:{key}"));
        if self.fail_save_token.load(Ordering::SeqCst) {
            return Err(CliError::new(
                output::ErrorOrigin::Keyring,
                "keyring_unavailable",
                "fake keyring failure",
            ));
        }
        self.tokens
            .lock()
            .unwrap()
            .insert(key, token.expose().to_string());
        Ok(())
    }

    fn delete_token(&self, base_url: &Url) -> Result<bool, CliError> {
        let key = auth::canonical_url_string(base_url);
        self.events
            .lock()
            .unwrap()
            .push(format!("delete_token:{key}"));
        Ok(self.tokens.lock().unwrap().remove(&key).is_some())
    }
}

pub(crate) struct FakePrompt {
    token: String,
    calls: AtomicUsize,
}

impl FakePrompt {
    pub(crate) fn new(token: &str) -> Self {
        Self {
            token: token.to_string(),
            calls: AtomicUsize::new(0),
        }
    }

    pub(crate) fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl auth::SecretPrompt for FakePrompt {
    fn prompt_api_key(&self) -> Result<auth::SecretToken, CliError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        auth::SecretToken::new(self.token.clone())
    }
}

pub(crate) struct FakeConfirmation {
    answer: bool,
    calls: AtomicUsize,
}

impl FakeConfirmation {
    pub(crate) fn new(answer: bool) -> Self {
        Self {
            answer,
            calls: AtomicUsize::new(0),
        }
    }

    pub(crate) fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl DeleteConfirmation for FakeConfirmation {
    fn confirm_delete(&self, _id: Uuid) -> Result<bool, CliError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(self.answer)
    }
}

#[derive(Clone)]
pub(crate) struct RecordedRequest {
    pub(crate) method: String,
    pub(crate) target: String,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) body: Vec<u8>,
}

impl RecordedRequest {
    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(header, _)| header.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

pub(crate) struct MockServer {
    base_url: String,
    requests: Arc<Mutex<Vec<RecordedRequest>>>,
    handle: Option<JoinHandle<()>>,
}

impl MockServer {
    pub(crate) fn start(status: u16, body: impl Into<String>) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind mock server");
        let address = listener.local_addr().expect("mock server address");
        let base_url = format!("http://{address}");
        let requests = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&requests);
        let body = body.into();

        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("mock server accept");
            stream
                .set_read_timeout(Some(Duration::from_secs(10)))
                .expect("mock read timeout");
            stream
                .set_write_timeout(Some(Duration::from_secs(10)))
                .expect("mock write timeout");
            let request = read_http_request(&mut stream).expect("mock server read request");
            recorded.lock().unwrap().push(request);
            write_http_response(&mut stream, status, &body).expect("mock server write response");
        });

        Self {
            base_url,
            requests,
            handle: Some(handle),
        }
    }

    pub(crate) fn base_url(&self) -> &str {
        &self.base_url
    }

    pub(crate) fn requests(&self) -> Vec<RecordedRequest> {
        self.requests.lock().unwrap().clone()
    }

    pub(crate) fn expect_requests(&self, expected: usize) -> Vec<RecordedRequest> {
        let requests = self.requests();
        assert_eq!(
            requests.len(),
            expected,
            "unexpected number of HTTP requests"
        );
        requests
    }

    /// Join only after request-count assertions. A failed test drops the
    /// handle so the listener thread detaches instead of hanging the test.
    pub(crate) fn join(mut self) {
        if let Some(handle) = self.handle.take() {
            handle.join().expect("mock server thread");
        }
    }
}

fn read_http_request(stream: &mut TcpStream) -> std::io::Result<RecordedRequest> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let header_end = loop {
        if let Some(position) = buffer.windows(4).position(|window| window == b"\r\n\r\n") {
            break position + 4;
        }
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "request ended before headers",
            ));
        }
        buffer.extend_from_slice(&chunk[..read]);
    };

    let head = String::from_utf8_lossy(&buffer[..header_end]);
    let mut lines = head.split("\r\n");
    let request_line = lines.next().unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_owned();
    let target = parts.next().unwrap_or_default().to_owned();

    let mut headers = Vec::new();
    let mut content_length = 0usize;
    for line in lines {
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            let name = name.trim().to_ascii_lowercase();
            let value = value.trim().to_owned();
            if name == "content-length" {
                content_length = value.parse().unwrap_or(0);
            }
            headers.push((name, value));
        }
    }

    while buffer.len() < header_end + content_length {
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
    let body_end = (header_end + content_length).min(buffer.len());

    Ok(RecordedRequest {
        method,
        target,
        headers,
        body: buffer[header_end..body_end].to_vec(),
    })
}

fn write_http_response(stream: &mut TcpStream, status: u16, body: &str) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        401 => "Unauthorized",
        500 => "Internal Server Error",
        _ => "Response",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}

pub(crate) fn runtime(
    env: Arc<FakeEnvironment>,
    stores: Arc<FakeStores>,
    prompt: Arc<FakePrompt>,
    stdin_is_tty: bool,
) -> Runtime {
    runtime_with_confirmation(
        env,
        stores,
        prompt,
        Arc::new(FakeConfirmation::new(false)),
        stdin_is_tty,
    )
}

pub(crate) fn runtime_with_confirmation(
    env: Arc<FakeEnvironment>,
    stores: Arc<FakeStores>,
    prompt: Arc<FakePrompt>,
    confirm: Arc<FakeConfirmation>,
    stdin_is_tty: bool,
) -> Runtime {
    Runtime {
        env: env as Arc<dyn auth::Environment>,
        stores: stores as Arc<dyn auth::LocalStores>,
        // Keep loopback unit tests hermetic even when proxy env vars are set.
        http: reqwest::Client::builder()
            .no_proxy()
            .timeout(client::REQUEST_TIMEOUT)
            .build()
            .expect("test HTTP client"),
        prompt: prompt as Arc<dyn auth::SecretPrompt>,
        confirm: confirm as Arc<dyn DeleteConfirmation>,
        stdin_is_tty,
        today: today(),
    }
}

pub(crate) fn global(json: bool, base_url: Option<&str>) -> GlobalArgs {
    GlobalArgs {
        json,
        pretty: false,
        base_url: base_url.map(str::to_string),
    }
}
