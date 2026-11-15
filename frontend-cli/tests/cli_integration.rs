//! External integration tests for the `calco` executable.
//!
//! These tests exercise the real process boundary: clap parsing, output modes,
//! exit codes, stderr contracts, and HTTP requests against a finite loopback
//! mock server. They use no keyring, no saved config, no PostgreSQL, and no
//! external network. Every child process gets an isolated HOME/XDG root and an
//! obviously fake token.

use std::fs;
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

const TEST_TOKEN: &str = "calco-test-only-token-not-a-real-secret";
const PRODUCT_ID: &str = "11111111-1111-1111-1111-111111111111";
const LOG_ID: &str = "33333333-3333-3333-3333-333333333333";

// ─── Isolated child process ─────────────────────────────────

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

struct TestEnv {
    root: PathBuf,
    token: Option<&'static str>,
}

impl TestEnv {
    fn new() -> Self {
        Self::with_token(Some(TEST_TOKEN))
    }

    fn without_token() -> Self {
        Self::with_token(None)
    }

    fn with_token(token: Option<&'static str>) -> Self {
        let root = std::env::temp_dir().join(format!(
            "calco-cli-integration-{}-{}",
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).expect("create isolated test directory");
        Self { root, token }
    }

    fn run(&self, args: &[&str]) -> RunResult {
        let output = self
            .command()
            .args(args)
            .output()
            .expect("run the calco binary");
        RunResult {
            code: output.status.code(),
            stdout: String::from_utf8(output.stdout).expect("stdout is UTF-8"),
            stderr: String::from_utf8(output.stderr).expect("stderr is UTF-8"),
        }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_calco"));
        command
            .env_clear()
            .env("HOME", &self.root)
            .env("XDG_CONFIG_HOME", self.root.join("xdg-config"))
            .env("XDG_DATA_HOME", self.root.join("xdg-data"))
            .env("NO_PROXY", "127.0.0.1,localhost")
            .env("no_proxy", "127.0.0.1,localhost")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(token) = self.token {
            command.env("CALCO_API_KEY", token);
        }
        command
    }

    fn assert_no_local_storage(&self) {
        let mut pending = vec![self.root.clone()];
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(&directory).expect("read isolated test directory") {
                let entry = entry.expect("read isolated test entry");
                let path = entry.path();
                if entry.file_type().expect("entry type").is_dir() {
                    pending.push(path);
                } else {
                    panic!("unexpected local file created: {}", path.display());
                }
            }
        }
    }
}

impl Drop for TestEnv {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

struct RunResult {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

fn parse_stdout_json(result: &RunResult) -> Value {
    assert_eq!(
        result.code,
        Some(0),
        "expected success; stderr: {}",
        result.stderr
    );
    assert!(
        result.stderr.is_empty(),
        "success wrote to stderr: {}",
        result.stderr
    );
    assert!(
        result.stdout.ends_with('\n'),
        "stdout must end with a newline: {:?}",
        result.stdout
    );
    serde_json::from_str(&result.stdout).unwrap_or_else(|error| {
        panic!(
            "stdout is not one JSON document: {error}\nstdout: {}",
            result.stdout
        )
    })
}

fn compact_stdout_json(result: &RunResult) -> Value {
    let value = parse_stdout_json(result);
    assert_eq!(
        result.stdout.lines().count(),
        1,
        "compact JSON must be one line: {}",
        result.stdout
    );
    assert!(!result.stdout.contains('\r'), "unexpected CR in stdout");
    value
}

fn pretty_stdout_json(result: &RunResult) -> Value {
    let value = parse_stdout_json(result);
    assert!(
        result.stdout.starts_with("{\n  \"schema_version\": 1,"),
        "pretty JSON has unexpected framing: {}",
        result.stdout
    );
    assert!(result.stdout.lines().count() > 3);
    assert!(result.stdout.contains("\n  \"data\""));
    assert!(result.stdout.contains("\n  \"meta\""));
    value
}

fn error_json(result: &RunResult, expected_exit: i32) -> Value {
    assert_eq!(
        result.code,
        Some(expected_exit),
        "expected exit {expected_exit}; stderr: {}",
        result.stderr
    );
    assert!(
        result.stdout.is_empty(),
        "errors must not write stdout: {}",
        result.stdout
    );
    assert!(
        result.stderr.ends_with('\n'),
        "stderr must end with a newline: {:?}",
        result.stderr
    );
    assert_eq!(
        result.stderr.lines().count(),
        1,
        "structured errors must be compact and one line: {}",
        result.stderr
    );
    let value: Value = serde_json::from_str(&result.stderr).unwrap_or_else(|error| {
        panic!(
            "stderr is not one JSON document: {error}\nstderr: {}",
            result.stderr
        )
    });
    assert_eq!(value["schema_version"], 1);
    assert!(value.get("error").is_some());
    value
}

fn closed_loopback_url() -> String {
    let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind closed-port probe");
    let address = listener.local_addr().expect("closed-port address");
    drop(listener);
    format!("http://{address}")
}

// ─── Finite loopback mock server ────────────────────────────

struct MockResponse {
    status: u16,
    body: String,
}

impl MockResponse {
    fn new(status: u16, body: impl Into<String>) -> Self {
        Self {
            status,
            body: body.into(),
        }
    }
}

#[derive(Debug, Clone)]
struct RecordedRequest {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl RecordedRequest {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(header, _)| header.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    fn json_body(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or_else(|error| {
            panic!(
                "request body is not JSON: {error}\nbody: {}",
                String::from_utf8_lossy(&self.body)
            )
        })
    }
}

struct MockServer {
    base_url: String,
    requests: Arc<Mutex<Vec<RecordedRequest>>>,
    handle: Option<JoinHandle<()>>,
}

impl MockServer {
    fn start(responses: Vec<MockResponse>) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind mock server");
        let address = listener.local_addr().expect("mock server address");
        let base_url = format!("http://{address}");
        let requests = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&requests);

        let handle = thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().expect("mock server accept");
                stream
                    .set_read_timeout(Some(Duration::from_secs(10)))
                    .expect("mock read timeout");
                stream
                    .set_write_timeout(Some(Duration::from_secs(10)))
                    .expect("mock write timeout");
                let request = read_http_request(&mut stream).expect("mock server read request");
                recorded.lock().expect("requests lock").push(request);
                write_http_response(&mut stream, &response).expect("mock server write response");
            }
        });

        Self {
            base_url,
            requests,
            handle: Some(handle),
        }
    }

    fn base_url(&self) -> &str {
        &self.base_url
    }

    fn requests(&self) -> Vec<RecordedRequest> {
        self.requests.lock().expect("requests lock").clone()
    }

    fn expect_requests(&self, expected: usize) -> Vec<RecordedRequest> {
        let requests = self.requests();
        assert_eq!(
            requests.len(),
            expected,
            "unexpected number of HTTP requests"
        );
        requests
    }

    /// Join only after request-count assertions. If a test fails earlier, the
    /// join handle is dropped and the listener thread detaches instead of
    /// blocking the test harness on `accept`.
    fn join(mut self) {
        if let Some(handle) = self.handle.take() {
            handle.join().expect("mock server thread");
        }
    }
}

/// A bounded trap that records any attempted HTTP proxy connection. It never
/// blocks the test harness: the accept loop checks a stop flag and a hard
/// deadline, and the successful path stops it immediately after the child exits.
struct ProxyTrap {
    url: String,
    requests: Arc<Mutex<Vec<RecordedRequest>>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl ProxyTrap {
    fn start() -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind proxy trap");
        listener
            .set_nonblocking(true)
            .expect("set proxy trap nonblocking");
        let address = listener.local_addr().expect("proxy trap address");
        let url = format!("http://{address}");
        let requests = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&requests);
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = Arc::clone(&stop);

        let handle = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            while !stopping.load(Ordering::Relaxed) && Instant::now() < deadline {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .expect("proxy trap read timeout");
                        if let Ok(request) = read_http_request(&mut stream) {
                            recorded.lock().expect("proxy requests lock").push(request);
                        }
                        let _ = write_http_response(&mut stream, &MockResponse::new(502, "{}"));
                        break;
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(_) => break,
                }
            }
        });

        Self {
            url,
            requests,
            stop,
            handle: Some(handle),
        }
    }

    fn url(&self) -> &str {
        &self.url
    }

    fn finish(mut self) -> Vec<RecordedRequest> {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            handle.join().expect("proxy trap thread");
        }
        self.requests.lock().expect("proxy requests lock").clone()
    }
}

fn read_http_request(stream: &mut TcpStream) -> io::Result<RecordedRequest> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let header_end = loop {
        if let Some(position) = find_bytes(&buffer, b"\r\n\r\n") {
            break position + 4;
        }
        let read = stream.read(&mut chunk)?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
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

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn write_http_response(stream: &mut TcpStream, response: &MockResponse) -> io::Result<()> {
    let reason = match response.status {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        500 => "Internal Server Error",
        _ => "Response",
    };
    let head = format!(
        "HTTP/1.1 {} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        response.status,
        response.body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(response.body.as_bytes())?;
    stream.flush()
}

// ─── Response bodies ────────────────────────────────────────

fn product_food_log(log_date: &str) -> Value {
    json!({
        "id": LOG_ID,
        "log_date": log_date,
        "meal_slot": "lunch",
        "device_timezone": null,
        "item": {
            "type": "product",
            "id": PRODUCT_ID,
            "name": "Oats",
            "brand": null
        },
        "quantity": {"amount": "150.5", "unit": "g"},
        "nutrients": [{"code": "ENERGY_KCAL", "amount": "580", "unit": "kcal"}],
        "notes": null,
        "created_at": "2026-11-15T10:00:00Z",
        "updated_at": "2026-11-15T10:00:00Z"
    })
}

fn log_list_body(log_date: &str, items: Vec<Value>) -> String {
    json!({"log_date": log_date, "items": items}).to_string()
}

fn empty_log_list(log_date: &str) -> String {
    log_list_body(log_date, Vec::new())
}

fn error_body(code: &str, message: &str) -> String {
    json!({"error": {"code": code, "message": message}}).to_string()
}

// ─── Process and output contract ────────────────────────────

#[test]
fn help_and_version_are_normal_stdout_successes() {
    let env = TestEnv::new();

    let help = env.run(&["--help"]);
    assert_eq!(help.code, Some(0), "stderr: {}", help.stderr);
    assert!(help.stderr.is_empty());
    assert!(help.stdout.contains("Usage: calco"));
    assert!(help.stdout.contains("--json"));
    assert!(help.stdout.contains("logs"));

    let json_help = env.run(&["--json", "--help"]);
    assert_eq!(json_help.code, Some(0), "stderr: {}", json_help.stderr);
    assert!(json_help.stderr.is_empty());
    assert!(json_help.stdout.contains("Usage: calco"));

    let version = env.run(&["--version"]);
    assert_eq!(version.code, Some(0), "stderr: {}", version.stderr);
    assert!(version.stderr.is_empty());
    assert_eq!(
        version.stdout.trim(),
        format!("calco {}", env!("CARGO_PKG_VERSION"))
    );

    let logs_help = env.run(&["logs", "--help"]);
    assert_eq!(logs_help.code, Some(0), "stderr: {}", logs_help.stderr);
    assert!(logs_help.stderr.is_empty());
    assert!(logs_help.stdout.contains("list"));
    assert!(logs_help.stdout.contains("delete"));
}

#[test]
fn argument_errors_exit_two_and_never_write_stdout() {
    let env = TestEnv::new();
    let closed = closed_loopback_url();

    let pretty_without_json = env.run(&["--pretty", "foods", "search", "x"]);
    assert_eq!(
        pretty_without_json.code,
        Some(2),
        "stderr: {}",
        pretty_without_json.stderr
    );
    assert!(pretty_without_json.stdout.is_empty());
    assert!(
        pretty_without_json
            .stderr
            .contains("--pretty requires --json")
    );
    assert!(pretty_without_json.stderr.contains("origin: arguments"));

    let unknown = env.run(&["--json", "not-a-command"]);
    let error = error_json(&unknown, 2);
    assert_eq!(error["error"]["origin"], "arguments");
    assert_eq!(error["error"]["code"], "invalid_arguments");
    assert!(
        error["error"]["message"]
            .as_str()
            .expect("error message")
            .contains("unrecognized subcommand")
    );

    let invalid_amount = env.run(&[
        "logs",
        "add",
        "--food",
        PRODUCT_ID,
        "--amount",
        "0",
        "--unit",
        "g",
        "--idempotency-key",
        "zero-amount-key",
        "--json",
        "--base-url",
        &closed,
    ]);
    let error = error_json(&invalid_amount, 2);
    assert_eq!(error["error"]["origin"], "arguments");
    assert_eq!(error["error"]["code"], "invalid_arguments");
    assert!(
        error["error"]["message"]
            .as_str()
            .expect("error message")
            .contains("positive decimal")
    );

    let invalid_url = env.run(&[
        "foods",
        "search",
        "x",
        "--json",
        "--base-url",
        "http://example.com",
    ]);
    let error = error_json(&invalid_url, 2);
    assert_eq!(error["error"]["origin"], "arguments");
    assert_eq!(error["error"]["code"], "invalid_base_url");
}

#[test]
fn output_modes_are_human_by_default_compact_with_json_and_pretty_with_both() {
    let server = MockServer::start(vec![
        MockResponse::new(200, r#"{"items":[]}"#),
        MockResponse::new(200, r#"{"items":[]}"#),
        MockResponse::new(200, r#"{"items":[]}"#),
    ]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();

    let human = env.run(&["foods", "search", "milk", "--base-url", &base]);
    assert_eq!(human.code, Some(0), "stderr: {}", human.stderr);
    assert!(human.stderr.is_empty());
    assert_eq!(human.stdout, "No foods found.\n");

    let compact_run = env.run(&["foods", "search", "milk", "--json", "--base-url", &base]);
    let compact = compact_stdout_json(&compact_run);
    assert_eq!(compact["schema_version"], 1);
    assert_eq!(compact["data"]["items"], json!([]));
    assert_eq!(compact["meta"], json!({}));

    let pretty_run = env.run(&[
        "--json",
        "--pretty",
        "foods",
        "search",
        "milk",
        "--base-url",
        &base,
    ]);
    let pretty = pretty_stdout_json(&pretty_run);
    assert_eq!(pretty["schema_version"], 1);
    assert_eq!(pretty["data"], compact["data"]);
    assert_eq!(pretty["meta"], compact["meta"]);

    let requests = server.expect_requests(3);
    for request in &requests {
        assert_eq!(request.method, "GET");
        assert_eq!(request.target, "/api/foods/search?q=milk&scope=all");
    }
    server.join();
}

#[test]
fn search_maps_query_scope_bearer_and_accepts_global_flags_before_or_after() {
    let server = MockServer::start(vec![
        MockResponse::new(200, r#"{"items":[]}"#),
        MockResponse::new(200, r#"{"items":[]}"#),
    ]);
    let base = server.base_url().to_owned();
    let prefixed = format!("{base}/prefix/");
    let env = TestEnv::new();

    let after = env.run(&[
        "foods",
        "search",
        "banana bread & co",
        "--scope",
        "history",
        "--json",
        "--base-url",
        &prefixed,
    ]);
    let value = compact_stdout_json(&after);
    assert_eq!(value["data"]["items"], json!([]));
    assert_eq!(value["meta"], json!({}));

    let before = env.run(&["--json", "--base-url", &base, "foods", "search", "oats"]);
    let value = compact_stdout_json(&before);
    assert_eq!(value["data"]["items"], json!([]));
    assert_eq!(value["meta"], json!({}));

    let requests = server.expect_requests(2);
    assert_eq!(requests[0].method, "GET");
    assert_eq!(
        requests[0].target,
        "/prefix/api/foods/search?q=banana+bread+%26+co&scope=history"
    );
    assert_eq!(requests[1].target, "/api/foods/search?q=oats&scope=all");
    let expected_auth = format!("Bearer {TEST_TOKEN}");
    for request in &requests {
        assert_eq!(
            request.header("authorization"),
            Some(expected_auth.as_str())
        );
        assert_eq!(request.header("accept"), Some("application/json"));
        assert!(request.header("cookie").is_none());
        assert!(request.body.is_empty());
    }
    server.join();
}

#[test]
fn proxy_environment_is_ignored_so_the_bearer_token_never_leaves_for_a_proxy() {
    let server = MockServer::start(vec![MockResponse::new(200, r#"{"items":[]}"#)]);
    let proxy = ProxyTrap::start();
    let base = server.base_url().to_owned();
    let env = TestEnv::new();

    let mut command = env.command();
    command
        .env_remove("NO_PROXY")
        .env_remove("no_proxy")
        .env("HTTP_PROXY", proxy.url())
        .env("http_proxy", proxy.url())
        .env("HTTPS_PROXY", proxy.url())
        .env("https_proxy", proxy.url())
        .env("ALL_PROXY", proxy.url())
        .env("all_proxy", proxy.url())
        .args(["--json", "foods", "search", "oats", "--base-url", &base]);
    let output = command.output().expect("run the calco binary");
    let result = RunResult {
        code: output.status.code(),
        stdout: String::from_utf8(output.stdout).expect("stdout is UTF-8"),
        stderr: String::from_utf8(output.stderr).expect("stderr is UTF-8"),
    };
    let value = compact_stdout_json(&result);
    assert_eq!(value["data"]["items"], json!([]));

    let requests = server.expect_requests(1);
    assert_eq!(requests[0].target, "/api/foods/search?q=oats&scope=all");
    let expected_auth = format!("Bearer {TEST_TOKEN}");
    assert_eq!(
        requests[0].header("authorization"),
        Some(expected_auth.as_str())
    );
    server.join();

    let proxy_requests = proxy.finish();
    assert!(
        proxy_requests.is_empty(),
        "environment proxy unexpectedly received request(s): {proxy_requests:?}"
    );
}

#[test]
fn json_like_values_and_option_terminator_do_not_change_output_mode() {
    let mut add_response = product_food_log("2026-11-15");
    add_response["notes"] = json!("--json");
    let server = MockServer::start(vec![
        MockResponse::new(200, r#"{"items":[]}"#),
        MockResponse::new(201, add_response.to_string()),
    ]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();

    let search = env.run(&["foods", "search", "--base-url", &base, "--", "--json"]);
    assert_eq!(search.code, Some(0), "stderr: {}", search.stderr);
    assert!(search.stderr.is_empty());
    assert_eq!(search.stdout, "No foods found.\n");

    let add = env.run(&[
        "logs",
        "add",
        "--food",
        PRODUCT_ID,
        "--amount",
        "1",
        "--unit",
        "g",
        "--date",
        "2026-11-15",
        "--idempotency-key",
        "flag-like-value-key",
        "--notes=--json",
        "--base-url",
        &base,
    ]);
    assert_eq!(add.code, Some(0), "stderr: {}", add.stderr);
    assert!(add.stderr.is_empty());
    assert!(add.stdout.contains("Added: Oats · 150.5 g · 580 kcal"));
    assert!(add.stdout.contains("Today · 2026-11-15 · Lunch"));
    assert!(!add.stdout.starts_with('{'));

    let requests = server.expect_requests(2);
    assert_eq!(requests[0].target, "/api/foods/search?q=--json&scope=all");
    let body = requests[1].json_body();
    assert_eq!(body["notes"], "--json");
    server.join();
}

#[test]
fn auth_login_rejects_json_and_noninteractive_before_prompting_or_storage() {
    let env = TestEnv::without_token();
    let url = closed_loopback_url();

    let json = env.run(&["--json", "auth", "login", "--base-url", &url]);
    let error = error_json(&json, 2);
    assert_eq!(error["error"]["origin"], "arguments");
    assert_eq!(error["error"]["code"], "invalid_arguments");
    assert!(
        error["error"]["message"]
            .as_str()
            .expect("error message")
            .contains("does not support --json")
    );
    assert!(!json.stderr.contains("CalCo API key"));
    assert!(!json.stdout.contains("CalCo API key"));

    let noninteractive = env.run(&["auth", "login", "--base-url", &url]);
    assert_eq!(
        noninteractive.code,
        Some(2),
        "stderr: {}",
        noninteractive.stderr
    );
    assert!(noninteractive.stdout.is_empty());
    assert!(
        noninteractive
            .stderr
            .contains("requires an interactive terminal")
    );
    assert!(!noninteractive.stderr.contains("CalCo API key"));

    env.assert_no_local_storage();
}

#[test]
fn delete_without_yes_rejects_noninteractive_human_and_json_before_network() {
    let env = TestEnv::new();
    let url = closed_loopback_url();

    let human = env.run(&["logs", "delete", LOG_ID, "--base-url", &url]);
    assert_eq!(human.code, Some(2), "stderr: {}", human.stderr);
    assert!(human.stdout.is_empty());
    assert!(
        human
            .stderr
            .contains("requires --yes when stdin is not interactive")
    );
    assert!(human.stderr.contains("origin: arguments"));

    let json = env.run(&["--json", "logs", "delete", LOG_ID, "--base-url", &url]);
    let error = error_json(&json, 2);
    assert_eq!(error["error"]["origin"], "arguments");
    assert_eq!(error["error"]["code"], "invalid_arguments");
    assert!(
        error["error"]["message"]
            .as_str()
            .expect("error message")
            .contains("requires --yes in JSON mode")
    );

    env.assert_no_local_storage();
}

#[test]
fn log_add_sends_resolved_product_body_and_distinguishes_created_from_replay() {
    let body = product_food_log("2026-11-15").to_string();
    let server = MockServer::start(vec![
        MockResponse::new(201, body.clone()),
        MockResponse::new(200, body),
    ]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();
    let args = [
        "logs",
        "add",
        "--food",
        PRODUCT_ID,
        "--amount",
        "150.5",
        "--unit",
        "g",
        "--date",
        "2026-11-15",
        "--slot",
        "lunch",
        "--notes",
        "lunch note",
        "--device-timezone",
        "Asia/Kolkata",
        "--idempotency-key",
        "test-idempotency-key-1",
        "--json",
        "--base-url",
        &base,
    ];

    let created_run = env.run(&args);
    let created = compact_stdout_json(&created_run);
    assert_eq!(created["data"]["id"], LOG_ID);
    assert_eq!(created["data"]["log_date"], "2026-11-15");
    assert_eq!(created["data"]["quantity"]["amount"], "150.5");
    assert_eq!(
        created["meta"],
        json!({"date": "2026-11-15", "replayed": false})
    );

    let replayed_run = env.run(&args);
    let replayed = compact_stdout_json(&replayed_run);
    assert_eq!(
        replayed["meta"],
        json!({"date": "2026-11-15", "replayed": true})
    );
    assert_eq!(replayed["data"], created["data"]);
    assert!(!created_run.stdout.contains(TEST_TOKEN));
    assert!(!replayed_run.stdout.contains(TEST_TOKEN));

    let requests = server.expect_requests(2);
    let expected_auth = format!("Bearer {TEST_TOKEN}");
    for request in &requests {
        assert_eq!(request.method, "POST");
        assert_eq!(request.target, "/api/logs");
        assert_eq!(request.header("content-type"), Some("application/json"));
        assert_eq!(
            request.header("authorization"),
            Some(expected_auth.as_str())
        );
        assert!(request.header("idempotency-key").is_none());
        let body = request.json_body();
        assert_eq!(body["log_date"], "2026-11-15");
        assert_eq!(body["meal_slot"], "lunch");
        assert_eq!(body["device_timezone"], "Asia/Kolkata");
        assert_eq!(body["notes"], "lunch note");
        assert_eq!(body["item"], json!({"type": "product", "id": PRODUCT_ID}));
        assert_eq!(body["quantity"], json!({"amount": "150.5", "unit": "g"}));
        assert_eq!(body["idempotency_key"], "test-idempotency-key-1");
        assert!(body.get("idempotency-key").is_none());
        assert!(!body.to_string().contains(TEST_TOKEN));
    }
    server.join();
}

#[test]
fn log_add_reports_the_returned_log_date_when_a_replay_differs_from_the_request() {
    let created_body = product_food_log("2026-11-15").to_string();
    let mut replay_log = product_food_log("2026-11-14");
    replay_log["quantity"]["amount"] = json!("200");
    replay_log["nutrients"][0]["amount"] = json!("650");
    let replay_body = replay_log.to_string();
    let server = MockServer::start(vec![
        MockResponse::new(201, created_body),
        MockResponse::new(200, replay_body.clone()),
        MockResponse::new(200, replay_body),
    ]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();
    let args = [
        "logs",
        "add",
        "--food",
        PRODUCT_ID,
        "--amount",
        "150.5",
        "--unit",
        "g",
        "--date",
        "2026-11-15",
        "--slot",
        "lunch",
        "--idempotency-key",
        "date-replay-key-1",
        "--json",
        "--base-url",
        &base,
    ];

    let created_run = env.run(&args);
    let created = compact_stdout_json(&created_run);
    assert_eq!(created["data"]["log_date"], "2026-11-15");
    assert_eq!(created["data"]["log_date"], created["meta"]["date"]);
    assert_eq!(
        created["meta"],
        json!({"date": "2026-11-15", "replayed": false})
    );

    let replayed_run = env.run(&args);
    let replayed = compact_stdout_json(&replayed_run);
    assert_eq!(replayed["data"]["log_date"], "2026-11-14");
    assert_eq!(replayed["data"]["log_date"], replayed["meta"]["date"]);
    assert_eq!(
        replayed["meta"],
        json!({"date": "2026-11-14", "replayed": true})
    );
    assert_eq!(replayed["data"]["quantity"]["amount"], "200");

    let human_args = args
        .iter()
        .copied()
        .filter(|arg| *arg != "--json")
        .collect::<Vec<_>>();
    let human_run = env.run(&human_args);
    assert_eq!(human_run.code, Some(0), "stderr: {}", human_run.stderr);
    assert!(human_run.stderr.is_empty());
    assert!(
        human_run
            .stdout
            .starts_with("Already recorded: Oats · 200 g · 650 kcal\n")
    );
    assert!(human_run.stdout.contains("No new entry created."));
    assert!(human_run.stdout.contains("2026-11-14 · Lunch"));
    assert!(!human_run.stdout.contains("2026-11-15"));
    assert!(!human_run.stdout.contains(TEST_TOKEN));

    let requests = server.expect_requests(3);
    for request in &requests {
        assert_eq!(request.method, "POST");
        assert_eq!(request.target, "/api/logs");
        let body = request.json_body();
        assert_eq!(body["log_date"], "2026-11-15");
        assert_eq!(body["idempotency_key"], "date-replay-key-1");
        assert_eq!(body["quantity"], json!({"amount": "150.5", "unit": "g"}));
    }
    server.join();
}

#[test]
fn log_add_conflict_is_reported_without_retry() {
    let server = MockServer::start(vec![MockResponse::new(
        409,
        error_body(
            "conflict",
            "idempotency key was already used for another request",
        ),
    )]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();

    let result = env.run(&[
        "logs",
        "add",
        "--food",
        PRODUCT_ID,
        "--amount",
        "1",
        "--unit",
        "g",
        "--date",
        "2026-11-15",
        "--idempotency-key",
        "conflict-key",
        "--json",
        "--base-url",
        &base,
    ]);
    let error = error_json(&result, 5);
    assert_eq!(error["error"]["origin"], "server");
    assert_eq!(error["error"]["code"], "conflict");
    assert_eq!(error["error"]["http_status"], 409);
    assert_eq!(error["error"]["uncertain"], false);
    assert!(error["error"].get("request").is_none());
    assert!(
        error["error"]["recovery"]
            .as_str()
            .expect("conflict recovery")
            .contains("This key is bound to a different request")
    );
    assert!(!result.stderr.contains(TEST_TOKEN));

    let requests = server.expect_requests(1);
    assert_eq!(requests[0].json_body()["idempotency_key"], "conflict-key");
    server.join();
}

#[test]
fn malformed_created_response_is_uncertain_and_includes_the_full_resolved_request() {
    let server = MockServer::start(vec![MockResponse::new(
        201,
        format!(r#"{{"id":"{LOG_ID}"}}"#),
    )]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();

    let result = env.run(&[
        "logs",
        "add",
        "--food",
        PRODUCT_ID,
        "--amount",
        "150.5",
        "--unit",
        "g",
        "--date",
        "2026-11-15",
        "--slot",
        "lunch",
        "--notes",
        "lunch note",
        "--device-timezone",
        "Asia/Kolkata",
        "--idempotency-key",
        "malformed-key-1",
        "--json",
        "--base-url",
        &base,
    ]);
    let error = error_json(&result, 6);
    assert_eq!(error["error"]["origin"], "response");
    assert_eq!(error["error"]["code"], "invalid_response");
    assert_eq!(error["error"]["http_status"], 201);
    assert_eq!(error["error"]["uncertain"], true);

    let request = &error["error"]["request"];
    assert_eq!(request["method"], "POST");
    let expected_url = format!("{base}/api/logs");
    assert_eq!(request["url"].as_str(), Some(expected_url.as_str()));
    let body = &request["body"];
    assert_eq!(body["log_date"], "2026-11-15");
    assert_eq!(body["meal_slot"], "lunch");
    assert_eq!(body["device_timezone"], "Asia/Kolkata");
    assert_eq!(body["notes"], "lunch note");
    assert_eq!(body["item"], json!({"type": "product", "id": PRODUCT_ID}));
    assert_eq!(body["quantity"], json!({"amount": "150.5", "unit": "g"}));
    assert_eq!(body["idempotency_key"], "malformed-key-1");

    let recovery = error["error"]["recovery"].as_str().expect("write recovery");
    assert!(recovery.contains("Retry the identical request with the same idempotency key"));
    assert!(recovery.contains("A 200 response means the original write succeeded."));
    assert!(!result.stdout.contains(TEST_TOKEN));
    assert!(!result.stderr.contains(TEST_TOKEN));

    let requests = server.expect_requests(1);
    let expected_auth = format!("Bearer {TEST_TOKEN}");
    assert_eq!(
        requests[0].header("authorization"),
        Some(expected_auth.as_str())
    );
    server.join();
}

#[test]
fn delete_accepts_204_and_reports_missing_ids_without_echoing_tokens() {
    let server = MockServer::start(vec![
        MockResponse::new(204, ""),
        MockResponse::new(404, error_body("not_found", "log not found")),
        MockResponse::new(204, ""),
    ]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();

    let done = env.run(&[
        "logs",
        "delete",
        LOG_ID,
        "--yes",
        "--json",
        "--base-url",
        &base,
    ]);
    let value = compact_stdout_json(&done);
    assert_eq!(value["data"], json!({"id": LOG_ID, "deleted": true}));
    assert_eq!(value["meta"], json!({}));

    let missing = env.run(&[
        "logs",
        "delete",
        LOG_ID,
        "--yes",
        "--json",
        "--base-url",
        &base,
    ]);
    let error = error_json(&missing, 4);
    assert_eq!(error["error"]["origin"], "server");
    assert_eq!(error["error"]["code"], "not_found");
    assert_eq!(error["error"]["http_status"], 404);
    assert_eq!(error["error"]["uncertain"], false);
    assert!(!missing.stderr.contains(TEST_TOKEN));

    let human = env.run(&["logs", "delete", LOG_ID, "--yes", "--base-url", &base]);
    assert_eq!(human.code, Some(0), "stderr: {}", human.stderr);
    assert!(human.stderr.is_empty());
    assert_eq!(human.stdout, format!("Deleted log {LOG_ID}.\n"));

    let requests = server.expect_requests(3);
    let expected_auth = format!("Bearer {TEST_TOKEN}");
    let expected_target = format!("/api/logs/{LOG_ID}");
    for request in &requests {
        assert_eq!(request.method, "DELETE");
        assert_eq!(request.target, expected_target);
        assert!(request.body.is_empty());
        assert_eq!(
            request.header("authorization"),
            Some(expected_auth.as_str())
        );
        assert!(request.header("idempotency-key").is_none());
    }
    server.join();
}

#[test]
fn ranged_logs_are_sequential_and_fail_atomically_mid_range() {
    let success_server = MockServer::start(vec![
        MockResponse::new(
            200,
            log_list_body("2026-11-14", vec![product_food_log("2026-11-14")]),
        ),
        MockResponse::new(200, empty_log_list("2026-11-15")),
        MockResponse::new(200, empty_log_list("2026-11-16")),
    ]);
    let failure_server = MockServer::start(vec![
        MockResponse::new(200, empty_log_list("2026-11-14")),
        MockResponse::new(500, error_body("internal_error", "range failed")),
    ]);
    let env = TestEnv::new();

    let success_base = success_server.base_url().to_owned();
    let success = env.run(&[
        "logs",
        "list",
        "2026-11-14..2026-11-16",
        "--json",
        "--base-url",
        &success_base,
    ]);
    let value = compact_stdout_json(&success);
    assert_eq!(
        value["meta"],
        json!({"from_date": "2026-11-14", "to_date": "2026-11-16"})
    );
    let days = value["data"]["days"].as_array().expect("ranged days array");
    assert_eq!(days.len(), 3);
    assert_eq!(days[0]["date"], "2026-11-14");
    assert_eq!(days[0]["items"].as_array().expect("day items").len(), 1);
    assert_eq!(days[0]["items"][0]["id"], LOG_ID);
    assert_eq!(days[1]["date"], "2026-11-15");
    assert!(days[1]["items"].as_array().expect("day items").is_empty());
    assert_eq!(days[2]["date"], "2026-11-16");
    assert!(days[2]["items"].as_array().expect("day items").is_empty());

    let requests = success_server.expect_requests(3);
    assert_eq!(requests[0].target, "/api/logs?log_date=2026-11-14");
    assert_eq!(requests[1].target, "/api/logs?log_date=2026-11-15");
    assert_eq!(requests[2].target, "/api/logs?log_date=2026-11-16");
    success_server.join();

    let failure_base = failure_server.base_url().to_owned();
    let failure = env.run(&[
        "logs",
        "list",
        "2026-11-14..2026-11-16",
        "--json",
        "--base-url",
        &failure_base,
    ]);
    let error = error_json(&failure, 6);
    assert_eq!(error["error"]["origin"], "server");
    assert_eq!(error["error"]["code"], "internal_error");
    assert_eq!(error["error"]["http_status"], 500);
    assert!(failure.stdout.is_empty());

    let requests = failure_server.expect_requests(2);
    assert_eq!(requests[0].target, "/api/logs?log_date=2026-11-14");
    assert_eq!(requests[1].target, "/api/logs?log_date=2026-11-15");
    failure_server.join();
}

#[test]
fn empty_single_day_log_list_human_output_still_names_the_resolved_date() {
    let server = MockServer::start(vec![MockResponse::new(200, empty_log_list("2026-11-15"))]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();

    let human = env.run(&["logs", "list", "2026-11-15", "--base-url", &base]);
    assert_eq!(human.code, Some(0), "stderr: {}", human.stderr);
    assert!(human.stderr.is_empty());
    assert!(human.stdout.ends_with("2026-11-15\n  No logs.\n"));
    assert!(!human.stdout.contains("No items."));

    let requests = server.expect_requests(1);
    assert_eq!(requests[0].target, "/api/logs?log_date=2026-11-15");
    server.join();
}

#[test]
fn summary_zero_fills_missing_days_and_emits_decimal_totals_and_calendar_averages() {
    let summary = json!({
        "days": [{
            "date": "2026-11-14",
            "energy_kcal": "100",
            "protein_g": "90",
            "carbs_g": "210",
            "fat_g": "60"
        }]
    })
    .to_string();
    let server = MockServer::start(vec![
        MockResponse::new(200, summary.clone()),
        MockResponse::new(200, summary),
    ]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();

    let json_run = env.run(&[
        "summary",
        "2026-11-14..2026-11-16",
        "--json",
        "--base-url",
        &base,
    ]);
    let value = compact_stdout_json(&json_run);
    assert_eq!(
        value["meta"],
        json!({"from_date": "2026-11-14", "to_date": "2026-11-16"})
    );
    let days = value["data"]["days"]
        .as_array()
        .expect("summary days array");
    assert_eq!(days.len(), 3);
    assert_eq!(days[0]["date"], "2026-11-14");
    assert_eq!(days[0]["has_logs"], true);
    assert_eq!(days[0]["energy_kcal"], "100");
    assert_eq!(days[1]["date"], "2026-11-15");
    assert_eq!(days[1]["has_logs"], false);
    assert_eq!(days[2]["date"], "2026-11-16");
    assert_eq!(days[2]["has_logs"], false);
    for key in ["energy_kcal", "protein_g", "carbs_g", "fat_g"] {
        assert_eq!(days[1][key], "0");
        assert_eq!(days[2][key], "0");
        assert!(value["data"]["totals"][key].is_string());
        assert!(value["data"]["averages"][key].is_string());
    }
    assert_eq!(
        value["data"]["totals"],
        json!({
            "energy_kcal": "100",
            "protein_g": "90",
            "carbs_g": "210",
            "fat_g": "60"
        })
    );
    assert_eq!(
        value["data"]["averages"],
        json!({
            "energy_kcal": "33.33",
            "protein_g": "30",
            "carbs_g": "70",
            "fat_g": "20"
        })
    );

    let human = env.run(&["summary", "2026-11-14..2026-11-16", "--base-url", &base]);
    assert_eq!(human.code, Some(0), "stderr: {}", human.stderr);
    assert!(human.stderr.is_empty());
    assert!(human.stdout.lines().any(|line| {
        line.starts_with("DATE")
            && line.contains("KCAL")
            && line.contains("PROTEIN")
            && line.contains("CARBS")
            && line.contains("FAT")
    }));
    assert!(
        human
            .stdout
            .contains("2026-11-15  no logs (not zero intake)")
    );
    assert!(
        human
            .stdout
            .contains("2026-11-16  no logs (not zero intake)")
    );
    assert!(human.stdout.contains("Total       100"));
    assert!(human.stdout.contains("Daily avg   33.33"));
    assert!(!human.stdout.contains("2026-11-15  0"));
    assert!(!human.stdout.contains("energy_kcal"));

    let requests = server.expect_requests(2);
    let expected_auth = format!("Bearer {TEST_TOKEN}");
    for request in &requests {
        assert_eq!(
            request.target,
            "/api/logs/summary?from_date=2026-11-14&to_date=2026-11-16"
        );
        assert_eq!(
            request.header("authorization"),
            Some(expected_auth.as_str())
        );
    }
    server.join();
}

#[test]
fn ad_hoc_logs_are_preserved_in_json_and_escaped_in_human_output() {
    let ad_hoc_name = "Tea\u{1b}[31m";
    let ad_hoc = json!({
        "id": LOG_ID,
        "log_date": "2026-11-15",
        "meal_slot": null,
        "device_timezone": null,
        "item": {"type": "ad_hoc", "name": ad_hoc_name, "brand": null},
        "quantity": {"amount": "0", "unit": "g"},
        "nutrients": [],
        "notes": null,
        "created_at": "2026-11-15T10:00:00Z",
        "updated_at": "2026-11-15T10:00:00Z"
    });
    let list_body = log_list_body("2026-11-15", vec![ad_hoc.clone()]);
    let server = MockServer::start(vec![
        MockResponse::new(200, list_body.clone()),
        MockResponse::new(200, list_body),
        MockResponse::new(200, ad_hoc.to_string()),
    ]);
    let base = server.base_url().to_owned();
    let env = TestEnv::new();

    let json_run = env.run(&["logs", "list", "2026-11-15", "--json", "--base-url", &base]);
    let value = compact_stdout_json(&json_run);
    assert_eq!(value["meta"]["date"], "2026-11-15");
    let item = &value["data"]["items"][0];
    assert_eq!(item["id"], LOG_ID);
    assert_eq!(item["item"]["type"], "ad_hoc");
    assert_eq!(item["item"]["name"].as_str(), Some(ad_hoc_name));
    assert!(item["item"]["brand"].is_null());
    assert!(item["item"].get("id").is_none());
    assert_eq!(item["quantity"]["amount"], "0");
    assert_eq!(item["nutrients"], json!([]));
    assert!(item["meal_slot"].is_null());

    let human = env.run(&["logs", "list", "2026-11-15", "--base-url", &base]);
    assert_eq!(human.code, Some(0), "stderr: {}", human.stderr);
    assert!(human.stderr.is_empty());
    assert!(human.stdout.starts_with("Today · 2026-11-15\n"));
    assert!(human.stdout.contains("  Unspecified\n"));
    assert!(human.stdout.contains("    Tea\\u{001B}[31m · 0 g · -"));
    assert!(!human.stdout.contains('\u{1b}'));
    assert!(human.stdout.contains(&format!("id: {LOG_ID}")));
    assert!(!human.stdout.contains("meal_slot"));
    assert!(!human.stdout.contains("nutrients"));

    let show_run = env.run(&["logs", "show", LOG_ID, "--json", "--base-url", &base]);
    let show = compact_stdout_json(&show_run);
    assert_eq!(show["data"]["item"]["type"], "ad_hoc");
    assert_eq!(show["meta"]["date"], "2026-11-15");
    assert!(!json_run.stdout.contains(TEST_TOKEN));
    assert!(!show_run.stdout.contains(TEST_TOKEN));

    let requests = server.expect_requests(3);
    assert_eq!(requests[0].target, "/api/logs?log_date=2026-11-15");
    assert_eq!(requests[1].target, "/api/logs?log_date=2026-11-15");
    assert_eq!(requests[2].target, format!("/api/logs/{LOG_ID}"));
    server.join();
}
