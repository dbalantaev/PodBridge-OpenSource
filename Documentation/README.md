# PodBridge documentation

This directory contains the project's durable technical contracts. [AGENTS.md](../AGENTS.md) holds the operating rules for contributors and agents. [AgentContext/ProjectKnowledge.md](AgentContext/ProjectKnowledge.md) is the technical map of the repository.

## Documents

| Document | Purpose |
| --- | --- |
| [../README.md](../README.md) | Public setup, support, safety, build guidance, and current product screenshots. |
| [../ARCHITECTURE.md](../ARCHITECTURE.md) | Source ownership, target boundary, operation map, and transactional write rules. |
| [AgentContext/ProjectKnowledge.md](AgentContext/ProjectKnowledge.md) | Architecture, integration boundaries, build commands, tests, and confirmed constraints. |
| [WritingGuide.md](WritingGuide.md) | Ownership, structure, and maintenance of Markdown documentation. |
| [Testing/BusinessScenarioCoverage.md](Testing/BusinessScenarioCoverage.md) | Scenario coverage, manual checks, and residual risk. |
| [Templates/FeatureContract.md](Templates/FeatureContract.md) | Template for an independent feature contract. |
| [Templates/DecisionRecord.md](Templates/DecisionRecord.md) | Template for a long-lived cross-cutting decision. |
| [Workflows/](Workflows/) | Reusable task planning, review, and completion-report templates. |
| [Screenshots/README/](Screenshots/README/) | Versioned screenshots referenced by the public README. |

Create a feature document only when a feature has a substantial independent contract: multiple screens or navigation states, dedicated API constraints, non-trivial lifecycle or persistence, security requirements, or an external system with material timing boundaries. Keep smaller changes in `ProjectKnowledge.md`.

When adding a feature document, add it to this index, summarize and link it from `ProjectKnowledge.md`, and update the scenario matrix when user flow coverage changes.
