# Output Contracts

## Build Statuses

| Status | Meaning |
| --- | --- |
| SUCCEEDED | Final Rebuild and integrity checks passed. |
| CODE_FAILED_RETRYABLE | An evidence-based repair cycle remains. |
| CODE_FAILED_STOP | Code failure cannot be repaired autonomously. |
| ENVIRONMENT_FAILED | Local approved build environment failed. |
| TIMED_OUT | Approved build exceeded its timeout. |
| INTEGRITY_FAILED | Encoding, BOM, or line-ending integrity failed. |

`READY_FOR_HUMAN_REVIEW` is valid only after `SUCCEEDED`, final Rebuild success, and source-integrity verification. Usage records are task-level only and contain no person, operator, member, name, or email identifier.
