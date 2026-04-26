# Master Sequence: Streaming + Ingestion Rollout

**Date**: 2026-04-26
**Scope**: Orders four work streams (Q2 ingestion, Q1 streaming, gate-2 rerun, prompt-pack realignment) against the Sprint 1 work already in flight.
**Companion docs**:
- `tasks/plan-2026-04-26-streaming-and-ingestion.md` (full plan)
- `tasks/ticket-2026-04-26-gate2-per-agent-rerun-targeting.md`
- `tasks/ticket-2026-04-26-prompt-pack-realignment.md`

---

## Sequencing principles

1. **Restore broken behavior before adding UX.** Q2 (ingestion) is non-negotiable first — uploaded PDFs are silently ignored today.
2. **Foundation before behavior.** Q1 streaming foundation (Q1.1-Q1.3) lands with no user-visible change before any conversational-mode logic ships.
3. **Bake schema bumps.** Q2.3a (reader-side compat) must merge and ride at least one staging release before Q2.3b (writer flip) is allowed to land. Same gate principle for any future schema bumps.
4. **Establish patterns once, reuse them.** Q1.6 establishes the conversational-mode prompt section. The prompt-pack realignment (Phase 5) reuses that pattern across the other 7 prompts — it slots between backend dual-mode (Phase 4) and frontend rendering (Phase 6) so prompts are coherent before the UI surface forces wider review.
5. **Independent tickets interleave opportunistically.** Gate-2 scoped rerun has no coupling to streaming/ingestion; slot it wherever a backend engineer has capacity.
6. **Don't edit `prompts.py` twice.** If Sprint 1 C3a (LangSmith push + registry rewrite) is still active when we reach Phase 5, fold the realignment into the C3a PR.

## Coordination with Sprint work already in flight

**Verified 2026-04-26 against actual repo state.** The "Sprint 1 starting state" notes in `tasks/todo.md` are stale — the codebase is past Sprint 4. Resolved status:

| Sprint stream | Status (verified 2026-04-26) | Implication for this plan |
|---|---|---|
| **Sprint 1 A1** — phased `create_agent` + Send fan-out + middleware | ✅ **MERGED** (factory uses `create_agent` + `ToolStrategy` + middleware throughout — see `factory.py:237-244`). Sprint 4 4.A5 has shipped on top of it. | Phase 4 has **no A1 blocker**. D2 in the original sequence is RESOLVED — strike it. |
| **Sprint 1 C3a** — LangSmith prompts push + `prompts.py` registry rewrite | ✅ **SHIPPED** (re-verified 2026-04-26 evening). `src/pipeline/graph/prompt_registry.py` is the live read path: `get_prompt(phase)` pulls from LangSmith with a local-file fallback at `prompts/<phase>.md`. The factory at `agents/factory.py:172-179` consumes that, not `AGENT_PROMPTS`. The legacy `AGENT_PROMPTS` dict in `prompts.py:90` is dead weight referenced only by 2 tests (`test_intake_prompt_guard_rail.py`, `test_graph_state.py:260`) — out of scope for this sequence. **Phase 5 audit target shifts to the 7 markdown files in `prompts/`** — `intake.md`, `research-{evidence,facts,witnesses,law}.md`, `synthesis.md`, `audit.md`. | Phase 5 ships as its own ticket on `feat/prompt-pack-realignment` (in `VerdictCouncil_Backend`). Push back to LangSmith via `scripts/migrate_prompts_to_langsmith.py` after edits so registry pull and local fallback agree. |
| **Sprint 1 DEP1** — LangGraph CLI scaffolding | Status not verified; orthogonal to this plan regardless. | No coupling. |
| **Sprint 4 active work** (4.A3 interrupt-HITL, A5 stability/whatif fork) | Mostly merged; one local branch (`feat/sprint4-a3-interrupt-hitl`) is in flight. | No code-path overlap with Q1/Q2. Watch for `factory.py` touches if 4.A3 lingers. |

The 4 prompt edits in Q2.3b/Q2.4/Q1.6 land on the live `prompts/<phase>.md` files (the 2026-04-26-AM "inline string" framing was based on a stale read; corrected above).

## The sequence

```
─────────────────────────────────────────────────────────────────────────
Phase 1: Q2 — Ingestion Fix                              [WAVE 1A | 1B | 1C]
─────────────────────────────────────────────────────────────────────────
  Wave 1A (parallel-safe, single PR or 3 PRs)
    Q2.1  Document.parsed_text caching at upload         (S+M)
    Q2.3a CaseState reader-side compat (no writer)       (S)
    Q2.5  /process 409 fail-fast                         (S)

  Wave 1B (after Wave 1A merges to development)
    Q2.2  Hydrate parsed_text into raw_documents         (S)
    Q2.4  Intake-prompt guard rail                       (S)

  Wave 1C (after at least one staging release of 1A + 1B)
    Q2.3b Writer flips to v3 + intake_extraction bridge  (M)
    Q2.6  Integration tests (e2e)                        (M)

  → CHECKPOINT A — Q2 merged to development; staging green; submodule SHA
                   bump committed to root main.

─────────────────────────────────────────────────────────────────────────
Phase 2: Gate-2 Scoped Rerun                             [INTERLEAVE OK]
─────────────────────────────────────────────────────────────────────────
  Standalone — no dependency on Q2 or Q1.
  Recommended slot: between Q2 merge and Phase 3 start, while Q2.3a bakes.
  Could also land earlier if a backend engineer has capacity during Wave 1.

  Branch: feat/gate2-scoped-rerun

─────────────────────────────────────────────────────────────────────────
Phase 3: Q1 Foundation (no UX change)                    [SERIAL after Q2]
─────────────────────────────────────────────────────────────────────────
  Prerequisite: Sprint 1 A1 merged (factory refactor lands first)

  Q1.1  Token coalescer + fire-and-forget publisher      (M)
  Q1.2  streaming_started flag — no ainvoke fallback     (M)
  Q1.3  llm_token + tool_call_delta SSE types (gated)    (S)

  → CHECKPOINT B — Foundation merged; production unchanged with flag OFF.

─────────────────────────────────────────────────────────────────────────
Phase 4: Q1 Dual-Mode Backend                            [SERIAL]
─────────────────────────────────────────────────────────────────────────
  Q1.4  conversational flag in _make_node                (M)
  Q1.5  Structuring-pass node                            (M)
  Q1.6  Wire intake to conversational=True behind flag   (M)
        → Includes fidelity gate: ≥95% field match on 20 historical cases

  → CHECKPOINT C — Backend dual-mode behind flag; staging SSE verified
                   via raw inspection. Conversational-mode prompt PATTERN
                   now exists in prompts.py for intake.

─────────────────────────────────────────────────────────────────────────
Phase 5: Prompt-Pack Realignment                         [STANDALONE]
─────────────────────────────────────────────────────────────────────────
  Re-verified 2026-04-26 (evening): C3a HAS shipped — prompt_registry.py
  + 7 `prompts/<phase>.md` files are the live path. Phase 5 audits those
  7 markdown files, not the legacy AGENT_PROMPTS dict in prompts.py.
  Ships as its own ticket on feat/prompt-pack-realignment in the backend
  submodule; push the realigned prompts back to LangSmith on completion.

  Audit checklist (per the ticket): tool match, state-schema match,
  raw_documents shape, intake_extraction awareness, output-schema match,
  citation contract.

  CONVERSATIONAL-MODE PLACEHOLDER DROPPED FROM SCOPE — Q1.6 shipped as a
  runtime-only flag (no prompt-section was added to intake.md), so the
  ticket's "copy the Q1.6 pattern" step is unfulfillable. Defer until a
  real pattern is needed.

  Audit phase (audit.md) must NOT receive a conversational-mode section
  (architecture decision A3) — moot now that the placeholder is dropped,
  but recorded for posterity.

  → CHECKPOINT C.5 — All 7 prompts coherent. JSON-mode replay tests still
                     byte-equal. New tool/prompt parity contract test in
                     CI. Realigned prompts pushed back to LangSmith.

─────────────────────────────────────────────────────────────────────────
Phase 6: Q1 Frontend Rendering                           [SERIAL]
─────────────────────────────────────────────────────────────────────────
  Q1.7  SSE event-union extension                        (S)
  Q1.8  Prose accumulator + consumer inventory           (M)
  Q1.9  ToolCallChip component                           (M)
  Q1.10 Result-artifact panel + AgentStreamPanel rewrite (M)

  → CHECKPOINT D — Frontend ships behind same flag; intake e2e verified
                   on staging with flag ON.

─────────────────────────────────────────────────────────────────────────
Phase 7: Q1 Rollout                                      [SERIAL]
─────────────────────────────────────────────────────────────────────────
  Q1.11 Risk #1 e2e regression (no double-call)          (S)
  Q1.12 Risk #2 load test (Redis backpressure)           (M)
  Q1.13 Expand flag: PIPELINE_CONVERSATIONAL_STREAMING_PHASES=intake,triage
                                                          (S)
        Audit phase verified to STAY JSON-only.
        With Phase 5 already done, triage is a flag-flip not a prompt edit.

  → CHECKPOINT E — Production rollout intake,triage; lessons captured in
                   tasks/lessons.md.
```

## Critical-path summary

```
[Sprint 1 A1] ──┐
                ├──→ [Q2 Wave 1A] ──→ [Q2 Wave 1B] ──→ [Staging bake] ──→
                │
[Sprint 1 C3a]──┤    (continues in parallel)
                │
[Sprint 1 DEP1]─┘    (orthogonal)

──→ [Q2 Wave 1C: 1A and 1B] ──→ ★A
                          ★A ──→ [Phase 3: Foundation] ──→ ★B
                          ★A ──→ [Phase 2: Gate-2 rerun, opportunistic]

★B ──→ [Phase 4: Dual-mode backend] ──→ ★C
       Requires: A1 merged
                                    ★C ──→ [Phase 5: Prompt realignment]
                                    │       (folded into C3a if open,
                                    │        else own ticket)
                                    │
                                    │   ──→ ★C.5
                                    │
                                    └──→ [Phase 6: Frontend] ──→ ★D
                                                              ★D ──→ [Phase 7: Rollout] ──→ ★E
```

## Branch + PR map

| Phase | Branch | Target | Depends on |
|---|---|---|---|
| Q2 Wave 1A | `feat/intake-document-hydration-foundation` | `development` | A1 |
| Q2 Wave 1B | (same branch as 1A or `feat/intake-document-hydration-runner`) | `development` | Wave 1A merged |
| Q2 Wave 1C | `feat/intake-extraction-bridge` | `development` | 1A + 1B baked one staging cycle |
| Gate-2 rerun | `feat/gate2-scoped-rerun` | `development` | None (interleave any time post-A1) |
| Phase 3 | `feat/streaming-foundation` | `development` | Q2 Checkpoint A; A1 merged |
| Phase 4 | `feat/streaming-dual-mode` | `development` | Phase 3 merged |
| Phase 5 | C3a PR (preferred) OR `feat/prompt-pack-realignment` | `development` | Phase 4 merged; C3a state determines branch choice |
| Phase 6 | `feat/streaming-renderer` (frontend submodule) | `development` (frontend) | Phase 4 merged |
| Phase 7 | `feat/streaming-rollout` (mostly config + tests) | `development` | Phases 5 + 6 merged |

## Decision points the user owns

- **D1** ✅ **RESOLVED 2026-04-26**: Sequence approved.
- **D2** ✅ **RESOLVED 2026-04-26**: Sprint 1 A1 already merged. No Phase 4 blocker.
- **D3** ⏳ (before Q2.3b ships): Confirm Q2.3a has had ≥1 full staging release cycle. Manual gate in PR description.
- **D4** ⏳ (before Phase 7 flag flip): Review the Q1.6 fidelity gate results (≥95% field match on 20 historical cases). If <95%, do not flip.
- **D5** (before Phase 7 expands beyond intake/triage): Confirm enrolled phase list. Default proposal: stay conservative at `intake,triage`. Research and synthesis phases stay JSON-only until a separate review.
- **D6** (before Q1.10 flag flip): Visual review of the new chat UI with the user (per Q-F — chat is a missing feature, not a refactor; user sign-off matters).

## Risks introduced by this sequencing

| Risk | Mitigation |
|---|---|
| A1 slips, blocking Phase 3 | Phase 3 has zero behavior change; can be staged on a feature branch even if A1's not in. Worst case Phase 3 starts on a rebased branch later. |
| C3a slips past Phase 4, forcing prompts.py edits in two shapes | Q2.3b/Q2.4/Q1.6 are ≤4 prompt edits; rewriting them on C3a's registry shape is small. Acceptable. |
| Q2.3a's staging bake takes longer than one release cycle | Q2.3b is gated manually in PR description. Reviewer holds the gate; not automatic. |
| Phase 5 expands beyond drift-fix into wider prompt rewrites | Ticket scope is explicit (drift fix only, not redesign). Reviewer rejects expansion. |
| Gate-2 rerun ticket sits in the backlog because it's "interleavable" | Add to the next sprint planning agenda as an explicit standalone item. |

## Engineer-assignment proposal (item 19, 2026-04-26)

The user asked me to investigate and propose. I don't have visibility into team rosters, so the proposal is **by skill profile**, not by name. Map names onto these profiles in the next planning session.

Three concurrent streams; each fits one engineer comfortably. A solo engineer can cover all three but the sequence stretches significantly.

| Stream | Skill profile | Phases | Approx. effort |
|---|---|---|---|
| **Backend / data path** | Python + SQLAlchemy + Alembic + arq workers + LangGraph factory + Pydantic + Pytest. Comfort with feature flags and schema migrations. | Q2 Wave 1A/1B/1C (Phase 1), Q1 Phase 3 (foundation), Q1 Phase 4 (dual-mode backend), Q1 Phase 7 backend bits (regression + load tests, flag expansion). Optionally also Phase 5 prompt realignment if same engineer wants prompt-pack ownership. | ~3-4 weeks |
| **Frontend / UX** | React + SSE consumers + Tailwind/CSS modules + a11y. Has shipped a chat-style UI before (Q1.10 is build-from-scratch — needs someone who's done message-bubble layouts and auto-scroll behavior, not just refactored an existing panel). | Q1 Phase 6 (Q1.7-Q1.10) and the visual-review portion of D6. Standalone — only blocked on Phase 4 merging the SSE schema. | ~2 weeks (Q1.10 is the long pole — net-new chat surface) |
| **Standalone tickets** | Backend Python — overlap with stream 1. | Gate-2 scoped rerun, prompt-pack realignment (if not folded into stream 1), document-parsed-text backfill. | ~1 week (sum of three small tickets) |

**Recommended bundling for a small team (2 engineers)**:
- Engineer α (backend): Streams 1 + 3.
- Engineer β (frontend with chat-UI experience): Stream 2.
- Sequence stretches ~5-6 weeks calendar-time on this split. Critical path is α (backend foundations gate β's frontend work).

**For a solo engineer**:
- All three streams in serial. Critical path lengthens to ~7-9 weeks. Not recommended unless other priorities free up.

**For a 3+ engineer team**:
- Add a second backend engineer to take Stream 3 (standalone tickets) in parallel — frees α to focus on Q2 + Q1 backend. Calendar-time drops to ~4 weeks.

**Independent of headcount, what should NOT happen**:
- Q2 owner ≠ Q1 owner is fine, but the engineer who lands Q1.6 should also land the Q1.6 fidelity-gate fixture run (same person, same head, same intent). Don't split that gate across owners.
- Q1.10 should not be picked up by an engineer who hasn't worked on chat UIs before — there are subtle behaviors (auto-scroll yielding to user scroll, accessibility live-regions, typing-indicator timing) that are easy to get wrong on a first attempt.

## What this sequence does NOT prescribe

- Sprint planning cadence (which phase goes in which sprint) — that's a sprint-planning conversation, not an architectural one.
- Exact PR review SLAs.
- Specific names against the engineer profiles above (item 19 — proposed by profile, not by name).

These are inputs to the sequence, not outputs.
