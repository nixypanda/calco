//! Transport interfaces are introduced after the application service exists.
//!
//! Keeping this module present establishes the bounded-context layout without
//! adding HTTP routes before their authentication and request limits are ready.
