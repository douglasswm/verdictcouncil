# AAS Project Presentation Guidelines

**Date:** Friday, 25 April 2026
**Time:** 4:00 PM SGT (UTC+8)

---

## 1. Introduction and Solution Overview

### 1.1 Project Objective and Scope
- Brief overview of what the project aims to solve
- Scope boundaries: what is and is not covered

### 1.2 Overall Solution Description
- High-level description of the multi-agent system
- Key value proposition

### 1.3 Agent Roles and Coordination
- List each agent and its role in one sentence
- How agents are orchestrated (centralized vs. peer-to-peer)

### 1.4 High-Level Workflow
- Diagram or narrative showing how agents interact end-to-end
- Entry point → processing pipeline → output

---

## 2. System Architecture

### 2.1 Logical Architecture
- Diagram of logical components and their relationships
- Description of each layer/component
- Justification for the chosen logical design

### 2.2 Physical Architecture
- Infrastructure diagram (cloud services, containers, networking)
- Deployment topology (where each component runs)
- Justification for infrastructure choices (cost, scalability, reliability)

### 2.3 Tech Stack
| Layer | Technology | Rationale |
|-------|------------|-----------|
| LLM / AI | | |
| Backend | | |
| Frontend | | |
| Messaging / Broker | | |
| Storage | | |
| Orchestration | | |
| Monitoring | | |

---

## 3. Agent Design

For each key agent, cover the following sections:

### 3.x \<Agent Name\>

#### Purpose and Responsibilities
- What the agent is responsible for
- Role in the overall system (no overlap with other agents)

#### Input and Output
| | Description | Format/Schema |
|-|-------------|---------------|
| **Input** | | |
| **Output** | | |

#### Planning / Reasoning Approach
- Model name used
- How the agent makes decisions (rules-based, LLM reasoning, hybrid)
- Prompting strategy or decision logic

#### Memory
- Does the agent use memory? Yes / No
- Type: Short-term (in-context) / Long-term (persisted)
- How memory is used in decision-making

#### Tools Used
- List of tools, APIs, or external services the agent calls
- Purpose of each tool

#### Interaction with Other Agents
- Receives input from: \<Agent(s)\>
- Sends output to: \<Agent(s)\>
- Position in the workflow

---

## 4. Explainable and Responsible AI Practices

### 4.1 Development and Deployment Alignment
- How each stage (design, training/prompting, deployment, monitoring) aligns with responsible AI principles

### 4.2 Fairness and Bias Mitigation
- Identified bias risks in the system
- Mitigation strategies applied (e.g., diverse test sets, prompt guardrails)

### 4.3 Explainability
- How the system surfaces reasoning to end users or operators
- Logging and audit trail mechanisms

### 4.4 Governance Framework Alignment
- Alignment with IMDA's Model AI Governance Framework
- Specific principles addressed: Accountability, Human Oversight, Operations Management, Stakeholder Interaction

---

## 5. AI Security Risk Register

| # | Risk | Category | Likelihood | Impact | Mitigation Strategy | Control Owner |
|---|------|----------|------------|--------|---------------------|---------------|
| 1 | Prompt Injection | Input Integrity | | | | |
| 2 | Data Exfiltration | Confidentiality | | | | |
| 3 | Model Hallucination | Reliability | | | | |
| 4 | Adversarial Inputs | Robustness | | | | |
| 5 | Insecure Tool Use | Authorization | | | | |

> Add rows for any additional risks identified during the project.

---

## 6. Application Demo

### Demo Script
1. Show the entry point (user interaction or trigger)
2. Walk through a representative end-to-end scenario
3. Highlight agent handoffs visible in the UI or logs
4. Show output / result delivered to the user

### Demo Checklist
- [ ] Demo environment is stable and pre-warmed
- [ ] Test data / scenario is prepared
- [ ] Fallback screenshots/recording ready in case of live failure

---

## 7. MLSecOps / LLMSecOps Pipeline and Demo

### 7.1 CI/CD Pipeline Diagram
- Source control → Build → Test → Security scan → Deploy → Monitor
- Tools used at each stage (e.g., GitHub Actions, Trivy, SAST, DAST)

### 7.2 Pipeline Demo
- Show a pipeline run end-to-end (or recording)
- Highlight security gates that block vulnerable builds
- Show monitoring / alerting in action

---

## 8. Evaluation and Testing Summary

### 8.1 Test Types and Results

| Test Type | Scope | Tool/Method | Pass Rate / Result |
|-----------|-------|-------------|-------------------|
| Unit | Individual agent functions | | |
| Integration | Agent-to-agent communication | | |
| End-to-End | Full workflow | | |
| Security | Prompt injection, auth | | |
| Performance / Load | Throughput, latency | | |

### 8.2 Evaluation Results
- Key metrics tracked (accuracy, latency, cost, safety)
- Benchmark comparisons (baseline vs. system)
- Known limitations and outstanding issues

---

## Presentation Notes

- **Timing target:** ~45–60 minutes total including Q&A
- Each section should have a designated speaker
- Diagrams should be legible at presentation resolution
- All demos must be tested on the presentation machine beforehand
