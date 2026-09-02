# MSBUILD DEMO ADAPTER — NOT VC6 QUALIFICATION

## 証跡の読み方

このガイドは、ライブデモの期待成果物と、不在でなければならない情報を示します。pathはStage後の`C:\BobTeamDemo`を基準とし、実際のTask ID／invocation IDに置き換えます。MSBuild adapter evidenceはVC6資格証跡ではありません。

### 事前準備とqualification

| Evidence | 期待内容 | 不合格条件 |
| --- | --- | --- |
| Bob version record | executable path、ProductVersionが`*bob2.1.*`にmatch、記録時刻 | 2.0.x、path/hash不明 |
| Visual Studio preflight | `isComplete:true`、`isLaunchable:true`、v143、SDK 10.0.22621.0 | false、欠落、未記録 |
| Demo root marker | このStageに固有のmarkerとroot identity | markerなし／不一致／unsafe path |
| Environment backup | backup path、hash、ACL確認。内容は表示しない | secret値のlog出力、ACL不明 |
| Raw qualification JSON | Unicode banner、help、MSBuild hash、Build、Rebuild、compiler failure、linker failure、artifact、invalid targetの各probe | probe欠落、expected/observed exit不一致 |
| Qualification record | Record ID、role approvals、`AcceptNotVc6=YES` | 個人承認、未署名、VC6合格表現 |
| Demo-only catalog | `demo-msbuild-protocol-v1-not-vc6`だけがreview後にenabled | Stage直後からenabled、本番catalog変更 |
| Initial Bazaar baseline | 人の`init`／対象確認／`add`／初期commit、branch-local demo identity、clean status、完全revision-id | Stage／Bob／packet scriptによるmutation、対象外file、dirty status |

raw qualification driverはapprovalを行いません。Visual Studioがincomplete／unlaunchableなら`qualificationEligible:false`でなければなりません。人がraw evidenceをレビューした別invocationだけがdemo profileをenableできます。

### Phase chain

| Phase | Packet／成果物 | 必須内容 |
| --- | --- | --- |
| Requirements | `team-bob-work/<Task>/work-packet.md`、`drafts/requirement-ledger.csv`、`drafts/external-spec.md` | role approver、Word段落とExcel sheet/cell anchor、stable ReqID、Customer-A、threshold／consecutive／recovery／warm-up criteria |
| Impact | 新しいpacket、`drafts/impact-analysis.md` | Requirements成果物SHA-256、Open QA空、RT／Safety／Board／Driver／ABI／Build／Customer Branchを個別判定 |
| Green | 新しいpacket、`results/build-result.md`、timestamped machine result JSON | Risk Green、clean、Allowed File一件、demo profile、両role、両YES、Max Repair 2 |
| Change Review | `drafts/code-review.md`、Bazaar status/diff/nick/revision evidence | final diff、人工fault disclosure、Allowed Files、final Rebuild／integrityへの参照 |
| Test | 人のdemo commit後の新しいpacket、`drafts/test-spec.md` | prior SHA-256とrevision、実装taskから独立、境界／連続／復帰／warm-up／customer tests |

phaseをまたぐ成果物は、ファイル名だけでなくSHA-256で固定します。hash mismatch、存在しないbaseline、欠落したapprovalをBobが補完してはいけません。

### Adapterとbuild loop

外部log rootの各invocationに、CP932／BOMなし／CRLFの`build.log`と、UTF-8／BOMなしの`build.log.evidence.json`が対応します。

| Invocation | 期待status／exit | 必須evidence |
| --- | --- | --- |
| Make attempt 0 | wrapper=`CODE_FAILED_RETRYABLE`／10、native adapter=compiler failure／1 | ASCII fallback banner、`error Cxxxx`、`faultInjected=true`、Allowed File diagnostic block |
| Make attempt 1 | `SUCCEEDED`／0 | `faultInjected=false`、fixed Release／Win32、exact artifact hash |
| Rebuild attempt 1 | `SUCCEEDED`／0 | `faultInjected=false`、Rebuild action、fresh artifact、integrity success |
| Final gate | `READY_FOR_HUMAN_REVIEW` | final Rebuild successとsource integrityの両方への参照 |

CP932 logではem dashを表現できないため、`MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION`が正しいfallbackです。JSON sidecarではexact Unicode banner `MSBUILD DEMO ADAPTER — NOT VC6 QUALIFICATION`が必要です。

各sidecarには少なくともschema、Task ID、invocation、action、attempt、faultInjected、adapter hash、MSBuild hash、native exit、started/finished timestamp、statusを含めます。source本文、credential、環境変数全体、個人identityを含めません。

### 期待するsourceとBazaar差分

ライブ後の意図した変更は`demo/CycleWatch/src/CycleWatch.cpp`の次の一行だけです。

```diff
-    if (consecutiveOverruns_ >= 1U) {
+    if (consecutiveOverruns_ >= 3U) {
```

専用diagnostic block、`.vcxproj`、`.dsp`、header、tests、Office inputs、`.bzr`（人の明示的commit前）、production `profile/`は変更しません。adapterのcompiler failureは人工training faultであり、上記semantic diffがcompiler errorそのものを修正したという因果を主張しません。

Bazaar evidenceは少なくともstatus、diff、branch nick、完全revision-idを含みます。Stage／qualification approval後かつ最初のpacket前に、人がbranch-local demo identityで合成baselineを`init`、対象確認、`add`、初期commitし、clean statusと完全revision-idを固定します。read-only export後、独立reviewに合格した場合だけ、人が同じdemo identityで実装変更を別commitします。Stage、Bob、qualification、packet scriptがBazaarを変更した証跡、またはBobがcommit、merge、tagを実行した証跡があれば即時不合格です。

### Test specificationの期待case

| Case | Input | Expected |
| --- | --- | --- |
| Threshold below | Customer-A、post-warm-up、7,999 us | Normal、counter reset |
| Threshold equal 1／2 | Customer-A、8,000 usを1回／2回 | Normal |
| Third consecutive | Customer-A、8,000 us以上を3回連続 | 3回目でWarning |
| Immediate recovery | Warning後に7,999 us | 直ちにNormal、counter reset |
| Warm-up suppression | warm-up中に8,000 us以上 | Normal、counter reset |
| Warm-up reset boundary | post-warm-up overrun 2回、warm-up、再度overrun | warm-up前のcountを引き継がない |
| Customer scope | Customer-A以外でoverrun | Normal、Customer-A countへ混入しない |
| Non-functional boundary | board／driver／ABI／control period | 変更なし |

合成executableの結果は専用基板やリアルタイム制約の合格を意味しません。

## Evidence index template

技術レビュー時は次のindexをコピーし、相対pathとSHA-256だけを記録します。secret値や個人名を記録しません。

| Evidence ID | Phase | Relative path | SHA-256 | Reviewer role | Disposition |
| --- | --- | --- | --- | --- | --- |
| PRE-001 | Preflight | | | `DEMO-TARGET-PC-OWNER-ROLE` | |
| BZR-001 | Initial Bazaar baseline | | | `DEMO-OPERATIONS-OWNER-ROLE` | |
| QUAL-001 | Qualification | | | `DEMO-OPERATIONS-OWNER-ROLE` | |
| REQ-001 | Requirements | | | `DEMO-SPEC-APPROVER-ROLE` | |
| IMP-001 | Impact | | | `DEMO-IMPLEMENTATION-APPROVER-ROLE` | |
| BLD-001 | Green | | | `DEMO-IMPLEMENTATION-APPROVER-ROLE` | |
| REV-001 | Change Review | | | `DEMO-INDEPENDENT-REVIEWER-ROLE` | |
| TST-001 | Test | | | `DEMO-INDEPENDENT-REVIEWER-ROLE` | |

## 保持と不在確認

技術レビュー完了までworkspace、sandboxes、logs、evidence、qualification record、usage logを自動削除しません。restoreはBobローカル環境登録を戻す操作であり、証跡削除ではありません。

次が証跡に含まれていないことも確認します。

- 実顧客名、production source、credential、secret、token、個人名／email／account。
- 実機、専用基板、control networkへの接続結果。
- debugger attach、breakpoint、step実行。
- BobによるBazaar write。
- VC6互換性、リアルタイム性能、専用基板動作を合格とする表現。
