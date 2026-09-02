# MSBUILD DEMO ADAPTER — NOT VC6 QUALIFICATION

## 証跡の読み方

このガイドは、ライブデモの期待成果物と、不在でなければならない情報を示します。live pathはStage後の`C:\BobTeamDemo`を基準とし、実際のTask ID／invocation IDに置き換えます。rehearsalは別root `C:\BobTeamDemo-Rehearsal`に保持し、live evidenceへ混在させません。MSBuild adapter evidenceはVC6資格証跡ではありません。

### 事前準備とqualification

| Evidence | 期待内容 | 不合格条件 |
| --- | --- | --- |
| Bob version record | executable path、ProductVersionが`*bob2.1.*`にmatch、記録時刻 | 2.0.x、path/hash不明 |
| Visual Studio preflight | `isComplete:true`、`isLaunchable:true`、v143、SDK 10.0.22621.0 | false、欠落、未記録 |
| Endpoint protection preflight | security ownerが組織の承認済み手順でadapterの実行可否とprobe前後のhashを確認 | 削除、隔離、置換、起動拒否、保護無効化、未承認除外 |
| Sandbox ownership preflight | demo root／sandboxを排他的に使用し、予期しない変更主体や同時書込みprocessがないことをsecurity ownerが確認 | shared writer、sync tool、検査後のpath／内容差替え可能性 |
| Demo root marker | このStageに固有のmarkerとroot identity | markerなし／不一致／unsafe path |
| Environment backup | backup path、hash、ACL確認。内容は表示しない | secret値のlog出力、ACL不明 |
| Raw qualification JSON | Unicode banner、help、MSBuild hash、Build、Rebuild、compiler failure、linker failure、artifact、invalid targetの各probe、およびcompiler入力6 hash | probe欠落、expected/observed exit不一致、入力hash／variant不一致 |
| Qualification record | Record ID、role approvals、`AcceptNotVc6=YES` | 個人承認、未署名、VC6合格表現 |
| Demo-only catalog | `demo-msbuild-protocol-v1-not-vc6`だけがreview後にenabled | Stage直後からenabled、本番catalog変更 |
| Initial Bazaar baseline | 人の`init`／対象確認／`add`／初期commit、branch-local demo identity、clean status、完全revision-id | Stage／Bob／packet scriptによるmutation、対象外file、dirty status |
| Root isolation | rehearsal restore／untrust後にliveを別Stage、rootごとに別marker／Record ID／revision／evidence | 同じroot、copy／再利用、rehearsalをlive成功として表示 |
| Bob permission／trust | `/permissions`の事前／事後記録、Read-only auto-approve、Edit／Executeのmanual approval、workspace単体のtrust／remove | 親trust、Edit／Execute auto-approve、demo folderのtrust残存 |
| Usage log | versioned template hashとStage copy `C:\BobTeamDemo\evidence\usage-log.csv` | template変更、別path、個人識別列／値 |

raw qualification driverはapprovalを行いません。また、単独起動せず、`Prepare-TeamBobDemo.ps1 -Stage`が管理する外側のqualification timeout内でだけ実行します。Visual Studioがincomplete／unlaunchable、endpoint protection／EDRがadapterを阻止した場合、またはtimeout／子process残留があった場合は`qualificationEligible:false`でなければなりません。直接実行したMSBuild logやfake adapter試験をraw adapter qualificationの代替にしません。人がraw evidenceをレビューした別invocationだけがdemo profileをenableできます。

固定policy token: `ENDPOINT PROTECTION BYPASS FORBIDDEN`。`DIRECT MSBUILD OR FAKE ADAPTER IS NOT RAW QUALIFICATION`。保護機能を無効化せず、未承認の除外や迂回を追加しません。

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

各sidecarには少なくともschema、Task ID、invocation、action、attempt、faultInjected、adapter hash、MSBuild hash、native exit、started/finished timestamp、statusに加え、観測した`cycleWatchSourceSha256`、`cycleWatchSourceVariant`、`cycleWatchHeaderSha256`、`cycleWatchTestsSha256`を含めます。source variantは`baseline-error`、`threshold3-error`、`threshold3-fixed`の許可済み状態だけです。build manifestとraw qualification JSONはheader baseline、tests baseline、linker-probe tests、source 3 variantの6つのSHA-256を固定し、配布元baselineと一致しなければなりません。source本文、credential、環境変数全体、個人identityを含めません。

Green evidenceには、各Editのdiff previewを人がAllowed Fileと照合した記録、および各Executeの絶対path／全引数を人が完全一致確認した記録を含めます。auto-approveはReadだけです。custom modeにcommand allowlistがないため、過去のapproval、prefix、pattern、永続permissionを安全境界として扱いません。

### Negative boundary evidence

Task 3のStageはOpen QA付きnegative packetをversioned workspace外の`C:\BobTeamDemo\evidence\negative-packets\`へ生成し、絶対pathとSHA-256を記録します。拒否試験専用のfreshな`green-implement` negative taskでその絶対pathを`/bob-implement-green`へ渡し、Bob自身がpacket validationによりEdit／Execute tool request前に停止した証跡が必要です。禁止拡張子、Allowed Files外、完全一致しないExecuteも同じ専用negative Green taskで、mode／rulesによりtool request前に拒否することが合格条件です。禁止tool requestが出た場合、人はmanual rejectして安全を確保しますが、結果は`FAIL`／即時`STOP`です。人のrejectやTest task／`test-draft` modeのpermission拒否をGreen境界の合格証拠にしません。

### 期待するsourceとBazaar差分

ライブ後の意図した変更は`demo/CycleWatch/src/CycleWatch.cpp`の次の2行だけです。機能変更はMake attempt 0の前、人工fault repairは実`error Cxxxx`のevidenceを確認した後だけ行います。

```diff
-    if (consecutiveOverruns_ >= 1U) {
+    if (consecutiveOverruns_ >= 3U) {
-#error MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT "demo/CycleWatch/src/CycleWatch.cpp" AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")
+#pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")
```

専用diagnostic blockのbegin/end marker、`.vcxproj`、`.dsp`、header、tests、Office inputs、`.bzr`（人の明示的commit前）、production `profile/`は変更しません。`#error`→`#pragma message`は人工training faultだけに対する修復で、`>= 1U`→`>= 3U`は要求に対する機能実装です。この二つの因果を入れ替えず、VC6の修正証拠にもしません。配布元sourceの`#error`は保持し、修復済み`#pragma message`は隔離demo workspaceだけに残します。

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
| PRE-001 | Preflight／permissions | | | `DEMO-TARGET-PC-OWNER-ROLE` | |
| REH-001 | Rehearsal root／restore／untrust | | | `DEMO-OPERATIONS-OWNER-ROLE` | |
| BZR-001 | Initial Bazaar baseline | | | `DEMO-OPERATIONS-OWNER-ROLE` | |
| QUAL-001 | Qualification | | | `DEMO-OPERATIONS-OWNER-ROLE` | |
| REQ-001 | Requirements | | | `DEMO-SPEC-APPROVER-ROLE` | |
| IMP-001 | Impact | | | `DEMO-IMPLEMENTATION-APPROVER-ROLE` | |
| BLD-001 | Green | | | `DEMO-IMPLEMENTATION-APPROVER-ROLE` | |
| REV-001 | Change Review | | | `DEMO-INDEPENDENT-REVIEWER-ROLE` | |
| TST-001 | Test | | | `DEMO-INDEPENDENT-REVIEWER-ROLE` | |
| NEG-001 | Fresh Green negative task | | | `DEMO-INDEPENDENT-REVIEWER-ROLE` | |
| USE-001 | External runtime usage log | | | `DEMO-OPERATIONS-OWNER-ROLE` | |

## 保持と不在確認

技術レビュー完了までrehearsal／live両rootのworkspace、sandboxes、logs、evidence、qualification record、runtime usage logを自動削除しません。restoreはBobローカル環境登録を戻す操作であり、証跡削除ではありません。runtime metricsはStageがversioned templateからcopyした各rootの`evidence\usage-log.csv`にだけ書き、versioned templateは開始前後で同一SHA-256にします。

次が証跡に含まれていないことも確認します。

- 実顧客名、production source、credential、secret、token、個人名／email／account。
- 実機、専用基板、control networkへの接続結果。
- debugger attach、breakpoint、step実行。
- BobによるBazaar write。
- VC6互換性、リアルタイム性能、専用基板動作を合格とする表現。
