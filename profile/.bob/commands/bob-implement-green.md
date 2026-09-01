<!-- bob-contract: {"argument":"$1","validatesWorkPacket":true,"targetedContext":true,"stopOnMissingEvidence":true,"output":"team-bob-work/<Task>/results/build-result.md","workflow":["edit","Make","repair","final-Rebuild"],"maxRepairCycles":2,"readyAfter":"final-rebuild-success-and-integrity"} -->
# /bob-implement-green $1

Accept `$1` as the work-packet path. Validate it and proceed only when the packet is Green, Open QA is empty, all impacts are permitted, the working copy is clean, and both `Autonomous-Edit-Build-Approved: YES` and `Soft-Execute-Risk-Accepted: YES` are present. Read only targeted context.

Edit only C/C++ source or header files in Work Packet Allowed Files with extensions `.c`, `.cc`, `.cpp`, `.cxx`, `.h`, `.hh`, `.hpp`, `.hxx`, or `.inl`; never edit `.rc`, `.dsp`, `.dsw`, `.def`, `.idl`, `.mak`, or any other file. Preserve CP932, no BOM, and CRLF. Do not attach a debugger or execute breakpoints or steps.

Own exactly this loop: edit, Make, at most two evidence-based repairs, then final Rebuild. Write only allowed source/header edits and `team-bob-work/<Task>/results/build-result.md`. Never run Bazaar mutation commands, never commit/merge/tag, and never access actual machines, control networks, mainline, or secrets. Emit `READY_FOR_HUMAN_REVIEW` only after final Rebuild succeeds and integrity passes. Stop on missing evidence, an environment failure, a timeout, a forbidden impact, or an integrity failure.
