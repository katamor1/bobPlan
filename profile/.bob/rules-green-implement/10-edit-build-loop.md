# Green Edit/Build Loop

Enter Green only when the canonical packet risk is Green, Open QA is empty, every RT/safety/board/driver/ABI/build/customer-branch impact-clear field is YES, and Clean Working Copy is YES. Both approvers and both YES approvals are required.

The mode regex allows legacy C/C++ source/header extensions and safe task results, but Work Packet Allowed Files is the controlling dynamic file boundary. `.rc`, `.dsp`, `.dsw`, `.def`, `.idl`, `.mak`, and every file outside Allowed Files are forbidden.

Perform edit, Make, no more than two evidence-based repair cycles, and a final Rebuild. Classify the outcome with the output-contract status. Stop on environment failure, timeout, integrity failure, missing evidence, or a non-retryable code failure. Never invoke Bazaar mutation commands, debugger actions, actual-machine/control-network access, mainline access, or secrets access.
