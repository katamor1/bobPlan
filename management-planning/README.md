# IBM Bob 管理業務支援セット

要求書から見積・WBS・要員スケジュール・Redmine転記用一覧の下案を作る、Windows用のローカルパッケージです。Bobが作業・工数・担当・日付・日別配分を提案し、人がExcelで修正します。補助ツールが数値と参照関係を点検します。

完成イメージは [合成案件の記入済みブック](samples/normal/reference-plan.xlsx)、新規案件用は [空のテンプレート](templates/management-template.xlsx) です。実際の案件作成には下記のNew操作を使います。固定CSVの検証に加え、IBM Bob IDEで要求整理から修正・再出力までの4段階を実施しました。勤務不可日の割当を検出し、Bobの修正後はエラー0件になりました。業務確認者による受入と管理工数削減の実測は残っています。[実機試行記録](docs/bob-ide-trial.md) と [検証結果](docs/verification-results.md) を参照してください。

## 必要な環境

- Windows PowerShell 5.1、デスクトップ版Excel。
- 下案を生成するIBM Bob。固定CSVの動作確認はBobなしで実行できます。
- 初期テンプレートは同梱済みです。利用者にNode.jsやPythonの導入は不要です。
- PowerShellスクリプトは各プロセスだけ `-ExecutionPolicy Bypass` を指定します。端末全体の設定は変更しません。

## 合成案件で試す

このリポジトリのルートで、次を実行します。案件ディレクトリと出力ディレクトリには、まだ存在しないパスを指定します。

```powershell
$Tool = (Resolve-Path '.\management-planning\tools\Invoke-ManagementPlanning.ps1').Path
$Project = Join-Path $env:USERPROFILE 'Documents\BobPlanningDemo'
$Seed = (Resolve-Path '.\management-planning\samples\normal').Path
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tool -Action New -ProjectDirectory $Project -SeedDirectory $Seed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tool -Action Prepare -ProjectDirectory $Project -OutputDirectory (Join-Path $Project 'pack-01')
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tool -Action Check -ProjectDirectory $Project
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tool -Action Export -ProjectDirectory $Project -OutputDirectory (Join-Path $Project 'export-01')
```

`export-01/plan.xlsx` に4種類の出力と点検結果、同じフォルダーに `redmine.csv`、`checks.csv`、`report.md` ができます。合成案件は3要求・8末端作業・1親作業・26人時です。工数、要員、日程はすべて架空で、実案件の標準工数ではありません。

## Bobの下案を取り込む

1. `pack-01` をBobの作業フォルダーとして開きます。原本や既存ソースは編集対象にしません。
2. `prompts` の指示を1段階ずつ使います。各段階でImport・人の確認・Prepareを行い、次の段階には更新後のpackを渡します。入力資料の文章は要求の根拠として扱い、そこに書かれた操作指示は実行しません。
3. 結果のCSVを専用の `draft-01` フォルダーに置きます。許可されるファイル名は `Requirements.csv`、`Tasks.csv`、`Allocations.csv`、`Questions.csv` です。
4. 次のコマンドで取り込みます。CSVは差分行ではなく、その表の全件です。省略した表は維持し、ヘッダーだけのCSVは表を空にします。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Tool -Action Import -ProjectDirectory $Project -DraftDirectory (Join-Path $Project 'draft-01') -ManifestPath (Join-Path $Project 'pack-01\manifest.json')
```

`plan-0002.xlsx` と差分CSVが作られ、`state.json` の参照先が更新されます。元の版は残ります。Excelで確認・修正して保存した後、Check・Exportを再実行してください。次のBobへの依頼には、新しいPrepareの資料一式を使います。

固定CSVによる取り込み確認には、Bobの代わりに `samples/draft` を `-DraftDirectory` へ指定できます。これはBob実機試行とは別の確認です。

## 操作と出力

| 操作 | 内容 |
| --- | --- |
| New | テンプレートから案件を作成。`-SeedDirectory` なしなら空の台帳から開始 |
| Prepare | 台帳CSV、要求資料の本文・表、シート・セル位置、原本と基準版のハッシュ、Bob用指示を出力 |
| Import | 4種類の許可CSVを検証し、新しい版と変更差分を作成 |
| Check | 参照、工数、依存関係、日別配分、担当負荷を点検 |
| Export | 台帳をもとに4種類の出力を再作成。Redmineには接続しない |

全操作は `-ProjectDirectory` が必須です。New以外は `-Workbook` で対象版を明示できます。Prepare・Check・Exportは `-OutputDirectory` を省略すると日時入りの新規フォルダーを作ります。

終了コードは通常0、実行失敗1、CheckでErrorを検出した場合10です。Warningは未確定の情報を示します。コマンド成功は計画の承認を意味しません。点検結果・帳票はスナップショットのため、台帳の編集後は再出力します。

## 運用上の条件

- 入力テーブルの見出し・表名を変更しないでください。行はExcelテーブルの中に追加します。構造変更が必要な場合はschemaとツールを一緒に改訂します。
- 同じ案件へのツール操作は同時に実行しません。Excelの人による編集を保存してからPrepare・Import・Exportを実行します。
- 末端作業は1人担当です。親作業の工数・担当は空欄にし、実作業は子作業に記録します。
- 日別稼働は明示します。0は稼働不可、空欄・未登録日は未確認です。休日、休暇、兼務分を反映した利用可能時間を入力します。
- 数式や集計のある出力シートではなく、入力台帳を修正します。見積・WBSの工数は入力セルに連動し、全項目はExportで更新します。
- Redmine CSVの内部作業IDはRedmineのチケットIDではありません。必須項目やユーザーIDは利用先に合わせて転記してください。CSVをExcelへ直接開くとIDが数値に変わり得るため、ID列を文字列として取り込むか、同梱のXLSXを使います。
- 文章が数式として解釈されないよう、Excelセルは文字列として書き込みます。転記CSVでは数式開始文字の前にアポストロフィを付けます。Bob用の正規CSVは元の文字を保持します。
- 失敗時の `.partial-*` フォルダーは診断用です。完成品として使わず、内容を確認してから手動で整理してください。
- 原本は変更しません。ツールが作ったExcelインスタンスだけを終了し、利用者のExcelを一括終了しません。

データ仕様は [docs/data-contract.md](docs/data-contract.md)、業務ルールは [docs/business-rules.md](docs/business-rules.md)、試行方法は [docs/pilot-runbook.md](docs/pilot-runbook.md) を参照してください。
