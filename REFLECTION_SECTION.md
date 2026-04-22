# §9 Reflection

**For group report §9**

---

## Key Learnings

### 1. Fixed topology is the right choice for a judicial system — and needs to be justified early

The most debated architectural decision was whether to use a dynamic planner (let an LLM decide which agents to call and in what order) or a fixed pipeline topology. We chose fixed topology — and that decision shaped every downstream design choice.

The lesson: in a domain where auditability is non-negotiable, determinism is a feature. A dynamic planner that routes differently on different runs makes it impossible to reproduce the audit trail for an appeals process. A fixed topology means the audit log is structurally reproducible — the same case always runs the same agents in the same order. We learned to articulate this not as a limitation ("we didn't build a sophisticated planner") but as a positive design choice ("we chose reproducibility over adaptability because the domain requires it").

This justification — that design decisions must be grounded in domain requirements, not just technical preference — is the principle we applied most consistently across the project.

### 2. Field ownership enforcement catches real integration bugs

Early in development, agents occasionally wrote to fields they didn't own — usually because of a copy-paste error in a Pydantic model update or because a new agent was added without updating the ownership map. These bugs were silent: the field was overwritten, the downstream agent saw unexpected values, and the output was wrong in ways that were hard to trace.

Once we implemented `FIELD_OWNERSHIP` enforcement (each agent may only write its declared fields; violations are stripped and logged), these bugs became loud and immediate. The enforcement layer was written once in `src/shared/validation.py` and applied in both the in-process runner and the distributed mesh runner — meaning the same protection applies in unit tests and in production.

The learning: explicit ownership contracts between components, enforced at runtime, are more reliable than documentation or convention. The code cannot lie; a docstring can.

### 3. Running two orchestrators (test vs. production) is worth the complexity

We maintain two pipeline runners: `PipelineRunner` (in-process, no external dependencies) and `MeshPipelineRunner` (distributed SAM pub/sub, production Kubernetes). This was initially seen as duplicated complexity. In practice, it proved essential.

Unit tests that ran against `PipelineRunner` completed in seconds without requiring a running Solace broker, Kubernetes cluster, or OpenAI API key. The distributed `MeshPipelineRunner` was validated separately with a live broker. The shared interface — same `CaseState`, same hooks, same field ownership enforcement — meant bugs found in unit tests were genuinely representative of the production path.

The pattern mirrors testcontainers vs. in-memory stubs in database testing. The lesson: invest in the abstraction that lets you test the logic without requiring the infrastructure.

### 4. The Redis Lua barrier for L2 parallel fan-out was harder than it looked

The three L2 agents (evidence analysis, fact reconstruction, witness analysis) run in parallel and must all complete before Layer 3 begins. The naive approach — polling a shared flag — has race conditions: two agents completing simultaneously can both see the flag as unset, and neither publishes the merged state.

The Lua script running atomically in Redis solves this by making the "am I the last to finish?" check atomic. Writing and debugging this script took significantly longer than the initial estimate. The lesson: distributed coordination problems that look like simple "wait for all" tasks often have subtle race conditions that only appear under concurrent load. The Lua approach was the correct solution, but we underestimated the time needed to validate it.

### 5. SAM broker authentication required non-trivial debugging

Integrating Solace Agent Mesh as the A2A transport introduced early challenges with broker authentication. The SAM framework expects specific credential formats and VPN configurations, and error messages from the broker were not always descriptive. This was resolved by fixing the SAM broker auth configuration (reflected in commit history: "fix SAM broker auth + agent name identifiers"), but it consumed more time than anticipated.

The lesson: when adopting an OSS framework as infrastructure, budget time for integration friction that is not visible in the framework's happy-path documentation.

---

## Challenges Faced and How They Were Overcome

| Challenge | Root Cause | Resolution |
|---|---|---|
| SAM broker authentication failures during initial integration | Credential format mismatch between SAM config and broker; agent name format not matching SAM routing rules | Corrected VPN config and agent identifier format in SAM YAML configs; added integration smoke test (`test_sam_mesh_smoke.py`) to catch future regressions |
| What-If scenario running on incomplete state | The `WhatIfController` deep-clones a `CaseState`, but correctness depends on the calling API route supplying the full checkpoint state loaded from `pipeline_checkpoints` | Verified the controller logic is correct; documented the caller dependency as a known constraint; added checkpoint-reload requirement to the API route specification |
| L2 aggregator race condition under parallel load | Two agents completing near-simultaneously both attempted to publish the merged state | Replaced polling-based aggregation with an atomic Redis Lua script that returns `1` exactly once when all three agents have written |
| CaseState field access via dict vs. Pydantic model | Early agents accessed fields as raw dicts; as `CaseState` grew to 80+ typed fields, type errors became frequent and hard to trace | Migrated to typed `CaseState` (Phase 4 in commit history: "typed CaseState"); field access is now fully type-checked and IDE-navigable |
| CI/CD documentation diverging from reality | Architecture docs were written aspirationally (describing the target CI/CD design), while actual workflow files evolved separately | Added an explicit "Reality vs. Target State" callout to `docs/architecture/06-cicd-pipeline.md` listing all differences; accepted that the target design is aspirational and labelled it as such |
| Judge KB not injected into pipeline | The knowledge base service was built as a standalone REST API for document management, but no pipeline hook was written to inject judge-KB results into agent prompts mid-pipeline | Documented as a known gap; the judge KB is functional as a standalone tool but does not yet influence the pipeline |

---

## Suggestions for Future Improvements

### Immediate (highest ROI)

1. **Wire MLflow distributed tracing.** Adding `mlflow.openai.autolog()` to the runners captures every LLM call — inputs, outputs, latency, token counts — into a queryable trace store. This is ~1 hour of work and produces concrete observability evidence for both internal monitoring and grading audit.

2. **Make security CI gates blocking.** `pip-audit` and `bandit` both run in CI but with `continue-on-error: true`. Removing that flag makes dependency CVEs and Python SAST findings hard failures — a necessary step for a system handling judicial data.

3. **Add adversarial test suite.** Three to five pytest tests that send known injection payloads to `check_input_injection` and assert they are blocked and recorded in the audit log. Zero new dependencies, directly demonstrates AI security testing capability.

### Medium term

4. **Inject judge KB into pipeline.** Register a `BeforeAgentHook` for `legal-knowledge` that retrieves relevant documents from the judge's personal knowledge base and prepends them to the agent's context. This closes the gap between the KB REST API and the pipeline.

5. **Migrate rate limiter to Redis.** The current in-memory sliding window is not shared across web-gateway replicas (HPA 2-5 pods). Each pod has an independent counter, making the 60 req/min limit per-pod rather than per-system. Redis-backed rate limiting requires ~2 hours and provides genuine multi-replica protection.

6. **Demographic bias evaluation set.** Add test cases that rotate demographic attributes (names, identifiers) to measure whether the pipeline produces systematically different verdicts. This directly addresses the known gap in the fairness audit.

### Longer term

7. **Formalise IMDA governance alignment in operations.** The current fairness audit is a terminal LLM check. A more robust implementation would log structured fairness metrics per case, aggregate them over time via MLflow monitoring, and alert when bias indicators exceed thresholds — implementing the IMDA Pillar 3 (Operations Management) requirement at the system level, not just per-case.

8. **Extend to Magistrates' Court domain.** The current scope is intentionally narrow (SCT + Traffic). Expanding to Magistrates' Court would require legal knowledge reconfiguration, new domain-specific tools, and a broadened PAIR API query scope — but the pipeline architecture would remain unchanged.

9. **Implement US-036 amendment-of-record end-to-end.** The senior judge review flow is partially implemented; the amendment-of-record workflow (where a senior judge formally amends a junior judge's recorded decision) requires additional API endpoints and a frontend workflow not yet built.
