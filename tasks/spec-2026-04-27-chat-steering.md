# Spec: Chat-Based Steering for the LangGraph Pipeline

**Status:** Draft v0 — awaiting review
**Author:** Claude (initial draft)
**Date:** 2026-04-27
**Scope:** v1 — narrow, shippable mid-run human-in-the-loop. Larger ambitions (full bidirectional cancellation, freeform mid-stream interrupt) are explicitly v2+.

---

## Objective

Today the judge can only steer the pipeline at four gate boundaries (notes / field_corrections / per-subagent rerun). Agents themselves cannot ask the judge for input, and the judge cannot inject context into a running agent. This spec defines a v1 chat surface that closes that gap with the smallest mechanism that delivers real value:

1. **Agent-initiated questions.** An agent that detects ambiguity calls a `human_input(question)` tool. The graph pauses via `interrupt()`. The frontend renders the question. The judge types an answer. The graph resumes with the answer in the agent's message history.
2. **Persistent case thread.** A single `judge_messages` log per case, surfaced as a chat panel. Includes every agent question + judge reply, plus any free-form judge note left at a gate. Each phase agent's system prompt sees the full thread, so context survives across gates.

**Non-goals for v1:**
- Mid-stream cancellation while a model call is in flight.
- Multi-turn back-and-forth within a single agent step (one question → one answer → continue).
- Judge-pressed pause-anytime button. (See "v2 directions" at the bottom.)
- Voice / file attachment in the chat panel.
- Per-tool-call approval (HumanInTheLoopMiddleware pattern). Considered but rejected for v1 — see "Steering surface choices" below.

**Success looks like:** during a synthesis run, the agent encounters a contested point with two viable readings, calls `human_input("Which reading should I prioritise: A or B?")`, the judge picks B in the chat panel, and the agent's reasoning chain reflects that choice — visible in the streamed `llm_token` output and the final structured artifact.

---

## Assumptions

> **Correct any of these now or I'll proceed with them.**

1. **One steering surface, not three.** v1 targets agent-initiated questions only. Judge-pressed interrupt and per-tool approval are v2.
2. **Synthesis is the v1 phase.** It's where judge insight matters most and where one well-placed question can reshape the conclusion. Other phases get the tool but their prompts won't instruct them to use it. (Reasoning: research subagents have parallel branches — interrupting one mid-fan-out is messy. Audit must stay independent per architecture decision A3.)
3. **Existing `/cases/{id}/respond` is the seam.** New action `"message"` slots in next to `advance` / `rerun` / `halt` / `send_back`. No new endpoint.
4. **`add_messages` reducer for `judge_messages`.** Standard LangGraph pattern. Append-only. Persists in the checkpointer, replays on rerun.
5. **Existing `useAgentStream` SSE channel carries the new events.** `agent_awaiting_input` and `agent_resumed`. No second WebSocket.
6. **The chat panel lives inside the focused-agent drawer (`FocusDrawer` in `BuildingSimulation.jsx`)**, not in every `AgentCard`. Reasoning: a chat surface in a 220px card is unusable; the drawer already exists for detailed inspection.
7. **Trunk-based on the orchestration root, gitflow on submodules** (per CLAUDE.md). Backend changes go on `feat/chat-steering` in `VerdictCouncil_Backend`; frontend changes on `feat/chat-steering` in `VerdictCouncil_Frontend`; orchestration root just bumps submodule SHAs.

---

## Steering surface choices (task #2 resolution)

Three patterns considered:

| Pattern | Mechanism | v1 fit | Reason |
|---|---|---|---|
| **A. Per-tool approval** | `HumanInTheLoopMiddleware` wraps every tool call; judge approves / edits / rejects | ❌ | Too noisy — pipeline runs ~30+ tool calls; gating each one buries valuable interruptions in approval fatigue. |
| **B. Agent-initiated `human_input`** | Agent calls a tool when it wants to ask; tool fires `interrupt()` | ✅ **picked** | Agent has prompt-level guidance on when to ask. Low frequency, high signal. Single round-trip. |
| **C. Judge-pressed interrupt** | Anytime button in UI; backend cancels current step, injects message, replays | ⏳ v2 | Cancellation across `astream` is non-trivial — needs abort token threaded through middleware + tool calls. Worth it eventually, not for v1. |

v1 is Pattern B. Pattern C is the natural follow-up.

---

## Tech stack (relevant parts)

**Backend (VerdictCouncil_Backend):**
- LangGraph 0.x — graph orchestration, `interrupt()` / `Command(resume=...)` primitives.
- LangChain — `create_agent`, tool decorator, middleware.
- Pydantic v2 — `CaseState`, `GraphState`, phase-output schemas.
- FastAPI — REST endpoints, SSE.
- Redis — pub/sub channel for SSE fan-out (`vc:case:{id}:progress`).
- Postgres + SQLAlchemy async — `pipeline_jobs`, `pipeline_events` tee-write, `cases`.

**Frontend (VerdictCouncil_Frontend):**
- React 18 + Vite + Tailwind.
- `Streamdown` for live markdown render of `llm_token` deltas.
- `useAgentStream` hook for SSE + polling fallback (already lifted into `CaseDetail` per recent fix).

---

## Commands

**Backend:**
```bash
cd VerdictCouncil_Backend
.venv/bin/python -m pytest tests/unit -k "chat_steering or human_input"
.venv/bin/python -m pytest tests/integration -k "chat_steering"
.venv/bin/ruff check src/
.venv/bin/mypy src/
```

**Frontend:**
```bash
cd VerdictCouncil_Frontend
npm test -- --run src/components/AgentChatPanel.test.jsx
npm run lint
npm run typecheck
npm run dev   # local manual verify
```

---

## Project structure

```
VerdictCouncil_Backend/
  src/
    pipeline/graph/
      state.py                       # GraphState — add judge_messages slot + reducer
      tools/human_input.py           # NEW — interrupt-firing tool
      agents/factory.py              # add human_input to PHASE_TOOL_NAMES["synthesis"]
      prompts.py                     # synthesis prompt — instruct when to call human_input
    api/
      routes/cases.py                # /respond — accept action="message"
      schemas/pipeline_events.py     # AgentAwaitingInputEvent, AgentResumedEvent
  tests/
    unit/test_human_input_tool.py
    integration/test_chat_steering_e2e.py

VerdictCouncil_Frontend/
  src/
    components/
      AgentChatPanel.jsx             # NEW — chat thread + input
      AgentChatPanel.test.jsx
    pages/visualizations/
      BuildingSimulation.jsx         # FocusDrawer: render AgentChatPanel
    hooks/
      useAgentStream.js              # surface awaiting_input / resumed frames
    lib/
      api.js                         # api.sendJudgeMessage(caseId, agent, text)
```

---

## Wire format

### New GraphState slot

```python
# src/pipeline/graph/state.py
from langgraph.graph.message import add_messages
from langchain_core.messages import BaseMessage

class GraphState(TypedDict):
    # ... existing slots ...

    # Append-only chat log for the case. AIMessages are agent questions
    # (raised via the `human_input` tool); HumanMessages are judge replies
    # injected by the /respond endpoint. Phase agents read this in their
    # input payload so they see prior thread context across gates.
    judge_messages: Annotated[list[BaseMessage], add_messages]
```

### `human_input` tool

```python
# src/pipeline/graph/tools/human_input.py
from langchain_core.tools import tool
from langgraph.types import interrupt

@tool
def human_input(question: str) -> str:
    """Ask the operator (judge) a clarifying question and pause the
    pipeline until they respond. Use SPARINGLY — only when the answer
    materially changes your output and you cannot reasonably infer it
    from raw_documents, intake_extraction, or upstream phase outputs.

    Args:
        question: A specific, single-sentence question. Do not ask
            for confirmation; ask for information you actually need.

    Returns:
        The judge's reply text.
    """
    reply = interrupt({
        "kind": "human_input",
        "question": question,
    })
    if isinstance(reply, dict):
        return str(reply.get("text", ""))
    return str(reply or "")
```

### New SSE event types

```python
# src/api/schemas/pipeline_events.py — additions

class AgentAwaitingInputEvent(BaseModel):
    """Fired when an agent calls human_input(...) and the graph pauses.

    The frontend mounts the chat input on receipt; the agent stays
    paused until /respond with action="message" lands."""
    kind: Literal["interrupt"] = "interrupt"
    schema_version: Literal[1] = 1
    case_id: str
    agent: str                          # phase or research-{scope}
    question: str
    interrupt_id: str                   # for de-dupe across SSE replay
    ts: str
    trace_id: str | None = None


class AgentResumedEvent(BaseModel):
    """Fired immediately after /respond resumes the graph. Lets the
    UI clear the chat input + return the card to its 'running' state
    before the next llm_token frame lands."""
    kind: Literal["agent"] = "agent"
    schema_version: Literal[1] = 1
    case_id: str
    agent: str
    interrupt_id: str
    ts: str
    trace_id: str | None = None
```

### REST extension

Existing `POST /cases/{id}/respond` body shape, new action variant:

```json
{
  "action": "message",
  "text": "Prioritise reading B; the witness statement supports it.",
  "interrupt_id": "..."
}
```

Backend behavior:
1. Read pending interrupt from checkpointer; verify `interrupt_id` matches.
2. Append `HumanMessage(content=text)` to `judge_messages` via state update.
3. `Command(resume={"text": text})` continues the graph.
4. Emit `AgentResumedEvent`.

### Frontend `api.js`

```js
// Existing /respond is reused — no new endpoint.
api.sendJudgeMessage = (caseId, { agent, text, interruptId }) =>
  request('POST', `/api/v1/cases/${caseId}/respond`, {
    action: 'message',
    agent,
    text,
    interrupt_id: interruptId,
  });
```

---

## Code style (one snippet beats three paragraphs)

```jsx
// src/components/AgentChatPanel.jsx
//
// Chat thread for an agent. Reads judge_messages from outlet context
// (CaseDetail owns the SSE connection). Posts new judge replies via
// /respond when an awaiting_input frame is active for this agent.

export default function AgentChatPanel({ caseId, agentId }) {
  const { stream } = useOutletContext();
  const { interrupt, judgeMessages } = stream;
  const awaiting =
    interrupt?.kind === 'interrupt'
    && interrupt?.agent === agentId
    && interrupt?.case_id === caseId;
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);

  const send = useCallback(async () => {
    if (!awaiting || !draft.trim()) return;
    setSending(true);
    try {
      await api.sendJudgeMessage(caseId, {
        agent: agentId,
        text: draft.trim(),
        interruptId: interrupt.interrupt_id,
      });
      setDraft('');
    } finally {
      setSending(false);
    }
  }, [awaiting, draft, caseId, agentId, interrupt]);

  return (
    <div className="flex flex-col gap-2">
      <ChatThread messages={judgeMessages.filter(m => m.agent === agentId)} />
      {awaiting && (
        <ChatInput
          value={draft}
          onChange={setDraft}
          onSend={send}
          placeholder={interrupt.question}
          disabled={sending}
        />
      )}
    </div>
  );
}
```

Conventions:
- Backend: `_underscore_helpers`, type hints required, Pydantic models for everything on the wire.
- Frontend: function components only, hooks at top, early-return for loading/empty states, Tailwind utility classes.
- No emojis in code or commits.
- No co-author trailers (per global CLAUDE.md).

---

## Testing strategy

| Level | Framework | Lives in | What it covers |
|---|---|---|---|
| Backend unit | pytest | `tests/unit/test_human_input_tool.py` | Tool fires `interrupt()` with right shape; resume payload reaches the agent's `messages`. |
| Backend integration | pytest + LangGraph in-process | `tests/integration/test_chat_steering_e2e.py` | Full happy path: synthesis calls `human_input` → SSE emits `agent_awaiting_input` → POST /respond → graph resumes → final state contains the judge's reply influence. |
| Frontend unit | vitest + React Testing Library | `src/components/AgentChatPanel.test.jsx` | Renders awaiting state on interrupt frame; disables input when not awaiting; posts correct payload. |
| Frontend SSE shape | vitest | `src/__tests__/sseEvents.test.js` | New event schemas validate; `useAgentStream` surfaces interrupt frames correctly. |
| Manual E2E | Browser | n/a | Real synthesis run with a contrived ambiguous case — verify the question appears, the reply influences the artifact. |

Coverage target: 80% on new files. Existing files keep their current coverage.

---

## Boundaries

**Always:**
- Run unit + integration tests before merging.
- Update `useAgentStream` and the SSE schema in lockstep — frontend must not crash on an unknown frame.
- Persist every judge message via the checkpointer (free with `add_messages`); replay-safe is non-negotiable.
- Tee-write `judge_messages` to `pipeline_events` so post-hoc replay is possible.

**Ask first:**
- Adding `human_input` to phases other than synthesis (changes prompt scope).
- Schema changes to `judge_messages` shape (forward-compat is harder once cases exist with prior shape).
- Touching the existing `/respond` action variants.
- Storing chat content in a new DB table (vs. checkpointer-only). v1 is checkpointer-only; if a "case chat history" page is wanted, that's a separate spec.

**Never:**
- Skip `interrupt_id` validation — replay attacks / stale-tab double-sends would corrupt resume state.
- Cancel an in-flight model call without the abort-token plumbing (defer to v2).
- Persist secrets / PII in `judge_messages` without redaction (the existing audit-log redaction policy applies).
- Auto-resume after a timeout — judge must explicitly reply or hit Halt.

---

## Success criteria

A v1 release is "done" when all of these are objectively true:

1. **Backend.** `pytest -k "chat_steering or human_input"` passes. Synthesis prompt includes guidance on when to call `human_input`. The tool is registered on the synthesis phase only. `judge_messages` slot is on `GraphState` with `add_messages` reducer. `/respond` accepts `action="message"`.

2. **Wire.** `agent_awaiting_input` and `agent_resumed` events validate against their Pydantic schemas. SSE consumers see them on the existing `agent` / `interrupt` SSE event names. Existing tests for `LlmTokenEvent` / `ToolCallDeltaEvent` / `InterruptEvent` still pass.

3. **Frontend.** `AgentChatPanel` renders inside `FocusDrawer`. Disabled when not awaiting, enabled with the agent's question as placeholder when awaiting. Send posts `/respond` with the correct payload. After resume, the input clears and the card returns to running state. Frontend tests pass. `npm run lint` + `typecheck` clean.

4. **E2E.** Manual test on a real case: judge sees the question, types a reply, the streamed reasoning chain visibly incorporates the reply. The final structured artifact reflects the choice.

5. **Trace.** The full sequence (tool call → interrupt → resume → continued reasoning → final output) is visible as one tree in LangSmith — no broken parent/child links.

6. **Docs.** This spec file is updated with any deltas discovered during implementation, then committed alongside the feature.

---

## Open questions

> **Need answers before Phase 2 (Plan).**

1. **Q1 — Phase scope.** Synthesis only for v1 (assumption #2)? Or include intake too (judge could clarify ambiguous fact patterns at intake)?
2. **Q2 — Chat panel placement.** Inside `FocusDrawer` only (assumption #6)? Or always-visible chat sidebar in `CaseDetail`?
3. **Q3 — Persistence horizon.** Checkpointer-only (cleared when case is archived), or mirror `judge_messages` to a `case_chat` DB table for permanent record + post-hoc audit?
4. **Q4 — Multi-turn.** If the agent calls `human_input` and the judge's reply itself is ambiguous, can the agent call `human_input` again in the same step? v1 default: yes (each call fires its own interrupt). Confirm.
5. **Q5 — What if the judge ignores the prompt for hours?** v1 default: no auto-timeout. Halt remains the manual escape. Confirm.
6. **Q6 — Cost.** Each `human_input` call adds a tool round-trip + judge wait time. Acceptable for synthesis (low call volume) but a cap (e.g. max 3 questions per phase) would be cheap insurance. Default: no cap. Want one?

---

## Estimated scope

Once Q1–Q6 are answered:

| Component | Effort |
|---|---|
| Backend: tool + state slot + prompt update + tests | 0.5 day |
| Backend: /respond extension + SSE event schemas + integration test | 0.5 day |
| Frontend: `AgentChatPanel` + drawer integration + tests | 0.75 day |
| Frontend: `useAgentStream` event surfacing + SSE test | 0.25 day |
| E2E manual + bug-fix iteration | 0.5 day |
| Spec/PR/review buffer | 0.5 day |
| **Total v1** | **~3 days** |

---

## v2+ directions (out of scope for v1)

- **Judge-pressed interrupt anytime.** Requires threading a cancellation token through `astream` + middleware + tool calls. Big change; worth doing once v1 proves the chat surface earns its keep.
- **Per-tool approval (HITL middleware).** Useful for high-risk tools (e.g. anything that mutates external state). Pipeline today is read-only against external systems — low value.
- **Multi-modal input.** Image upload, file attach, audio. Not needed for textual judicial work.
- **Cross-case chat memory.** A judge-personal "things I've told the system before" store. Major scope.
- **Live "agent typing" indicator.** Already implicit via `llm_token` streaming.
