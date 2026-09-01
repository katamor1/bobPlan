<!-- bob-contract: {"argument":"$1","validatesWorkPacket":true,"targetedContext":true,"stopOnMissingEvidence":true,"output":"team-bob-work/<Task>/drafts/impact-analysis.md"} -->
# /bob-analyze-impact $1

Accept `$1` as the work-packet path. Validate it before work and inspect only the targeted files, branch metadata, and requirement evidence named there. Write only `team-bob-work/<Task>/drafts/impact-analysis.md` using the template. Assess RT, safety, board, driver, ABI, build, and customer-branch impact. Stop without output when evidence is missing or an impact cannot be classified.
