# Source-Driven Audit — Sprint 0 + Sprint 1

**Scope:** Framework-specific API claims in `tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md` for Sprint 0 (audit/design tasks) and Sprint 1 (A1 + C3a + DEP1).
**Authority hierarchy used:** project's installed `.claude/skills/{langchain-*,langgraph-*}` (canonical for this codebase per CLAUDE.md) → official LangChain/LangGraph/LangSmith docs via context7.
**Out of scope:** observational drift findings (file:line locations), Sprint 2+ tasks, scope/architecture decisions.

---

## 1. Stack detected

From `VerdictCouncil_Backend/pyproject.toml` (current state):

| Package | Currently pinned | Target per breakdown 1.A1.0 | Current LTS (skill: `langchain-dependencies`) | Verdict |
|---|---|---|---|---|
| `langchain` | **not declared** | `>=1.0` | `>=1.0,<2.0` | ⚠ breakdown missing `<2.0` cap |
| `langchain-core` | `>=0.3.0` | `>=0.3` | `>=1.0,<2.0` | ✗ **target is stale** |
| `langgraph` | `>=0.2.0` | `>=0.4` | `>=1.0,<2.0` | ✗ **target is stale** |
| `langchain-openai` | `>=0.2.0` | `>=0.3` | (latest within current major) | ⚠ tightening needed for native Pydantic `response_format` |
| `langgraph-checkpoint-postgres` | `>=2.0.0` | `>=2.0` | not version-pinned by skill; v2 series is current | ✓ |
| `langsmith` | not declared | `>=0.3` | `>=0.3.0` | ✓ |
| `mlflow>=2.18,<3` | declared | (drop per rev 2 scope cut) | n/a | action: remove |
| `requires-python` | `>=3.12` | (`langgraph.json` says `3.11`) | LangChain 1.0 needs ≥3.10 | ✗ **inconsistency** — see finding F-7 |

> Source: `langchain-dependencies` skill, "Environment Requirements" + "Versioning Policy" tables.

---

## 2. Verified patterns (cite directly when implementing)

These breakdown claims match current canonical patterns. Implementations following the breakdown verbatim on these points are safe.

| # | Breakdown claim | Source |
|---|---|---|
| V-1 | `from langchain.agents import create_agent` with `model=`, `tools=`, `system_prompt=`, `response_format=`, `middleware=`, `checkpointer=` | `langchain-fundamentals` skill, `<create_agent>` + `<ex-basic-agent>` |
| V-2 | Middleware decorators `@wrap_tool_call`, `@wrap_model_call`, `@before_model`, `@after_model`, `@before_agent`, `@after_agent` from `langchain.agents.middleware` | `langchain-middleware` skill, "Custom Middleware Hooks" — six hooks confirmed |
| V-3 | `from langgraph.types import Send, interrupt, Command, RetryPolicy, Overwrite` | `langgraph-fundamentals` skill (`Send`, `Command`, `RetryPolicy`); `langgraph-human-in-the-loop` (`interrupt`); `langgraph-persistence` `<fix-update-state-with-reducers>` (`Overwrite`) |
| V-4 | `Send` fan-out via `add_conditional_edges(node, router, [destinations])` where `router` returns `list[Send]` — **NOT** a node returning `list[Send]` | `langgraph-fundamentals`, `<ex-orchestrator-worker>`: `.add_conditional_edges(START, orchestrator, ["worker"])` where `orchestrator` returns `[Send("worker", {"task": task})]` |
| V-5 | Reducer-backed accumulator: `Annotated[list[X], operator.add]` for `Send` results | `langgraph-fundamentals`, `<fix-send-accumulator>` |
| V-6 | `interrupt({...})` returns judge decision; `Command(resume=...)` is the only valid resume input | `langgraph-human-in-the-loop`, `<ex-basic-interrupt-resume>` + `<fix-resume-with-command>` |
| V-7 | Idempotent side-effects before `interrupt()` (e.g. `upsert_case_status` in 1.A1.7 gate stub) | `langgraph-human-in-the-loop`, `<idempotency-rules>` + `<ex-idempotent-patterns>`: "Use upsert (not insert) operations before interrupt()" |
| V-8 | `graph.astream(stream_mode="custom")` with `get_stream_writer()` for SSE bridge | `langgraph-fundamentals`, `<ex-stream-custom-data>` |
| V-9 | `graph.get_state_history(config)`, `update_state(past.config, ...)`, `invoke(None, past_config)` for forking/replay | `langgraph-persistence`, `<ex-resume-from-checkpoint>` |
| V-10 | `RetryPolicy(max_attempts=...)` on `add_node(..., retry_policy=...)` | `langgraph-fundamentals`, `<ex-retry-policy>` |
| V-11 | `ToolStrategy(Schema)` with `handle_errors=True` retries on validation error (default) | LangChain docs: `https://docs.langchain.com/oss/python/langchain/structured-output` — "`handle_errors`... default setting of `True`" |
| V-12 | `LANGSMITH_TRACING=true` + `LANGSMITH_API_KEY` enables auto-tracing for LangChain code, no custom code needed | `https://github.com/langchain-ai/langsmith-sdk/blob/main/python/README.md` |
| V-13 | `client.push_prompt(name, object=template, description=..., tags=...)` returns URL; `client.pull_prompt(name)` retrieves; specific commits via `name:version` | `https://context7.com/langchain-ai/langsmith-sdk/llms.txt` — "Integrate with LangSmith Hub for Prompt Management" |
| V-14 | `LANGSMITH_PROJECT` env var sets project; defaults to `"default"` | LangSmith SDK README (above) |
| V-15 | `langgraph.json` keys: `dependencies`, `graphs`, `env` | `https://docs.langchain.com/oss/python/langgraph/studio` + `/application-structure` |

---

## 3. Findings — must address before / during Sprint 1

### F-1 (P0) — `PostgresSaver.from_conn_string` is a context manager, not a factory

**Where:** Task `1.A1.PG`, acceptance criterion: *"`runner.py` instantiates `PostgresSaver.from_conn_string(settings.database_url)` once at startup; `setup()` called (idempotent)"*.

**Problem:** Every official example uses it as a context manager:

```python
# Source: docs.langchain.com/oss/python/langgraph/add-memory
with PostgresSaver.from_conn_string(DB_URI) as checkpointer:
    builder = StateGraph(...)
    graph = builder.compile(checkpointer=checkpointer)
```

Calling `PostgresSaver.from_conn_string(...)` without `with` returns the context-manager wrapper, **not** a usable saver. The graph compile would silently fail at runtime when checkpointer methods are invoked.

**Fix options** (combine with F-1b on async):
- **Recommended:** Hold the CM open over the FastAPI app lifetime via `lifespan` events — `async with AsyncPostgresSaver.from_conn_string(DB_URI) as checkpointer: yield`, exposed on `app.state`.
- **Alternative:** Construct the saver from a managed `psycopg.AsyncConnection` / `AsyncConnectionPool` directly: `AsyncPostgresSaver(conn=pool)`. This is the production-grade path; `from_conn_string` is a dev/test convenience.

**Action:** Update `1.A1.PG` description to specify lifespan-managed CM (or pool-backed constructor) and add a shutdown hook. Tests must verify the saver remains live across requests.

> **Source:** `langgraph-persistence` skill, `<ex-production-postgres>` (`with PostgresSaver.from_conn_string(...) as checkpointer:`); `https://docs.langchain.com/oss/python/langgraph/add-memory`.

---

### F-1b (P0) — Backend is async; use `AsyncPostgresSaver`, not the sync `PostgresSaver`

**Where:** Same task `1.A1.PG`. The breakdown specifies `PostgresSaver` (sync); the rest of the backend stack is async (`asyncpg`, `sqlalchemy[asyncio]`, FastAPI handlers).

**Problem:** Mixing the sync saver into an async request path either serializes requests through the saver's blocking psycopg connection or deadlocks under load. The canonical async import:

```python
# Source: docs.langchain.com/oss/python/langgraph/add-memory ("Async Postgres Store and Runtime Integration")
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

async with AsyncPostgresSaver.from_conn_string(DB_URI) as checkpointer:
    await checkpointer.setup()  # await, not sync
    graph = builder.compile(checkpointer=checkpointer)
```

In a long-running FastAPI app, hold the async CM open across the lifespan: `async with` in a `lifespan` async generator, yield the saver into `app.state`.

**Action:** Update `1.A1.PG` to specify `AsyncPostgresSaver` (with the lifespan-managed CM noted in F-1) and `await checkpointer.setup()`. Same applies to any test fixture that previously used `InMemorySaver` synchronously — switch to `langgraph.checkpoint.memory.InMemorySaver` (async-compatible) or async fixtures.

> **Source:** `https://docs.langchain.com/oss/python/langgraph/add-memory` — "Async Postgres Store and Runtime Integration" snippet.

---

### F-2 (P0) — Empty list does NOT overwrite under `operator.add` reducer

**Where:** Task `1.A1.5`, code block: *`return {"research_parts": []}  # empty list overwrites under add reducer (idempotent re-entry)`*.

**Problem:** `operator.add` on lists is `+`, so `[A, B] + [] = [A, B]`. Returning `[]` from a node is a **no-op**, not a reset. The acceptance criterion tail-acknowledges this ("must be cleared via `Overwrite` semantics or explicit reset path") but the in-task code is wrong and the comment is misleading.

Note also: `Overwrite(...)` is documented for `graph.update_state(...)`, **not** for values returned from a node. Node returns always pass through reducers. To clear an `operator.add`-backed list, options are:

1. **Custom reducer** that supports a sentinel reset token, e.g. `def merge(left, right): return [] if right is None else left + right`. Then `return {"research_parts": None}` resets.
2. **Replace the list with a dict-keyed shape** — `Annotated[dict[str, ResearchPart], merge_dict]` keyed by subagent scope name (`"evidence"`, `"facts"`, ...). Re-entry naturally overwrites the entry for that scope; partial-output handling becomes "missing key" rather than "missing index". Matches the team's mental model and skips the sentinel-reducer cognitive cost.
3. **Out-of-band reset via `graph.update_state(config, {"research_parts": Overwrite([])})`** before re-entering — only available from outside the graph (e.g. the rerun handler in `cases.py`).

**Action:** Recommend option **(2)** unless there's a reason not to — it's the cheapest fix and aligns with how `ResearchOutput.from_parts(parts_dict)` would naturally consume the merged state. Rewrite `1.A1.5`'s `research_dispatch_node`, the schema declaration, and the join classmethod accordingly. Update both the code block and the acceptance criterion. Cross-check `4.A3.x` rerun semantics now, not in Sprint 4.

> **Source:** `langgraph-persistence` skill, `<fix-update-state-with-reducers>`: *"`update_state` PASSES THROUGH reducers... To REPLACE instead, use `Overwrite`"*; `langgraph-fundamentals` `<fix-send-accumulator>` confirms reducer behavior.

---

### F-3 (P0) — Dependency targets in `1.A1.0` are stale

**Where:** Task `1.A1.0` lists `langgraph>=0.4`, `langchain-core>=0.3`, `langchain-openai>=0.3`, `langchain>=1.0`.

**Problem:** Per the project's own `langchain-dependencies` skill (canonical), the current LTS for the entire ecosystem is the **1.x line**, not 0.x:

| Package | Breakdown target | Skill LTS |
|---|---|---|
| `langchain` | `>=1.0` | `>=1.0,<2.0` |
| `langchain-core` | `>=0.3` | `>=1.0,<2.0` |
| `langgraph` | `>=0.4` | `>=1.0,<2.0` |

Skill text: *"LangChain 1.0 is the current LTS release. Always start new projects on 1.0+. LangChain 0.3 is legacy maintenance-only — do not use it for new work."*

A `langchain>=1.0` install will pull `langchain-core` 1.x as a dep — but if the explicit pin says `langchain-core>=0.3`, dep resolvers may pick the older line and create a peer-dep conflict. Same for `langgraph`.

Also missing: explicit upper-major caps (`<2.0`) on all three, recommended by the skill's "Versioning Policy" table.

**Action:** Update `1.A1.0` to:
```toml
"langchain>=1.0,<2.0",
"langchain-core>=1.0,<2.0",
"langgraph>=1.0,<2.0",
"langchain-openai",  # latest compatible with langchain>=1.0 — verify floor with `uv tree` post-install
"langgraph-checkpoint-postgres>=2.0,<3.0",
"langsmith>=0.3.0",
```
And drop `mlflow>=2.18,<3` per the rev 2 scope cut. Note: the `langchain-dependencies` skill does **not** pin a minimum version for partner provider packages like `langchain-openai`; the right floor is whatever release is current and compatible with `langchain>=1.0` at install time. Asserting `>=1.0` would be a guess — verify with `uv tree | rg langchain-openai` after the first `uv sync` and write the actual resolved floor back into the pin.

> **Source:** `langchain-dependencies` skill, `<fix-legacy-version>` and "Core Packages > Python — orchestration".

---

### F-4 (P1) — `langgraph.json` `python_version: "3.11"` contradicts project's `requires-python = ">=3.12"`

**Where:** Task `1.DEP1.1`, sample `langgraph.json`:
```json
{ ..., "python_version": "3.11" }
```

**Problem:** `pyproject.toml` declares `requires-python = ">=3.12"`. LangGraph Cloud will build a 3.11 image, attempt to install a project that demands 3.12, and fail at install time.

**Action:** Set `"python_version": "3.12"` (or drop the field — the example in `https://docs.langchain.com/oss/python/langgraph/studio` shows it as optional).

> **Source:** project `pyproject.toml`; LangGraph CLI docs above.

---

### F-5 (P1) — `system_prompt` value-shape mismatch between `1.C3a.3` and `1.A1.4`

**Where:**
- `1.C3a.3`: *"`get_prompt(agent_name, judge_corrections=None) -> tuple[str, str]` (template, commit_hash)"*.
- `1.A1.4`: *"`create_agent(... system_prompt=get_prompt(f"verdict-council/{phase}"), ...)`"*.

**Problem:** `create_agent`'s `system_prompt` expects a string. Passing a `(template, commit_hash)` tuple will fail validation.

**Action:** In `1.A1.4`, unpack: `system_prompt, prompt_commit = get_prompt(f"verdict-council/{phase}")`, then pass `system_prompt=system_prompt`. The commit hash should flow into LangSmith via run metadata (already noted in 1.C3a.4 — but make the metadata wiring explicit, e.g. `RunnableConfig(metadata={"prompt_commit": prompt_commit})`).

> **Source:** `langchain-fundamentals` skill, `<ex-basic-agent>`: `system_prompt="You are a helpful assistant."` (string).

---

### F-6 (P2) — Org-scoped LangSmith API keys need `LANGSMITH_WORKSPACE_ID`

**Where:** Task `0.11c` and `1.C3a.1` — env var list does not include `LANGSMITH_WORKSPACE_ID`. The breakdown says *"Org id `7ac65285-...` is implicit from the API key"*.

**Problem:** Per LangSmith SDK README: *"`LANGSMITH_WORKSPACE_ID = ...` Required for org-scoped API keys"*. If the team uses an **org-scoped** key (common in production), tracing breaks without this var. If the key is **personal-scoped**, it's fine — but the breakdown should make the distinction explicit so the user picks the right key type.

**Action:** Add `LANGSMITH_WORKSPACE_ID=` to `docs/setup-2026-04-25.md`'s env var list with a note: *"required only if `LANGSMITH_API_KEY` is org-scoped — set when generating the key"*.

> **Source:** `https://github.com/langchain-ai/langsmith-sdk/blob/main/python/README.md`.

---

### F-7 (P2) — `HumanInTheLoopMiddleware` not considered for tool-call gates

**Where:** Sprint 1 uses raw `interrupt()` in node-level gates (`1.A1.7`). This is correct for **between-phase** gates.

**However:** for any *future* tool-call gating (e.g. "judge approves before `search_precedents` runs"), the canonical pattern is `HumanInTheLoopMiddleware`, not raw `interrupt()`:

```python
# Source: langchain-middleware skill, <ex-basic-hitl-setup>
middleware=[HumanInTheLoopMiddleware(
    interrupt_on={"send_email": {"allowed_decisions": ["approve","edit","reject"]}}
)]
```

This is informational — no action needed for Sprint 1, but worth noting in `0.11a` (agent design doc) so the team doesn't reinvent this if a tool-call gate is added later.

> **Source:** `langchain-middleware` skill, `<ex-basic-hitl-setup>`.

---

### F-8 (P2) — `ToolStrategy` import path needs to be explicit in `0.11a`/`1.A1.4`

**Where:** Breakdown references `ToolStrategy`/`ProviderStrategy` ambiguously: *"native `response_format=Schema` handles structured output (LangChain's `ToolStrategy`/`ProviderStrategy` per the structured-output doc)"*.

**Two equivalent forms** (both verified):

```python
# Form A: implicit — agent picks strategy
agent = create_agent(model="...", tools=[...], response_format=Schema)

# Form B: explicit — recommended when behavior matters
from langchain.agents.structured_output import ToolStrategy
agent = create_agent(model="...", tools=[...], response_format=ToolStrategy(Schema))
```

`handle_errors=True` is the default in Form B (validation failures retry with corrective feedback); Form A's behavior depends on which strategy LangChain auto-picks per provider (`ProviderStrategy` for native-structured-output models, `ToolStrategy` otherwise).

**Action:** In `0.11a`, decide per phase whether to use Form A or Form B. If `extra="forbid"` is load-bearing for `1.A1.SEC3` (it is — that test asserts ValidationError on undeclared fields), Form B with explicit `ToolStrategy(Schema)` is safer and gives deterministic retry behavior.

> **Source:** `https://docs.langchain.com/oss/python/langchain/structured-output`; `langchain-fundamentals` skill `<structured_output>`.

---

### F-9 (P3) — `langgraph dev` Studio port

**Where:** Task `1.DEP1.2` claims *"UI accessible at `localhost:2024`"*.

**Problem:** I could not verify the exact default port from the docs fetched (the studio docs page doesn't pin a port number in the snippets returned). The CLI's actual default port for `langgraph dev` in 1.x may differ. Low risk — verifiable by running `langgraph dev --help` once `1.A1.0` is done.

**Action:** Mark this as "verify during 1.DEP1.2 execution; update task if port differs" rather than asserting `2024` in the acceptance criterion.

> **Source:** unverified — flag, do not block.

---

## 4. Unverified — explicit acknowledgments

These claims in the breakdown could not be verified against canonical sources during this audit. They aren't necessarily wrong — but the team should verify on first execution and feed corrections back.

- **U-1**: Per-env metadata via `config.metadata["env"] = os.getenv("APP_ENV", "dev")` (Task `1.C3a.1`). The pattern of attaching metadata to runs is standard, but the exact key LangSmith UI surfaces for filtering is not pinned in the docs fetched. Verify by running with `metadata={"env": "dev"}` and confirming the trace shows it filterably in the LangSmith UI.
- **U-2**: `tool_span()` deletion (Task `0.9` — drop unused helper). Observational, not a framework claim — fine.
- **U-3**: `langgraph build` / `langgraph deploy` semantics for Sprint 5 — out of audit scope.
- **U-4**: `astream(stream_mode="custom")` cancellation propagation through `runner_stream_adapter` (Task `1.A1.3` acceptance: "Cancellation-safe"). Standard asyncio cancellation should work but verify with an explicit test that doesn't swallow `CancelledError`.

---

## 5. Action items (rolled-up)

| # | Action | Owner task | Severity |
|---|---|---|---|
| A-1 | Rewrite `1.A1.PG` to use lifespan-managed CM or pool-backed `AsyncPostgresSaver(conn=pool)` constructor | `1.A1.PG` | P0 |
| A-1b | Switch from `PostgresSaver` to `AsyncPostgresSaver` (sync→async); `await checkpointer.setup()` | `1.A1.PG` | P0 |
| A-2 | Rewrite `1.A1.5` `research_dispatch_node` reset semantics — recommend dict-keyed `Annotated[dict[str, ResearchPart], merge_dict]` | `1.A1.5` + `4.A3.x` | P0 |
| A-3 | Update `1.A1.0` dep pins to current 1.x LTS with `<2.0` caps; drop `mlflow`; verify `langchain-openai` floor via `uv tree` post-install | `1.A1.0` | P0 |
| A-4 | Set `langgraph.json` `python_version` to `"3.12"` (or drop the field) | `1.DEP1.1` | P1 |
| A-5 | Unpack `(template, commit_hash)` tuple before passing to `create_agent.system_prompt`; route commit via `RunnableConfig.metadata` | `1.A1.4` + `1.C3a.4` | P1 |
| A-6 | Add `LANGSMITH_WORKSPACE_ID` to setup doc with org-scoped-key note | `0.11c` | P2 |
| A-7 | Note `HumanInTheLoopMiddleware` as the canonical tool-call HITL pattern in agent design doc | `0.11a` | P2 |
| A-8 | Decide per phase: implicit `response_format=Schema` vs explicit `ToolStrategy(Schema)`; document choice | `0.11a` | P2 |
| A-9 | Drop the `localhost:2024` assertion from `1.DEP1.2`; verify port at execution | `1.DEP1.2` | P3 |
| A-10 | Add a regression test for `astream(stream_mode="custom")` cancellation that asserts `CancelledError` is not swallowed | `1.A1.3` | P3 |

---

## 6. Skills relied on

This audit was bounded by the project's installed canonical skills (`.claude/skills/`):

- `langchain-dependencies` — version pinning policy
- `langchain-fundamentals` — `create_agent` signature, structured output basics
- `langchain-middleware` — six middleware decorator hooks, `HumanInTheLoopMiddleware`
- `langgraph-fundamentals` — `StateGraph`, edges, `Send`, reducers, streaming, `RetryPolicy`
- `langgraph-human-in-the-loop` — `interrupt`/`Command`, idempotency rules, multiple interrupts
- `langgraph-persistence` — `PostgresSaver` lifecycle, `get_state_history`/`update_state`/`Overwrite`, subgraph checkpointer scoping

External sources cited:

- `https://docs.langchain.com/oss/python/langchain/structured-output` (ToolStrategy + handle_errors)
- `https://docs.langchain.com/oss/python/langgraph/studio` (langgraph.json)
- `https://docs.langchain.com/oss/python/langgraph/application-structure` (langgraph.json keys)
- `https://docs.langchain.com/oss/python/langgraph/add-memory` (PostgresSaver context-manager pattern)
- `https://github.com/langchain-ai/langsmith-sdk/blob/main/python/README.md` (env vars, tracing toggles)
- `https://context7.com/langchain-ai/langsmith-sdk/llms.txt` (`Client.push_prompt` / `pull_prompt`)
