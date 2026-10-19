# Documentation writing guide

## Purpose

Documentation is durable shared memory for maintainers and agents. It records confirmed contracts, constraints, decisions, and verifiable operating procedures. It does not replace code, tests, Git history, issue tracking, or local task state.

## Information ownership

Each durable fact has one authoritative home:

- `AGENTS.md` owns contributor workflow and enduring operational constraints.
- `Documentation/AgentContext/ProjectKnowledge.md` owns the repository map, architecture, tooling, integrations, and confirmed current state.
- A feature contract owns a substantial product, API, navigation, lifecycle, or persistence contract.
- `Documentation/Testing/BusinessScenarioCoverage.md` owns scenario coverage and residual risk.
- Local task state records only the current checkpoint of a long task.
- Code and tests own executable behavior.

Do not duplicate a contract. Other documents should contain a short summary and a repository-relative link to the authoritative location.

## Writing rules

Start with purpose and scope. Put critical constraints and non-goals before implementation detail. Use stable, descriptive headings. Use tables for repeated mappings and lists for independent rules. Put commands in fenced blocks and report success only after the command has run.

Use `path:Symbol` or `path:line` for code references and a path plus exact heading for contract references. Do not paste large logs, diffs, reasoning traces, credentials, personal data, or facts that a reader can recover directly from one source file.

Use **Not established** when an inspected source has no answer. Use **Needs decision** when the product or system owner must decide. Do not present an observation as a general rule without evidence.

## Significant decisions

Record the decision, rationale, material alternatives, evidence, and a condition for revisiting it. Create a separate decision record only when the decision crosses several feature contracts or has an independent long-term lifecycle.

## Maintenance

Update documentation in the same task as code that changes its durable contract. After editing, check links, resolve contradictions, and run `git diff --check`. Record test results with the exact command, date, and the scope they actually verify.
