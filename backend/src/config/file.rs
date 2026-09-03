use std::path::Path;

use serde::Deserialize;

use super::ConfigError;

/// Typed settings loaded from `CALCO_CONFIG_FILE`.
///
/// This is intentionally empty until file-owned application features are
/// introduced. Rejecting unknown fields prevents a misspelled or premature
/// setting from being silently ignored.
#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct FileConfig {}

pub(super) fn load_config_file(path: Option<&Path>) -> Result<FileConfig, ConfigError> {
    let Some(path) = path else {
        return Ok(FileConfig::default());
    };

    let raw = std::fs::read_to_string(path).map_err(|_| ConfigError::ConfigFileUnreadable)?;
    toml_edit::de::from_str(&raw).map_err(|_| ConfigError::InvalidToml)
}
