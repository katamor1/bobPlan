# MSBUILD DEMO ADAPTER — NOT VC6 QUALIFICATION

このディレクトリは IBM Bob IDE の説明用に用意した synthetic-only の MSBuild デモです。VC6 の emulation、qualification、実機検証ではありません。machine-control hardware、control network、production repository、credentials、customer data には接続しません。

合成要件は Customer-A の cycle-overrun 監視だけです。warm-up 中は Warning を抑止して連続回数を reset し、warm-up 後は 8,000 microseconds 以上が 3 cycles 連続した場合だけ Warning にします。8,000 未満では直ちに Normal に戻して回数を reset します。board、driver、ABI、control period は変更しません。

Allowed File: `demo/CycleWatch/src/CycleWatch.cpp`

header が counter と status の storage をあらかじめ所有するため、ライブ修復で ABI や class layout は変わりません。checked-in baseline は安全ですが意図的に不完全で、最初の post-warm-up overrun で Warning にします。`CycleWatchTests.cpp` は要求どおりの三連続動作を表現しますが、project はテスト executable を build するだけで自動実行しません。

CP932 の legacy assets では U+2014 em dash を表現できないため、banner の documented fallback として ASCII hyphen (`MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION`) を使います。

Office inputs は Word/Excel COM を使わず `tools/New-DemoOfficeInputs.ps1` で再生成します。安定した source anchor は requirements の `word/document.xml` と QA table の `xl/tables/table1.xml`（`A1:B6`）です。binary 全体の ZIP hash ではなく、OOXML の entry、relationship、可視内容を evidence として扱います。
