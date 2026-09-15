# データ契約 v1.0

schema.jsonが表名、列順、型、日本語見出しの正本です。Excelは4行目を見出し、5行目からデータとし、表名はmp_で始まります。CSVは英語列名です。

## Project

`Key,Value,Notes`

## Sources

`SourceID,Path,Kind,Sheet,Range`

## Standards

`RuleID,Phase,UnitHours,Basis,Provisional`

## Requirements

`ReqID,SourceID,SourceAnchor,Interpretation,AcceptanceCriteria,QAStatus`

## People

`MemberID,Name,Phases,Skills`

## Capacity

`MemberID,Date,AvailableHours`

## Tasks

`TaskID,ParentTaskID,ReqIDs,Title,Phase,Deliverable,AcceptanceCriteria,EstimatedHours,EstimateBasis,AssigneeID,StartDate,EndDate,PredecessorIDs,Status`

## Allocations

`TaskID,Date,Hours`

## Questions

`QuestionID,EntityID,Question,Status,Resolution`

## 入出力と型

数値は有限の非負の人時、日付はyyyy-MM-dd、空欄は未確定です。IDと文章は文字列として保持します。CSVはUTF-8、列順を固定し、余分・不足・順序違いの列は取り込みません。IDは同じ表内で一意です。複数ID・工程の区切りはセミコロンです。

IDの照合はExcelに合わせて大文字・小文字を区別しません。表記自体は保持します。大文字・小文字だけ異なるIDは重複です。IDには空白、`;`、`|`、`#`、`*`、`?`、`~`を使いません。先頭のゼロは保持します。

Tasks.ReqIDsとPredecessorIDsは複数ID、AssigneeIDは単一です。Capacityの複合キーはMemberIDとDate、AllocationsはTaskIDとDateです。親作業の実工数は空欄で、葉の集計が出力側に表示されます。

Requirements.QAStatusおよびQuestions.Statusは未解決Open／確認済みResolvedです。Tasks.StatusはDraft／Reviewedを記録する説明用状態です。Standards.ProvisionalはYes／Noです。

Prepareのmanifestは基準ブックのSHA256を含みます。Importへ-ManifestPathを指定した場合は一致を要求し、基準が変わっていたら新たにPrepareします。manifestなしのImportは明示した現行ブックを基準にします。

## 出力の対応

- EstimateView: 作業台帳の作業ID、工程、見積根拠と末端工数・親集計。
- WbsView: 同じID・親ID・工数に成果物、担当、日程、依存関係を付ける。
- ScheduleView: 配分1行ごとに担当者、同日合計、利用可能時間を付ける。日計・利用可能時間は行に繰り返し表示するため、それらの列を縦に合計しない。
- RedmineView: 件名、成果物・完了条件・見積根拠を含む説明、末端の予定工数、担当、日付、内部ID。親行の工数は空欄。
- Checks: Severity、Code、Entity、Field、Message。正常時はヘッダーだけで、正常を装う0行の指摘は作らない。

Excelは数値・日付を型付きで保存します。BobとのCSVは生の文字を保持します。人が開くRedmine CSVは数式開始文字をアポストロフィで保護するため、正規データへの逆取り込みには使用しません。

## 入力資料

Sources.Pathは初期化時はseedディレクトリからの相対パスを使えます。Newが絶対パスへ解決します。実案件で入力する場合は原本の絶対パスを推奨します。
DOCXの段落はparagraph:1、表はtable:1/row:1/cell:1、XLSXはQA!B2のように位置を記録します。XLSXの数式は保存済み結果を読みます。画像・OCR・書式による意味推定・再計算は対象外です。
