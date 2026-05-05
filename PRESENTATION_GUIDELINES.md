# AAS Presentation Guideline

1. **Introduction and solution overview**
   - Brief overview of project objective and scope
   - Brief description of overall solution
   - Agent roles and coordination
   - High-level workflow showing how agents interact

2. **System Architecture**
   - Logical architecture diagram with description, and justification
   - Physical architecture diagram with infrastructure details, and justification
   - Tech stack

3. **Agent Design**

   For **key** agents:

   - Purpose and responsibilities: clearly define what the agent is responsible for and what role it plays in the overall system (no overlap with other agents).
   - Input and output: specify what the agent receives and what it produces
   - Planning / reasoning approach: Model name, explain how the agent makes decisions (e.g., rules, LLM reasoning)
   - Memory (if applicable): whether the agent uses memory, what type (short-term/long-term), and how it is used.
   - Tools used: identify the tools/APIs the agent uses
   - Interaction with other agents: explain how the agent fits into the workflow, including which agents it receives input from and sends output to.

4. **Explainable and Responsible AI Practices**
   - How the different stages of development & deployment are aligned with the explainable and responsible AI principles.
   - Approach to fairness, bias mitigation, explainability
   - Governance framework alignment (e.g., IMDA's Model AI Governance Framework)

5. **AI Security Risk Register**
   - Table of identified risks (e.g., prompt injection)
   - Mitigation strategies and security controls

6. **Application demo**

7. **MLSecOps / LLMSecOps Pipeline and demo**
   - CICD pipeline diagram
   - Demo

8. **Evaluation and Testing Summary**
   - Types of tests performed (unit, integration, security etc) and results
   - Evaluation results