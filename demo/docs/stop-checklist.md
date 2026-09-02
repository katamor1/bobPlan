# MSBUILD DEMO ADAPTER — NOT VC6 QUALIFICATION

## 即時停止チェックリスト

いずれか一つでも`YES`なら、新しいapproval、編集、build、commitを行わずデモを停止します。現在の画面、Work Packet、adapter log、sidecar evidence、Bazaar status/diffを保存し、`DEMO-OPERATIONS-OWNER-ROLE`へ引き渡します。

### 開始前

- [ ] Bob executableの`ProductVersion`が`*bob2.1.*`にmatchしない。
- [ ] Visual Studio instanceが`isComplete:true`かつ`isLaunchable:true`ではない。
- [ ] v143またはWindows SDK 10.0.22621.0が存在しない。
- [ ] Windows PowerShell 5.1／PowerShell 7のpackage testsが失敗している。
- [ ] endpoint protection／EDRがadapter executableを削除、隔離、置換、または起動拒否した。保護機能の無効化や未承認の除外追加で継続してはならない。
- [ ] demo root／sandboxへ予期しない主体、sync tool、別processが同時書込みでき、adapterの検査後にpathや内容を差し替え得る。
- [ ] Stage／raw qualification evidence／役割による承認のいずれかが未完了である。
- [ ] `-AcceptNotVc6`なしでdemo profileがenabledになっている。
- [ ] 本番catalogが空でない、またはproduction exampleが`enabled:false`ではない。
- [ ] workspaceがUNC、mapped drive、reparse path、配布元との重複、marker不一致の場所にある。
- [ ] rehearsalとliveが同じroot、またはrehearsal restore／untrust完了前にliveをStageした。
- [ ] rehearsalのcatalog、packet、revision、Record ID、evidenceをliveへ再利用した。
- [ ] Bob設定backup、`/permissions`事前記録、permission reset、workspace trust、復元手順のいずれかを確認できない。
- [ ] demo rootの親、drive root、配布元がtrustedである。
- [ ] Stageまたはqualification scriptが`.bzr`を作成・変更した。
- [ ] 人によるinitial Bazaar bootstrapが未完了、full revision-id不明、またはbaseline直後の`status --short`が空でない。
- [ ] initial `bzr add`対象にlogs、evidence、backup、secret、実顧客dataが含まれる。

### 要求／仕様／Impact

- [ ] Word段落またはExcel sheet／cellのImmutable Source Anchorがない。
- [ ] Bobが存在しないReqID、回答、承認、acceptance criteriaを推測した。
- [ ] Open QAが残っているのにGreenへ進もうとしている。
- [ ] RT、安全、board、driver、ABI、build、Customer分岐のimpactが不明またはclearでない。
- [ ] 全repositoryの無計画な読込み、workspace外read、実顧客情報、credential、secretへのaccessが発生した。

### Green／build

- [ ] Green以外、cleanでないworking copy、承認欠落、role以外のapproverで実装を開始した。
- [ ] Read以外がauto-approvedである、またはGreenの各Edit／各Executeを毎回manual reviewしていない。
- [ ] Editのdiff previewでAllowed Fileと意図した内容を確認せず承認した。
- [ ] `.vcxproj`、`.dsp`、`.dsw`、`.rc`、`.def`、`.idl`、`.mak`、またはAllowed Files外を編集した／編集しようとした。
- [ ] CP932、BOMなし、CRLFのいずれかが崩れた。
- [ ] approval画面のExecuteが完全一致する`Invoke-Vc6Build.ps1` commandではない。
- [ ] adapter開始前からsandbox project配下に`bin`または`obj`が存在する、またはadapter作成後にreparse／別主体の変更が見つかった。
- [ ] shell、任意command、Bazaar、network、実機、専用基板、driver、debuggerをBobが呼び出した／呼び出そうとした。
- [ ] attempt 0 Make以外で`TEAM_BOB_DEMO_FAULT`がinjectされた。
- [ ] 人工faultを実製品defectまたはVC6 qualificationの証拠として扱った。
- [ ] repairが2回を超えた、evidenceに根拠のないrepairを行った、またはattempt 0の実compiler evidence取得前に訓練用`#error`を変更した。
- [ ] `CODE_FAILED_STOP`、`ENVIRONMENT_FAILED`、`TIMED_OUT`、`INTEGRITY_FAILED`の後も継続した。
- [ ] final Rebuildとintegrity検査の前に`READY_FOR_HUMAN_REVIEW`を出した。
- [ ] 元working copyにbuild生成物またはAllowed Files外の変更が残った。

### Review／Bazaar／Test

- [ ] Bazaar status/diffが承認済みAllowed File以外の差分を示す。
- [ ] Bob、Stage、qualification、packet scriptがinit、add、commit、merge、tag、whoamiその他のBazaar writeを実行した／要求した。initial baseline bootstrapと承認済み変更commitは人だけが行う。
- [ ] 人の独立reviewでCritical不合格があるのにcommitしようとしている。
- [ ] Test taskが実装taskの状態を引き継いだ、または前工程SHA-256を検証していない。
- [ ] 拒否試験を専用fresh `green-implement` negative task以外で行った、またはTest modeの拒否をGreen境界の証拠にした。
- [ ] Open QA negative packetがlive rootのexternal `evidence\negative-packets`外にある、Stage生成の絶対path／SHA-256を確認していない、またはversioned workspaceへ追加された。
- [ ] negative試験でBobが禁止Edit／不一致Executeのtool requestを出した。人がmanual rejectしても試験は`FAIL`／即時`STOP`とする。
- [ ] 実機、リアルタイム、専用基板の未実施結果を合格として記録した。
- [ ] usage logにperson、operator、member、name、email、account、user IDなどの識別列／値がある。
- [ ] versioned `demo/docs/usage-log.csv`をruntime記録で変更した、または`C:\BobTeamDemo\evidence\usage-log.csv`以外へlive metricsを記録した。

### 終了／復元

- [ ] restore対象のmarkerまたはbackupが一致しない。
- [ ] restoreがworkspace、logs、evidenceを削除しようとしている。
- [ ] rehearsalまたはliveのworkspace／logs／evidenceを技術review前に削除した。
- [ ] Bobのpermissionまたは事前設定を復元・確認できない。
- [ ] `/permissions`でrehearsal／live demo folderをuntrust／removeしていない、または親／drive rootがtrustedのままである。

## 停止時に行うこと

1. 未承認のBob actionを`Reject`し、該当taskをそれ以上進めない。
2. 実行中のbuildがある場合はwrapperの終了／timeout evidenceを待ち、別commandで強制継続しない。
3. 現在のpacket、draft、result、CP932 build log、UTF-8 sidecar、qualification record、Bazaar read-only evidenceを保持する。
4. `DEMO-OPERATIONS-OWNER-ROLE`が事象、時刻、影響、保持pathを記録する。個人名はusage logへ入れない。
5. Bazaar commit、profile enablement、再Stage、削除、手動上書きは、原因と復元可能性を人がレビューするまで行わない。

停止は失敗を隠すためのrollbackではありません。証跡を保持し、「ライブ合格」「VC6 qualification」「実機合格」のいずれも主張しません。
