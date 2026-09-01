<!-- bob-contract: {"argument":"$1","validatesWorkPacket":true,"targetedContext":true,"stopOnMissingEvidence":true,"output":"team-bob-work/<Task>/drafts/external-spec.md"} -->
# /bob-draft-spec $1

Accept `$1` as the work-packet path. Validate it before work, read only the packet's ReqIDs and linked ledger evidence, and write only `team-bob-work/<Task>/drafts/external-spec.md` using the template. Do not infer missing requirements. Stop without output when evidence, a baseline, or a required human approval is missing.
