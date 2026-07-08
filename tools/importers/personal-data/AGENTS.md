# Personal Data Import Agent Guardrails

Read `../../../AGENTS.md`, `../../README.md`, `README.md`, and
`../../../docs/imports.md` before changing this importer.

- This directory handles private user import workflows, currently centered on
  MyFitnessPal exports.
- Raw exports and review CSVs can contain private food, diary, and account
  information. Do not log or document personal values unless the task requires
  a specific local review artifact.
- Keep transformations explicit and reproducible through the numbered pipeline
  outputs.
- Review state belongs in pipeline-owned CSV/JSONL files under `data/`.
- Use user-facing CalCo APIs for food creation and diary import.
- Do not overwrite finalized review CSVs blindly; write a new output and
  compare before merging decisions.

Run the checks documented in `README.md` before handing off importer changes.
