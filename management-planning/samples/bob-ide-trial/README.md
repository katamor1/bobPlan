# IBM Bob IDEで取得したCSV

2026年9月9日（日本時間）に、IBM Bob IDE 2.1.0のAskモードへ合成資料を渡して取得しました。固定の期待回答をBobの回答として置き換えていません。画面に表示されたCSVコードブロックを抽出し、UTF-8のCSVとして保存しています。

- `stage-01`: 要求整理のRequirementsとQuestions。
- `stage-02`: 作業分解・見積のTasksとQuestions。
- `stage-03`: 担当・日程・配分のTasks、Allocations、Questions。勤務不可日の割当を含む、修正前の実出力です。
- `stage-04`: 指摘修正後のRequirements、Tasks、Allocations。Questionsは変更されず、第3段階の5件を引き継ぎます。
- `evidence`: 修正前後の点検結果と、実際の取り込みで作成された変更差分。

案件条件、出典資料、標準参照例、要員、日別稼働は `../normal` と同じです。要求・作業・配分・確認事項の4表は空から開始しました。見積時に既存の合成参照例（8末端作業で26人時）を追加で提示したため、26人時という結果をBobの独立した見積精度の証拠にしません。

次の固定再生試験が、空の4表を持つ新規案件を作成し、保存済みCSVを段階順に取り込みます。各段階でPrepareし直し、元の版の保持、勤務不可日の検出、修正後のエラー0件、確認事項の維持、4出力を確認します。これは保存済み結果の再生であり、Bobを新たに実行する試験ではありません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File management-planning\tests\Test-BobTrial.ps1
```

最後に表示される保存先の `export/plan.xlsx` が再作成したブック、`export/redmine.csv` が転記用一覧です。実機試行の判断と残件は [試行記録](../../docs/bob-ide-trial.md) に記載しています。
