# Team Bob 運用手順（v0.1.0-poc）

## 適用範囲と安全境界

この profile は IBM Bob IDE 2.1.x、Windows、Visual C++ 6.0、Bazaar 2.5.1 の PoC 用です。Bob Shell 1.0.1 は対象外です。Bob は commit、merge、tag を行わず、実機、制御ネットワーク、mainline、secrets に接続しません。Word/Excel の基準資料は不変で、人が ReqID・原典アンカー付き要求台帳を承認します。

通常 mode の自動承認は Read だけです。Green は隔離済み開発環境、清浄な専用 Bazaar copy、承認済み Green work packet、新しい専用 Bob task に限り Edit/Execute を自動承認できます。custom mode に command allowlist はないため Execute は任意コマンドを実行可能です。これは PoC として明示的に受容する運用リスクであり、技術的制御ではありません。

約 8,000 ファイル/約 100 MB を毎回投入しません。work packet、Bazaar 証跡、対象検索、短く新しいフェーズ task を使い、無計画な全リポジトリ取り込みを禁止します。

## 初回インストールと開始

1. `powershell.exe -File .\scripts\Install-TeamBobProfile.ps1 -TargetPath <Bob プロファイル配置先> -WhatIf` を実行し、変更予定と衝突を確認します。
2. 人が承認したら `-WhatIf` を外して実行します。既存ファイルは上書きせず、Bazaar 操作はしません。
3. `.bobignore.base` を人が既存 `.bobignore` に統合します。`.bzr`、secrets、credentials、限定生成物は隠しますが、Word/Excel と `team-bob-work` の packet/drafts/results は隠しません。
4. `.bzrignore.snippet` も人がレビューして統合します。`team-bob-work/` 全体を ignore し、タスク成果物で working copy を dirty にしないためです。
5. 専用 target PC で `profile\team-bob\tools\Initialize-LocalEnvironment.ps1` を実行します。続けて `Test-TeamBobProfile.ps1 -RepositoryRoot <profile 配置先> -Strict` を実行します。
6. clean dedicated Bazaar working copy で `Start-TeamBobTask.ps1` を使い packet を作成します。mode/slash command はフェーズに一致させ、仕様承認・実装承認・Soft-Execute-Risk-Accepted を人が確認してから境界を越えます。

## 標準フロー

1. 人が Word/Excel 基準資料から、安定した ReqID・source anchor・受入基準・QA link を持つ requirement ledger を承認する。
2. 新しい task で外部仕様草案を作り、人が external-spec review gate を通す。
3. 新しい task で RT、安全、board、driver、ABI、build、customer branch の impact analysis を行う。未解決 QA または禁止領域への影響があれば Green に進まない。
4. 新しい Green task は、Green risk、Open QA 空、全 impact clear=YES、Clean Working Copy=YES、両 approver、両 YES approval、許可ファイルを満たす packet だけで開始する。
5. Green 完了後は独立した人間レビューを行い、さらに新しい test-spec task を作る。最後に専用 PC/board で手動試験を行う。debugger attach、breakpoint、step execution は禁止する。

## Green 編集・ビルド

編集できるのは packet の Allowed Files にある `.c`、`.cc`、`.cpp`、`.cxx`、`.h`、`.hh`、`.hpp`、`.hxx`、`.inl` だけです。`.rc`、`.dsp`、`.dsw`、`.def`、`.idl`、`.mak` と packet 外は編集禁止です。legacy source は CP932、BOM なし、CRLF を維持します。

実行順序は次のとおりです。

1. `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Make -Attempt 0`
2. `CODE_FAILED_RETRYABLE` のときだけ証跡に基づく修正を 1 回行い、`Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Make -Attempt 1`
3. 再び `CODE_FAILED_RETRYABLE` のときだけ最後の修正を 1 回行い、`Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Make -Attempt 2`
4. 成功した Make の後に必ず `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Rebuild -Attempt 2`

これは最大 2 repair cycle、合計 3 Make attempt、最終 Rebuild です。attempt 2 の `CODE_FAILED_RETRYABLE` は `CODE_FAILED_STOP` として停止します。`READY_FOR_HUMAN_REVIEW` は最終 Rebuild の `SUCCEEDED` と整合性確認の両方がある場合だけです。Bob は Bazaar mutation を実行しません。

| Status | Exit | オペレーター処置 |
| --- | ---: | --- |
| `SUCCEEDED` | 0 | Make なら final Rebuild へ、Rebuild なら証跡 export と人間レビューへ進む。 |
| `CODE_FAILED_RETRYABLE` | 10 | attempt 0/1 のみ、該当証跡で許可ファイルを修正する。attempt 2/最終 Rebuild は停止する。 |
| `CODE_FAILED_STOP` | 11 | 修正せず停止し、人間にエスカレーションする。 |
| `ENVIRONMENT_FAILED` | 20 | target PC/登録/プロファイルを人が調査する。 |
| `TIMED_OUT` | 21 | 停止し、ログと sandbox を人が調査する。 |
| `INTEGRITY_FAILED` | 30 | 停止し、source/packet/Bazaar/encoding 境界を人が調査する。 |

各フェーズ後は `Export-BazaarEvidence.ps1 -WorkPacket <packet>` で read-only status/diff/nick/revision evidence を `results` に出します。人間レビュー、test spec、専用 PC/board 手動試験の全てが終わるまで変更を統合しません。

## Bob IDE 手動受入れと target-PC qualification

Bob IDE で 5 mode と 6 slash command が表示されること、通常 mode が Read のみであること、Green が隔離条件下だけ Edit/Execute を提示すること、packet 外・禁止拡張子の編集を止めること、各草案/結果が `team-bob-work` に出ること、固定 status が表示されることを確認します。

PC ごとに `MSDEV.COM /?` を記録し、正常 Make、正常 Rebuild、意図的な compile failure、意図的な link failure を実行します。switch、exit code、output log pattern、PC ID、日時、record ID を qualification に残します。全証跡がそろうまで build catalog/profile は disabled のままです。偽 MSDEV/Bazaar は製品 tree に置かず、テストの一時 root だけで生成します。

PowerShell suite はクリーン checkout から実 VC6/Bazaar なしで動作し、installer source/target/code/`.bzr` 不変性、custom-mode contract、work-packet gate、CP932/CRLF、匿名 usage columns、disabled catalog を確認します。

## 例外、所有者、停止、rollback

例外は `templates/exception-record.md` に Task ID、ReqID、事実、影響、証跡、期限、Soft-Execute-Risk-Accepted、仕様/実装承認者を記録します。operations owner は導入・停止判断、requirement owner は仕様 gate、implementation approver は Green gate、independent reviewer はレビュー判定、target-PC owner は qualification/board 試験を承認します。

critical misunderstanding、out-of-scope edit、実機/制御ネットワーク接続、Bazaar mutation のいずれかで直ちに停止します。2 人（operations owner を含む）で 2 週間、requirement interpretation・Green auto-repair・test spec を校正し、停止事象を反映して v0.1.1-poc に改訂後、残り 8 人に展開します。研修は 3 時間、最初の 3 task はペア、以後 6 週間は週 30 分の calibration です。

usage log は匿名・task-only です: Task ID、Profile Version、Phase、Difficulty、Bobcoin、Human/Rework Hours、Build Count、First Pass、Critical Findings、Result。Bob IDE Bobalytics は adoption/Bobcoin の補助であり、品質判定はローカル log と review outcomes です。

rollback は人間レビュー後、インストール済み profile ファイルだけを削除して previous approved profile に戻します。v0.1 では destructive cleanup を自動化しません。
