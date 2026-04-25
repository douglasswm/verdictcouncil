# Tool Implementation Audit — VerdictCouncil

- **Date**: 2026-04-25
- **Sprint**: 0 / Task 0.3 (feeds 0.4 architecture proposal & Sprint 1 tool roster)
- **Source of truth**: `/Users/douglasswm/Project/AAS/VER/VerdictCouncil_Backend/src/pipeline/graph/tools.py` (registration) and `/Users/douglasswm/Project/AAS/VER/VerdictCouncil_Backend/src/tools/*.py` (implementations)
- **Agent → tool map**: `/Users/douglasswm/Project/AAS/VER/VerdictCouncil_Backend/src/pipeline/graph/prompts.py:74-84` (`AGENT_TOOLS`)

## Enumeration

The only `@tool`-decorated registrations in the backend are produced by
`make_tools(...)` at `src/pipeline/graph/tools.py:127-319`. There are
**seven** tools registered, exactly matching the breakdown's list (no hidden
tools were discovered). No `BaseTool` subclasses or alternative
`create_tool` registrations exist anywhere under `src/`.

Registered tools (in registration order):

1. `parse_document`        (tools.py:149)
2. `cross_reference`       (tools.py:173)
3. `timeline_construct`    (tools.py:193)
4. `generate_questions`    (tools.py:210)
5. `confidence_calc`       (tools.py:236)
6. `search_precedents`     (tools.py:263)
7. `search_domain_guidance` (tools.py:291)

`AGENT_TOOLS` (prompts.py:74) currently distributes them across 7 of 9
agents (`complexity-routing`, `hearing-analysis`, `hearing-governance` get
no tools).

---

## 1. `parse_document`

- **Registration**: `/Users/douglasswm/Project/AAS/VER/VerdictCouncil_Backend/src/pipeline/graph/tools.py:149-168`
- **Implementation**: `/Users/douglasswm/Project/AAS/VER/VerdictCouncil_Backend/src/tools/parse_document.py:84-214`
- **Signature**: `parse_document(file_id: str, extract_tables: bool = True, ocr_enabled: bool = False, run_classifier: bool = False) -> dict` — returns `{file_id, filename, content_type, text, pages, tables, metadata, parsing_notes, sanitization}`.
- **Classification**: **REAL — KEEP**
- **Evidence**: Calls the OpenAI Files API (`client.files.retrieve`, parse_document.py:118) and the Responses API with `input_file` attachments (parse_document.py:50-80) plus deterministic regex sanitisation (`sanitize_text` at parse_document.py:156, 175). The `state` runner short-circuits on cache hit (parse_document.py:92-99); on miss the tool performs real I/O against OpenAI plus PII regex scrubbing — not a thin LLM wrapper.
- **Worth simplifying?**: Yes (cosmetic). The "Use OpenAI Responses to JSON-extract pages" body is doing what is essentially structured RAG ingest; for Sprint 1 it should be replaced with a deterministic loader (PyMuPDF / pdfplumber → `RecursiveCharacterTextSplitter` → embeddings) per `langchain-rag` skill. The `@tool` surface stays the same; only the internals change. Treat as **KEEP-with-simplify**.
- **Caller map**: `case-processing`, `evidence-analysis` (prompts.py:75, 77).

## 2. `cross_reference`

- **Registration**: `src/pipeline/graph/tools.py:173-188`
- **Implementation**: `src/tools/cross_reference.py:67-136`
- **Signature**: `cross_reference(segments: list[dict] | None = None, check_type: str = "all") -> dict` — returns `{contradictions: [...], corroborations: [...]}`.
- **Classification**: **LLM-wrapper — DROP**
- **Evidence**: The whole tool body is one `client.chat.completions.create(..., model=settings.openai_model_strong_reasoning, response_format={"type": "json_object"})` (cross_reference.py:37-64). Inputs are simply re-serialised as JSON (`documents_text = json.dumps(doc_summaries, ...)`, line 113) and passed verbatim to the LLM. There is no domain logic, no external lookup, no deterministic computation — a strong-reasoning LLM is being invoked through a tool boundary purely to reformat its prompt. The calling `evidence-analysis` agent already runs on a strong reasoning model and can perform the same comparison natively in its own structured-output reply.
- **Caller map**: `evidence-analysis` (prompts.py:77).

## 3. `timeline_construct`

- **Registration**: `src/pipeline/graph/tools.py:193-205`
- **Implementation**: `src/tools/timeline_construct.py:50-121`
- **Signature**: `timeline_construct(events: list[TimelineFact]) -> list[dict]`.
- **Classification**: **REAL but borderline — DROP (defer to agent structured output)**
- **Evidence**: Module docstring states "Pure-logic tool that sorts extracted facts into chronological order. No LLM calls required." (timeline_construct.py:1-5). Implementation is a `datetime.strptime` loop over a fixed `_DATE_FORMATS` list (lines 18-30, 42-46) followed by `dated_entries.sort(key=lambda pair: pair[0])` (line 109). The deterministic logic is real; however, sorting a list of <50 events by ISO date is something the `fact-reconstruction` agent can already do reliably inside a structured response. Keeping it as a tool spends a round-trip on a `dates.sort()` call — drop and let the agent emit a chronologically ordered timeline directly. If date-format ambiguity proves to be a problem in eval, re-introduce as a small `parse_dates` utility (not as a top-level tool).
- **Caller map**: `fact-reconstruction` (prompts.py:78).

## 4. `generate_questions`

- **Registration**: `src/pipeline/graph/tools.py:210-231`
- **Implementation**: `src/tools/generate_questions.py:74-141`
- **Signature**: `generate_questions(argument_summary: str, weaknesses: list[str], question_types: list[str] | None = None, max_questions: int = 5) -> list[dict]`.
- **Classification**: **LLM-wrapper — DROP**
- **Evidence**: Body is one `client.chat.completions.create(..., model=settings.openai_model_strong_reasoning, response_format={"type": "json_object"})` (generate_questions.py:41-71). Inputs `argument_summary` and `weaknesses` are dropped verbatim into the user prompt (lines 58-66). The post-processing is just shape-normalising the returned questions (lines 128-137). The calling `witness-analysis` agent is *itself* an LLM whose entire job is to interrogate witness credibility; asking it to delegate question wording to a sibling LLM call adds latency and tokens with zero capability lift.
- **Caller map**: `witness-analysis` (prompts.py:79).

## 5. `confidence_calc`

- **Registration**: `src/pipeline/graph/tools.py:236-258`
- **Implementation**: `src/tools/confidence_calc.py:48-146`
- **Signature**: `confidence_calc(evidence_strengths, fact_statuses, witness_scores, precedent_similarities) -> {confidence_score, breakdown, classification}`.
- **Classification**: **REAL — KEEP (small)**
- **Evidence**: Pure deterministic arithmetic — fixed weight dict (`_DEFAULT_WEIGHTS` line 13-18), label→score lookups (`_EVIDENCE_STRENGTH_MAP`, `_FACT_STATUS_MAP` lines 21-34), weighted sum and band classification (lines 116-130). No LLM, no I/O. Module header says "Pure calculation -- no LLM calls" (confidence_calc.py:2-5).
- **However**: Whether this lands in the Sprint-1 roster depends on the architecture proposal. The breakdown's target roster is the 3 RAG/ingest tools only — confidence scoring may instead live as a *post-processing utility* invoked by the verdict-synthesis node directly (not registered as an agent-callable tool), since LLMs are notoriously bad at using exact numeric weights even when given a calculator. Recommendation: **demote to internal utility** rather than agent tool. If kept as a tool it stays as REAL.
- **Caller map**: `argument-construction` (prompts.py:81).

## 6. `search_precedents`

- **Registration**: `src/pipeline/graph/tools.py:263-286`
- **Implementation**: `src/tools/search_precedents.py:138-302` (sync wrapper at 290-302; metadata variant at 305-317)
- **Signature**: `search_precedents(query: str, domain: str = "small_claims", max_results: int = 5) -> list[dict]` — `vector_store_id` injected via closure (tools.py:281).
- **Classification**: **REAL — KEEP**
- **Evidence**: HTTP call to PAIR Search API (`httpx.AsyncClient` POST to `settings.pair_api_url`, search_precedents.py:112-118), Redis-backed distributed rate-limit (`_rate_limit`, lines 70-81), Redis cache (lines 153-165, 270-275), circuit breaker (`get_pair_search_breaker`, lines 204-225), and OpenAI vector-store fallback (`vector_store_search`, lines 181-187, 211-218, 242-249). This is the heaviest tool and is unambiguously real infrastructure.
- **Worth simplifying?**: One observation — the metadata side-channel (`PrecedentMetaSideChannel` at tools.py:45-56 + worst-of merge at tools.py:22-37) is non-trivial because PAIR can degrade. That complexity is justified.
- **Caller map**: `legal-knowledge` (prompts.py:80).

## 7. `search_domain_guidance`

- **Registration**: `src/pipeline/graph/tools.py:291-313`
- **Implementation**: `src/tools/search_domain_guidance.py:30-94`
- **Signature**: `search_domain_guidance(query: str, vector_store_id: str, max_results: int = 5) -> list[dict]` (vector_store_id injected via closure at tools.py:309).
- **Classification**: **REAL — KEEP, RENAME**
- **Evidence**: Calls `client.responses.create(..., tools=[{"type": "file_search", "vector_store_ids": [vector_store_id], ...}])` (search_domain_guidance.py:57-66), iterating real `file_search_call` results back to a citation list (lines 70-80). This is genuine OpenAI vector-store RAG, not a free-text LLM call. Raises `DomainGuidanceUnavailable` (a CriticalToolFailure) when no store is provisioned (line 51-52, 92-94) — semantics the agent cannot replicate without it.
- **Rename**: `search_domain_guidance` → **`search_legal_rules`** to match the breakdown's Sprint-1 contract (statutes / practice directions / bench books are "the rules", clearer than "guidance" which sounds advisory).
- **Caller map**: `legal-knowledge` (prompts.py:80).

---

## Proposed final roster (Sprint 1)

Three real tools, in priority order:

1. **`parse_document`** — only deterministic ingestion path from uploaded files into structured pages/tables; precondition for all downstream RAG and analysis. Keep the `@tool` surface; replace the internal "Responses API JSON extraction" body with a deterministic loader + splitter per `langchain-rag` skill in Sprint 1.
2. **`search_precedents`** — only path to PAIR judiciary case law, with rate limiting, cache, circuit breaker, and vector-store fallback. The most operationally complex tool and the highest-value RAG surface. Keep as-is.
3. **`search_legal_rules`** (renamed from `search_domain_guidance`) — only path to the curated per-domain vector store (statutes, bench books, practice directions). Keep implementation, rename for clarity.

## Drop list

| Tool | Classification | Why dropped |
|---|---|---|
| `cross_reference` | LLM-wrapper | Body is one `chat.completions.create` with strong-reasoning model and JSON output; the calling `evidence-analysis` agent runs on the same tier and can produce contradictions/corroborations natively in its structured response. |
| `timeline_construct` | Real-but-trivial | Pure `strptime` + `list.sort` over <50 events; an LLM agent on a strong-reasoning model can emit a chronologically ordered list directly with comparable reliability. |
| `generate_questions` | LLM-wrapper | Body is one `chat.completions.create` returning question dicts; `witness-analysis` is itself an LLM whose entire job is generating probative questions — the tool adds a round-trip with no capability gain. |
| `confidence_calc` | Real (deterministic) — **demote, do not delete** | Pure arithmetic over fixed weights. Move out of the agent-callable tool registry and invoke directly from the verdict-synthesis node (or wherever Sprint 1 lands the final score), since giving an LLM a "calculator" for fixed-weight scoring invites incorrect call sites. The Python function survives; only its `@tool` registration is dropped. |

## Name changes

- `search_domain_guidance` → `search_legal_rules` (registration name and module name; keeps the closure-injected `vector_store_id` pattern and `DomainGuidanceUnavailable` error semantics).

No other renames recommended.

## Open questions for Sprint 0.4

1. **`confidence_calc` placement** — keep as agent tool, demote to utility, or replace entirely with a structured-output Pydantic schema computed in Python after the verdict-synthesis node? The audit recommends "demote to utility", but the routing must be confirmed against the new pipeline graph shape proposed in Sprint 0.4.
2. **`parse_document` internals** — do we keep the OpenAI Responses-API extraction during transition, or land the deterministic loader (PyMuPDF/pdfplumber + `RecursiveCharacterTextSplitter`) in Sprint 1 directly? Both preserve the same `@tool` contract; the choice affects ingestion latency and OCR coverage.
3. **`timeline_construct` retention** — if Sprint 1 evals show date-parsing drift in agent-emitted timelines, do we re-introduce a smaller `parse_dates` helper (not registered as a tool, called from the fact-reconstruction node) instead of the full `timeline_construct`?
4. **Tool-less agents** — `complexity-routing`, `hearing-analysis`, `hearing-governance` already declare empty tool lists (`AGENT_TOOLS` lines 76, 82, 83). After the drops above, `evidence-analysis`, `fact-reconstruction`, `witness-analysis`, and `argument-construction` also become tool-less. Sprint 0.4 should confirm whether these collapse into plain LLM nodes (preferred per `langgraph-fundamentals` — `StateGraph` directly, not `create_agent`) or remain as agents-with-no-tools.
