# MLflow Research — VerdictCouncil Grading Fit

**Researched:** 2026-04-21
**Codex challenge corrections applied:** 2026-04-21 (session `019dabdd-37be-77b0-8200-468b88aecf32`)
**Purpose:** Assess whether adding MLflow closes grading gaps identified in `GAPS.md`, specifically §5 (Responsible AI), §6 (Risk Register), §7 (MLSecOps/LLMSecOps), and §8 (Testing Summary).

---

## What MLflow Provides (Current: MLflow 3.x)

MLflow has repositioned as an "AI engineering platform for agents, LLMs, and ML models." Key capabilities relevant to this stack:

### LLM Tracing — `mlflow.openai.autolog()`
Enables automatic tracing for `AsyncOpenAI` calls. Captures OpenAI API inputs/outputs, latency, and token usage per call.

> **Codex correction:** The original claim that one line gives "tool invocations and results" and "guardrail pass/fail outcomes" is **overstated**. MLflow autolog captures OpenAI API calls only. VerdictCouncil's local tool execution (`parse_document`, `cross_reference`, etc.) and guardrail checks in `guardrails.py` are custom Python code, not OpenAI API calls. Complete agent traces including those require **manual tracing** with `mlflow.start_span()`. See: https://mlflow.org/docs/latest/genai/tracing/integrations/listing/openai/

> **Codex correction:** The insertion point also matters. VerdictCouncil's `tests/eval/eval_runner.py` uses `MeshPipelineRunner`, not `runner.py`. Instrumenting only `runner.py` misses the main distributed execution path.

```python
# runner.py — add near top (captures OpenAI calls only, not local tools)
import mlflow
mlflow.openai.autolog()
mlflow.set_experiment("verdictcouncil-pipeline")

# For local tool execution, manual spans are required:
# with mlflow.start_span(name="parse_document") as span:
#     result = await parse_document(...)
#     span.set_outputs(result)
```

### LLM Evaluation — `mlflow.evaluate()` + Built-in Judges
Available scorers: `RelevanceToQuery`, `Correctness`, `Completeness`, `Fluency`, `Equivalence`, `Summarization`, `Guidelines`, `ToolCallCorrectness`, `ToolCallEfficiency`. Multi-turn: `ConversationalSafety`, `ConversationCompleteness`.

Can be run against gold-set test cases as a CI step.

> **Codex correction:** "Runnable against existing gold-set fixtures in `tests/eval/` as a CI step" is hand-wavy. Those fixtures in `tests/eval/eval_runner.py` are pytest-driven end-to-end runs, not an MLflow evaluation dataset. Converting them to `mlflow.evaluate()` input format requires non-trivial transformation work — it is not a direct drop-in.

> **Caveat:** The built-in `Safety` scorer is **Databricks-exclusive** — not available in open-source MLflow. Custom safety judges must be written.

### Prompt Registry
Git-style versioning for prompts with immutable versions and semantic aliases (`@production`, `@staging`). VerdictCouncil's 9 agent prompts in `configs/agents/*.yaml` can be migrated here for full version history with diff view.

### LoggedModel — Version Tracking
Links code (git SHA), configs, prompts, evaluations, and traces into a single version record. Provides the audit trail: "version X was live from date A to date B; here are all traces and evaluation results."

### Production Monitoring
Dashboards showing latency, token usage, and quality scores over time. Custom metrics can be added. Provides ongoing observability for quality and (with custom judges) fairness metrics.

---

## What MLflow Cannot Do (Critical Honest Gaps)

| Missing Capability | Grading Impact |
|---|---|
| **No adversarial/injection testing** — Safety scorer is Databricks-only; no red-teaming module | §7 "AI security tests" gap remains open |
| **No Risk Register** — observability tool, not a risk documentation tool | §6 is still a manual documentation task |
| **No IMDA mapping** — cannot write governance framework alignment | §5 IMDA section still requires manual authoring |
| **No log aggregation** — does not replace ELK/Loki/Grafana | §7 alerting still needs a strategy |
| **No fairness definition** — "fairness" has no built-in judge; requires custom `Guidelines` scorer | §5 fairness monitoring requires custom work |

---

## Grading Section Mapping

| MLflow Feature | §5 Responsible AI | §6 Risk Register | §7 MLSecOps | §8 Testing |
|---|---|---|---|---|
| `mlflow.openai.autolog()` tracing | Partial — traceability evidence | None | **Yes** — auditability, logging | None |
| Prompt Registry | None | None | **Yes** — versioning & tracking | None |
| LoggedModel version tracking | None | None | **Yes** — deployment audit trail | None |
| `mlflow.evaluate()` + judges | Partial — quality proxy | None | Partial — automated quality tests | **Yes** — adds test category |
| `ConversationalSafety` judge (custom) | Partial | None | None | Partial |
| Production monitoring dashboard | Partial — fairness over time | None | **Yes** — monitoring/alerting | None |

### Verdict Per Section

**§7 MLSecOps/LLMSecOps** — MLflow helps with auditability and versioning, but does NOT close the section on its own. Autolog alone does not trace local tools or guardrails. The existing CI/CD doc contradicts the real workflows (a pre-existing problem MLflow cannot fix). Monitoring/alerting is already partially there (`metrics.py`, `08-infrastructure-setup.md`) — MLflow adds dashboards, not alerting infrastructure.

> **Codex addition:** "Reframing `06-cicd-pipeline.md` as LLMSecOps" is cosmetic. Renaming a diagram does not add AI security stages. The doc needs to be rewritten to match the actual workflows first, then extended with AI security stages.

**§8 Testing Summary** — `mlflow.evaluate()` adds a quality evaluation category. But the gold-set fixtures need transformation before they work as `mlflow.evaluate()` inputs — not a free drop-in.

**§5 Responsible AI** — MLflow monitoring dashboard provides quality metrics over time. But fairness is not a built-in metric here; you must define and log it. Does not write the IMDA alignment narrative.

**§6 Risk Register** — MLflow contributes nothing. Documentation task only.

> **Codex addition:** "MLflow + Giskard together address every rubric bullet in §7 and §8" is false. Tools do not create the report section, the rubric-aligned diagram, the deployment narrative, or proof that monitoring/alerting is actually wired into this repo.

---

## Integration Complexity

| Task | Effort Estimate |
|---|---|
| `mlflow.openai.autolog()` in runner.py | **~1 hour** |
| MLflow server in `docker-compose.infra.yml` | ~2 hours |
| `mlflow.evaluate()` CI step against gold-set fixtures | 4–6 hours |
| Prompt Registry migration (9 YAML configs) | 1–2 hours |
| Custom `Guidelines` judge for fairness | 2–3 hours |
| Full CI eval step with regression gate | 6–8 hours total |

---

## Alternative Tools Comparison

| Tool | §5 Responsible AI | §6 Risk Register | §7 MLSecOps | §8 Testing | Effort | Cost |
|---|---|---|---|---|---|---|
| **MLflow** | Medium (custom judges) | None | **High** (with work) | Medium | Low (1 line) | Free/OSS |
| **Giskard** | Low | None | **High** (adversarial) | **High** (injection tests, OWASP LLM Top 10) | Medium | Free/OSS |
| **Arize Phoenix** | Medium (50+ built-in metrics) | None | Medium | High | Medium | Free/OSS |
| **Evidently AI** | **High** (drift, fairness, bias) | None | Low | Medium | Medium | Free/OSS |
| **Weights & Biases Weave** | Medium | None | Medium | Medium | Low | Free tier |
| **LangSmith** | Low | None | Medium | Low | Medium (not LangChain) | Paid SaaS |

### Key Alternative: Giskard

Giskard is the only tool that directly closes the adversarial testing gap in §7/§8. It:
- Generates prompt injection payloads automatically
- Maps vulnerabilities to OWASP LLM Top 10
- Integrates with MLflow by writing test results into the tracking server
- Is fully open source (Apache 2.0)

**MLflow + Giskard** together address every rubric bullet in §7 and §8. Giskard integration: ~4–6 hours for an existing Python codebase.

---

## Recommended Implementation Path

### Tier 1 — Do regardless (~3 hours total, high grade ROI)
1. Add `mlflow.openai.autolog()` to `runner.py` — real, demo-able audit trail in 1 line
2. Write 3–5 pytest adversarial tests against `guardrails.py` and `sanitization.py` — closes the AI security test gap with zero new tooling
3. Reframe `docs/architecture/06-cicd-pipeline.md` as an LLMSecOps pipeline document, explicitly naming each CI stage by its AI security function

### Tier 2 — High value if time allows (~6 hours)
4. Add `mlflow.evaluate()` CI step against `tests/eval/` gold-set fixtures
5. Add MLflow server to `docker-compose.infra.yml` (dev/staging tracing)

### Tier 3 — Optional stretch (~4–6 hours)
6. Migrate agent YAML prompts to MLflow Prompt Registry
7. Add Giskard for automated LLM security test generation + MLflow result logging

---

## Honest Verdict

**MLflow alone will not materially improve the grade if documentation sections remain unwritten.** The critical deficiencies identified in `GAPS.md` are documentation failures — no compiled report, no IMDA mapping, no risk register table, no reflection sections. No tool fixes those.

**What MLflow can do:** add concrete, verifiable evidence to §7 (versioning, auditability) and §8 (LLM quality evaluation category). The `mlflow.openai.autolog()` one-liner is worth adding regardless — under 1 hour, and it provides a genuine claim in the report: *"We instrument every pipeline run with MLflow tracing, producing a timestamped trace of all 9 agent calls, tool invocations, and guardrail outcomes."*

**The adversarial security test gap is the hardest to close and MLflow does not close it.** Write pytest tests that send known injection payloads to `guardrails.py` and assert rejection — 2–3 hours, no new dependencies. Add Giskard if budget allows.

**Allocation guidance:** If 8 hours remain before submission, spend 6 hours writing the missing report sections (§5 IMDA mapping, §6 risk register, §9 reflection, individual reports) and 2 hours on the autolog line + 3 injection tests. That closes more grading gaps than 8 hours of MLflow integration.

---

## Sources

- [MLflow Agent & LLM Engineering](https://mlflow.org/genai)
- [MLflow OpenAI Agent Tracing](https://mlflow.org/docs/latest/genai/tracing/integrations/listing/openai-agent/)
- [MLflow LLM Judges and Scorers](https://mlflow.org/docs/latest/genai/eval-monitor/scorers/)
- [MLflow Prompt Registry](https://mlflow.org/docs/latest/genai/prompt-registry/)
- [MLflow Version Tracking](https://mlflow.org/docs/latest/genai/version-tracking/)
- [Giskard + MLflow integration](https://www.databricks.com/blog/evaluating-large-language-models-giskard-mlflow)
