# Team Bob VC6/Bazaar Profile v0.1.0-poc

これは Windows 上の IBM Bob IDE 2.1.x、Visual C++ 6.0、Bazaar 2.5.1 向けの限定 PoC profile です。Bob Shell 1.0.1 は対象外です。Bob は commit、merge、tag を行わず、実機、制御ネットワーク、mainline、secrets には決して接続しません。

実 VC6 の qualification は未完了です。そのため同梱の **build catalog** (`vc6-build-targets.json`) は空で disabled です。Green custom mode 自体は技術的には同梱・存在しますが、PC ID が一致する profile を人が qualification して enabled にするまで、選択も auto-approve もしてはいけません。これは mode を無効にした、という意味ではありません。

完全な運用手順は [USAGE.md](profile/team-bob/USAGE.md) を正とします。この README は導入、境界、実行可能な入口を示します。

IBM Bob IDE 2.1.xの90分技術評価は、完全合成データと実MSBuildを使う [demo package](demo/README.md) と [runbook](demo/docs/90-minute-runbook.md) を使います。demo adapterは既存wrapperの呼出し契約だけを評価するtest doubleであり、VC6のemulation、互換性試験、qualificationではありません。生成する画面表示と証跡は常に`MSBUILD DEMO ADAPTER — NOT VC6 QUALIFICATION`と明記します。

## 作業の考え方

約 8,000 ファイル／約 100 MB を毎 task に読ませると Bobcoin と context を浪費し、根拠のない変更を誘発します。必ず `team-bob-work/<Task ID>/work-packet.md`、Bazaar の read-only evidence、対象を絞った検索、短く新しい phase 専用 Bob task を使います。計画のない全 repository 取り込みは行いません。

Word/Excel baseline は不変です。人が stable ReqID と source anchor を含む requirement ledger を承認し、external-spec review、impact analysis、Green edit/build、独立した human review、新しい test-spec task、専用 PC/board の手動試験へ進めます。実機試験でも attach、breakpoint、step 実行は行いません。

## パスと作業ディレクトリの約束

以下の `<Bazaar-root>` は、`.bzr` を直下にもつ専用かつ clean な Bazaar working copy の絶対パスです。インストール後の操作はこの root を current directory にし、**すべて** `<Bazaar-root>\team-bob\tools` の installed tools を呼びます。配布 source の `profile\team-bob\...` はインストール前の参照用であり、日常運用では実行しません。

profile が読む JSON、JSON 形式の YAML、work packet、environment registration、config、template は strict UTF-8 **without BOM** です。production writer も UTF-8 without BOM を出力し、Windows PowerShell 5.1 の既定 ANSI decoding には依存しません。VC6 legacy source と `/OUT` log の CP932 contract はこれとは別です。

```powershell
Set-Location "<Bazaar-root>"
```

## 導入とローカル登録

配布 checkout の root で、まず変更予定だけを確認します。`<Bazaar-root>` は既存の Bazaar working copy の絶対パスに置き換えます。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\scripts\Install-TeamBobProfile.ps1" -TargetPath "<Bazaar-root>" -WhatIf
```

人が衝突と内容を確認してから実インストールします。インストーラーは衝突を上書きせず、Bazaar 操作もしません。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\scripts\Install-TeamBobProfile.ps1" -TargetPath "<Bazaar-root>"
```

`.bobignore.base` と `.bzrignore.snippet` は自動結合しません。人が既存 ignore 設定へレビューして統合します。前者は `.bzr/`、secrets、credentials、限定した生成物を Bob から隠せますが、Word/Excel baseline と `team-bob-work` の packet/drafts/results を隠してはいけません。後者は `team-bob-work/` 全体を Bazaar ignore にして task artifact が working copy を dirty にしないようにします。

インストールと human ignore merge の後は、人が管理する release/integration process が profile と ignore の変更を version 化して承認します。Bob はこの移行でも commit、merge、tag その他の Bazaar write を実行しません。承認済み状態から fresh dedicated checkout を取得するか、人が read-only の `bzr status --short` を実行して出力が空であることを確認してから `Start-TeamBobTask.ps1` を実行します。

target PC で次を実行します。四つの必須引数はすべて絶対パスです。sandbox と log root は Bazaar root の外で、互いを含まない別 directory にします。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Initialize-LocalEnvironment.ps1" -MsdevPath "C:\VC6\Common\MSDev98\Bin\MSDEV.COM" -BazaarPath "C:\Program Files\Bazaar\bzr.exe" -SandboxRoot "C:\BobTeam\sandboxes" -LogRoot "C:\BobTeam\logs"
```

catalog が空の出荷状態では通常の strict validation を実行します。特定 profile を指定する strict validation は、次節の qualification/enablement を人が完了した **後** のみ実行します。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Test-TeamBobProfile.ps1" -RepositoryRoot "<Bazaar-root>" -Strict
```

## target-PC qualification と enablement

PC ごとに人が `MSDEV.COM /?`、正常 Make、正常 Rebuild、意図した compile failure、意図した link failure を専用 sandbox で実施し、switch、exit code、output/log pattern、PC ID、日時、record ID を確認します。review 済みの結果だけを `<Bazaar-root>\team-bob\config\vc6-build-targets.json` の profile qualification に転記します。`qualification.pcId` は登録した PC の ID と一致し、`enabled` は全証跡と人の承認が揃うまで `false` のままにします。

human reviewer が config の project/target/timeout/artifact pattern と上記 evidence を確認し、PC ID が一致することを再確認して初めて、対象 profile だけを enabled にします。続けて次を実行します。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Test-TeamBobProfile.ps1" -RepositoryRoot "<Bazaar-root>" -BuildProfileId "qualified-vc6-profile-id" -Strict
```

空/disabled catalog を ship するのは、未知の VC6 switch・exit・log pattern や別 PC 上で build を実行させないためです。実機 VC6 qualification は明示的に pending のままであり、この package に実 build profile は含みません。

## Green の開始・ビルド・evidence

通常 modes には draft 用の Edit group が技術的にありますが、auto-approved は Read だけです。Edit は必ず human approval を要します。Green は fresh dedicated Bob task と approved Green packet を使う soft-rule mode であり、qualified/enabled/PC-matched profile がある隔離開発条件でだけ Edit/Execute を auto-approve できます。custom mode に command allowlist はないため Execute は技術的に任意 command を実行できます。これは明示的に受容する PoC risk であり、技術制御ではありません。

Green packet は Open QA が空、全 seven impact-clear が `YES`、両 approver、両 approval、Allowed Files、fixed repair budget を必要とします。次は必須 parameter と全 `YES` gate を含む作成例です（実在する baseline、ReqID、allowed file、enabled profile ID に置換します）。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Start-TeamBobTask.ps1" -TaskId "GREEN-0001" -BazaarRoot "<Bazaar-root>" -Difficulty "Small" -Classification "Green" -Customer "Customer-A" -ReqIds "REQ-001","REQ-002" -WordBaseline "WORD-BASELINE-42" -QaBaseline "QA-BASELINE-17" -SpecBaseline "SPEC-BASELINE-9" -AllowedFiles "src\module.cpp","include\module.hpp" -BuildProfileId "qualified-vc6-profile-id" -SpecificationApprover "spec-approver" -ImplementationApprover "implementation-approver" -RTImpactClear YES -SafetyImpactClear YES -BoardImpactClear YES -DriverImpactClear YES -ABIImpactClear YES -BuildImpactClear YES -CustomerBranchImpactClear YES -AutonomousEditBuildApproved YES -SoftExecuteRiskAccepted YES -MaxRepairCycles 2
```

Bob の `/bob-implement-green` は shared repair budget `N=0..2` で Make N を先に呼びます。Make または Rebuild が `CODE_FAILED_RETRYABLE` で `N < 2` のときだけ one evidence-based repair を行い、`N` を増やして **Make N に戻ります**。Rebuild を直接 retry しません。各 invocation は次の正確な形です。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$Packet" -Action Make -Attempt N
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$Packet" -Action Rebuild -Attempt N
```

operator が single invocation の動作を確認するときは、packet を先に設定し、実数 attempt を指定します。Green state machine を手で省略してはなりません。

```powershell
$Packet = "<Bazaar-root>\team-bob-work\GREEN-0001\work-packet.md"
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$Packet" -Action Make -Attempt 0
# Make が SUCCEEDED のときだけ、同じ attempt の Rebuild を実行する。
powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$Packet" -Action Rebuild -Attempt 0
```

`SUCCEEDED` は要求した Make **または** Rebuild と integrity checks の成功です。Make 成功は同じ `N` の Rebuild に進むだけで、successful final Rebuild と integrity verification のときだけ `READY_FOR_HUMAN_REVIEW` です。`CODE_FAILED_RETRYABLE`（exit 10）は `N < 2` だけ repair、`CODE_FAILED_STOP`（11）、`ENVIRONMENT_FAILED`（20）、`TIMED_OUT`（21）、`INTEGRITY_FAILED`（30）は即停止です。

完了後に read-only Bazaar evidence を export します。

```powershell
$Packet = "<Bazaar-root>\team-bob-work\GREEN-0001\work-packet.md"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<Bazaar-root>\team-bob\tools\Export-BazaarEvidence.ps1" -WorkPacket "$Packet"
```

`build-result.md` は Bob-authored の短い result summary、`build-result-*.json` は build invocation ごとの timestamped machine result、登録済み external `logRoot` は VC6 の外部 log evidence です。三者を混同せず、人間レビューには packet と Bazaar evidence も添えます。

## 受入れ、運用、停止

package test は installer の source/target/code/`.bzr` 不変性、mode contract、packet gate、CP932/no-BOM/CRLF、anonymous usage columns、disabled catalog、build/Bazaar evidence を real VC6/Bazaar なしで検証します。`tests/fixtures/` に実行可能な fake tool は追跡せず、検証済み temporary root にだけ生成します。

Bob IDE では、5 modes/6 slash commands、normal mode の Read-only auto approval、Green の限定 Edit/Execute、packet 外・禁止拡張子 edit の拒否、task output、固定 status 表示を人が確認します。Green 後は independent human review、新しい test-spec task、dedicated PC/board の手動試験の順です。

例外は `team-bob/templates/exception-record.md` に Task ID、ReqID(s)、facts、impact、evidence、Specification/Implementation Approver、risk acceptance、expiry、disposition を記録し、人が判断します。critical misunderstanding、out-of-scope edit、実機/制御 network 接続、Bazaar mutation は即停止です。rollback は human review 後に installed profile files だけを削除し、v0.1 では destructive cleanup を自動化しません。

最初の 2 週間は operations owner を含む 2 人で requirement interpretation、Green auto-repair、test spec を校正します。停止事象を v0.1.1-poc に反映してから残り 8 人へ展開します。training は 3 時間、最初の 3 task は pair、以後 6 週間は週 30 分の calibration です。metrics は匿名 task-only（Task ID、profile version、phase、difficulty、Bobcoin、human/rework hours、build count、first-pass、critical findings、result）です。Bobalytics は adoption/Bobcoin の補助であり、quality の根拠は local log と review outcome です。
