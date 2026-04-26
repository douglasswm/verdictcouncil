# Plan: Chat-Based Steering — Implementation Plan

**Spec:** `spec-2026-04-27-chat-steering.md` (approved 2026-04-27)
**Scope locked:** v1 — agent-initiated `human_input` tool on synthesis only, FocusDrawer chat panel, checkpointer-only persistence, no caps, no timeout, multi-turn allowed.

---

## Dependency map

```
                ┌──────────────────────────────────┐
                │  T1  GraphState.judge_messages   │
                │      slot + add_messages reducer │
                └──────────────┬───────────────────┘
                               │
        ┌──────────────────────┴────────────────────────┐
        ▼                                               ▼
┌────────────────────┐                    ┌──────────────────────────┐
│ T2  human_input    │                    │ T3  SSE event schemas     │
│     tool + register│                    │     AgentAwaitingInput    │
│     on synthesis   │                    │     AgentResumed          │
└──────────┬─────────┘                    └────────────┬─────────────┘
           │                                           │
           ▼                                           │
┌────────────────────────┐                             │
│ T4  Synthesis prompt   │                             │
│     guidance update    │                             │
└──────────┬─────────────┘                             │
           │                                           │
           ▼                                           ▼
┌──────────────────────────────────────────────────────────────┐
│ T5  /respond accepts action="message" + emits new SSE events │
└──────────────────────────────────┬───────────────────────────┘
                                   │
              ┌────────────────────┼───────────────────────┐
              ▼                                            ▼
┌──────────────────────────────┐               ┌─────────────────────────┐
│ T6  Backend integration test │               │ T7  Frontend wire types  │
│     — full e2e happy path    │               │     in lib/sseEvents.ts  │
└──────────────────────────────┘               └────────────┬────────────┘
                                                            │
                                                            ▼
                                          ┌────────────────────────────────┐
                                          │ T8  useAgentStream surfaces    │
                                          │     awaiting/resumed frames    │
                                          └────────────┬───────────────────┘
                                                       │
                                                       ▼
                                          ┌────────────────────────────────┐
                                          │ T9  AgentChatPanel component   │
                                          │     + tests                    │
                                          └────────────┬───────────────────┘
                                                       │
                                                       ▼
                                          ┌────────────────────────────────┐
                                          │ T10 FocusDrawer integration    │
                                          └────────────┬───────────────────┘
                                                       │
                                                       ▼
                                          ┌────────────────────────────────┐
                                          │ T11 Manual E2E + bug-fix       │
                                          │     iteration                  │
                                          └────────────────────────────────┘
```

**Parallelism:** T2 + T3 run in parallel after T1. T7+T8+T9 are sequential frontend work. The backend stack (T1–T6) can be developed and merged independently of the frontend stack (T7–T10) because the wire format is locked by the spec.

---

## Implementation order

1. **T1** GraphState slot. Foundation; everything else depends on it.
2. **T2 + T3** in parallel.
3. **T4** Synthesis prompt update.
4. **T5** REST extension + SSE emission (depends on T1, T2, T3).
5. **T6** Backend integration test (gate before frontend wire-up).
6. **T7 → T8 → T9 → T10** Frontend chain.
7. **T11** Manual E2E.

Backend merges to `development` after T6. Frontend merges to `development` after T10. Orchestration root bumps both submodule SHAs in a single commit.

---

## Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `interrupt()` inside a `@tool` doesn't work in conversational streaming mode (the synthesis phase uses conversational mode for token streaming) | Medium | T2's unit test explicitly exercises the conversational-mode path. If `interrupt()` is incompatible with `astream(stream_mode="messages")`, fall back to firing `interrupt()` from a wrap-tool middleware that catches the `human_input` call and pauses outside the streaming loop. |
| `interrupt_id` instability — LangGraph doesn't expose a stable ID for the pending interrupt | Medium | Mint our own UUID inside the tool body before calling `interrupt()`; include it in the interrupt payload + the SSE event. Validation on resume compares the inbound `interrupt_id` against the checkpointer's pending interrupt payload. |
| Multi-turn within a single agent step (Q4 default = allowed) creates a re-entrant interrupt that the checkpointer mishandles | Low-medium | Integration test T6 covers a 2-turn case explicitly. If the checkpointer corrupts state on second interrupt, fall back to "one question per phase" (a Q6-style cap) with a clear error message. |
| Frontend's existing `interrupt` SSE event listener (currently used for gate pauses via `InterruptEvent`) collides with the new `AgentAwaitingInputEvent` | Low | Both events share `kind="interrupt"`. Discriminate on payload shape: gate pauses carry `gate`, agent pauses carry `question` + `interrupt_id`. `useAgentStream` already routes by event-name; we add a sub-router on the parsed body. |
| Judge sends two `/respond` POSTs (double-click, network retry) | Low | Idempotency via `interrupt_id`: the second POST verifies the pending interrupt no longer matches and returns 409 instead of double-resuming. |
| Synthesis prompt change degrades existing synthesis quality on cases that don't need a question | Medium | Prompt diff goes through `git diff prompts.py` review. Spot-check 3 prior cases (replay via LangSmith) before merging T4. |
| Tee-write to `pipeline_events` table grows unbounded for chatty cases | Low | Existing `AgentEvent` shape already tee-writes; `judge_messages` reuses that path. No additional volume risk for v1. |

---

## Verification checkpoints

| After | Verify |
|---|---|
| T1 | `pytest tests/unit/test_graph_state.py` (existing); add a 1-line assert that `judge_messages` exists with the right reducer. |
| T2 | New `tests/unit/test_human_input_tool.py` — tool fires `interrupt()`, returns the resume payload's text. |
| T3 | New schema tests in `tests/api/test_pipeline_events_schema.py` — both events validate, both round-trip JSON. |
| T4 | Manual: read the prompt diff. No automated check (prompts are evaluated qualitatively). |
| T5 | New `tests/integration/test_chat_steering_e2e.py` — POST /respond with `action="message"` resumes a paused graph; SSE emits both events in order. |
| T6 | Same integration test; gate before frontend work. |
| T7 | `npm test src/__tests__/sseEvents.test.js` — both events parse. |
| T8 | `npm test src/__tests__/useAgentStream.test.jsx` — interrupt surface includes the new fields. |
| T9 | `npm test src/components/AgentChatPanel.test.jsx`. |
| T10 | `npm run lint && npm run typecheck`; manual: agent card focused → drawer shows panel. |
| T11 | Real backend + browser. Run a synthesis on a contrived ambiguous case. Ship-blocker: judge reply visibly influences final artifact. |

---

## Out of plan (deferred)

- LangSmith trace verification (success criterion #5 in spec) — runs as part of T11; if traces are broken, file a P1 bug, do not block ship.
- Documentation in repo root README — add as a small follow-up PR after v1 ships.
- ADR for the chat-steering decision — write after v1 ships and survives one real case.
