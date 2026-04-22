# SDK Adoption Decision

Updated: 2026-04-22

This decision note is grounded in the current VerdictCouncil architecture:
- backend source of truth: `VerdictCouncil_Backend/docs/architecture/01-user-stories.md`
- orchestration source of truth: `AGENT_ARCHITECTURE.md`
- current implementation baseline: FastAPI/Python backend plus React 18 + Vite frontend

## Recommendation Summary

| SDK | Official positioning | Fit for VerdictCouncil | Decision |
|---|---|---|---|
| [Streamdown](https://streamdown.ai/) | streaming markdown renderer with typography, code blocks, math, diagrams, and interactive streaming behavior | Strong fit for verdict explanations, fairness audits, deliberation traces, citations, and hearing-pack style AI output | Adopt first for explainability-heavy UI |
| [AI SDK](https://ai-sdk.dev/docs/reference/ai-sdk-core/stream-text) | TypeScript SDK for streamed text, tool calls, and structured output generation | Good fit for a future judge-assistant panel or richer structured streaming UI, but not a replacement for the Python pipeline | Adopt selectively later |
| [AI Elements](https://elements.ai-sdk.dev/docs/setup) | shadcn/ui-based AI component library with AI SDK integration | Weak near-term fit because the docs currently target React 19, Next.js 14+, shadcn/ui, and Tailwind 4, while VerdictCouncil is on React 18 + Vite | Defer unless frontend stack changes |
| [Workflow SDK](https://workflow-sdk.dev/) | durable, resumable TypeScript workflows and agents | Could help if VerdictCouncil adds a TypeScript sidecar for durable HITL workflows, but that is a larger architectural shift than the current backend contract work | Defer |
| [Chat SDK](https://chat-sdk.dev/docs) | unified TypeScript SDK for cross-platform bots on Slack, Teams, Google Chat, Discord, GitHub, and more | Useful for future external bot channels, but not for the core web application or current frontend-backend integration gaps | Do not adopt for the core app now |

## Why This Order

1. The current bottleneck is product truth, not lack of AI UI chrome. The user stories still need stronger end-to-end workflow coverage around rejection override, selective re-processing, amendment-of-record, and senior review.
2. Streamdown improves the most visible weakness with the lowest architectural risk: rendering long-form AI output cleanly and safely inside the existing React frontend.
3. AI SDK is promising where VerdictCouncil wants streaming structured responses or tool-backed assistant panels, but the existing Python pipeline remains the authoritative orchestration layer.
4. AI Elements and Workflow SDK both assume a TypeScript-centric path that does not match the present repo layout closely enough to justify immediate adoption.

## Suggested Near-Term Adoption Scope

### Phase 1
- Add Streamdown to the dossier and verdict surfaces where the system renders:
  - deliberation reasoning chain
  - verdict recommendation
  - fairness audit explanation
  - hearing-pack narrative sections

### Phase 2
- Prototype a narrow AI SDK sidecar only for streamed, structured judge assistance:
  - question drafting
  - hearing-pack summarization
  - scenario comparison output

### Not Recommended In This Pass
- Re-platforming the frontend around Next.js just to use AI Elements
- Rewriting Python orchestration into Workflow SDK
- Building Slack/Teams/Discord bots before the core web workflow meets the source user stories

## Review Trigger

Revisit this decision if any of the following become true:
- the frontend migrates to React 19 / Next.js / shadcn conventions
- the team decides to introduce a TypeScript workflow sidecar
- the project scope expands from an in-app judicial console to external chat channels
