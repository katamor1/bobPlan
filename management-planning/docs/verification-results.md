# 初版の検証結果

実施日: 2026-09-08～09。Windows PowerShell 5.1とインストール済みデスクトップExcelで実行しました。管理業務パッケージの実装と固定CSVの検証に加え、実際のBob IDE出力による4段階の試行、指摘修正、再出力を完了しました。業務確認者の受入と管理工数削減の実測は未完了です。

## 実施済み

| 試験 | 結果 | 確認内容 |
| --- | --- | --- |
| Test-Core.ps1 | 39項目成功 | CSV往復、重複・参照・循環、未確定、工数・日程・負荷、ID照合 |
| Test-Template.ps1 | 14シート・520項目成功 | 表名・見出し・列・数値日付書式・固定見出し・フィルター |
| Test-Excel.ps1 | 成功 | 実Excel往復、日本語・改行、文字列ID、数式として実行しない文章、原本保持 |
| Test-Integration.ps1 | 成功 | 5操作一巡、DOCX段落とXLSXセル出典、版追加、4出力、9転記行・26人時 |
| Test-ExcelValidation.ps1 | 15項目成功 | Excel数式の再計算、未確定の親集計、入力並べ替え、別Excelの維持、4不整合例 |
| Test-FailureRecovery.ps1 | 18項目成功 | 不正CSV・状態ファイルロック時の失敗処理、古いmanifestの拒否、人の修正後の再取り込み |
| Test-Reference.ps1 | 426項目成功 | 同梱完成ブックの全入力値とseed CSVの一致、親26人時、実Excel数式エラーなし、元ブック不変 |
| Test-BobTrial.ps1 | 31項目成功 | 実際のBob CSVを4段階で固定再生。勤務不可日の検出、修正後Error 0、確認事項・旧版の保持、26人時・9転記行 |

空テンプレート14シートをレンダーで確認しました。記入済みブックも14シートの表示、主要数値・日付・改行を確認しました。汎用ライブラリの再取り込みに表示・計算の差があるため、最終確認はExcelのPDF出力と実Excel再計算を使いました。日別稼働の目視対象は先頭10行、全57行のデータ保持は自動比較で確認しています。

合成案件は3要求・8末端作業・1親作業・26人時です。正常例はError 0、Warning 0、暫定基準のInfo 3です。親行の工数は見積・WBSで集計し、Redmineの親予定工数は空欄にして二重計上を防ぎます。

## 再実行

リポジトリルートで実行します。Excelを一括終了する処理はありません。

```powershell
$TestRoot = '.\management-planning\tests'
foreach ($TestName in @('Test-Core.ps1','Test-Template.ps1','Test-Excel.ps1','Test-Integration.ps1','Test-ExcelValidation.ps1','Test-FailureRecovery.ps1','Test-Reference.ps1','Test-BobTrial.ps1')) {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $TestRoot $TestName)
    if ($LASTEXITCODE -ne 0) { throw "Failed: $TestName" }
}
```

試験は一意の一時ディレクトリに成果物を作ります。実行結果に出る保存先を確認し、不要になったものだけ整理します。テンプレート再作成はauthoring/Build-Template.ps1、正常CSVからの参照ブック作成はauthoring/Build-Reference.ps1です。参照ブック作成先は既存ファイルを上書きしません。

## Bob実機試行と残件

- 9月9日、IBM Bob IDE 2.1.0の新しいAskタスクで、要求整理、見積、日別配分、修正を実行しました。実出力のCSVを保存し、4回の取り込みでplan-0005.xlsxまで作成しました。詳細は [実機試行記録](bob-ide-trial.md) にあります。
- Bobの初回配分には勤務不可日への割当が1件あり、補助ツールが2件のErrorを報告しました。Bobへの修正依頼1回で解消し、最終はError 0、Warning 7、Info 3でした。日程の4作業と、要求の確認状態2行を修正しました。
- 最終の5要求・8末端作業・26人時は4出力で整合し、デスクトップExcelで全14シートの表示と数式エラー0件を確認しました。未解決の確認事項5件と、対応する要求2件のOpenを維持しています。26人時は提示した合成参照例に基づき、実案件での独立した見積精度を示しません。
- 以前のIDEウィンドウのサインイン失敗表示は今回の新しいAskタスクの動作を妨げませんでした。Shell 1.0.1はライセンス同意、再確認したShell 2.0.2はAPIキーが必要という応答で未実施です。IDEの試行成功をShellの成功と読み替えません。
- 業務確認者による作業粒度・見積根拠・帳票の使いやすさの受入と、同条件の手作業との時間比較は残っています。usage-log.csvは未記入の測定書式です。会話の経過時間を作業時間に置き換えず、削減時間・削減率は未測定とします。

## 既存リポジトリの試験

既存Test-Package.ps1は357件のパッケージ契約検査を通過した後、Test-DemoAdapter.ps1の「Native success without artifact always displays the fixed non-qualification banner」で失敗しました。変更のない元のmain作業ディレクトリでも、Test-DemoAdapter.ps1の同じ失敗を再現しました。旧ビルド用アダプターは今回変更していません。既存Test-DemoPackage.ps1の247項目は成功しています。既存一括試験全体の成功とは報告しません。

実装はcodex/management-planning作業ブランチにあります。コミット、mainへの統合、外部登録は行っていません。
