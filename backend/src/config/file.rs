use std::path::{Path, PathBuf};
use std::str::FromStr;

use axum::http::HeaderName;
use serde::{Deserialize, Deserializer};
use url::Url;

use super::ConfigError;

/// Typed settings loaded from `CALCO_CONFIG_FILE`.
///
/// Deserialization either produces a disabled AI capability or a complete,
/// runtime-ready enabled configuration. There is intentionally no public
/// intermediate representation requiring a separate validation pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileConfig {
    pub ai: AiRuntimeSettings,
}

impl Default for FileConfig {
    fn default() -> Self {
        Self {
            ai: AiRuntimeSettings::Disabled,
        }
    }
}

/// AI settings safe to retain during application composition. Enabled settings
/// contain API-key file paths, never API-key contents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AiRuntimeSettings {
    Disabled,
    Enabled(AiEnabledSettings),
}

impl AiRuntimeSettings {
    pub fn is_enabled(&self) -> bool {
        matches!(self, Self::Enabled(_))
    }

    pub fn as_enabled(&self) -> Option<&AiEnabledSettings> {
        match self {
            Self::Disabled => None,
            Self::Enabled(settings) => Some(settings),
        }
    }
}

/// Complete settings for an enabled OpenAI-compatible deployment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiEnabledSettings {
    pub endpoint: Url,
    pub model: AiModel,
    pub supports_images: bool,
    pub authentication: AiAuthenticationSettings,
}

/// A non-empty, trimmed provider model identifier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AiModel(String);

impl AiModel {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Authentication metadata for an enabled AI deployment.
///
/// The credential file path is retained only as deployment metadata. Parsing
/// deliberately does not open, inspect, canonicalize, or otherwise access it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AiAuthenticationSettings {
    None,
    Bearer {
        api_key_file: PathBuf,
    },
    Header {
        header_name: HeaderName,
        api_key_file: PathBuf,
    },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawFileConfig {
    ai: Option<RawAiConfig>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawAiConfig {
    enabled: bool,
    endpoint: Option<String>,
    model: Option<String>,
    #[serde(default)]
    supports_images: bool,
    authentication: Option<RawAuthentication>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawAuthentication {
    kind: RawAuthenticationKind,
    api_key_file: Option<PathBuf>,
    header_name: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum RawAuthenticationKind {
    None,
    Bearer,
    Header,
}

impl<'de> Deserialize<'de> for FileConfig {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawFileConfig::deserialize(deserializer)?;
        raw.into_file_config().map_err(serde::de::Error::custom)
    }
}

impl RawFileConfig {
    fn into_file_config(self) -> Result<FileConfig, &'static str> {
        let Some(ai) = self.ai else {
            return Ok(FileConfig::default());
        };

        if !ai.enabled {
            return Ok(FileConfig::default());
        }

        let endpoint = ai
            .endpoint
            .ok_or("ai.endpoint is required when AI is enabled")
            .and_then(parse_endpoint)?;
        let model = ai
            .model
            .ok_or("ai.model is required when AI is enabled")
            .and_then(parse_model)?;
        let authentication = ai
            .authentication
            .ok_or("ai.authentication is required when AI is enabled")?
            .into_settings()?;

        Ok(FileConfig {
            ai: AiRuntimeSettings::Enabled(AiEnabledSettings {
                endpoint,
                model,
                supports_images: ai.supports_images,
                authentication,
            }),
        })
    }
}

fn parse_endpoint(value: String) -> Result<Url, &'static str> {
    let endpoint =
        Url::parse(&value).map_err(|_| "ai.endpoint must be an HTTP(S) URL with a host")?;
    if matches!(endpoint.scheme(), "http" | "https") && endpoint.host().is_some() {
        Ok(endpoint)
    } else {
        Err("ai.endpoint must be an HTTP(S) URL with a host")
    }
}

fn parse_model(value: String) -> Result<AiModel, &'static str> {
    let value = value.trim();
    if value.is_empty() {
        return Err("ai.model must not be empty");
    }
    Ok(AiModel(value.to_owned()))
}

impl RawAuthentication {
    fn into_settings(self) -> Result<AiAuthenticationSettings, &'static str> {
        match self.kind {
            RawAuthenticationKind::None => {
                if self.api_key_file.is_some() || self.header_name.is_some() {
                    return Err("none authentication cannot include API-key settings");
                }
                Ok(AiAuthenticationSettings::None)
            }
            RawAuthenticationKind::Bearer => {
                if self.header_name.is_some() {
                    return Err("bearer authentication cannot include a header name");
                }
                Ok(AiAuthenticationSettings::Bearer {
                    api_key_file: required_api_key_file(self.api_key_file)?,
                })
            }
            RawAuthenticationKind::Header => {
                let header_name = self
                    .header_name
                    .ok_or("header authentication requires a header name")?;
                let header_name = HeaderName::from_str(header_name.trim())
                    .map_err(|_| "header authentication requires a valid header name")?;
                Ok(AiAuthenticationSettings::Header {
                    header_name,
                    api_key_file: required_api_key_file(self.api_key_file)?,
                })
            }
        }
    }
}

fn required_api_key_file(value: Option<PathBuf>) -> Result<PathBuf, &'static str> {
    let path = value.ok_or("authentication requires an API-key file path")?;
    if path.as_os_str().is_empty() {
        return Err("authentication requires a non-empty API-key file path");
    }
    Ok(path)
}

pub(super) fn load_config_file(path: Option<&Path>) -> Result<FileConfig, ConfigError> {
    let Some(path) = path else {
        return Ok(FileConfig::default());
    };

    let raw = std::fs::read_to_string(path).map_err(|_| ConfigError::ConfigFileUnreadable)?;
    toml_edit::de::from_str(&raw).map_err(|_| ConfigError::InvalidToml)
}
