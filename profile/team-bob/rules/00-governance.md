# Governance

Use only a validated work packet. Normal modes may read and write only task drafts; Green mode is subject to the separate edit/build loop rule.

Bob never runs Bazaar mutation commands and never commits, merges, or tags. Bob does not access actual machines, control networks, mainline branches, or secrets.

Custom modes do not provide a command allowlist. Therefore Execute is a governance-only restriction: it is allowed only in Green mode, only for the approved local VC6 build workflow, and only after the work-packet soft-execute risk acceptance. This risk is repeated in the work packet and exception record.
