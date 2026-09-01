<!-- bob-contract: {"buildStatuses":["SUCCEEDED","CODE_FAILED_RETRYABLE","CODE_FAILED_STOP","ENVIRONMENT_FAILED","TIMED_OUT","INTEGRITY_FAILED"]} -->
# Output Contracts

Build outcomes use exactly one of these statuses:

- `SUCCEEDED`
- `CODE_FAILED_RETRYABLE`
- `CODE_FAILED_STOP`
- `ENVIRONMENT_FAILED`
- `TIMED_OUT`
- `INTEGRITY_FAILED`

`READY_FOR_HUMAN_REVIEW` is valid only after `SUCCEEDED`, final Rebuild success, and source-integrity verification. Usage records are task-level only and contain no person, operator, member, name, or email identifier.
