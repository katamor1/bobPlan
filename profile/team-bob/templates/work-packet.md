# Work Packet

Commands and tools must parse the canonical JSON object below and validate it against `../config/work-packet.schema.json`. The surrounding Markdown is explanatory only; the JSON object is the authoritative packet representation.

<!-- canonical-work-packet-json:start -->
```json
{
  "Profile Version": "0.1.0-poc",
  "Task ID": "EXAMPLE-0001",
  "Difficulty": "Example",
  "Risk": "Amber",
  "Customer": "Example Customer",
  "ReqIDs": ["REQ-EXAMPLE-001"],
  "Word Baseline": "word-baseline-001",
  "QA Baseline": "qa-baseline-001",
  "Spec Baseline": "spec-baseline-001",
  "Bazaar Root": "relative/bazaar/root",
  "Bazaar Branch": "example-branch",
  "Bazaar Full Revision ID": "example-revision-id",
  "Allowed Files": ["src/example.cpp"],
  "Forbidden Areas": ["actual-machine", "control-network", "mainline", "secrets"],
  "RT Impact": "No assessed RT impact.",
  "Safety Impact": "No assessed safety impact.",
  "Board Impact": "No assessed board impact.",
  "Driver Impact": "No assessed driver impact.",
  "ABI Impact": "No assessed ABI impact.",
  "Build Impact": "No assessed build impact.",
  "Customer Branch Impact": "No assessed customer-branch impact.",
  "RT Impact Clear": "NO",
  "Safety Impact Clear": "NO",
  "Board Impact Clear": "NO",
  "Driver Impact Clear": "NO",
  "ABI Impact Clear": "NO",
  "Build Impact Clear": "NO",
  "Customer Branch Impact Clear": "NO",
  "Clean Working Copy": "NO",
  "Open QA": ["QA-EXAMPLE-001"],
  "Build Profile ID": "example-local-vc6",
  "Autonomous-Edit-Build-Approved": "YES",
  "Soft-Execute-Risk-Accepted": "YES",
  "Max-Repair-Cycles": 2,
  "Specification Approver": "Example Specification Approver",
  "Implementation Approver": "Example Implementation Approver"
}
```
<!-- canonical-work-packet-json:end -->

Green requires Risk `Green`, an empty `Open QA` array, YES for every `* Impact Clear` field and `Clean Working Copy`, plus both approvals and both explicit YES acceptances. Amber and Red packets may retain Open QA while awaiting human disposition.
