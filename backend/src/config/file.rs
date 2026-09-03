use std::path::Path;

use toml_edit::DocumentMut;

use super::ConfigError;

pub(super) fn validate_config_file(path: Option<&Path>) -> Result<(), ConfigError> {
    let Some(path) = path else {
        return Ok(());
    };

    let raw = std::fs::read_to_string(path).map_err(|_| ConfigError::ConfigFileUnreadable)?;
    let document = raw
        .parse::<DocumentMut>()
        .map_err(|_| ConfigError::InvalidToml)?;

    if !document.as_table().is_empty() {
        return Err(ConfigError::InvalidField {
            field: "CALCO_CONFIG_FILE",
        });
    }

    Ok(())
}
