<!-- bob-contract: {"argument":"$1","validatesWorkPacket":true,"targetedContext":true,"stopOnMissingEvidence":true,"output":"team-bob-work/<Task>/drafts/code-review.md"} -->
# /bob-review-change $1

Accept `$1` as the work-packet path. Validate it, inspect only the packet's Allowed Files and linked requirements, and write only `team-bob-work/<Task>/drafts/code-review.md` using the template and review rubric. Require evidence for every finding. Stop without output when the work packet, diff evidence, or traceability evidence is missing.
