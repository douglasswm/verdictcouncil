# Individual Report Template

**Instructions:** Each team member copies this template and fills in the sections for their assigned agent. Replace all `[PLACEHOLDER]` text. Do not delete any section — if a section does not apply, write one sentence explaining why and cross-reference another section where it is addressed.

**Cover page fields:**
- Project title: VerdictCouncil — AI-Assisted Judicial Decision Support
- Team number: [your team number]
- Individual name: [your name]
- Agent responsible for: [agent name, e.g. "Evidence Analysis Agent (Agent 3)"]

---

## Agent Quick Reference

| Agent | Layer | Model Tier | Primary Owner |
|---|---|---|---|
| `case-processing` (Agent 1) | L1 | Lightweight (`gpt-5.4-nano`) | [name] |
| `complexity-routing` (Agent 2) | L1 | Lightweight | [name] |
| `evidence-analysis` (Agent 3) | L2 | Strong (`gpt-5`) | [name] |
| `fact-reconstruction` (Agent 4) | L2 | Strong | [name] |
| `witness-analysis` (Agent 5) | L2 | Efficient (`gpt-5-mini`) | [name] |
| `legal-knowledge` (Agent 6) | L3 | Strong | [name] |
| `argument-construction` (Agent 7) | L3 | Frontier (`gpt-5.4`) | [name] |
| `hearing-analysis` (Agent 8) | L4 | Frontier | [name] |
| `hearing-governance` (Agent 9) | L4 | Frontier | [name] |

> **Naming note:** Agents 8 and 9 were renamed in v0.3.0 (CHANGELOG: `deliberation → hearing-analysis`, `governance-verdict → hearing-governance`). Older planning docs may still use the old names — treat the names above as authoritative.

---

## §1 Introduction

### 1.1 Agent Purpose

[2–3 sentences. What specific judicial task does this agent solve? Why does this step need to exist separately rather than being merged into a neighbouring agent?]

**Example (evidence-analysis):** The Evidence Analysis Agent identifies contradictions and corroborations across all submitted documents, assigning a reliability assessment to each piece of evidence. It exists as a separate step because evidence credibility assessment requires strong multi-document reasoning that is computationally expensive and should not be conflated with fact extraction (Agent 4) or witness assessment (Agent 5), which operate on different data dimensions.

### 1.2 Position in the Pipeline

- **Layer:** [L1 / L2 / L3]
- **Preceded by:** [agent name(s)]
- **Followed by:** [agent name(s) or "Layer 2 barrier" or "pipeline halt"]
- **Can trigger halt?** [Yes — describe condition / No]

### 1.3 Inputs and Outputs

| Direction | CaseState fields read | CaseState fields written |
|---|---|---|
| Input | [list field names from FIELD_OWNERSHIP map] | — |
| Output | — | [list field names from FIELD_OWNERSHIP map] |

Source: `src/shared/validation.py` — `FIELD_OWNERSHIP` dict.

---

## §2 Agent Design

### 2.1 Role and Functionality

[Describe what the agent does step by step. What does it analyse? What judgements does it make? What structure does its output have?]

### 2.2 Reasoning and Planning Workflow

[Describe the agent's internal reasoning approach. Does it use a structured chain-of-thought? Does it compare multiple hypotheses? Is its reasoning tool-grounded (must cite retrieved content) or open-ended?]

**Key prompt engineering choices:**
- [Choice 1 and rationale — e.g. "System prompt instructs agent to quote verbatim evidence text before making any claim about it, to prevent hallucination"]
- [Choice 2 and rationale]
- [Fallback instruction — e.g. "If contradictory evidence cannot be resolved, the agent must report the contradiction explicitly rather than defaulting to one side"]

### 2.3 Memory and State Management

- **In-context memory:** The agent receives the full `CaseState` JSON as part of its input on every call. It reads its declared input fields and writes its declared output fields. It does not maintain memory between cases.
- **Long-term persistence:** The orchestrator checkpoints `CaseState` to the `pipeline_checkpoints` PostgreSQL table after each agent hop. If the pipeline resumes from this point (e.g. via What-If), the agent receives the checkpointed state.
- **Agent-specific memory:** [Describe any additional state — e.g. "none" or "the judge KB vector store is scoped per-judge and retrieved externally by the search_precedents tool"]

### 2.4 Tools Integrated

| Tool | Type | Purpose | Key implementation detail |
|---|---|---|---|
| [tool name] | Custom Python / SAM Dynamic | [what it does] | [e.g. retry decorator, circuit breaker, sanitization] |

If no tools: write "This agent uses no tools. Its output is a pure LLM reasoning step over the inputs provided in the CaseState JSON."

### 2.5 Communication and Coordination Logic

- **How the agent receives work:** [PipelineRunner: direct in-process call / MeshPipelineRunner: Solace A2A pub/sub message with CaseState JSON payload]
- **How the orchestrator receives the result:** [synchronous return / SAM response message]
- **L2 parallel coordination (if applicable):** [Describe how your agent interacts with the Redis Lua barrier — writes its output to the Redis hash; barrier publishes merged state when all three L2 agents have written]

### 2.6 Prompt Engineering Patterns

[Describe the key techniques used in the system prompt for this agent. Reference the actual YAML config: `configs/agents/[agent-name].yaml`]

Common patterns to reference if applicable:
- **Tool-grounded output:** agent must cite tool-returned content verbatim, not paraphrase
- **Structured JSON output:** `response_format: json_object` with explicit schema in prompt
- **Chain-of-thought:** numbered reasoning steps with explicit "cite your source" instructions
- **Aggressive false-positive bias:** (governance-verdict) explicit instruction to flag bias even if uncertain
- **Confidence bounds:** agent must express uncertainty as a range, not a single score

### 2.7 Fallback Strategies

[What happens if the agent's LLM call fails? What happens if a tool fails?]

- LLM call failure: [retry decorator — how many retries? exponential backoff? or propagated as exception?]
- Tool failure: [tool-specific — e.g. `search_precedents` has circuit breaker → vector store fallback]
- Missing input fields: [agent receives partial CaseState — does it gracefully handle None fields?]

---

## §3 Implementation Details

### 3.1 Code Structure Overview

Key files for this agent:

| File | Purpose |
|---|---|
| `configs/agents/[agent-name].yaml` | SAM agent config: model tier, tools declaration, system prompt |
| `src/pipeline/runner.py` — `AGENT_TOOLS`, `TOOL_SCHEMAS`, `_execute_tool_call` | Tool registration for in-process runner |
| `src/tools/[tool-name].py` | Tool implementation (if applicable) |
| `tests/unit/test_[agent-name].py` or `test_[tool-name].py` | Agent/tool unit tests |

### 3.2 Tech Stack

| Component | Technology | Justification |
|---|---|---|
| LLM | OpenAI GPT (tier: [Lightweight / Efficient / Strong / Frontier]) | [Why this tier? e.g. "Strong model required for multi-document contradiction reasoning"] |
| Agent framework | Solace Agent Mesh (SAM) — `app_module: solace_agent_mesh.agent.sac.app` | A2A pub/sub transport for independent pod deployment |
| Orchestrator | `MeshPipelineRunner` (production) / `PipelineRunner` (tests) | See §2.5 |
| State format | Pydantic v2 `CaseState` JSON (~80+ fields) | Typed shared blackboard; field validation enforced |
| Tools | Custom Python (`src/tools/`) | Team-authored; no platform-provided tools |

### 3.3 Implementation Highlights

[2–4 sentences on what was non-trivial to implement. Reference specific line numbers. Examples:]
- "The `cross_reference` tool (`src/tools/cross_reference.py:38-72`) uses a strong model to compare document segments pairwise. The exponential-backoff retry decorator handles transient OpenAI rate-limit errors without failing the pipeline."
- "The `SearchPrecedentsTool` (`src/tools/sam/search_precedents_tool.py:62-80`) uses SAM's `DynamicTool` shell — the most complex tool integration pattern because it requires SAM to dynamically dispatch the tool call at runtime rather than registering a static function."

---

## §4 Testing and Validation

### 4.1 Unit Tests

| Test file | What it tests | Key assertions |
|---|---|---|
| `tests/unit/test_[name].py` | [describe] | [e.g. "injection payload blocked", "field ownership violation stripped", "verdict held after perturbation"] |

**How to run:**
```bash
cd VerdictCouncil_Backend
.venv/bin/pytest tests/unit/test_[name].py -v
```

### 4.2 Integration Tests

[Did you write integration tests for your agent? If yes, describe. If no, explain why and what would be needed.]

The SAM A2A integration smoke test (`tests/integration/test_sam_mesh_smoke.py`) covers the full distributed path but requires a live Solace broker. It is excluded from default CI (`-m mesh_smoke` marker) and must be run manually.

### 4.3 AI Security Tests

[For your agent specifically, what adversarial scenarios were tested?]

For all agents: the `test_guardrails_activation.py` suite sends known injection patterns (`<|im_start|>`, `<system>`, `[INST]`) to the pipeline input guardrail and asserts `input_injection_blocked` appears in the audit log.

[Agent-specific: e.g. for `legal-knowledge`: "A test case with a document claiming to be a legal statute but containing a system-override instruction was processed; the regex guardrail stripped the injection token before the document reached the agent."]

### 4.4 Results and Key Findings

[Summarise what the tests revealed. Were there bugs caught? What edge cases surfaced?]

---

## §5 Explainable and Responsible AI Considerations

### 5.1 How This Agent Addresses Explainability

[What does your agent produce that a judge can read and understand? Where does it appear in the dossier?]

Reference the group-level explainability architecture in `RESPONSIBLE_AI_SECTION.md §5.3` and add what is specific to your agent.

### 5.2 Bias Mitigation Strategies

[Is your agent's output at risk of amplifying bias? How is this mitigated?]

Examples:
- `evidence-analysis`: bias risk if inconsistently applying reliability standards across party types. Mitigation: structured output format forces the same assessment schema for every evidence item regardless of which party submitted it.
- `governance-verdict`: bias risk is highest here. See group report §5.2 for the full fairness audit mechanism.

### 5.3 Handling Sensitive Content and Governance Alignment

[Does your agent encounter sensitive content (names, financial amounts, medical conditions)? How does it handle it?]

All agents receive only case document text that has already been sanitized by the input guardrail. No agent is instructed to extract or store personal data beyond what is structurally necessary for the case decision.

Reference IMDA Pillar 2 (Human Involvement) from `RESPONSIBLE_AI_SECTION.md §5.1` — your agent's output is a recommendation, not a decision.

---

## §6 Security Practices

### 6.1 Agent-Specific Security Risks

[From `SECURITY_RISK_REGISTER.md`, which risks are most relevant to your agent?]

| Risk ID | Risk | Relevance to this agent |
|---|---|---|
| R-01 | Prompt injection via documents | [How does this agent's input surface expose it?] |
| R-02 | Hallucinated citations | [Applicable to legal-knowledge agent primarily; note if relevant] |
| R-14 | No strict JSON schema | [Does this agent's output have required fields validated?] |

### 6.2 Mitigations at Code Level

[What specific code mitigations apply to your agent?]

Examples:
- Input sanitization: `sanitize_document_content` called inside `parse_document.py:137-149` on all extracted file text before it enters any LLM context.
- Field ownership: your agent may only write its declared fields (`src/shared/validation.py` — `FIELD_OWNERSHIP`). Any attempt to write other fields is stripped.
- Tool retry: [describe retry decorator and limits for your agent's tools]
- [Agent-specific: e.g. `legal-knowledge` — circuit breaker at `src/shared/circuit_breaker.py` prevents cascading PAIR API failures]

---

## §7 Reflection

### 7.1 Personal Learnings

[3–5 sentences on what you personally learned from implementing this agent. What was harder than expected? What would you design differently?]

**Prompts to guide your reflection:**
- What did you learn about prompt engineering for structured JSON output that you didn't know before?
- What did the field ownership enforcement reveal about your initial implementation?
- How did the two-runner design (in-process test vs. distributed production) change how you wrote and debugged your agent?
- What did you learn about the Singapore legal domain that influenced your design?

### 7.2 Suggestions for Future Improvement

[2–3 concrete improvements specific to your agent. Reference the group report §9 for system-wide improvements; focus here on agent-specific improvements.]

Examples:
- "Add a confidence calibration step — the agent currently produces a single confidence score; a future version should output a confidence interval and flag when the interval is too wide to be actionable."
- "Integrate judge KB retrieval as a pipeline hook — the judge knowledge base API exists but is not yet injected into this agent's context. This would allow the agent to personalise its analysis to the sitting judge's known preferences and past rulings."
- "Add golden trajectory comparison tests — the eval suite currently checks field presence, not reasoning quality. Snapshot tests that compare the agent's step-by-step reasoning against a curated gold trace would catch prompt regressions."
