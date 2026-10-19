# {{FEATURE_NAME}}

## Purpose and scope

{{USER_VISIBLE_OUTCOME}}

In scope:

- {{IN_SCOPE_ITEM}}

Out of scope:

- {{NON_GOAL}}

## Sources

- Product decision: {{SOURCE}}
- Design: {{DESIGN_SOURCE_OR_NOT_ESTABLISHED}}
- API contract: {{API_SOURCE_OR_NOT_APPLICABLE}}
- Related code: `{{PATH_OR_SYMBOL}}`

## Significant decisions

### Decision: {{DECISION_TITLE}}

- **Decision:** {{DECISION}}
- **Rationale:** {{RATIONALE}}
- **Alternatives:** {{ALTERNATIVES}}
- **Evidence:** {{EVIDENCE}}
- **Revisit when:** {{REVISIT_CONDITION}}

Remove this section when the feature has no independent significant decision.

## Navigation and lifecycle

{{ENTRY_EXIT_OWNER_PRESENTATION_AND_RECOVERY}}

## Models and state

{{STATE_OWNER_TRANSITIONS_PERSISTENCE_AND_INVALIDATION}}

## API or external integrations

{{ENDPOINTS_PAYLOADS_ERRORS_AUTH_AND_TEMPORARY_BOUNDARIES}}

## UI contract

{{SCREENS_STATES_ACTIONS_DESIGN_SYSTEM_AND_ACCESSIBILITY}}

## Errors, loading, and cancellation

{{RETRY_IDEMPOTENCY_CANCELLATION_AND_USER_FEEDBACK}}

## Verification

| Layer | Establishes | Test or command | Residual risk |
| --- | --- | --- | --- |
| Unit or contract | {{BEHAVIOR}} | `{{TEST_NAME_OR_COMMAND}}` | {{RISK}} |
| UI or end-to-end | {{FLOW}} | `{{TEST_NAME_OR_COMMAND}}` | {{RISK}} |

## Open questions and constraints

- {{OPEN_QUESTION_OWNER_AND_BLOCKED_SCOPE}}
