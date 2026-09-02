# MSBUILD DEMO ADAPTER — NOT VC6 QUALIFICATION

## Record identity

このtemplateは、demo adapterのraw protocol evidenceを人がレビューした事実を記録します。VC6資格記録ではありません。approval欄には個人名ではなく固定roleだけを使用します。

| Field | Value |
| --- | --- |
| Record ID | |
| Recorded at (timezone付き) | |
| Root purpose (`REHEARSAL` / `LIVE`) | |
| Demo root | `C:\BobTeamDemo-Rehearsal` または `C:\BobTeamDemo` |
| Distribution revision | |
| Bob executable ProductVersion | |
| Bob executable SHA-256 | |
| Visual Studio instance ID | |
| Visual Studio `isComplete` | |
| Visual Studio `isLaunchable` | |
| PlatformToolset | `v143` |
| Windows SDK | `10.0.22621.0` |
| MSBuild absolute path | |
| MSBuild SHA-256 | |
| Adapter SHA-256 | |
| DSP token SHA-256 | |
| VCXPROJ SHA-256 | |
| CycleWatch header baseline SHA-256 | |
| CycleWatch tests baseline SHA-256 | |
| CycleWatch linker-probe tests SHA-256 | |
| CycleWatch source `baseline-error` SHA-256 | |
| CycleWatch source `threshold3-error` SHA-256 | |
| CycleWatch source `threshold3-fixed` SHA-256 | |
| Raw evidence relative path | |
| Raw evidence SHA-256 | |
| `qualificationEligible` | `false` |
| Demo profile ID | `demo-msbuild-protocol-v1-not-vc6` |
| Initial Bazaar full revision-id (人のbootstrap後) | |
| Initial Bazaar clean status evidence SHA-256 | |
| `/permissions` pre-state evidence SHA-256 | |
| Versioned usage template SHA-256 | |
| External runtime usage copy relative path／SHA-256 | `evidence/usage-log.csv` / |
| External Open QA negative packet relative path／SHA-256 | `evidence/negative-packets/...` / |

`qualificationEligible`は、全probe合格に加えてVisual Studioがcompleteかつlaunchableの場合だけ`true`へ変更できます。templateの初期値`false`を証拠なしで変更しません。rehearsalとliveは別Record ID、別root、別marker、別revision、別evidenceを持ち、一方のrecordを他方へコピーしません。

## Required probe review

| Probe ID | Class | Expected | Observed exit／result | Log／sidecar／artifact SHA-256 | PASS／FAIL |
| --- | --- | --- | --- | --- | --- |
| Q-HELP | Adapter help | bannerと固定usage、MSBuild未起動 | | | |
| Q-HASH | MSBuild identity | baked SHA-256一致 | | | |
| Q-BUILD | Normal Make | exit 0、artifact存在 | | | |
| Q-REBUILD | Normal Rebuild | exit 0、fresh artifact存在 | | | |
| Q-COMPILER | Real compiler failure | attempt 0 Make、`error Cxxxx`、exit 1 | | | |
| Q-LINKER | Real linker failure | retained sandboxだけを変更、`LNKxxxx`、exit 1 | | | |
| Q-ARTIFACT | Artifact integrity | exact relative pathとSHA-256 | | | |
| Q-INVALID | Invalid target／input | exit 20、MSBuild未起動 | | | |

linker probeはretained sandbox copyの`CycleWatchTests.cpp`だけを、上表の固定linker-probe hashとなる既知variantへ変更し、配布元／workspaceを変更してはいけません。各probe sidecarの観測source variant／hash、header hash、tests hashは上表の許可済み値と一致させます。全probeは`Prepare-TeamBobDemo.ps1 -Stage`の外側timeout内でローカルfixed drive上だけで実行し、raw driverを単独起動せず、network、Bazaar、実機、基板、driver、shellを呼び出しません。

## Immutability review

- [ ] 配布元はprobe前後で同一hashである。
- [ ] production `profile/`はprobe前後で同一hashである。
- [ ] production `vc6-build-targets.json`は空である。
- [ ] production exampleは`enabled:false`である。
- [ ] `.bzr`はprobeで変更されていない。
- [ ] source workspaceのAllowed Fileはprobeで変更されていない。
- [ ] build manifest、raw evidence、上表のcompiler入力6 hashが一致し、配布元のheader／tests／source baselineも一致する。
- [ ] 各sidecarのsource variant／hash、header hash、tests hashがそのprobeで許可された値だけである。
- [ ] versioned `demo/docs/usage-log.csv`はStage前後で同一hashである。
- [ ] runtime usage logとnegative packetはversioned workspace外の現在rootの`evidence`配下にある。
- [ ] endpoint protection／EDRはadapterを削除、隔離、置換、起動拒否しておらず、probe前後のadapter SHA-256がmanifestと一致する。
- [ ] qualificationのために保護機能を無効化せず、未承認の除外または迂回を追加していない。
- [ ] demo root／sandboxはoperator管理下で排他的に使用され、予期しない変更主体、sync tool、同時書込みprocessがないことをsecurity ownerが確認した。
- [ ] logs／evidenceにsecret、credential、個人identityがない。
- [ ] 全user-visible evidenceにNOT VC6表示がある。

## Approval後のhuman-only Bazaar bootstrap

- [ ] Stage／qualificationは`.bzr`を作成・変更していない。
- [ ] `DEMO-OPERATIONS-OWNER-ROLE`が固定demo identityをbranch-localに設定した。
- [ ] 人が`bzr init`を実行した。
- [ ] 人が合成data、profile、ignore設定だけを確認して`bzr add`した。
- [ ] logs、evidence、backup、secret、実顧客dataをaddしていない。
- [ ] 人がinitial baseline commitを実行した。
- [ ] commit後の`bzr status --short`が空である。
- [ ] 完全なrevision-idとevidence SHA-256を上表へ記録した。
- [ ] Bobとpacket scriptにはBazaar writeを許可していない。

## Permission、trust、root isolation follow-up

- [ ] Stage前に`/permissions`でauto-approveとtrustの事前状態を記録した。
- [ ] auto-approveはReadだけで、Edit／Executeは各actionを毎回manual approvalした。
- [ ] rehearsalは`C:\BobTeamDemo-Rehearsal`だけ、liveは`C:\BobTeamDemo`だけを使用した。
- [ ] rehearsal workspaceをclose／untrust／removeし、restoreを完了してからliveをStageした。
- [ ] 親demo root、drive root、配布元をtrustしていない。
- [ ] rehearsal／liveのcatalog、packet、revision、Record ID、evidenceを相互再利用していない。
- [ ] 終了時に`/permissions`で両demo folderをuntrust／removeし、事前設定へ復元した。
- [ ] rehearsal／live両rootのworkspace、logs、evidenceを技術reviewまで保持した。
- [ ] negative拒否試験はfresh `green-implement` taskとexternal Open QA packet絶対pathで行い、Bob自身が全禁止caseをtool request前に拒否した。manual rejectやTest mode拒否をGreen境界の合格根拠にしていない。

## Human gate

次のすべてが`YES`の場合だけ、別の`-ApproveQualification -RecordId <ID> -AcceptNotVc6` invocationを許可します。

| Gate | Value |
| --- | --- |
| All required probes reviewed and PASS | `NO` |
| MSBuild／adapter／project hashes match | `NO` |
| VS complete and launchable | `NO` |
| Source／profile／Bazaar immutability confirmed | `NO` |
| Evidence contains no restricted data | `NO` |
| Root-specific Record ID／marker／evidence confirmed | `NO` |
| Read-only auto-approve／manual Edit and Execute confirmed | `NO` |
| `AcceptNotVc6` | `NO` |
| Target PC review role | `DEMO-TARGET-PC-OWNER-ROLE` |
| Operations approval role | `DEMO-OPERATIONS-OWNER-ROLE` |
| Disposition (`APPROVE_DEMO_ONLY` / `REJECT`) | `REJECT` |

`APPROVE_DEMO_ONLY`は、合成workspaceでadapter protocolを使う許可だけです。VC6、リアルタイム性能、実機、専用基板、driver、ABIの資格・合格を意味しません。
