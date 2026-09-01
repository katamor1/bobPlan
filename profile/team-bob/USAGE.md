# Team Bob 運用手順（v0.1.0-poc）

## 適用範囲、権限、パス

この profile は Windows、IBM Bob IDE 2.1.x、Visual C++ 6.0、Bazaar 2.5.1 の限定 PoC です。Bob Shell 1.0.1 は対象外です。Bob は commit、merge、tag をせず、actual machine、control network、mainline、secrets へ接続しません。Word/Excel baseline は immutable であり、人が stable ReqID、source anchor、acceptance criteria を持つ requirement ledger を承認します。

`<Bazaar-root>` は `.bzr` を直下にもつ専用・clean Bazaar working copy の絶対パスです。日常運用は次の current-directory convention を使い、配布 source の `profile\team-bob` ではなく、installed `<Bazaar-root>\team-bob\tools` のみを実行します。

JSON、JSON 形式の YAML、canonical work packet、environment registration、config、template はすべて strict UTF-8 **without BOM** とし、production writer も BOM を付けません。Windows PowerShell 5.1 の既定 ANSI reader は使いません。legacy source と VC6 `/OUT` log の CP932/no-BOM/CRLF contract は別途維持します。

```powershell
Set-Location "<Bazaar-root>"
```

normal modes は draft artifact 用の constrained Edit group を持ちますが、auto-approved なのは Read だけです。Edit は human approval が必要です。Green custom mode は技術的に ship/present され、soft rules を持ちます。ただし qualified、enabled、PC-matched build profile が存在するまで Green を選択または auto-approve してはいけません。空で disabled なのは Green mode ではなく build catalog です。custom modes に command allowlist はないため Execute は技術的に arbitrary command を実行できます。これは accepted PoC risk であり technical control ではありません。

8,000 files／約 100 MB を task ごとに投入しません。canonical work packet、Bazaar read-only evidence、targeted search、short/fresh phase task を使い、unplanned full-repository ingestion を禁止します。

## インストール、ignore、ローカル登録

配布 checkout の root から install の dry run を行い、human が collision と内容を確認します。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\scripts\Install-TeamBobProfile.ps1" -TargetPath "<Bazaar-root>" -WhatIf
```

承認後に実行します。installer は conflict を上書きせず、Bazaar を操作しません。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\scripts\Install-TeamBobProfile.ps1" -TargetPath "<Bazaar-root>"
```

人が `.bobignore.base` を既存 `.bobignore` へ merge します。`.bzr/`、secrets、credentials、qualified irrelevant/generated paths は隠せますが、Word/Excel baseline と `team-bob-work` の work packet/drafts/results は Bob に見えるままにします。人が `.bzrignore.snippet` も merge し、`team-bob-work/` **全体**を Bazaar ignore にします。

install と human ignore merge が終わったら、人が管理する release/integration process で profile と ignore の変更を version 化し、レビューして承認します。この transition でも Bob は commit、merge、tag その他の Bazaar write を一切行いません。承認済み revision から fresh dedicated checkout を取得するか、人が read-only の `bzr status --short` を実行して出力が空であることを確認し、その後にだけ `Start-TeamBobTask.ps1` を使います。

target PC で、登録先が external root になる四つの必須 argument をすべて指定します。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Initialize-LocalEnvironment.ps1" -MsdevPath "C:\VC6\Common\MSDev98\Bin\MSDEV.COM" -BazaarPath "C:\Program Files\Bazaar\bzr.exe" -SandboxRoot "C:\BobTeam\sandboxes" -LogRoot "C:\BobTeam\logs"
```

出荷時は `vc6-build-targets.json` が空で disabled なので、profile identity と local registration を strict に確認します。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Test-TeamBobProfile.ps1" -RepositoryRoot "<Bazaar-root>" -Strict
```

## target-PC qualification と build profile enablement

real VC6 qualification は pending で、この package に enabled build profile はありません。PC owner と human reviewer は PC ごとに `MSDEV.COM /?`、normal Make、normal Rebuild、intentional compile failure、intentional link failure を external sandbox で実施します。switch、exit code、log/output pattern、PC ID、record ID、recordedAt を review します。

reviewer は結果を `<Bazaar-root>\team-bob\config\vc6-build-targets.json` に転記し、profile の project/target/timeout/artifact/pattern と `qualification` のすべてを確認します。`qualification.pcId` が local registration の PC ID と一致し、全証跡と approval が揃った場合だけ対象 profile を `enabled: true` にします。完了後には BuildProfileId を明示した strict validation を行います。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Test-TeamBobProfile.ps1" -RepositoryRoot "<Bazaar-root>" -BuildProfileId "qualified-vc6-profile-id" -Strict
```

empty/disabled catalog のまま ship する理由は、未確認の VC6 switch、exit code、log pattern、別 PC への build 実行を防ぐためです。profile を silent に enable したり、PC ID 不一致を許容したりしません。

## 標準 phase flow

1. 人が Word/Excel baseline から requirement ledger を承認する。
2. fresh task で external specification を作り、human external-spec review gate を通す。
3. fresh task で RT/safety/board/driver/ABI/build/customer-branch impact を評価する。Open QA または禁止領域 impact があれば Green に進まない。
4. fresh dedicated Green task は、Green risk、Open QA 空、seven impact-clear=YES、Clean Working Copy=YES、both approvers、both YES approvals、Allowed Files、enabled PC-matched BuildProfileId を必要とする。
5. Green 後は independent human review、fresh test-spec task、dedicated PC/board manual test の順に行う。attach/breakpoint/step execution は禁止する。

## Green packet の作成

下記は `Start-TeamBobTask.ps1` の mandatory argument と Green に必要な全 YES gate を含む例です。値は承認済みの実値へ置換し、`AllowedFiles` は既存の legacy source/header に限定します。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Start-TeamBobTask.ps1" -TaskId "GREEN-0001" -BazaarRoot "<Bazaar-root>" -Difficulty "Small" -Classification "Green" -Customer "Customer-A" -ReqIds "REQ-001","REQ-002" -WordBaseline "WORD-BASELINE-42" -QaBaseline "QA-BASELINE-17" -SpecBaseline "SPEC-BASELINE-9" -AllowedFiles "src\module.cpp","include\module.hpp" -BuildProfileId "qualified-vc6-profile-id" -SpecificationApprover "spec-approver" -ImplementationApprover "implementation-approver" -RTImpactClear YES -SafetyImpactClear YES -BoardImpactClear YES -DriverImpactClear YES -ABIImpactClear YES -BuildImpactClear YES -CustomerBranchImpactClear YES -AutonomousEditBuildApproved YES -SoftExecuteRiskAccepted YES -MaxRepairCycles 2
```

Allowed Files にある `.c`、`.cc`、`.cpp`、`.cxx`、`.h`、`.hh`、`.hpp`、`.hxx`、`.inl` だけを edit できます。`.rc`、`.dsp`、`.dsw`、`.def`、`.idl`、`.mak`、packet 外の files は禁止です。legacy source の CP932、no BOM、CRLF を維持します。

## Green build state machine と status

`/bob-implement-green` の repair budget は Make と Rebuild で共有します。`N = 0` から Make N を実行し、`SUCCEEDED` なら同じ N の Rebuild を実行します。実行形は毎回次の installed command です。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$Packet" -Action Make -Attempt N
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$Packet" -Action Rebuild -Attempt N
```

single invocation を確認する operator は packet を設定して actual attempt number を指定します。state machine の repair/retry 判定を手で省略してはいけません。

```powershell
$Packet = "<Bazaar-root>\team-bob-work\GREEN-0001\work-packet.md"
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$Packet" -Action Make -Attempt 0
# Make が SUCCEEDED のときだけ同じ attempt の Rebuild を実行する。
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$Packet" -Action Rebuild -Attempt 0
```

Make または Rebuild が `CODE_FAILED_RETRYABLE` かつ `N < 2` なら、その invocation の evidence に基づいて Allowed Files を一度だけ repair し、`N` を increment して **Make N に戻ります**。Rebuild を直接 retry しません。`N = 2` の retryable は `CODE_FAILED_STOP` として停止します。fixed stopping status も即停止です。

| Status | Exit | 処置 |
| --- | ---: | --- |
| `SUCCEEDED` | 0 | 要求した Make または Rebuild と integrity checks が成功。Make なら同じ N の Rebuild、successful Rebuild なら review evidence を整える。 |
| `CODE_FAILED_RETRYABLE` | 10 | `N < 2` だけ one evidence-based repair、increment N、Make N へ戻る。 |
| `CODE_FAILED_STOP` | 11 | repair せず human に escalation。 |
| `ENVIRONMENT_FAILED` | 20 | local registration/profile/PC を人が調査。 |
| `TIMED_OUT` | 21 | 停止し log と sandbox を人が調査。 |
| `INTEGRITY_FAILED` | 30 | 停止し source/packet/Bazaar/encoding boundary を人が調査。 |

`READY_FOR_HUMAN_REVIEW` は successful final Rebuild とその integrity verification がそろう場合だけです。Make success 単独では発行しません。Bob は Bazaar mutation を実行しません。

## Result と Bazaar evidence

work packet を指定して read-only Bazaar evidence を export します。

```powershell
$Packet = "<Bazaar-root>\team-bob-work\GREEN-0001\work-packet.md"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Export-BazaarEvidence.ps1" -WorkPacket "$Packet"
```

出力は役割が異なります。

- `team-bob-work/<Task>/results/build-result.md`: Bob-authored build result summary。
- `team-bob-work/<Task>/results/build-result-*.json`: invocation ごとの timestamped machine-readable result。
- local environment registration の external `logRoot`: VC6 が作る外部 registered log evidence。

human reviewer は三種類に packet と Bazaar `status/diff/nick/revision` evidence を合わせます。

## 手動受入れ、例外、rollout

Bob IDE で 5 custom modes と 6 slash commands、normal mode の Read-only auto approval、Green の soft governance、constrained edit regex、output location、fixed status 表示を確認します。package tests は installer source/target/code/`.bzr` immutability、custom-mode contract、packet gate、CP932/no-BOM/CRLF、anonymous usage columns、empty/disabled catalog、build/Bazaar evidence を clean checkout から real VC6/Bazaar なしで確認します。`tests/fixtures/` は説明のみを追跡し、fake MSDEV/Bazaar executable は verified temporary root で生成します。

exception は `templates/exception-record.md` に Task ID、ReqID(s)、facts、impact、evidence、Specification Approver、Implementation Approver、Soft-Execute-Risk-Accepted、expiry、disposition を残します。operations owner は install/stop、requirement owner は specification gate、implementation approver は Green gate、independent reviewer は review、target-PC owner は qualification/manual test を承認します。

critical misunderstanding、out-of-scope edit、actual-machine/control-network connection、Bazaar mutation は即時 stop です。2 名（operations owner を含む）で 2 週間、requirements、Green auto-repair、test specs を calibration し、v0.1.1-poc に反映してから残り 8 名に rollout します。training は 3 時間、最初の 3 tasks は paired、以後 6 週間は週 30 分 calibration です。

metrics は anonymous/task-only: Task ID、Profile Version、Phase、Difficulty、Bobcoin、Human/Rework Hours、Build Count、First Pass、Critical Findings、Result。Bobalytics は adoption/Bobcoin の補助で、quality の根拠は local logs と review outcomes です。rollback は human review 後に installed profile files だけを削除して prior approved profile に戻し、v0.1 では destructive cleanup を自動化しません。
