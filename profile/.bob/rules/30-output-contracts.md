# Output Contracts

## Build Statuses

| Status | Meaning |
| --- | --- |
| SUCCEEDED | The requested Make or Rebuild action and its integrity checks passed. |
| CODE_FAILED_RETRYABLE | An evidence-based repair cycle remains. |
| CODE_FAILED_STOP | Code failure cannot be repaired autonomously. |
| ENVIRONMENT_FAILED | Local approved build environment failed. |
| TIMED_OUT | Approved build exceeded its timeout. |
| INTEGRITY_FAILED | Encoding, BOM, or line-ending integrity failed. |

Only a successful final Rebuild and source-integrity verification permit `READY_FOR_HUMAN_REVIEW`. A successful Make permits the paired Rebuild, not human review. Usage records are task-level only and contain no person, operator, member, name, or email identifier.
