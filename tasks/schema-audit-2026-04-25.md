# DB Schema Audit — Sprint 0 Task 0.1

**Date:** 2026-04-25
**Backend submodule:** `/Users/douglasswm/Project/AAS/VER/VerdictCouncil_Backend/`
**Migrations head:** `0024_pipeline_events_replay.py`
**Scope:** every pipeline-touching table. Feeds Sprint 0.5 (target schema doc) + Sprint 2 migrations.

All file:line citations are absolute paths inside the backend submodule. Where a claim could not be confirmed it is flagged "ambiguous". The seed findings supplied in the task brief are corrected inline where the source disagreed.

---

## 1. `audit_logs` (table name plural — confirmed `src/models/audit.py:18`)

### Columns
- Defined at `src/models/audit.py:17-37` and migration `alembic/versions/0001_initial_schema.py:279-295`.
  - `id` UUID PK (mixin).
  - `case_id` UUID, NOT NULL, FK `cases.id` ON DELETE CASCADE.
  - `agent_name` String(100), NOT NULL.
  - `action` String(255), NOT NULL.
  - `input_payload`, `output_payload`, `llm_response`, `tool_calls`, `token_usage` JSONB, nullable.
  - `system_prompt` Text, nullable.
  - `model` String(100), nullable.
  - `created_at` timestamptz, NOT NULL, server_default now().
- Indexes (migration only):
  - `ix_audit_logs_case_id` (`case_id`) — `0001_initial_schema.py:295`.
- The `solace_message_id` column was dropped by `0023_drop_solace_message_id.py`.

### Writers (INSERT — `AuditLog(...)` constructor)
- `persist_finalize_audit (src/db/persist_case_results.py:325)` — terminal pipeline persist.
- `submit_reopen_request (src/api/routes/reopen_requests.py:63)` — judge submits reopen.
- `review_reopen_request (src/api/routes/reopen_requests.py:144)` — admin/senior_judge approves/rejects.
- `update_case_data (src/api/routes/case_data.py:338)` — judge edits case fields pre-pipeline.
- `start_pipeline_via_case_data (src/api/routes/case_data.py:437)` — outbox enqueue side-effect.
- `create_hearing_note (src/api/routes/hearing_notes.py:50)` and update / lock / delete (`:121`, `:154`, `:193`).
- `create_case (src/api/routes/cases.py:1607)`, `cancel_case (:1674)`, gate-related writes at `:1734`, `:1795`, `:1850`.
- `confirm_intake (src/api/routes/judge.py:87)`.

### Readers (SELECT)
- `list_audit_logs (src/api/routes/audit.py:32-52)` — `WHERE case_id = ?` AND optional `agent_name` AND created_at range.
- `case_data audit listing (src/api/routes/case_data.py:503)` — `WHERE case_id = ?`, ordered by created_at.
- `judge` route audit listings at `src/api/routes/judge.py:208`, `:353`.
- Eager-loaded as relationship `Case.audit_logs` via selectinload at `src/services/case_report_data.py:59`, `src/api/routes/cases.py:599`, `:948`, `:993`.

### Cruft flags
- **No index on `agent_name`** despite filter at `src/api/routes/audit.py:43`. Confirmed (no matching `create_index` in any migration). Will be a sequential scan as table grows.
- **No index on `created_at`** despite range filter at `:45`/`:47`. Same scan risk for time-bounded queries.
- `llm_response`, `tool_calls`, `token_usage` are written but NEVER projected in any reader's `select()`; only `selectinload` of the whole row pulls them. They are effectively a write-only blob — confirms seed.
- No retention/TTL policy; rows accumulate forever. Nothing in `src/` references deletion.

### Notes for new 6-agent topology
- Per-agent name string is opaque; if agent set churns there is no enum constraint. New topology should fix a versioned set or move to an `agent_id` FK.
- Token-usage / cost analytics will require an actual reader of `token_usage` (currently nobody reads it).

---

## 2. `pipeline_checkpoints` (plural — `src/models/pipeline_checkpoint.py:26`)

### Columns
- Migration `alembic/versions/0009_pipeline_checkpoints.py:18-37`; model at `src/models/pipeline_checkpoint.py:25-39`.
  - `case_id` UUID, NOT NULL.
  - `run_id` Text, NOT NULL.
  - `agent_name` Text, NOT NULL.
  - `case_state` JSONB, NOT NULL.
  - `updated_at` timestamptz, NOT NULL, server_default NOW().
- Composite PK `(case_id, run_id)` (migration `:31`).
- Index `ix_pipeline_checkpoints_case_id (case_id)` at migration `:33-37`.

### Writers
- `persist_case_state (src/db/pipeline_state.py:85-157)` — single upsert function. Uses raw SQL, retries on transient OperationalError/DBAPIError, raises on IntegrityError, swallows unknown.
- Callers of that function:
  - `src/pipeline/graph/nodes/common.py:382` (after every agent resolves).
  - `src/db/persist_case_results.py:94` (terminal persist).
  - `src/api/routes/cases.py:1422` (gate-state save path).
  - `src/workers/tasks.py:234` (worker gate resume).

### Readers
- `load_case_state (src/db/pipeline_state.py:160-212)` — single read function.
- Callers: `src/api/routes/what_if.py:94`, `:183`; `src/workers/tasks.py:143`.

### Cruft flags
- **`schema_version` lives INSIDE the JSON `case_state`**, not as a column. `pipeline_state.py:42` declares `CURRENT_SCHEMA_VERSION = 2`; loader at `:195-205` rejects rows missing or mismatching this field. **Correction to seed**: there is no row-level `schema_version` column — the v1 rejection is on the JSON property `case_state.schema_version`.
- Default `CaseState.schema_version = 2` (`src/shared/case_state.py:91`), so writers always emit v2. Any v1 row is therefore pre-bump legacy.
- Composite PK `(case_id, run_id)` means only one checkpoint per run — earlier per-agent checkpoints are overwritten. This is by design (latest-only) but means crash recovery cannot replay step-by-step; only the last successful agent's state survives.
- No `ON DELETE CASCADE` from `cases` (PK has no FK declared at all in migration `0009`). Orphan checkpoints persist after `cases` row deletion.
- No retention/TTL; rows accumulate.

### Notes for new 6-agent topology
- Per-step replay (the new topology may need finer-grained recovery) requires either (case_id, run_id, agent_name) PK or an append-only model.
- Bumping CaseState payload schema requires a migration of stored rows or a fail-loud deployment cut-over (already partially codified by `CURRENT_SCHEMA_VERSION`).

---

## 3. `pipeline_events` (plural — `src/models/pipeline_event.py:20`)

### Columns
- Migration `alembic/versions/0024_pipeline_events_replay.py:21-47`; model `src/models/pipeline_event.py:13-33`.
  - `id` UUID PK, server_default `gen_random_uuid()`.
  - `case_id` UUID, NOT NULL (model has `index=True` but the migration's table-level Index covers `(case_id, ts)`; the per-column index from `index=True` is a model artefact only — ambiguous whether it physically exists).
  - `kind` Text, NOT NULL.
  - `schema_version` Integer, NOT NULL, server_default `1`.
  - `agent` Text, nullable.
  - `ts` timestamptz, NOT NULL, server_default NOW().
  - `payload` JSONB, NOT NULL.
- Indexes: `ix_pipeline_events_case_ts (case_id, ts)`; `ix_pipeline_events_payload_gin (payload USING gin)` — both at migration `:41-47`.

### Writers
- `_tee_write (src/services/pipeline_events.py:24-52)` — fire-and-forget INSERT, swallows all exceptions. Called from:
  - `publish_progress (src/services/pipeline_events.py:81-92)`.
  - `publish_agent_event (:95-115)`.
  - `publish_narration (:118-144)`.

### Readers
- `list_pipeline_events (src/api/routes/cases.py:1080-1115)` — `select(PipelineEvent).where(case_id=?).order_by(ts.asc())`.
- No other readers.

### Cruft flags
- **Hardcoded `schema_version=1` everywhere**. Every emitter uses `Literal[1] = 1` (`src/api/schemas/pipeline_events.py:40`, `:88`, `:105`, `:117`, `:125`); the `_tee_write` line `int(payload.get("schema_version", 1))` (`src/services/pipeline_events.py:44`) inherits it. There is no bump path. Confirms seed.
- Fire-and-forget — writes are awaited via `asyncio.create_task` then never reaped. Failures only show in logs (`logger.exception` at `:52`).
- GIN index on `payload` (`ix_pipeline_events_payload_gin`) implies the team intends JSONB queries, but no reader uses `payload @>` / `payload ?` / `jsonb_path_exists`. Index is unused as of HEAD — confirms seed.
- `agent` is nullable Text rather than constrained to the agent enum.
- No retention/TTL.

### Notes for new 6-agent topology
- Replay for the new topology will exercise the GIN index — at that point the index becomes load-bearing.
- A `schema_version` bump is needed before the new event kinds ship; otherwise consumers cannot distinguish.

---

## 4. `pipeline_jobs` (plural — `src/models/pipeline_job.py:42`)

### Columns
- Migration `alembic/versions/0013_add_pipeline_jobs.py:48-92`; model `src/models/pipeline_job.py:32-63`.
  - `id` UUID PK, server_default `gen_random_uuid()`.
  - `case_id` UUID, NOT NULL, FK `cases.id` ON DELETE CASCADE.
  - `job_type` ENUM `pipelinejobtype` (values: `case_pipeline`, `whatif_scenario`, `stability_computation`, `gate_run` added in `0017_gate_model.py:48`, `intake_extraction` added in `0021_intake_draft_states_and_document_kind.py:49`).
  - `target_id` UUID, nullable.
  - `status` ENUM `pipelinejobstatus` (`pending`, `dispatched`, `completed`, `failed`), NOT NULL, default `pending`.
  - `attempts` Integer, NOT NULL, default 0.
  - `payload` JSONB, nullable.
  - `error_message` Text, nullable.
  - `created_at`, `dispatched_at`, `completed_at` timestamptz.
- Indexes: `ix_pipeline_jobs_status_created_at (status, created_at)`, `ix_pipeline_jobs_case_id (case_id)` — migration `:83-92`.

### Writers
- `enqueue_outbox_job (src/workers/outbox.py:24-47)` — INSERT pending row.
- `mark_dispatched (:86-94)` — UPDATE pending → dispatched.
- `mark_completed (:106-107)` — UPDATE dispatched → completed.
- `mark_failed (:122-131)` — UPDATE dispatched → failed AND `attempts = attempts + 1`.
- `recover_stuck_jobs (:149-156)` — UPDATE dispatched → pending if `dispatched_at` older than threshold (sets `dispatched_at=NULL`).
- API call sites of `enqueue_outbox_job` (state-flip + outbox in same tx):
  - `src/api/routes/cases.py:719`, `:752`, `:1500`, `:1617`, `:1685`, `:1749`.
  - `src/api/routes/case_data.py:360`, `:461`.
  - `src/api/routes/reopen_requests.py:136`.
  - `src/api/routes/what_if.py:303`, `:418`.

### Readers
- `claim_pending_jobs (src/workers/outbox.py:65-74)` — `SELECT … WHERE status='pending' FOR UPDATE SKIP LOCKED`.
- `_run_with_outbox (src/workers/tasks.py)` reads single rows by id (idempotency check).
- Dispatcher loop `src/workers/dispatcher.py:28-66` consumes claim results.

### Cruft flags
- **Correction to seed**: `attempts` IS incremented on failure (`mark_failed`, `outbox.py:114`). Seed claim "never incremented" is wrong.
- No retry policy on `attempts` — failed rows never re-enter `pending`. Once `failed`, they stay there. Effectively single-shot.
- No index on `attempts` or on `(status, dispatched_at)` for the `recover_stuck_jobs` predicate (`outbox.py:138-145`); recovery scan uses `ix_pipeline_jobs_status_created_at` plus a filter — adequate but not optimal.
- `error_message` is truncated to 1000 chars at write (`outbox.py:130`) but column is unbounded `Text`; cap should match.

### Notes for new 6-agent topology
- New gate / agent boundaries will likely add new `job_type` values — keep the additive enum migration pattern (`ALTER TYPE ... ADD VALUE`).
- Failure-retry semantics need to be decided before migrating: requeue with `attempts < max_attempts` or terminal-on-first-fail.

---

## 5. `cases` (plural — `src/models/case.py:146`)

### Columns (relevant subset; full enum set at `case.py:31-138`)
- `id` UUID PK; mixin `TimestampMixin` adds `created_at` (NOT NULL, default now()) and `updated_at` (nullable, onupdate=now()).
- `domain` ENUM `CaseDomain` (`small_claims`, `traffic_violation`), NOT NULL — `case.py:148`.
- `domain_id` UUID, nullable, FK `domains.id` — `case.py:163-165` (added in `0019_add_domains_and_case_domain_fk.py:80-82`).
- `title`, `description`, `offence_code` String/Text, nullable.
- `filed_date` Date, nullable; `claim_amount` Float, nullable.
- `consent_to_higher_claim_limit` Boolean, NOT NULL, default false.
- `status` ENUM `CaseStatus` — 12 values (`case.py:36-57`): `draft`, `extracting`, `awaiting_intake_confirmation`, `pending`, `processing`, `ready_for_review`, `escalated`, `closed`, `failed`, `failed_retryable`, `awaiting_review_gate1..gate4`.
- `jurisdiction_valid` Boolean, nullable.
- `complexity` ENUM, nullable; `route` ENUM, nullable.
- `latest_run_id` String(36), nullable — `case.py:174`.
- `gate_state`, `judicial_decision`, `intake_extraction` JSONB, nullable.
- `created_by` UUID, NOT NULL, FK `users.id`.
- Indexes (migration files):
  - `ix_cases_created_by (created_by)` — `0001_initial_schema.py:119`.
  - `ix_cases_status (status)` — `0001_initial_schema.py:120`.
  - `ix_cases_filed_date (filed_date)` — `0011_add_case_intake_metadata.py:31`.
  - `ix_cases_offence_code (offence_code)` — `:32`.
  - `ix_cases_description_fts` GIN tsvector — `0007_case_fts_index.py:20`.
  - **No** index on `domain` or `domain_id`.

### Writers
- INSERT: `create_case (src/api/routes/cases.py)` — sets `domain`, `domain_id`, `created_by`, `status`.
- UPDATE: many sites flip `case.status`. Representative writers (status transitions):
  - `persist_finalize (src/db/persist_case_results.py:134)` — terminal.
  - `cancel_case`, `start_pipeline`, `submit_intake_correction`, gate-pause / gate-advance handlers across `src/api/routes/cases.py` (`:650`, `:718`, `:755`, `:1384`, `:1399`, `:1681`, `:1745`).
  - `update_case_data (src/api/routes/case_data.py:359, :434)`.
  - `submit_reopen_request (src/api/routes/reopen_requests.py:129)` — flips back to processing.
  - `run_intake_extraction (src/services/intake_extraction.py:268, :310, :324)`.
  - Stuck-case watchdog `src/services/stuck_case_watchdog.py:67` (read-only filter, but writes `failed_retryable` elsewhere).
- `latest_run_id` written by `persist_case_results.py` (terminal persist).
- `intake_extraction` written by `intake_extraction.py:267, :323`.
- `gate_state`, `judicial_decision` written via various gate handlers in `cases.py`.
- `jurisdiction_valid` written by `persist_case_results.py:154`.

### Readers
- Domain enum still actively read at: `cases.py:169` (claim limit check), `:212` (offence required), `:622`, `:638`, `:905` (filter by domain), `:1329`; `dashboard.py:37` (group_by domain); `hearing_pack.py:220`; `workers/tasks.py:164`; `services/case_report_data.py:113`.
- `domain_id` / `domain_ref` read at: `cases.py:324-327`, `:378`, `:1322-1323`; `workers/tasks.py:182-194` (asserts both populated).
- `status` filtered widely (eg `dashboard.py:56`, `services/stuck_case_watchdog.py:67`, plus all UI list/detail paths in `cases.py`).
- `intake_extraction` read at `cases.py:801`.
- `latest_run_id` read at `what_if.py:94`, `:183`.

### Cruft flags
- **Dual-write legacy**: both `domain` enum and `domain_id` FK are populated and BOTH are read (see Readers). The migration `0019` made `domain_id` nullable; nothing has dropped `domain`. Confirms seed top-finding #1 — blocks `domain_id NOT NULL` cutover.
- The 12-value `status` enum has no machine-readable grouping — gate-pause states, intake states, terminal states are all peers. Routing logic uses ad-hoc `if/elif` chains.
- `intake_extraction` JSONB is **unversioned** — there is no `schema_version` field in the payload (intake_extraction.py:318-322 builds payload from LLM JSON + `model` + `ran_at` only). Confirms seed.
- `consent_to_higher_claim_limit` is a Boolean column on the parent table that only matters for `small_claims` — domain leakage onto the canonical row.
- **Correction to seed**: `jurisdiction_valid` is NOT orphaned. It is written by `persist_case_results.py:154` and read by `judge.py:342` (jurisdiction_validation endpoint). Seed claim is wrong.
- **Correction to seed**: `ix_cases_status` exists (`0001_initial_schema.py:120`). Seed claim "missing index on cases.status" is wrong.
- No FK index on `domain_id` — every domain-scoped query falls back to a sequential scan. Seed missed this.

### Notes for new 6-agent topology
- New gate boundaries imply the 4-gate enum (`awaiting_review_gate1..4`) will need to be remodeled (probably to `(gate_index INT, status ENUM)` pair) — every transition site in `cases.py` will touch it.
- `intake_extraction` payload should grow a `schema_version` before the next agent emits into it.
- `domain` enum drop and `domain_id NOT NULL` cutover should bundle into Sprint 2.

---

## 6. `calibration_records` (plural — `src/models/calibration.py:14`)

### Columns
- Model `src/models/calibration.py:13-29`. Migration: defined in `0001_initial_schema.py` (table list per init script).
  - `id` UUID PK; `case_id` UUID NOT NULL FK→cases ON DELETE CASCADE.
  - `judge_id` UUID NOT NULL FK→users.
  - `ai_recommendation_type` String(100), nullable.
  - `ai_confidence_score` Integer, nullable.
  - `judge_decision` String(50), NOT NULL.
  - `judge_modification_summary` Text, nullable.
  - `divergence_score` Float, NOT NULL.
  - `created_at` timestamptz NOT NULL.

### Writers
- **None**. Grep across `src/` and `tests/` for `CalibrationRecord` returns only the model definition (`src/models/calibration.py:13-14`). Confirms seed top-finding #3 — dead table.

### Readers
- **None**.

### Cruft flags
- Entirely dead. No constructor call, no SELECT, no relationship from `Case` or `User`.
- `divergence_score` is NOT NULL but no writer means it can never be populated; FK structure is wasted.

### Notes for new 6-agent topology
- Decision needed: drop the table, OR backfill and wire it from a new judge-confirmation handler. Per seed, this is a Sprint 2 candidate either way.

---

## 7. `domains` (plural — `src/models/domain.py:26`)

### Columns
- Migration `alembic/versions/0019_add_domains_and_case_domain_fk.py:25-49`; model `src/models/domain.py:25-44`.
  - `id` UUID PK; `code` String(100) UNIQUE NOT NULL; `name` String(255) NOT NULL.
  - `description` Text, nullable.
  - `vector_store_id` String(255), UNIQUE, **nullable** — `0019:31`, `domain.py:31`.
  - `is_active` Boolean, NOT NULL, server_default `false`.
  - `created_by` UUID, nullable, FK `users.id`.
  - `provisioning_started_at` timestamptz, nullable.
  - `provisioning_attempts` Integer, NOT NULL, default 0.
  - `created_at`, `updated_at` via TimestampMixin.
- Seeds: 2 rows inserted at migration time with `is_active=false` (`0019:84-93`): `small_claims`, `traffic_violation`.

### Writers
- `create_domain (src/api/routes/domains.py:120-160)` — INSERT; `is_active` flips true once `ensure_domain_vector_store` succeeds inside that call.
- `update_domain (:194-220)` — PATCH name / description / is_active.
- `retire_domain (:238-289)` — soft delete (`is_active=False`) or hard delete.
- `ensure_domain_vector_store (src/services/knowledge_base.py:167-191)` — sets `vector_store_id`, flips `is_active=True`.

### Readers
- `list_active_domains (src/api/routes/domains.py:60-73)` — `WHERE is_active=true`.
- `list_domains_admin (:101-106)` — admin list.
- `get_domain_admin (:178-181)`.
- `create_case` (`cases.py:411-437`) — looks up by `domain_id` or by legacy `code`.
- `domain_ref` selectinload across `cases.py:378`, `:1322-1323`; `workers/tasks.py:182-194`.

### Cruft flags
- **`provisioning_attempts` and `provisioning_started_at` are NEVER written or read** anywhere in `src/`. Confirmed by grep — only model + Alembic defs reference them. Confirms seed.
- **`vector_store_id` is `UNIQUE` AND nullable**. Multiple domains can have NULL vector_store, which is needed for unprovisioned rows, but the unique constraint also blocks reuse. OK as-is, but worth flagging — confirms seed.
- Seed rows (`small_claims`, `traffic_violation`) are inserted with `is_active=false`. Until `create_domain` is called via API for them, they cannot be returned by `list_active_domains`. Confirms seed.
- No index on `code` beyond the implicit UNIQUE B-tree.

### Notes for new 6-agent topology
- Domain provisioning observability is missing because the two timing columns are dead — Sprint 2 can revive them or drop them.

---

## 8. `domain_documents` (plural — `src/models/domain.py:48`; **NOT** in original 11-table list)

### Columns
- Migration `alembic/versions/0019_add_domains_and_case_domain_fk.py:51-77`; model `src/models/domain.py:47-80`.
  - `id` UUID PK; `domain_id` UUID NOT NULL FK→domains ON DELETE CASCADE.
  - `openai_file_id` String(255), nullable — original uploaded file.
  - `sanitized_file_id` String(255), nullable — post-classifier file used for indexing.
  - `filename` String(500), NOT NULL.
  - `mime_type` String(100), nullable.
  - `size_bytes` Integer, nullable.
  - `sanitized` Boolean, NOT NULL, default false.
  - `status` String(20) (model uses Python ENUM `DomainDocumentStatus` mapped to a String column — note the SA column type is plain `String(20)` not a Postgres enum), values `pending|uploading|parsed|indexing|indexed|failed`.
  - `error_reason` Text, nullable.
  - `idempotency_key` UUID, NOT NULL, default uuid4(); UNIQUE constraint `uq_domain_document_idempotency`.
  - `uploaded_by` UUID, NOT NULL, FK→users.
  - `uploaded_at` timestamptz, NOT NULL, default NOW().
- No status index.

### Writers
- `upload_domain_document (src/api/routes/domains.py:489-562)` — INSERT pending row.
- `_ingest_domain_document (:323-468)` — background pipeline that walks the row through the full status chain (`uploading → parsed → indexing → indexed | failed`), setting `openai_file_id`, `sanitized_file_id`, `sanitized`, and `error_reason`.
- `delete_domain_document (:575-624)`.

### Readers
- `list_domain_documents (:307-320)` — list by `domain_id`, ordered by `uploaded_at desc`.
- `delete_domain_document (:581-585)` — single-row lookup.

### Cruft flags
- **`openai_file_id` vs `sanitized_file_id` purpose ambiguity**: `openai_file_id` is the raw upload, `sanitized_file_id` is the post-classifier copy actually attached to the vector store. Both are kept for cleanup, but the schema does not document this. Confirms seed.
- `status` is a plain `String(20)` rather than a Postgres ENUM — a typo in a writer would silently insert garbage. The Python ENUM gives runtime safety but no DB-level constraint.
- No index on `(domain_id, status)` despite admin UI listing per domain by status implicitly.
- `sanitized` boolean duplicates information that can be derived from `sanitized_file_id IS NOT NULL`.

### Notes for new 6-agent topology
- This table is the entry point for the new RAG pipeline; sprint 2 likely tightens the status workflow and adds parsing-progress observability.

---

## 9. `users` (plural — `src/models/user.py:25`)

### Columns
- Migration `alembic/versions/0001_initial_schema.py` (initial); `0010_admin_persistence_and_judge_kb.py:59-62` adds `knowledge_base_vector_store_id`.
- Model `src/models/user.py:24-39`.
  - `id` UUID PK; mixin `TimestampMixin`.
  - `name` String(255) NOT NULL.
  - `email` String(255) UNIQUE NOT NULL.
  - `role` ENUM `UserRole` (`judge`, `admin`, `senior_judge`).
  - `password_hash` String(255) NOT NULL.
  - `knowledge_base_vector_store_id` String(255), nullable.
- `senior_judge` was dropped in `0018` and re-added in `0020_re_add_senior_judge_role.py`.

### Writers
- `register_user (src/api/routes/auth.py:88)` — INSERT.
- `manage_user_action set-role (src/api/routes/admin.py:90)` — UPDATE role.
- `ensure_judge_vector_store (src/services/knowledge_base.py:54-58)` — sets `knowledge_base_vector_store_id`.

### Readers
- `get_current_user (src/api/deps.py:64)` — by id (auth path).
- `auth.py:81, :120, :274` — by email (login / register / password reset).
- `auth.py:322` — by id (reset-token consume).
- `admin.py:77` — manage_user_action.
- `knowledge_base.py:97, :205, :243, :273` — read judge KB store id.

### Cruft flags
- **Correction to seed**: `knowledge_base_vector_store_id` is NOT orphaned. It is written (`services/knowledge_base.py:58`) and read (`api/routes/knowledge_base.py:97, :205, :243, :273`). Seed claim is wrong.
- Roles `judge|admin|senior_judge` are usable but the role-set churn (drop/re-add of senior_judge) leaves a brittle migration history.
- No index on `role`. Admin-only filters at `admin.py` rely on row-level role check, not DB filter — fine for now.

### Notes for new 6-agent topology
- If the 6-agent system introduces a per-judge config or per-judge agent overrides, expect more JSONB on this row. Plan for it explicitly rather than ad-hoc adds.

---

## 10. `admin_events` (plural — `src/models/admin_event.py:15`)

### Columns
- Migration `alembic/versions/0010_admin_persistence_and_judge_kb.py:19-39`.
  - `id` UUID PK.
  - `actor_id` UUID NOT NULL FK→users.
  - `action` String(100), NOT NULL.
  - `payload` JSONB, nullable.
  - `created_at` timestamptz NOT NULL default now().
- Indexes: `ix_admin_events_actor_id`, `ix_admin_events_action`, `ix_admin_events_created_at`.

### Writers
- `domains.py` — `domain_created` (`:152`), `domain_updated` (`:212`), `domain_deleted` (`:268`), `domain_retired` (`:281`), `domain_document_uploaded` (`:450`), `domain_document_deleted` (`:616`).
- `admin.py:44` — `vector_store_refresh_requested`.
- (Also written elsewhere — none found via grep beyond the above.)

### Readers
- **None in `src/`.** Grep `select(AdminEvent)` and `AdminEvent.` returns no read site. Confirms seed top-finding #4-adjacent — table is write-only.

### Cruft flags
- No reader endpoint — admin audit trail is invisible to UI. Confirms seed.
- `action` is unbounded String(100) — values are unversioned magic strings (e.g. `"domain_document_uploaded"`); a typo bypasses any check. Confirms seed.
- No TTL / retention. Indexed on `created_at` which suggests intent to time-bound queries that don't yet exist.
- `payload` shape varies per `action` with no schema_version.

### Notes for new 6-agent topology
- Cost-config / agent-tuning will write here; need a reader endpoint and a typed action enum before the table is shipped to production.

---

## 11. `what_if_scenarios` + `what_if_results` + `stability_scores` (the `what_if(s)` cluster)

### Columns
- `what_if_scenarios` — `src/models/what_if.py:59-89`:
  - `case_id`, `original_run_id`, `scenario_run_id` (UNIQUE) String(255), `modification_type` ENUM, `modification_description` Text, `modification_payload` JSONB, `status` ENUM (`pending|running|completed|failed|cancelled`), `created_by`, `created_at`, `completed_at`.
- `what_if_results` — `:91-109`: 1:1 to scenario via UNIQUE FK; `original_analysis`, `modified_analysis`, `diff_view` JSONB; `analysis_changed` Boolean; `created_at`.
- `stability_scores` — `:112-135`: `case_id`, `run_id` String(255), `score` Integer, `classification` ENUM (`stable|moderately_sensitive|highly_sensitive`), `perturbation_count`, `perturbations_held`, `perturbation_details` JSONB, `status` ENUM (`pending|computing|completed|failed`), `created_at`, `completed_at`.

### Writers
- `WhatIfScenario`: INSERT at `src/api/routes/what_if.py:281`; UPDATE status / completed_at via worker (`workers/tasks.py` and via outbox completion paths).
- `WhatIfResult`: INSERT at `what_if.py:127`.
- `StabilityScore`: INSERT at `what_if.py:397`; status flipped by worker.

### Readers
- `what_if.py:63-65` — scenario by id.
- `what_if.py:161` — stability by id.
- `what_if.py:333-337` — scenario + result eager load.
- `what_if.py:447-449` — stability list per case.

### Cruft flags
- `original_run_id` and `scenario_run_id` are String(255) — should be the same width as `cases.latest_run_id` (currently String(36)).
- No FK from `original_run_id`/`scenario_run_id` to `pipeline_checkpoints(run_id)`; orphan rehydration is silently OK by design but undocumented.
- `analysis_changed` is a derived Boolean (writer computes it, reader doesn't); could be a generated column.
- `stability_scores.run_id` has no FK either; same orphan risk.
- No index on `(case_id, created_at)` for stability — list endpoint uses sequential scan + sort.

### Notes for new 6-agent topology
- The new agent topology likely produces different `modification_type` values; enum will need to grow. Same pattern as `pipelinejobtype`.

---

## 12. `system_config` (singular — `src/models/system_config.py:15`)

### Columns
- Migration `0010_admin_persistence_and_judge_kb.py:41-57`; model `src/models/system_config.py:14-24`.
  - `key` String(100) PK.
  - `value` JSONB NOT NULL.
  - `updated_by` UUID, nullable, FK→users.
  - `updated_at` timestamptz NOT NULL, server_default now(), `onupdate=func.now()`.

### Writers
- `set_cost_config (src/api/routes/admin.py:124-153)` — `INSERT … ON CONFLICT DO UPDATE` for key `cost_config`.

### Readers
- **None in `src/`.** Confirms seed top-finding #4 — writer with no reader.

### Cruft flags
- Single writer, no reader: cost config is persisted but no agent / pipeline node reads it back. Anything that should respect this config falls back to env / `settings`.
- `onupdate=func.now()` is SQLAlchemy-level only (Postgres-portable since it uses `func.now()`); no actual DB trigger. **Correction to seed**: it's not "PG-specific" in a problematic way — it's portable SA. The note about a trigger was off.
- `key` is String(100) — no enum, no documented set of valid keys (today only `cost_config` exists).

### Notes for new 6-agent topology
- If new topology accepts runtime tuning (agent flags, model overrides), this is the natural home. Wiring a reader is Sprint 2 work.

---

## Summary of findings (top concerns at the schema level)

1. **Dual-domain dual-write is unresolved.** `cases.domain` (enum) and `cases.domain_id` (FK) are BOTH read by live code (`cases.py:169, 212, 622, 638, 905, 1329`, `dashboard.py:37`, `hearing_pack.py:220`, `workers/tasks.py:164`). Until every reader migrates to `domain_id`, the `NOT NULL` cutover and enum drop cannot ship. Sprint 2 must enumerate and convert each reader. **Confirms seed #1.**
2. **`pipeline_events.schema_version` is hardcoded to 1 system-wide** (`Literal[1] = 1` on every emitter pydantic class at `api/schemas/pipeline_events.py:40, 88, 105, 117, 125`). There is no bump mechanism. New event kinds in the 6-agent topology must introduce v2 publishers AND a consumer that fans by version, otherwise observability tooling cannot tell old from new. **Confirms seed #2.**
3. **`calibration_records` is fully dead.** Zero writers, zero readers across `src/` and `tests/` (only the model file references it). Either drop in Sprint 2 or backfill from judge-confirmation paths. **Confirms seed #3.**
4. **`system_config` and `admin_events` are write-only.** `system_config` has a single writer (`admin.py:124`) and no reader; `admin_events` has many writers (domains.py, admin.py) and zero readers. Both need a consumer endpoint before they earn their keep. **Confirms seed #4 and extends it.**
5. **Missing index hot-spots.** `audit_logs.agent_name` and `audit_logs.created_at` filter columns at `audit.py:43-47` have no indexes. `cases.domain_id` FK has no index — every domain-scoped read is a sequential scan. `domain_documents.(domain_id, status)` is unindexed. **Partially corrects seed #5**: `cases.status` IS already indexed (`0001:120`).
6. **Unversioned JSONB blobs.** `cases.intake_extraction` (no `schema_version` field; `intake_extraction.py:318-322`), `cases.gate_state`, `cases.judicial_decision`, `pipeline_jobs.payload`, `admin_events.payload`, `system_config.value` all carry free-form dicts. Any agent topology change risks silent shape drift. Sprint 2 should require an embedded `schema_version` per JSONB column with a migration to backfill.
7. **`pipeline_checkpoints` versioning lives inside the JSON, not on the row.** `CURRENT_SCHEMA_VERSION = 2` (`db/pipeline_state.py:42`) is enforced by reading `case_state.schema_version` (`:195-205`). Any future migration that changes CaseState must either bump and reject all old rows (current loud-fail behavior) or add a row-level column to allow co-existence. **Corrects seed**: there is no `schema_version` column on the table.
8. **Dead provisioning fields on `domains`.** `provisioning_started_at` and `provisioning_attempts` (added in `0019:34-35`) are never written or read. Either drop in Sprint 2 or wire them into `ensure_domain_vector_store` so admins can see provisioning failures. Confirms seed.

### Corrections to seed findings

- `attempts` IS incremented on `pipeline_jobs` failure (`outbox.py:114`).
- `cases.jurisdiction_valid` is NOT orphaned — written at `persist_case_results.py:154`, read at `judge.py:342`.
- `users.knowledge_base_vector_store_id` is NOT orphaned — used by `services/knowledge_base.py` and `api/routes/knowledge_base.py`.
- `ix_cases_status` exists (`0001_initial_schema.py:120`); seed's "missing index on cases.status" is incorrect.
- `system_config.onupdate=func.now()` is a portable SQLAlchemy hook, not a Postgres-specific trigger as seed implied.
- The "v1 rows rejected" claim on `pipeline_checkpoints` is correct but operates on the JSON property `case_state.schema_version`, not on a row column.
