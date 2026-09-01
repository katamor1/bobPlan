# Green Edit/Build Loop

Enter Green only when the canonical packet risk is Green, Open QA is empty, every RT/safety/board/driver/ABI/build/customer-branch impact-clear field is YES, and Clean Working Copy is YES. Both approvers and both YES approvals are required. The Green custom mode is shipped with soft governance; do not select or auto-approve it until the requested build profile is human-qualified, enabled, and PC-matched. The shipped build catalog is empty and disabled.

The mode regex allows legacy C/C++ source/header extensions and safe task results, but Work Packet Allowed Files is the controlling dynamic file boundary. `.rc`, `.dsp`, `.dsw`, `.def`, `.idl`, `.mak`, and every file outside Allowed Files are forbidden.

Set the shared repair budget `N = 0`. Run Make N using:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$1" -Action Make -Attempt N
```

On Make `SUCCEEDED`, run Rebuild with the same N using:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$1" -Action Rebuild -Attempt N
```

Make and Rebuild share one repair budget. If Make or Rebuild returns `CODE_FAILED_RETRYABLE` and `N < 2`, inspect that invocation's evidence, perform one permitted evidence-based repair, increment N, and return to Make N. Rebuild `CODE_FAILED_RETRYABLE` therefore returns to Make N; never retry Rebuild directly. At `N = 2`, a retryable result is handled as `CODE_FAILED_STOP`; no third repair occurs. `CODE_FAILED_STOP`, `ENVIRONMENT_FAILED`, `TIMED_OUT`, and `INTEGRITY_FAILED` stop immediately and preserve evidence.

Only a successful final Rebuild and its integrity verification permit `READY_FOR_HUMAN_REVIEW`; a successful Make alone does not. Never invoke Bazaar mutation commands, debugger actions, actual-machine/control-network access, mainline access, or secrets access.
