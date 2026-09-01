<!-- bob-contract: {"argument":"$1","validatesWorkPacket":true,"targetedContext":true,"stopOnMissingEvidence":true,"output":"team-bob-work/<Task>/drafts/requirement-ledger.csv"} -->
# /bob-normalize-requirements $1

Accept `$1` as the work-packet path. Validate it against the installed work-packet schema, including immutable Word, QA, and specification baselines. Read only targeted source evidence identified by the packet. Write only `team-bob-work/<Task>/drafts/requirement-ledger.csv` using the template. Preserve stable ReqIDs and immutable source anchors. Stop without output when evidence, a baseline, or a required human approval is missing.
