use argon2::Argon2;
use argon2::password_hash::{
    Error as PasswordHashError, PasswordHash as ParsedPasswordHash,
    PasswordHasher as ArgonPasswordHasher, PasswordVerifier as ArgonPasswordVerifier, SaltString,
};

use crate::auth::domain::{
    AuthError, CredentialVerifier, NewPassword, Password, PasswordHash, PasswordHasher,
};

pub struct Argon2Credentials;

impl PasswordHasher for Argon2Credentials {
    fn hash(&self, password: &NewPassword) -> Result<PasswordHash, AuthError> {
        let salt = SaltString::generate(&mut rand::rngs::OsRng);

        Argon2::default()
            .hash_password(password.password().as_bytes(), &salt)
            .map(|hash| PasswordHash(hash.to_string()))
            .map_err(|_| AuthError::CredentialProcessingFailed)
    }
}

impl CredentialVerifier for Argon2Credentials {
    fn verify(&self, password: &Password, expected_hash: &PasswordHash) -> Result<bool, AuthError> {
        let parsed_hash = ParsedPasswordHash::new(&expected_hash.0)
            .map_err(|_| AuthError::CredentialProcessingFailed)?;

        match Argon2::default().verify_password(password.as_bytes(), &parsed_hash) {
            Ok(()) => Ok(true),
            Err(PasswordHashError::Password) => Ok(false),
            Err(_) => Err(AuthError::CredentialProcessingFailed),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_are_salted_and_verify() {
        let credentials = Argon2Credentials;
        let new_password = NewPassword::new("testpassword").unwrap();

        let first_hash = credentials.hash(&new_password).unwrap();
        let second_hash = credentials.hash(&new_password).unwrap();

        assert_ne!(first_hash, second_hash);
        assert!(
            credentials
                .verify(&Password::new("testpassword"), &first_hash)
                .unwrap()
        );
        assert!(
            !credentials
                .verify(&Password::new("wrongpassword"), &first_hash)
                .unwrap()
        );
    }

    #[test]
    fn malformed_hash_is_a_processing_error() {
        let result = Argon2Credentials.verify(
            &Password::new("testpassword"),
            &PasswordHash("not-a-password-hash".into()),
        );

        assert!(matches!(result, Err(AuthError::CredentialProcessingFailed)));
    }
}
