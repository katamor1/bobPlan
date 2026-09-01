# Team Bob VC6/Bazaar Profile v0.1.0-poc

これは IBM Bob IDE 2.1.x 上で、Windows、Visual C++ 6.0、Bazaar 2.5.1 を対象にした、限定運用のチーム・プロファイルです。対象外は Bob Shell 1.0.1、実機・制御ネットワーク・mainline・秘密情報への接続、および Bob による commit/merge/tag です。実機 VC6 の認定はまだ完了していないため、同梱のビルド・カタログは無効です。認定証跡が揃うまで Green は有効化しません。

完全なオペレーター手順、例外、判定表は [USAGE.md](profile/team-bob/USAGE.md) を正とします。この README は導入前にチーム全員が共有する安全境界と導線です。

## 目的と作業原則

約 8,000 ファイル、約 100 MB を毎タスクで読み込むと Bobcoin とコンテキストを浪費し、根拠のない変更を誘発します。必ず `team-bob-work/<Task ID>/work-packet.md` を入口にし、Bazaar の status/diff/revision 証跡、対象を絞った検索、短く新しいフェーズ専用 Bob タスクだけを使います。要求外の全リポジトリ取り込みはしません。

Word/Excel の基準資料は不変です。人が安定した ReqID と原典アンカーをもつ要求台帳を承認し、外部仕様レビュー、影響分析、Green の編集/ビルド、独立した人間レビュー、別の新しいテスト仕様タスク、専用 PC/ボードでの手動試験の順に進めます。実機試験中も attach、breakpoint、step 実行はしません。

## 導入手順

1. 配布元で試行表示を行います。`powershell.exe -File .\scripts\Install-TeamBobProfile.ps1 -TargetPath <Bob プロファイル配置先> -WhatIf`
2. 内容と衝突を人が確認してから、同じコマンドから `-WhatIf` を外してインストールします。インストーラーは衝突を上書きせず、Bazaar 操作もしません。
3. `.bobignore.base` と `.bzrignore.snippet` は自動で結合しません。人がレビューして既存の ignore 設定に統合します。前者は `.bzr`、秘密情報、資格情報、限定された生成物を隠しますが、Word/Excel と work packet/drafts/results は Bob に見せます。後者は `team-bob-work/` 全体を Bazaar の未追跡変更から除外します。
4. 対象 PC だけで `Initialize-LocalEnvironment.ps1` を実行し、`Test-TeamBobProfile.ps1 -Strict` でローカル登録、ハッシュ、外部 sandbox/log root、無効なビルド・カタログを確認します。
5. 専用の清浄な Bazaar working copy を用意し、`Start-TeamBobTask.ps1` で task packet を開始します。Bob ではフェーズに合う mode と slash command を選び、承認境界を超える前に人が packet を承認します。
6. Green 後は Bazaar 証跡を export し、人間レビューと新しいテスト仕様タスク、手動 PC/ボード試験を完了します。

## 権限と PoC リスク

通常 mode は Read だけを自動承認します。Green は隔離された開発条件で、完全な Green packet を持つ新規・専用 Bob タスクに限り Edit/Execute を自動承認できます。custom mode にはコマンド allowlist がないため、Execute は技術的には任意コマンドを実行できます。これは受容した PoC リスクであり、技術的制御ではありません。実機、制御ネットワーク、mainline、secrets には決して接続しません。

Green は許可済み C/C++ source/header だけを CP932、BOM なし、CRLF のまま編集します。Make、最大 2 回の証跡ベース修正（合計 3 Make 試行）、最終 Rebuild、整合性確認の全てが成功した場合だけ `READY_FOR_HUMAN_REVIEW` です。固定 status/exit code と停止条件は USAGE を参照してください。

## 導入・運用の受入れ

自動パッケージテストは、インストーラーの source/target/code/`.bzr` 不変性、custom mode、packet gate、CP932/CRLF、匿名利用列、無効カタログ、ビルドと Bazaar 証跡を確認します。`tests/fixtures/` は安全なテスト用の説明だけを追跡し、偽 MSDEV/Bazaar 実行ファイルは検証済みの一時 root で生成します。

Bob IDE では、5 mode/6 slash command、Read-only 通常 mode、Green の限定 Edit/Execute、packet 外編集の拒否、出力先、停止表示を人が確認してください。target-PC qualification は `MSDEV.COM /?`、通常 Make/Rebuild、意図的な compile/link failure の各 PC の switch・exit・log pattern を記録して初めて完了です。すべての証跡が揃うまで profile は disabled のままです。

## ロールアウトと測定

2 週間は operations owner を含む 2 名で運用し、要求解釈、Green 自動修正、テスト仕様を校正します。重大な誤解、スコープ外編集、実機接続、Bazaar 変更が一つでも起きたら停止します。結果を v0.1.1-poc に反映してから残り 8 名へ展開します。研修は 3 時間、最初の 3 タスクはペア、以後 6 週間は週 30 分の校正です。

計測は匿名・タスク単位のみです: Task ID、Profile version、phase、difficulty、Bobcoin、human/rework hours、build count、first-pass、critical findings、result。Bob IDE Bobalytics は導入状況/Bobcoin の補助にできますが、品質の根拠はローカル log と人間レビュー結果です。

問題時は USAGE の status 判定、例外記録、所有者・承認、rollback に従います。v0.1 では人のレビュー後にインストール済み profile ファイルだけを削除する rollback とし、破壊的クリーンアップを自動化しません。
