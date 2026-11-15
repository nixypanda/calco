//! Configuration, environment and credential stores, prompts, and auth commands.
//!
//! URLs and tokens are resolved with the documented precedence. Saved defaults
//! and keyring credentials are bound to the normalized server URL, and tokens
//! never appear in output or errors.

use std::fmt;
use std::fs::{self, File};
use std::io::{self, Write as IoWrite};
use std::net::Ipv6Addr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use url::{Host, Url};
use zeroize::Zeroize;

use crate::client;
use crate::commands::{GlobalArgs, Runtime};
use crate::output::{self, CliError, CommandOutput, ErrorOrigin};

pub const ENV_BASE_URL: &str = "CALCO_BASE_URL";
pub const ENV_API_KEY: &str = "CALCO_API_KEY";
pub const KEYRING_SERVICE: &str = "calco-cli";

const CONFIG_SCHEMA_VERSION: u32 = 1;
const CONFIG_FILE_NAME: &str = "config.json";

fn invalid_base_url(message: &'static str) -> CliError {
    CliError::new(ErrorOrigin::Arguments, "invalid_base_url", message)
}

// ─── Secret token ────────────────────────────────────────────

pub struct SecretToken(String);

impl SecretToken {
    pub fn new(raw: impl Into<String>) -> Result<Self, CliError> {
        let mut raw = raw.into();
        if raw.trim().is_empty() {
            raw.zeroize();
            return Err(CliError::new(
                ErrorOrigin::Credentials,
                "auth_missing",
                "API key is empty",
            ));
        }
        if !raw.chars().all(|c| c.is_ascii_graphic()) {
            raw.zeroize();
            return Err(CliError::new(
                ErrorOrigin::Credentials,
                "invalid_credentials",
                "API key contains characters that are not allowed in an HTTP header",
            ));
        }
        Ok(Self(raw))
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for SecretToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretToken([REDACTED])")
    }
}

impl fmt::Display for SecretToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("[REDACTED]")
    }
}

impl Drop for SecretToken {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

// ─── Environment and local stores ────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialSource {
    Environment,
    Keyring,
}

pub trait Environment: Send + Sync {
    fn var(&self, name: &str) -> Option<String>;
}

pub struct ProcessEnvironment;

impl Environment for ProcessEnvironment {
    fn var(&self, name: &str) -> Option<String> {
        std::env::var(name).ok()
    }
}

pub trait LocalStores: Send + Sync {
    fn load_default_base_url(&self) -> Result<Option<Url>, CliError>;
    fn save_default_base_url(&self, base_url: &Url) -> Result<(), CliError>;
    fn load_token(&self, base_url: &Url) -> Result<Option<SecretToken>, CliError>;
    fn save_token(&self, base_url: &Url, token: &SecretToken) -> Result<(), CliError>;
    fn delete_token(&self, base_url: &Url) -> Result<bool, CliError>;
}

pub struct OsLocalStores;

impl LocalStores for OsLocalStores {
    fn load_default_base_url(&self) -> Result<Option<Url>, CliError> {
        read_config_file(&config_file_path()?)
    }

    fn save_default_base_url(&self, base_url: &Url) -> Result<(), CliError> {
        write_config_file(&config_file_path()?, base_url)
    }

    fn load_token(&self, base_url: &Url) -> Result<Option<SecretToken>, CliError> {
        let entry = keyring_entry(base_url)?;
        match entry.get_password() {
            Ok(raw) => SecretToken::new(raw).map(Some).map_err(|_| {
                CliError::new(
                    ErrorOrigin::Keyring,
                    "keyring_unavailable",
                    format!(
                        "the stored credential for {} is not a valid API key",
                        canonical_url_string(base_url)
                    ),
                )
            }),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(keyring_error("read", base_url, error)),
        }
    }

    fn save_token(&self, base_url: &Url, token: &SecretToken) -> Result<(), CliError> {
        keyring_entry(base_url)?
            .set_password(token.expose())
            .map_err(|error| keyring_error("save", base_url, error))
    }

    fn delete_token(&self, base_url: &Url) -> Result<bool, CliError> {
        match keyring_entry(base_url)?.delete_credential() {
            Ok(()) => Ok(true),
            Err(keyring::Error::NoEntry) => Ok(false),
            Err(error) => Err(keyring_error("remove", base_url, error)),
        }
    }
}

pub struct ResolvedConnection {
    pub base_url: Url,
    pub token: SecretToken,
    pub source: CredentialSource,
}

// ─── Prompt ──────────────────────────────────────────────────

pub trait SecretPrompt: Send + Sync {
    fn prompt_api_key(&self) -> Result<SecretToken, CliError>;
}

pub struct TtyPrompt;

impl SecretPrompt for TtyPrompt {
    fn prompt_api_key(&self) -> Result<SecretToken, CliError> {
        let raw = rpassword::prompt_password("CalCo API key: ").map_err(|_| {
            CliError::new(
                ErrorOrigin::Internal,
                "internal_error",
                "could not read the API key from the terminal",
            )
        })?;
        SecretToken::new(raw)
    }
}

// ─── URL resolution ──────────────────────────────────────────

pub fn normalize_base_url(raw: &str) -> Result<Url, CliError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(invalid_base_url("base URL is empty"));
    }
    if trimmed.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(invalid_base_url(
            "base URL must not contain whitespace or control characters",
        ));
    }
    if authority_contains_at(trimmed) {
        return Err(invalid_base_url(
            "base URL must not include user information",
        ));
    }

    let mut url =
        Url::parse(trimmed).map_err(|_| invalid_base_url("base URL is not a valid URL"))?;

    if !matches!(url.scheme(), "http" | "https") {
        return Err(invalid_base_url("base URL must use http or https"));
    }
    if !url.username().is_empty() || url.password().is_some() || authority_contains_at(url.as_str())
    {
        return Err(invalid_base_url(
            "base URL must not include user information",
        ));
    }
    if url.host().is_none() {
        return Err(invalid_base_url("base URL must include a host"));
    }
    if url.query().is_some() {
        return Err(invalid_base_url("base URL must not include a query string"));
    }
    if url.fragment().is_some() {
        return Err(invalid_base_url("base URL must not include a fragment"));
    }
    if url.scheme() == "http" && !is_loopback_host(&url) {
        return Err(invalid_base_url(
            "http base URLs are allowed only for loopback hosts",
        ));
    }

    trim_trailing_path_slashes(&mut url)?;
    Ok(url)
}

pub fn resolve_base_url(
    flag: Option<&str>,
    env: &dyn Environment,
    stores: &dyn LocalStores,
) -> Result<Url, CliError> {
    if let Some(raw) = flag {
        return normalize_base_url(raw);
    }

    if let Some(raw) = env.var(ENV_BASE_URL)
        && !raw.trim().is_empty()
    {
        return normalize_base_url(&raw);
    }

    match stores.load_default_base_url()? {
        Some(base_url) => Ok(base_url),
        None => Err(CliError::new(
            ErrorOrigin::Arguments,
            "base_url_missing",
            "no base URL configured; pass --base-url or set CALCO_BASE_URL",
        )),
    }
}

pub fn resolve_token(
    base_url: &Url,
    env: &dyn Environment,
    stores: &dyn LocalStores,
) -> Result<(SecretToken, CredentialSource), CliError> {
    if let Some(raw) = env.var(ENV_API_KEY)
        && !raw.trim().is_empty()
    {
        return Ok((SecretToken::new(raw)?, CredentialSource::Environment));
    }

    match stores.load_token(base_url)? {
        Some(token) => Ok((token, CredentialSource::Keyring)),
        None => Err(CliError::new(
            ErrorOrigin::Credentials,
            "auth_missing",
            "no API key configured; set CALCO_API_KEY or run `calco auth login`",
        )),
    }
}

pub fn resolve_connection(
    flag: Option<&str>,
    env: &dyn Environment,
    stores: &dyn LocalStores,
) -> Result<ResolvedConnection, CliError> {
    let base_url = resolve_base_url(flag, env, stores)?;
    let (token, source) = resolve_token(&base_url, env, stores)?;
    Ok(ResolvedConnection {
        base_url,
        token,
        source,
    })
}

pub fn save_login(
    base_url: &Url,
    token: &SecretToken,
    stores: &dyn LocalStores,
) -> Result<(), CliError> {
    let base_url = normalize_base_url(base_url.as_str())?;
    if let Err(mut error) = stores.save_token(&base_url, token) {
        error.message = format!(
            "the API key was not saved; use CALCO_API_KEY instead ({})",
            error.message
        );
        return Err(error);
    }
    if let Err(mut error) = stores.save_default_base_url(&base_url) {
        let server = canonical_url_string(&base_url);
        error.message = format!(
            "credential was saved for {server} but the default server could not be saved; \
             pass --base-url {server} until it can be saved ({})",
            error.message
        );
        return Err(error);
    }
    Ok(())
}

pub fn delete_login(base_url: &Url, stores: &dyn LocalStores) -> Result<bool, CliError> {
    let base_url = normalize_base_url(base_url.as_str())?;
    stores.delete_token(&base_url)
}

fn is_loopback_host(url: &Url) -> bool {
    match url.host() {
        Some(Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(address)) => address.is_loopback(),
        Some(Host::Ipv6(address)) => address == Ipv6Addr::LOCALHOST,
        None => false,
    }
}

fn authority_contains_at(serialized_url: &str) -> bool {
    let Some((_, rest)) = serialized_url.split_once("://") else {
        return false;
    };
    let authority = rest.split(['/', '?', '#', '\\']).next().unwrap_or_default();
    authority.contains('@')
}

fn trim_trailing_path_slashes(url: &mut Url) -> Result<(), CliError> {
    while url.path().len() > 1 && url.path().ends_with('/') {
        let previous = url.path().to_owned();
        url.path_segments_mut()
            .map_err(|_| invalid_base_url("base URL cannot be used as a base URL"))?
            .pop_if_empty();
        if url.path() == previous {
            break;
        }
    }
    Ok(())
}

pub(crate) fn canonical_url_string(url: &Url) -> String {
    let serialized = url.as_str();
    let trimmed = serialized.trim_end_matches('/');
    if trimmed.is_empty() {
        serialized.to_owned()
    } else {
        trimmed.to_owned()
    }
}

// ─── Config file ─────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
struct ConfigFile {
    schema_version: u32,
    default_base_url: String,
}

fn config_file_path() -> Result<PathBuf, CliError> {
    let project_dirs = ProjectDirs::from("", "", "calco").ok_or_else(|| {
        CliError::new(
            ErrorOrigin::Config,
            "config_read_failed",
            "could not determine the platform config directory",
        )
    })?;
    Ok(project_dirs.config_dir().join(CONFIG_FILE_NAME))
}

fn config_read_error() -> CliError {
    CliError::new(
        ErrorOrigin::Config,
        "config_read_failed",
        "could not read the saved default server configuration",
    )
}

fn config_write_error() -> CliError {
    CliError::new(
        ErrorOrigin::Config,
        "config_write_failed",
        "could not write the saved default server configuration",
    )
}

fn read_config_file(path: &Path) -> Result<Option<Url>, CliError> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(config_read_error()),
    };
    let config: ConfigFile = serde_json::from_slice(&bytes).map_err(|_| config_read_error())?;
    if config.schema_version != CONFIG_SCHEMA_VERSION {
        return Err(CliError::new(
            ErrorOrigin::Config,
            "config_read_failed",
            "saved default server configuration has an unsupported schema version",
        ));
    }
    normalize_base_url(&config.default_base_url)
        .map(Some)
        .map_err(|_| {
            CliError::new(
                ErrorOrigin::Config,
                "invalid_base_url",
                "saved default server URL is invalid",
            )
        })
}

fn write_config_file(path: &Path, base_url: &Url) -> Result<(), CliError> {
    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    let parent = path.parent().ok_or_else(config_write_error)?;
    fs::create_dir_all(parent).map_err(|_| config_write_error())?;

    let config = ConfigFile {
        schema_version: CONFIG_SCHEMA_VERSION,
        default_base_url: canonical_url_string(base_url),
    };
    let bytes = serde_json::to_vec_pretty(&config).map_err(|_| config_write_error())?;

    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(CONFIG_FILE_NAME);
    let temp_path = path.with_file_name(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));

    let result = (|| -> io::Result<()> {
        let mut file = File::create(&temp_path)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp_path, path)
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
        return Err(config_write_error());
    }
    Ok(())
}

// ─── Keyring ─────────────────────────────────────────────────

fn keyring_entry(base_url: &Url) -> Result<keyring::Entry, CliError> {
    keyring::Entry::new(KEYRING_SERVICE, &canonical_url_string(base_url))
        .map_err(|error| keyring_error("open", base_url, error))
}

fn keyring_error(action: &str, base_url: &Url, error: keyring::Error) -> CliError {
    CliError::new(
        ErrorOrigin::Keyring,
        "keyring_unavailable",
        format!(
            "could not {action} the OS credential for {}: {error}",
            canonical_url_string(base_url)
        ),
    )
}

#[derive(Debug, clap::Args)]
pub struct AuthArgs {
    #[command(subcommand)]
    pub command: AuthCommand,
}

#[derive(Debug, clap::Subcommand)]
pub enum AuthCommand {
    Login,
    Status,
    Logout,
}

pub async fn run(
    command: AuthCommand,
    global: &GlobalArgs,
    runtime: &Runtime,
) -> Result<CommandOutput, CliError> {
    match command {
        AuthCommand::Login => run_login(global, runtime).await,
        AuthCommand::Status => run_status(global, runtime).await,
        AuthCommand::Logout => run_logout(global, runtime),
    }
}

async fn run_login(global: &GlobalArgs, runtime: &Runtime) -> Result<CommandOutput, CliError> {
    if global.json {
        return Err(output::arguments_error(
            "invalid_arguments",
            "auth login does not support --json",
        ));
    }
    if !runtime.stdin_is_tty {
        return Err(output::arguments_error(
            "invalid_arguments",
            "auth login requires an interactive terminal",
        ));
    }

    let base_url = resolve_base_url(
        global.base_url.as_deref(),
        runtime.env.as_ref(),
        runtime.stores.as_ref(),
    )?;

    let prompted = runtime.prompt.prompt_api_key()?;
    let probe_token = SecretToken::new(prompted.expose())?;
    let api = client::ApiClient::with_http(base_url.clone(), probe_token, runtime.http.clone());
    api.units().await?;

    save_login(&base_url, &prompted, runtime.stores.as_ref())?;

    let environment_key_active = environment_key_active(runtime);
    Ok(CommandOutput {
        data: Value::Null,
        meta: output::empty_meta(),
        human: render_login(&base_url, environment_key_active),
    })
}

async fn run_status(global: &GlobalArgs, runtime: &Runtime) -> Result<CommandOutput, CliError> {
    let ResolvedConnection {
        base_url,
        token,
        source,
    } = resolve_connection(
        global.base_url.as_deref(),
        runtime.env.as_ref(),
        runtime.stores.as_ref(),
    )?;

    let api = client::ApiClient::with_http(base_url.clone(), token, runtime.http.clone());
    api.units().await?;

    let credential_source = credential_source_label(source);
    let data = json!({
        "base_url": canonical_url_string(&base_url),
        "credential_source": credential_source,
        "probe": {
            "method": "GET",
            "path": "/api/units",
            "http_status": 200,
        },
    });

    Ok(CommandOutput {
        data,
        meta: output::empty_meta(),
        human: render_auth_status(&base_url, credential_source),
    })
}

fn run_logout(global: &GlobalArgs, runtime: &Runtime) -> Result<CommandOutput, CliError> {
    let base_url = resolve_base_url(
        global.base_url.as_deref(),
        runtime.env.as_ref(),
        runtime.stores.as_ref(),
    )?;
    let removed = delete_login(&base_url, runtime.stores.as_ref())?;
    let environment_key_active = environment_key_active(runtime);

    let data = json!({
        "base_url": canonical_url_string(&base_url),
        "removed": removed,
        "environment_key_active": environment_key_active,
    });

    Ok(CommandOutput {
        data,
        meta: output::empty_meta(),
        human: render_auth_logout(&base_url, removed, environment_key_active),
    })
}

fn environment_key_active(runtime: &Runtime) -> bool {
    runtime
        .env
        .var(ENV_API_KEY)
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false)
}

fn credential_source_label(source: CredentialSource) -> &'static str {
    match source {
        CredentialSource::Environment => "environment",
        CredentialSource::Keyring => "keyring",
    }
}

fn render_login(base_url: &url::Url, environment_key_active: bool) -> String {
    let mut lines = vec![
        format!(
            "Logged in to {}.",
            output::escape_text(&canonical_url_string(base_url))
        ),
        "Credential saved to the OS keyring.".to_string(),
    ];
    if environment_key_active {
        lines.push(
            "Warning: CALCO_API_KEY is set and will override the saved credential for later commands."
                .to_string(),
        );
    }
    lines.join("\n") + "\n"
}

fn credential_source_human(source: &str) -> String {
    match source {
        "environment" => "CALCO_API_KEY (environment)".to_string(),
        "keyring" => "OS keyring".to_string(),
        other => output::escape_text(other),
    }
}

fn render_auth_status(base_url: &url::Url, credential_source: &str) -> String {
    [
        format!(
            "Server: {}",
            output::escape_text(&canonical_url_string(base_url))
        ),
        format!(
            "Credentials: {}",
            credential_source_human(credential_source)
        ),
        "Connection: authenticated".to_string(),
    ]
    .join("\n")
        + "\n"
}

fn render_auth_logout(base_url: &url::Url, removed: bool, environment_key_active: bool) -> String {
    let base_url = output::escape_text(&canonical_url_string(base_url));
    let mut lines = if removed {
        vec![
            format!("Logged out of {base_url}."),
            "Removed the saved credential from the OS keyring.".to_string(),
        ]
    } else {
        vec![format!("No saved credential for {base_url}.")]
    };
    if environment_key_active {
        lines.push(
            "Note: CALCO_API_KEY remains active and overrides the stored credential.".to_string(),
        );
    }
    lines.join("\n") + "\n"
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::test_support::{
        FakeEnvironment, FakePrompt, FakeStores, MockServer, global, runtime,
    };

    fn parse_url(raw: &str) -> Url {
        normalize_base_url(raw).unwrap()
    }
    // ─── URL normalization ───────────────────────────────────

    #[test]
    fn normalize_base_url_lowercases_and_removes_default_port_and_slash() {
        let url = parse_url("HTTPS://Example.COM:443/CalCo/");
        assert_eq!(url.scheme(), "https");
        assert_eq!(url.host_str(), Some("example.com"));
        assert_eq!(url.port(), None);
        assert_eq!(url.path(), "/CalCo");
        assert_eq!(canonical_url_string(&url), "https://example.com/CalCo");
    }

    #[test]
    fn normalize_base_url_canonical_root_has_no_trailing_slash() {
        let url = parse_url("https://example.com/");
        assert_eq!(canonical_url_string(&url), "https://example.com");
        assert_eq!(
            canonical_url_string(&parse_url("https://example.com/foo///")),
            "https://example.com/foo"
        );
        assert_eq!(
            canonical_url_string(&parse_url("https://example.com:8443/")),
            "https://example.com:8443"
        );
    }

    #[test]
    fn normalize_base_url_allows_only_loopback_http() {
        for raw in [
            "http://localhost",
            "http://localhost:8080/",
            "http://127.0.0.1",
            "http://127.4.3.2:9000",
            "http://[::1]",
            "http://[::1]:3000/",
            "https://example.com",
            "https://127.0.0.1",
            "https://[::1]",
        ] {
            assert!(normalize_base_url(raw).is_ok(), "{raw} should be accepted");
        }

        for raw in [
            "http://example.com",
            "http://localhost.evil.example",
            "http://[::2]",
            "http://127.0.0.1.evil.example",
        ] {
            assert!(
                normalize_base_url(raw).is_err(),
                "{raw} should require https"
            );
        }
    }

    #[test]
    fn normalize_base_url_rejects_userinfo_query_fragment_and_bad_shapes() {
        for raw in [
            "https://user:pass@example.com",
            "https://user@example.com",
            "https://@example.com",
            "https://example.com?x=1",
            "https://example.com/?",
            "https://example.com/#fragment",
            "ftp://example.com",
            "example.com",
            "/relative",
            "https://",
            "   ",
            "https://exa mple.com",
            "https://example.com/a b",
        ] {
            assert!(normalize_base_url(raw).is_err(), "{raw} should be rejected");
        }
    }

    #[test]
    fn normalize_base_url_errors_never_echo_userinfo() {
        let error = normalize_base_url("https://user:super-secret@example.com").unwrap_err();
        assert_eq!(error.exit_code(), 2);
        assert_eq!(error.code, "invalid_base_url");
        let debug = format!("{error:?}");
        assert!(!error.message.contains("super-secret"));
        assert!(!debug.contains("super-secret"));
        assert!(!error.message.contains("user:pass"));
    }

    #[test]
    fn keyring_identity_matches_normalized_url() {
        let url = parse_url("HTTPS://Example.COM:443/CalCo/");
        assert_eq!(canonical_url_string(&url), "https://example.com/CalCo");
        assert_eq!(
            canonical_url_string(&parse_url("http://127.0.0.1:80/")),
            "http://127.0.0.1"
        );
    }
    // ─── Environment/store precedence ───────────────────────

    struct ConfigEnvironment(HashMap<String, String>);

    impl ConfigEnvironment {
        fn new(values: &[(&str, &str)]) -> Self {
            Self(
                values
                    .iter()
                    .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
                    .collect(),
            )
        }
    }

    impl Environment for ConfigEnvironment {
        fn var(&self, name: &str) -> Option<String> {
            self.0.get(name).cloned()
        }
    }

    #[derive(Default)]
    struct ConfigStores {
        default_base_url: Mutex<Option<Url>>,
        tokens: Mutex<HashMap<String, String>>,
        events: Mutex<Vec<String>>,
        fail_save_token: AtomicBool,
        fail_save_default: AtomicBool,
    }

    impl ConfigStores {
        fn with_default(self, base_url: Url) -> Self {
            *self.default_base_url.lock().unwrap() = Some(base_url);
            self
        }

        fn with_token(self, base_url: &Url, token: &str) -> Self {
            self.tokens
                .lock()
                .unwrap()
                .insert(canonical_url_string(base_url), token.to_owned());
            self
        }

        fn default_url(&self) -> Option<Url> {
            self.default_base_url.lock().unwrap().clone()
        }

        fn token_for(&self, base_url: &Url) -> Option<String> {
            self.tokens
                .lock()
                .unwrap()
                .get(&canonical_url_string(base_url))
                .cloned()
        }

        fn events(&self) -> Vec<String> {
            self.events.lock().unwrap().clone()
        }
    }

    impl LocalStores for ConfigStores {
        fn load_default_base_url(&self) -> Result<Option<Url>, CliError> {
            Ok(self.default_base_url.lock().unwrap().clone())
        }

        fn save_default_base_url(&self, base_url: &Url) -> Result<(), CliError> {
            let key = canonical_url_string(base_url);
            self.events
                .lock()
                .unwrap()
                .push(format!("save_default:{key}"));
            if self.fail_save_default.load(Ordering::SeqCst) {
                return Err(CliError::new(
                    ErrorOrigin::Config,
                    "config_write_failed",
                    "fake config failure",
                ));
            }
            *self.default_base_url.lock().unwrap() = Some(base_url.clone());
            Ok(())
        }

        fn load_token(&self, base_url: &Url) -> Result<Option<SecretToken>, CliError> {
            self.token_for(base_url).map(SecretToken::new).transpose()
        }

        fn save_token(&self, base_url: &Url, token: &SecretToken) -> Result<(), CliError> {
            let key = canonical_url_string(base_url);
            self.events
                .lock()
                .unwrap()
                .push(format!("save_token:{key}"));
            if self.fail_save_token.load(Ordering::SeqCst) {
                return Err(CliError::new(
                    ErrorOrigin::Keyring,
                    "keyring_unavailable",
                    "fake keyring failure",
                ));
            }
            self.tokens
                .lock()
                .unwrap()
                .insert(key, token.expose().to_owned());
            Ok(())
        }

        fn delete_token(&self, base_url: &Url) -> Result<bool, CliError> {
            let key = canonical_url_string(base_url);
            self.events
                .lock()
                .unwrap()
                .push(format!("delete_token:{key}"));
            Ok(self.tokens.lock().unwrap().remove(&key).is_some())
        }
    }

    #[test]
    fn base_url_precedence_is_flag_then_env_then_saved() {
        let saved = parse_url("https://saved.example");
        let stores = ConfigStores::default().with_default(saved.clone());
        let env = ConfigEnvironment::new(&[(ENV_BASE_URL, "https://env.example/")]);

        assert_eq!(
            canonical_url_string(
                &resolve_base_url(Some("https://flag.example/"), &env, &stores).unwrap()
            ),
            "https://flag.example"
        );
        assert_eq!(
            canonical_url_string(&resolve_base_url(None, &env, &stores).unwrap()),
            "https://env.example"
        );

        let blank_env = ConfigEnvironment::new(&[(ENV_BASE_URL, "   ")]);
        assert_eq!(
            canonical_url_string(&resolve_base_url(None, &blank_env, &stores).unwrap()),
            "https://saved.example"
        );

        let missing =
            resolve_base_url(None, &ConfigEnvironment::new(&[]), &ConfigStores::default())
                .unwrap_err();
        assert_eq!(missing.exit_code(), 2);
        assert_eq!(missing.code, "base_url_missing");
    }

    #[test]
    fn invalid_flag_or_env_url_never_falls_back() {
        let stores = ConfigStores::default().with_default(parse_url("https://saved.example"));
        let empty_env = ConfigEnvironment::new(&[]);

        let flag = resolve_base_url(Some("http://example.com"), &empty_env, &stores).unwrap_err();
        assert_eq!(flag.exit_code(), 2);
        assert_eq!(flag.code, "invalid_base_url");

        let env = ConfigEnvironment::new(&[(ENV_BASE_URL, "http://example.com")]);
        let env_error = resolve_base_url(None, &env, &stores).unwrap_err();
        assert_eq!(env_error.exit_code(), 2);
        assert_eq!(env_error.code, "invalid_base_url");
    }

    #[test]
    fn token_precedence_is_environment_then_keyring_then_missing() {
        let base_url = parse_url("https://calco.example");
        let stores = ConfigStores::default().with_token(&base_url, "keyring-token");

        let env = ConfigEnvironment::new(&[(ENV_API_KEY, "env-token")]);
        let (token, source) = resolve_token(&base_url, &env, &stores).unwrap();
        assert_eq!(token.expose(), "env-token");
        assert_eq!(source, CredentialSource::Environment);

        let blank_env = ConfigEnvironment::new(&[(ENV_API_KEY, "  ")]);
        let (token, source) = resolve_token(&base_url, &blank_env, &stores).unwrap();
        assert_eq!(token.expose(), "keyring-token");
        assert_eq!(source, CredentialSource::Keyring);

        let missing = resolve_token(
            &base_url,
            &ConfigEnvironment::new(&[]),
            &ConfigStores::default(),
        )
        .unwrap_err();
        assert_eq!(missing.exit_code(), 3);
        assert_eq!(missing.code, "auth_missing");
    }

    #[test]
    fn environment_token_is_used_verbatim_and_validated_without_echo() {
        let base_url = parse_url("https://calco.example");
        let stores = ConfigStores::default().with_token(&base_url, "keyring-token");
        let env = ConfigEnvironment::new(&[(ENV_API_KEY, "bad token\nwith-control")]);
        let error = resolve_token(&base_url, &env, &stores).unwrap_err();
        assert_eq!(error.exit_code(), 3);
        assert!(!format!("{error:?}").contains("bad token"));
        assert!(!error.message.contains("bad token"));

        let env = ConfigEnvironment::new(&[(ENV_API_KEY, "good-token")]);
        let (token, _) = resolve_token(&base_url, &env, &stores).unwrap();
        assert_eq!(token.expose(), "good-token");
    }

    #[test]
    fn resolve_connection_combines_both_sources() {
        let saved = parse_url("https://saved.example/prefix/");
        let stores = ConfigStores::default()
            .with_default(saved)
            .with_token(&parse_url("https://saved.example/prefix"), "stored");
        let env = ConfigEnvironment::new(&[]);
        let connection = resolve_connection(None, &env, &stores).unwrap();
        assert_eq!(connection.base_url.path(), "/prefix");
        assert_eq!(connection.token.expose(), "stored");
        assert_eq!(connection.source, CredentialSource::Keyring);
    }

    #[test]
    fn save_login_writes_keyring_before_default_and_keeps_token_on_config_failure() {
        let base_url = parse_url("https://calco.example/");
        let token = SecretToken::new("save-secret").unwrap();
        let stores = ConfigStores::default();
        save_login(&base_url, &token, &stores).unwrap();
        assert_eq!(
            stores.events(),
            vec![
                "save_token:https://calco.example".to_owned(),
                "save_default:https://calco.example".to_owned()
            ]
        );
        assert_eq!(stores.token_for(&base_url).as_deref(), Some("save-secret"));

        let failing = ConfigStores::default();
        failing.fail_save_default.store(true, Ordering::SeqCst);
        let error = save_login(&base_url, &token, &failing).unwrap_err();
        assert_eq!(error.exit_code(), 1);
        assert_eq!(error.origin.label(), "config");
        assert!(error.message.contains("--base-url"));
        assert!(!error.message.contains("save-secret"));
        assert!(!format!("{error:?}").contains("save-secret"));
        assert_eq!(failing.token_for(&base_url).as_deref(), Some("save-secret"));
        assert!(failing.default_url().is_none());
    }

    #[test]
    fn save_login_stops_before_config_when_keyring_fails() {
        let base_url = parse_url("https://calco.example");
        let token = SecretToken::new("save-secret").unwrap();
        let stores = ConfigStores::default();
        stores.fail_save_token.store(true, Ordering::SeqCst);
        let error = save_login(&base_url, &token, &stores).unwrap_err();
        assert_eq!(error.exit_code(), 1);
        assert_eq!(error.origin.label(), "keyring");
        assert!(error.message.contains("CALCO_API_KEY"));
        assert!(!error.message.contains("save-secret"));
        assert!(!format!("{error:?}").contains("save-secret"));
        assert!(stores.default_url().is_none());
        assert_eq!(
            stores.events(),
            vec!["save_token:https://calco.example".to_owned()]
        );
    }

    #[test]
    fn delete_login_only_removes_credential() {
        let base_url = parse_url("https://calco.example");
        let stores = ConfigStores::default()
            .with_default(base_url.clone())
            .with_token(&base_url, "remove-secret");
        assert!(delete_login(&base_url, &stores).unwrap());
        assert!(stores.default_url().is_some());
        assert!(stores.token_for(&base_url).is_none());
        assert!(!delete_login(&base_url, &stores).unwrap());
    }
    // ─── Config file ────────────────────────────────────────

    static CONFIG_TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    struct TestDir {
        path: PathBuf,
    }

    impl TestDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "calco-cli-test-{}-{}",
                std::process::id(),
                CONFIG_TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self { path }
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn config_file_contains_only_version_and_canonical_url() {
        let directory = TestDir::new();
        let path = directory.path.join("config.json");
        assert!(read_config_file(&path).unwrap().is_none());

        let base_url = parse_url("HTTPS://Example.COM:443/CalCo/");
        write_config_file(&path, &base_url).unwrap();

        let value: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let object = value.as_object().unwrap();
        assert_eq!(object.len(), 2);
        assert_eq!(value["schema_version"], CONFIG_SCHEMA_VERSION);
        assert_eq!(value["default_base_url"], "https://example.com/CalCo");

        let loaded = read_config_file(&path).unwrap().unwrap();
        assert_eq!(canonical_url_string(&loaded), "https://example.com/CalCo");

        let entries = fs::read_dir(&directory.path).unwrap().count();
        assert_eq!(entries, 1, "atomic write should leave no temp file");
    }

    #[test]
    fn config_file_rejects_unsupported_schema_without_echoing_contents() {
        let directory = TestDir::new();
        let path = directory.path.join("config.json");
        fs::write(
            &path,
            r#"{"schema_version":2,"default_base_url":"https://example.com"}"#,
        )
        .unwrap();
        let error = read_config_file(&path).unwrap_err();
        assert_eq!(error.exit_code(), 1);
        assert_eq!(error.origin.label(), "config");
        assert!(!format!("{error:?}").contains("example.com"));
    }
    #[test]
    fn secret_token_redacts_debug_and_display() {
        let token = SecretToken::new("super-secret-token").unwrap();
        assert_eq!(token.expose(), "super-secret-token");
        assert!(!format!("{token:?}").contains("super-secret-token"));
        assert!(!format!("{token}").contains("super-secret-token"));
    }

    #[test]
    fn secret_token_rejects_blank_and_control_values_without_echo() {
        for raw in ["", "   ", "bad token", "line\nbreak"] {
            let error = SecretToken::new(raw).unwrap_err();
            assert_eq!(error.exit_code(), 3);
            let debug = format!("{error:?}");
            assert!(!debug.contains("bad token"));
            assert!(!debug.contains("line"));
        }
        assert!(!format!("{:?}", SecretToken::new("bad token").unwrap_err()).contains("bad"));
    }
    #[test]
    fn auth_human_output_normalizes_the_base_url_without_a_trailing_slash() {
        let base_url = url::Url::parse("https://calco.example.com/").unwrap();
        assert_eq!(canonical_url_string(&base_url), "https://calco.example.com");

        let status = render_auth_status(&base_url, "environment");
        assert_eq!(
            status,
            "Server: https://calco.example.com\n\
             Credentials: CALCO_API_KEY (environment)\n\
             Connection: authenticated\n"
        );
        assert!(!status.contains("https://calco.example.com/\n"));

        let logout = render_auth_logout(&base_url, true, false);
        assert_eq!(
            logout,
            "Logged out of https://calco.example.com.\n\
             Removed the saved credential from the OS keyring.\n"
        );

        let login = render_login(&base_url, false);
        assert_eq!(
            login,
            "Logged in to https://calco.example.com.\n\
             Credential saved to the OS keyring.\n"
        );
        assert!(!login.contains("Warning:"));
    }

    #[test]
    fn auth_human_output_reports_only_observed_facts() {
        let base_url = url::Url::parse("https://calco.example.com").unwrap();
        let status = render_auth_status(&base_url, "environment");
        assert!(status.contains("Server: https://calco.example.com"));
        assert!(status.contains("Credentials: CALCO_API_KEY (environment)"));
        assert!(status.contains("Connection: authenticated"));
        assert!(!status.contains("probe"));
        assert!(!status.to_ascii_lowercase().contains("token"));

        let keyring = render_auth_status(&base_url, "keyring");
        assert!(keyring.contains("Credentials: OS keyring"));

        let logout = render_auth_logout(&base_url, true, true);
        assert!(logout.contains("Logged out of https://calco.example.com."));
        assert!(logout.contains("Removed the saved credential from the OS keyring."));
        assert!(logout.contains("Note: CALCO_API_KEY remains active"));
        assert!(logout.contains("overrides the stored credential"));
    }

    #[tokio::test]
    async fn login_rejects_json_before_prompting_or_storage() {
        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::default());
        let prompt = Arc::new(FakePrompt::new("prompted-token"));
        let runtime = runtime(env, stores, prompt.clone(), true);

        let error = run(
            AuthCommand::Login,
            &global(true, Some("https://calco.example.com")),
            &runtime,
        )
        .await
        .expect_err("expected an error");

        assert_eq!(error.code, "invalid_arguments");
        assert_eq!(prompt.calls(), 0);
    }

    #[tokio::test]
    async fn login_rejects_non_tty_before_prompting_or_storage() {
        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::default());
        let prompt = Arc::new(FakePrompt::new("prompted-token"));
        let runtime = runtime(env, stores, prompt.clone(), false);

        let error = run(
            AuthCommand::Login,
            &global(false, Some("https://calco.example.com")),
            &runtime,
        )
        .await
        .expect_err("expected an error");

        assert_eq!(error.code, "invalid_arguments");
        assert_eq!(prompt.calls(), 0);
    }

    #[tokio::test]
    async fn login_verifies_prompted_token_saves_before_default_and_warns_about_override() {
        let server = MockServer::start(200, r#"{"items":[]}"#);
        let env = Arc::new(FakeEnvironment::new(&[(ENV_API_KEY, "environment-token")]));
        let stores = Arc::new(FakeStores::default());
        let prompt = Arc::new(FakePrompt::new("prompted-token"));
        let runtime = runtime(env, stores.clone(), prompt.clone(), true);

        let output = run(
            AuthCommand::Login,
            &global(false, Some(server.base_url())),
            &runtime,
        )
        .await
        .expect("successful login");

        assert_eq!(prompt.calls(), 1);
        assert!(output.data.is_null());
        let key = server.base_url().to_owned();
        assert_eq!(
            stores.events(),
            vec![format!("save_token:{key}"), format!("save_default:{key}"),],
            "the credential must be saved before the default URL"
        );
        assert_eq!(stores.token_for(&key).as_deref(), Some("prompted-token"));
        assert_eq!(
            stores
                .default_base_url()
                .map(|base_url| canonical_url_string(&base_url)),
            Some(key.clone())
        );
        assert!(output.human.contains(&format!("Logged in to {key}.")));
        assert!(output.human.contains("Warning: CALCO_API_KEY is set"));
        assert!(!output.human.contains("prompted-token"));
        assert!(!output.human.contains("environment-token"));

        let requests = server.expect_requests(1);
        assert_eq!(requests[0].method, "GET");
        assert_eq!(requests[0].target, "/api/units");
        assert!(requests[0].body.is_empty());
        assert_eq!(
            requests[0].header("authorization"),
            Some("Bearer prompted-token"),
            "login must verify the prompted token even when the environment key is set"
        );
        server.join();
    }

    #[tokio::test]
    async fn login_probe_failure_saves_nothing() {
        let server = MockServer::start(
            401,
            r#"{"error":{"code":"invalid_api_key","message":"bad key"}}"#,
        );
        let env = Arc::new(FakeEnvironment::new(&[(ENV_API_KEY, "environment-token")]));
        let stores = Arc::new(FakeStores::default());
        let prompt = Arc::new(FakePrompt::new("prompted-token"));
        let runtime = runtime(env, stores.clone(), prompt.clone(), true);

        let error = run(
            AuthCommand::Login,
            &global(false, Some(server.base_url())),
            &runtime,
        )
        .await
        .expect_err("rejected login");

        assert_eq!(prompt.calls(), 1);
        assert_eq!(error.code, "invalid_api_key");
        assert_eq!(error.exit_code(), 3);
        assert!(stores.events().is_empty());
        assert!(!stores.has_token(server.base_url()));
        assert!(stores.default_base_url().is_none());
        assert!(!error.message.contains("prompted-token"));
        assert!(!error.message.contains("environment-token"));

        let requests = server.expect_requests(1);
        assert_eq!(
            requests[0].header("authorization"),
            Some("Bearer prompted-token")
        );
        server.join();
    }

    #[tokio::test]
    async fn login_keyring_failure_keeps_the_existing_default_server() {
        let server = MockServer::start(200, r#"{"items":[]}"#);
        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::with_default("https://previous.example"));
        stores.fail_save_token.store(true, Ordering::SeqCst);
        let prompt = Arc::new(FakePrompt::new("prompted-token"));
        let runtime = runtime(env, stores.clone(), prompt, true);

        let error = run(
            AuthCommand::Login,
            &global(false, Some(server.base_url())),
            &runtime,
        )
        .await
        .expect_err("failed login");

        let key = server.base_url().to_owned();
        assert_eq!(error.code, "keyring_unavailable");
        assert_eq!(error.exit_code(), 1);
        assert_eq!(stores.events(), vec![format!("save_token:{key}")]);
        assert!(!stores.has_token(&key));
        assert_eq!(
            stores
                .default_base_url()
                .map(|base_url| canonical_url_string(&base_url))
                .as_deref(),
            Some("https://previous.example")
        );
        server.join();
    }

    #[tokio::test]
    async fn login_config_failure_keeps_the_existing_default_server() {
        let server = MockServer::start(200, r#"{"items":[]}"#);
        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::with_default("https://previous.example"));
        stores.fail_save_default.store(true, Ordering::SeqCst);
        let prompt = Arc::new(FakePrompt::new("prompted-token"));
        let runtime = runtime(env, stores.clone(), prompt, true);

        let error = run(
            AuthCommand::Login,
            &global(false, Some(server.base_url())),
            &runtime,
        )
        .await
        .expect_err("failed login");

        let key = server.base_url().to_owned();
        assert_eq!(error.code, "config_write_failed");
        assert_eq!(error.exit_code(), 1);
        assert!(error.message.contains("--base-url"));
        assert_eq!(
            stores.events(),
            vec![format!("save_token:{key}"), format!("save_default:{key}"),]
        );
        assert_eq!(stores.token_for(&key).as_deref(), Some("prompted-token"));
        assert_eq!(
            stores
                .default_base_url()
                .map(|base_url| canonical_url_string(&base_url))
                .as_deref(),
            Some("https://previous.example"),
            "a failed config write must not change the saved default server"
        );
        server.join();
    }

    #[tokio::test]
    async fn logout_removes_only_the_stored_credential_and_reports_environment_override() {
        let env = Arc::new(FakeEnvironment::new(&[(ENV_API_KEY, "environment-token")]));
        let stores = Arc::new(FakeStores::logged_in(
            "https://calco.example.com",
            "stored-token",
        ));
        assert!(
            stores.has_token("https://calco.example.com"),
            "the test must start with a stored credential"
        );
        let prompt = Arc::new(FakePrompt::new("unused"));
        let runtime = runtime(env, stores.clone(), prompt, true);

        let output = run(AuthCommand::Logout, &global(false, None), &runtime)
            .await
            .unwrap();

        assert_eq!(output.data["base_url"], "https://calco.example.com");
        assert_eq!(output.data["removed"], true);
        assert_eq!(output.data["environment_key_active"], true);
        assert!(!stores.has_token("https://calco.example.com"));
        assert_eq!(
            stores
                .default_base_url()
                .map(|base_url| canonical_url_string(&base_url))
                .as_deref(),
            Some("https://calco.example.com"),
            "logout must not remove the saved default server"
        );
        assert_eq!(
            stores.events(),
            vec!["delete_token:https://calco.example.com".to_string()]
        );
        assert!(!output.human.contains("stored-token"));
        assert!(!output.human.contains("environment-token"));
    }

    #[tokio::test]
    async fn logout_succeeds_when_no_stored_credential_exists() {
        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::with_default("https://calco.example.com"));
        assert!(!stores.has_token("https://calco.example.com"));
        let prompt = Arc::new(FakePrompt::new("unused"));
        let runtime = runtime(env, stores.clone(), prompt, true);

        let output = run(AuthCommand::Logout, &global(false, None), &runtime)
            .await
            .unwrap();

        assert_eq!(output.data["base_url"], "https://calco.example.com");
        assert_eq!(output.data["removed"], false);
        assert_eq!(output.data["environment_key_active"], false);
        assert!(!stores.has_token("https://calco.example.com"));
        assert_eq!(
            stores
                .default_base_url()
                .map(|base_url| canonical_url_string(&base_url))
                .as_deref(),
            Some("https://calco.example.com")
        );
    }

    #[tokio::test]
    async fn status_requires_a_credential_before_probing() {
        let env = Arc::new(FakeEnvironment::default());
        let stores = Arc::new(FakeStores::with_default("https://calco.example.com"));
        let prompt = Arc::new(FakePrompt::new("unused"));
        let runtime = runtime(env, stores, prompt, true);

        let error = run(AuthCommand::Status, &global(false, None), &runtime)
            .await
            .expect_err("expected an error");

        assert_eq!(error.code, "auth_missing");
    }
}
