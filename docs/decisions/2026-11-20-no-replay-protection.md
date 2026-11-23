# No Automatic Replay Protection

- **Status:** Accepted
- **Date:** 2026-11-20

## Decision

CalCo deliberately does not provide automatic replay or duplicate-submission
protection for food-log creation. If a create is retried or submitted twice, a
duplicate food log is acceptable: the user can see it and delete it manually.

We will not build a durable operation journal, request fingerprints, tombstones,
capability negotiation, or similar retry-safe creation infrastructure for this
service. Do not add such infrastructure as a default requirement for new write
paths.

Atomic writes, data ownership, and ordinary validation remain important. This
decision does not discard general integrity, authorization, or validation
guarantees.

Documentation that describes the abandoned idempotency-key API is historical and
does not override this decision.

## Abandoned Branch

The branch `feat/backend-durable-log-ops` and
[PR #51](https://github.com/nixypanda/calco/pull/51) are abandoned; do not
implement or merge them. The branch bundled auth and meal changes that were not
approved through this branch; this decision does not approve those changes.

The branch history still exists in the repository. This decision does not revert
committed branch code and does not authorize undoing applied schema changes or
other existing work.

## Revisit

Revisit only if a demonstrated recurring user problem shows that duplicate logs
or duplicate submissions cause material harm. Speculative future edge cases are
not sufficient.
