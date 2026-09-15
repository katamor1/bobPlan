# 合成案件での試行

## 固定CSVによる確認

リポジトリルートから以下を実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File management-planning\tests\Test-Core.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File management-planning\tests\Test-Template.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File management-planning\tests\Test-Excel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File management-planning\tests\Test-Integration.ps1
```

CoreはExcelなしで実行できます。Excel/Integrationはインストール済みExcelを使用します。Integrationは新規の隔離フォルダーを作り、NewからExportまで実行します。期待値は3要求、8末端作業、親作業1行、26人時、9配分行、Redmine9行です。Infoの暫定基準3件は意図した表示です。

`samples/negative` は異常値検出用です。normalの全表を読み込み、そのシナリオのCSVだけ差し替えます。ファイルは表全件の置換です。実案件へは取り込みません。

## IBM Bobでの試行

1. READMEのNew/Prepareを実行します。Bobでpackを開き、版・実行形態（IDE/Shell）・モデル表示・日時を記録します。
2. 元資料と現行台帳を参照し、最初の保存指示を使用します。出力をその段階専用のdraftへ保存します。
3. そのCSVを基準版のmanifestとともにImportし、Checkと人の確認・修正を行います。修正後の版からPrepareし直し、次の保存指示を新しいpackへ適用します。これを4段階について繰り返します。第1・第2段階の担当・日程・配分の未確定指摘は、後続段階で解消する項目として残します。
4. 最終のExport後、Excelで14シートを確認します。要求と作業、見積と配分、担当と日程を確認し、必要な修正を記録します。
5. Bobの応答原文・CSV・点検結果・差分・最終ブックを保管します。固定CSVの成功をBobの実出力成功と読み替えません。

Bobが未認証、利用上限、ライセンス未同意などで動作しない場合は、その事実と停止段階を記録します。試行成功や削減率は記載しません。IDE試行とShell試行は区別します。

2026年9月9日にIDEのAskモードで4段階を実行しました。[実機試行記録](bob-ide-trial.md) と `samples/bob-ide-trial` に実出力を残しています。フォルダーを開けない場合は、最新packの指示・CSV・sources.mdを貼り付け、ファイル名付きのCSVコードブロックで回答させる方法も使えます。入力が長い場合も、段階ごとに更新後の台帳を渡します。

同試行では、要員002の稼働0時間の日に2時間を配分する誤りがありました。補助ツールの2つのErrorは同じ割当を指しています。確認事項が未解決なのに要求のQAStatusがResolvedになっている矛盾も別途レビューで見つかりました。この対応関係は自動点検で十分に判定できないため、人の確認項目に含めます。指摘修正では、担当・日付・配分と後続作業を直し、要員条件や未解決事項を都合よく変更していないことを差分で確認します。

## 管理工数の測定

`usage-log.csv` に資料準備、指示作成、確認修正、転記・出力の実作業分数を記録します。待ち時間は別欄です。手作業とBob補助で同じ案件・完成基準を使用します。

合計人作業分数の差を削減時間とします。削減率は手作業時間が0を超える場合のみ計算します。試行順序による慣れの影響も記録します。合成案件は操作性・整合性の試験であり、実案件の生産性・見積精度を示しません。

## 受入条件

- 固定CSVで5操作が完走し、元資料・旧版が変わらない。
- 日本語、改行、引用符、先頭ゼロID、数式に見える文章が往復できる。
- 工数26人時が見積・WBS・配分・チケットで整合し、親を加算して52人時にしない。
- 異常シナリオが点検で報告され、未確定値が0や正常値にならない。
- 実際のBob出力について取り込み・点検・修正・再出力を記録する。
- Excelの全シート表示、主要数式、フィルター、固定見出しを確認する。
