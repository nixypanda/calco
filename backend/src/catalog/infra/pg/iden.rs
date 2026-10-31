use sea_query::Iden;

/// Schema identifiers shared by more than one catalog repository.
///
/// Repo-local tables stay next to the repository that owns them.
#[derive(Iden)]
pub(super) enum Nutrients {
    Table,
    Id,
    Code,
    Name,
    Unit,
    Category,
}
