# Change review checklist

## Scope and diff

- [ ] The changes solve the requested task without unrelated refactoring.
- [ ] Existing user work is preserved.
- [ ] New files belong to the correct architectural layer.
- [ ] No generated files, build artifacts, screenshots, or credentials are included accidentally.

## Contracts

- [ ] Behavior is supported by a user decision, design, API contract, or existing implementation.
- [ ] Conflicting sources are resolved explicitly.
- [ ] Durable documentation changed with the contract.
- [ ] Significant decisions include rationale and a revisit condition.

## Code

- [ ] Formatter, linter, and compiler rules are followed.
- [ ] State ownership, dependency injection, navigation, and concurrency boundaries remain clear.
- [ ] Cancellation, retries, idempotency, and error mapping are considered where applicable.
- [ ] Code and logs do not include secrets, personal data, or sensitive payloads.

## Verification

- [ ] The narrowest relevant tests ran.
- [ ] The appropriate build or lint check ran.
- [ ] Risky user flows received UI, end-to-end, or manual validation, or the residual risk is stated.
- [ ] `git diff --check` passed.
- [ ] The report includes exact commands, outcomes, and skipped checks.
