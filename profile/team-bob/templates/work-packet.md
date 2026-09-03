# Work Packet

Commands and tools must parse the canonical JSON object below and validate it against the Bazaar-root-relative `team-bob/config/work-packet.schema.json`. The surrounding Markdown is explanatory only; the JSON object is the authoritative packet representation.

<!-- canonical-work-packet-json:start -->
```json
{
  "Profile Version": "0.2.0-poc",
  "Policy Version": "0.2.0-poc",
  "Policy Bundle SHA256": "0000000000000000000000000000000000000000000000000000000000000000",
  "Role Ledger SHA256": "0000000000000000000000000000000000000000000000000000000000000000",
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
  "Max-Repair-Cycles": 2,
  "Specification Assignment ID": "ASSIGN-SPEC-EXAMPLE",
  "Implementation Assignment ID": "ASSIGN-IMPL-EXAMPLE",
  "Independent Reviewer Assignment ID": "ASSIGN-REVIEW-EXAMPLE"
}
```
<!-- canonical-work-packet-json:end -->

Green requires Risk `Green`, an empty `Open QA` array, and YES for every `* Impact Clear` field and `Clean Working Copy`. Human authority is bound by the three role-ledger assignment IDs and separate immutable approval records.
