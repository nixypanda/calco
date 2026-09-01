use std::path::{Path, PathBuf};
use std::str::FromStr;

use axum::http::HeaderName;
use toml_edit::{DocumentMut, Table};
use url::Url;

use super::{AiAuthenticationSettings, AiEnabledSettings, AiRuntimeSettings, ConfigError};

pub(super) fn load_ai_settings(path: &Path) -> Result<AiRuntimeSettings, ConfigError> {
    let raw = std::fs::read_to_string(path).map_err(|_| ConfigError::ConfigFileUnreadable)?;
    let file = parse_config_file(&raw)?;

    let Some(ai) = file.ai else {
        return Ok(AiRuntimeSettings::Disabled);
    };
    if !ai.enabled {
        return Ok(AiRuntimeSettings::Disabled);
    }

    let endpoint = ai.endpoint.ok_or(ConfigError::InvalidField {
        field: "ai.endpoint",
    })?;
    let endpoint = Url::parse(&endpoint)
        .ok()
        .filter(|url| matches!(url.scheme(), "http" | "https") && url.host().is_some())
        .ok_or(ConfigError::InvalidField {
            field: "ai.endpoint",
        })?;
    let model = ai
        .model
        .filter(|model| !model.trim().is_empty())
        .ok_or(ConfigError::InvalidField { field: "ai.model" })?;
    let authentication = ai
        .authentication
        .ok_or(ConfigError::InvalidField {
            field: "ai.authentication",
        })?
        .validate()?;

    // Verify startup can read the secret now, then immediately drop it. The
    // future provider adapter calls `read_api_key` once and owns that value.
    let _ = authentication.read_api_key()?;

    Ok(AiRuntimeSettings::Enabled(AiEnabledSettings {
        endpoint,
        model: model.trim().to_owned(),
        supports_images: ai.supports_images,
        authentication,
    }))
}

#[derive(Default)]
struct CalcoConfigFile {
    ai: Option<AiFileConfig>,
}

struct AiFileConfig {
    enabled: bool,
    endpoint: Option<String>,
    model: Option<String>,
    supports_images: bool,
    authentication: Option<AiAuthenticationFileConfig>,
}

struct AiAuthenticationFileConfig {
    kind: String,
    api_key_file: Option<PathBuf>,
    header_name: Option<String>,
}

impl AiAuthenticationFileConfig {
    fn validate(self) -> Result<AiAuthenticationSettings, ConfigError> {
        match self.kind.as_str() {
            "none" => {
                if self.api_key_file.is_some() {
                    return Err(ConfigError::InvalidField {
                        field: "ai.authentication.api_key_file",
                    });
                }
                if self.header_name.is_some() {
                    return Err(ConfigError::InvalidField {
                        field: "ai.authentication.header_name",
                    });
                }
                Ok(AiAuthenticationSettings::None)
            }
            "bearer" => {
                if self.header_name.is_some() {
                    return Err(ConfigError::InvalidField {
                        field: "ai.authentication.header_name",
                    });
                }
                let api_key_file = self.api_key_file.ok_or(ConfigError::InvalidField {
                    field: "ai.authentication.api_key_file",
                })?;
                if api_key_file.as_os_str().is_empty() {
                    return Err(ConfigError::InvalidField {
                        field: "ai.authentication.api_key_file",
                    });
                }
                Ok(AiAuthenticationSettings::Bearer { api_key_file })
            }
            "header" => {
                let header_name = self
                    .header_name
                    .filter(|name| !name.trim().is_empty())
                    .and_then(|name| HeaderName::from_str(&name).ok())
                    .ok_or(ConfigError::InvalidField {
                        field: "ai.authentication.header_name",
                    })?;
                let api_key_file = self.api_key_file.ok_or(ConfigError::InvalidField {
                    field: "ai.authentication.api_key_file",
                })?;
                if api_key_file.as_os_str().is_empty() {
                    return Err(ConfigError::InvalidField {
                        field: "ai.authentication.api_key_file",
                    });
                }
                Ok(AiAuthenticationSettings::Header {
                    header_name,
                    api_key_file,
                })
            }
            _ => Err(ConfigError::InvalidField {
                field: "ai.authentication.kind",
            }),
        }
    }
}

fn parse_config_file(raw: &str) -> Result<CalcoConfigFile, ConfigError> {
    let document = raw
        .parse::<DocumentMut>()
        .map_err(|_| ConfigError::InvalidToml)?;
    reject_unknown_fields(document.as_table(), &["ai"], "CALCO_CONFIG_FILE")?;

    let Some(ai) = document.get("ai") else {
        return Ok(CalcoConfigFile::default());
    };
    let ai = ai
        .as_table()
        .ok_or(ConfigError::InvalidField { field: "ai" })?;
    reject_unknown_fields(
        ai,
        &[
            "enabled",
            "endpoint",
            "model",
            "supports_images",
            "authentication",
        ],
        "ai",
    )?;

    Ok(CalcoConfigFile {
        ai: Some(AiFileConfig {
            enabled: required_bool(ai, "enabled", "ai.enabled")?,
            endpoint: optional_string(ai, "endpoint", "ai.endpoint")?,
            model: optional_string(ai, "model", "ai.model")?,
            supports_images: optional_bool(ai, "supports_images", "ai.supports_images")?
                .unwrap_or(false),
            authentication: optional_authentication(ai)?,
        }),
    })
}

fn optional_authentication(
    table: &Table,
) -> Result<Option<AiAuthenticationFileConfig>, ConfigError> {
    let Some(item) = table.get("authentication") else {
        return Ok(None);
    };
    let authentication = item.as_table().ok_or(ConfigError::InvalidField {
        field: "ai.authentication",
    })?;
    reject_unknown_fields(
        authentication,
        &["kind", "api_key_file", "header_name"],
        "ai.authentication",
    )?;

    Ok(Some(AiAuthenticationFileConfig {
        kind: optional_string(authentication, "kind", "ai.authentication.kind")?
            .filter(|kind| !kind.trim().is_empty())
            .ok_or(ConfigError::InvalidField {
                field: "ai.authentication.kind",
            })?,
        api_key_file: optional_string(
            authentication,
            "api_key_file",
            "ai.authentication.api_key_file",
        )?
        .map(PathBuf::from),
        header_name: optional_string(
            authentication,
            "header_name",
            "ai.authentication.header_name",
        )?,
    }))
}

fn required_bool(table: &Table, name: &str, field: &'static str) -> Result<bool, ConfigError> {
    optional_bool(table, name, field)?.ok_or(ConfigError::InvalidField { field })
}

fn optional_bool(
    table: &Table,
    name: &str,
    field: &'static str,
) -> Result<Option<bool>, ConfigError> {
    match table.get(name) {
        None => Ok(None),
        Some(item) => item
            .as_bool()
            .ok_or(ConfigError::InvalidField { field })
            .map(Some),
    }
}

fn optional_string(
    table: &Table,
    name: &str,
    field: &'static str,
) -> Result<Option<String>, ConfigError> {
    match table.get(name) {
        None => Ok(None),
        Some(item) => item
            .as_str()
            .ok_or(ConfigError::InvalidField { field })
            .map(|value| Some(value.to_owned())),
    }
}

fn reject_unknown_fields(
    table: &Table,
    allowed: &[&str],
    field: &'static str,
) -> Result<(), ConfigError> {
    if table.iter().any(|(name, _)| !allowed.contains(&name)) {
        return Err(ConfigError::InvalidField { field });
    }
    Ok(())
}
