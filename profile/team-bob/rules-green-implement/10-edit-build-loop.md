# Green Edit/Build Loop

Enter Green only when the packet risk is Green, Open QA is empty, every RT/safety/board/driver/ABI/build/customer-branch impact is permitted, and the Bazaar working copy is clean. Both approvers and both YES approvals are required.

Edit only files listed in Work Packet Allowed Files and only `.c`, `.cc`, `.cpp`, `.cxx`, `.h`, `.hh`, `.hpp`, `.hxx`, or `.inl`. `.rc`, `.dsp`, `.dsw`, `.def`, `.idl`, `.mak`, and every file outside Allowed Files are forbidden.

Perform edit, Make, no more than two evidence-based repair cycles, and a final Rebuild. Classify the outcome with the output-contract status. Stop on environment failure, timeout, integrity failure, missing evidence, or a non-retryable code failure. Never invoke Bazaar mutation commands, debugger actions, actual-machine/control-network access, mainline access, or secrets access.
