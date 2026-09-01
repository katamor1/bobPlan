# Green Edit/Build Loop

Enter Green only when the canonical packet risk is Green, Open QA is empty, every RT/safety/board/driver/ABI/build/customer-branch impact-clear field is YES, and Clean Working Copy is YES. Both approvers and both YES approvals are required.

The mode regex allows legacy C/C++ source/header extensions and safe task results, but Work Packet Allowed Files is the controlling dynamic file boundary. `.rc`, `.dsp`, `.dsw`, `.def`, `.idl`, `.mak`, and every file outside Allowed Files are forbidden.

Perform edit, then run `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Make -Attempt 0`. Only `CODE_FAILED_RETRYABLE` permits a repair. After repair cycle 1, run `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Make -Attempt 1`; after repair cycle 2, run `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Make -Attempt 2`. There are three total Make attempts and no third repair. A `CODE_FAILED_RETRYABLE` at attempt 2 is handled as `CODE_FAILED_STOP`.

After any successful Make, run `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Rebuild -Attempt 2`. `SUCCEEDED` is the only status that may continue. `CODE_FAILED_RETRYABLE`, `CODE_FAILED_STOP`, `ENVIRONMENT_FAILED`, `TIMED_OUT`, and `INTEGRITY_FAILED` stop and preserve evidence. `READY_FOR_HUMAN_REVIEW` requires the successful final Rebuild and its integrity verification. Never invoke Bazaar mutation commands, debugger actions, actual-machine/control-network access, mainline access, or secrets access.
