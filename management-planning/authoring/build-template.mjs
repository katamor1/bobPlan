import fs from 'node:fs/promises';
import path from 'node:path';
import { Workbook, SpreadsheetFile } from '@oai/artifact-tool';

// Run through Build-Template.ps1 so imports use the bundled runtime only.
const [schemaPath, outputPath, previewDir] = process.argv.slice(2);
const renderPreviews = process.argv.includes('--render');
if (!schemaPath || !outputPath || !previewDir) throw new Error('Expected schema, output, and preview paths.');
const schema = JSON.parse((await fs.readFile(schemaPath, 'utf8')).replace(/^\uFEFF/, ''));
const guidance = {
  Project: ['案件の範囲・期間と工数換算の条件を記入します。', '項目例: ProjectID、Scope、StartDate、DueDate、HoursPerDay、Synthetic'],
  Sources: ['要求の根拠となる資料を登録します。', 'Excel は対象シートと範囲を指定します。資料IDは重複させません。'],
  Standards: ['工程別の単位工数と、その根拠を記入します。', '工数の単位は人時です。暫定の基準は Provisional を Yes にします。'],
  Requirements: ['資料の出典位置、要求の解釈、受入条件を記入します。', '未確認の内容は確認事項に記録し、要求IDで結び付けます。'],
  People: ['要員ごとの担当可能工程とスキルを記入します。', '複数の工程・スキルは半角セミコロン（;）で区切ります。'],
  Capacity: ['要員・日付ごとの利用可能時間を人時で記入します。', '稼働できない日は 0、未確認の日は空欄にします。未登録日は未確認です。'],
  Tasks: ['要求を作業に分解し、成果物・完了条件・見積根拠を記入します。', '末端作業に担当者を1名設定します。親作業の工数・担当者は空欄にします。'],
  Allocations: ['末端作業の日別配分を人時で記入します。', '作業ごとの配分合計を見積工数に合わせます。日付は yyyy-mm-dd です。'],
  Questions: ['要求・作業の不明点と、確認後の対応内容を記入します。', '未解決事項は残して管理し、推測で確定値を埋めません。'],
  EstimateView: ['作業台帳から作成する見積の一覧です。', '親作業は末端作業を集計します。未確定の工数を含む合計は空欄です。'],
  WbsView: ['要求、作業の階層、成果物、担当者と日程を確認します。', '作業台帳を更新してから再出力します。親作業の日程は末端作業から集計します。'],
  ScheduleView: ['日別の作業配分と担当者の利用可能時間を確認します。', '利用可能時間が空欄の日は未確認です。過配分は点検結果で確認します。'],
  RedmineView: ['Redmine に転記する内容の確認用一覧です。', '作業ID・親作業IDは内部IDです。転記前に点検結果と確認事項を確認します。'],
  Checks: ['入力の不足、参照の不整合、日程と配分の問題を確認します。', 'Error は修正対象、Warning は未確認・要確認です。再点検して結果を更新します。'],
};
const widthByName = {
  Key: 25, Value: 26, Notes: 72, Path: 56, Interpretation: 48, AcceptanceCriteria: 48,
  Title: 42, Deliverable: 38, EstimateBasis: 45, Basis: 45, Question: 52, Resolution: 46,
  Description: 52, Subject: 42, Message: 64, SourceAnchor: 32, Skills: 36, Phases: 32,
  PredecessorIDs: 27, ReqIDs: 25, Code: 32, Name: 28,
};
function column(index) {
  let label = '';
  for (let n = index + 1; n > 0; n = Math.floor((n - 1) / 26)) label = String.fromCharCode(65 + (n - 1) % 26) + label;
  return label;
}
await fs.mkdir(path.dirname(outputPath), { recursive: true });
await fs.mkdir(previewDir, { recursive: true });
const workbook = Workbook.create();
const inspection = [];
for (const definition of schema.tables) {
  const sheet = workbook.worksheets.add(definition.sheet);
  const last = column(definition.columns.length - 1);
  sheet.showGridLines = false;
  sheet.tabColor = definition.role === 'input' ? '#B88934' : '#39577B';
  const frame = sheet.getRange(`A1:${last}7`);
  frame.format.font = { name: 'Arial', size: 11, color: '#25334A' };
  frame.format.rowHeight = 26;
  frame.format.verticalAlignment = 'center';
  sheet.getRange('A1').values = [[definition.sheet]];
  sheet.getRange('A1').format.font = { name: 'Arial', size: 17, bold: true, color: '#203653' };
  sheet.getRange(`A1:${last}1`).format.rowHeight = 34;
  sheet.getRange(`A1:${last}1`).format.borders = { bottom: { style: 'thin', color: '#A5B0BE' } };
  sheet.getRange('A2').values = [[guidance[definition.key][0]]];
  sheet.getRange('A3').values = [[guidance[definition.key][1]]];
  sheet.getRange(`A2:${last}3`).format.font = { name: 'Arial', size: 10, color: '#596579' };
  sheet.getRange(`A${schema.headerRow}:${last}${schema.headerRow}`).values = [definition.columns.map(c => c.label)];
  sheet.getRange(`A${schema.dataRow}:${last}${schema.dataRow}`).values = [definition.columns.map(() => null)];
  const table = sheet.tables.add(`A${schema.headerRow}:${last}${schema.dataRow}`, true, definition.table);
  table.style = 'TableStyleMedium2';
  table.showFilterButton = true;
  const header = sheet.getRange(`A${schema.headerRow}:${last}${schema.headerRow}`);
  header.format.fill = '#203653';
  header.format.font = { name: 'Arial', size: 11, bold: true, color: '#FFFFFF' };
  header.format.rowHeight = 40;
  header.format.wrapText = true;
  header.format.horizontalAlignment = 'center';
  header.format.borders = { insideVertical: { style: 'thin', color: '#FFFFFF' } };
  sheet.getRange(`A5:${last}6`).format.fill = definition.role === 'input' ? '#FFF6DE' : '#EFF3F8';
  sheet.getRange(`A5:${last}6`).format.rowHeight = 30;
  for (let i = 0; i < definition.columns.length; i++) {
    const c = definition.columns[i];
    const letter = column(i);
    sheet.getRange(`${letter}1:${letter}7`).format.columnWidth = widthByName[c.name] ?? (c.type === 'date' ? 17 : Math.max(20, c.label.length * 2 + 4));
    const body = sheet.getRange(`${letter}5:${letter}6`);
    body.setNumberFormat(c.type === 'date' ? 'yyyy-mm-dd' : c.type === 'number' ? '#,##0.######' : '@');
    body.format.horizontalAlignment = c.type === 'number' ? 'right' : 'left';
    body.format.wrapText = c.type === 'text';
  }
  sheet.freezePanes.freezeRows(schema.headerRow);
  const inspected = await workbook.inspect({ kind: 'table', range: `'${definition.sheet}'!A4:${last}5`, include: 'values,formulas', tableMaxRows: 2, tableMaxCols: definition.columns.length, maxChars: 4000 });
  inspection.push({ key: definition.key, result: inspected.ndjson });
  if (renderPreviews) {
    const preview = await workbook.render({ sheetName: definition.sheet, range: `A1:${last}7`, scale: 1.5, format: 'png' });
    await fs.writeFile(path.join(previewDir, `${definition.key}.png`), new Uint8Array(await preview.arrayBuffer()));
  }
  console.log(`Inspected: ${definition.sheet}`);
}
const errors = await workbook.inspect({ kind: 'match', searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A|#NUM!|#NULL!|#SPILL!|#CALC!', options: { useRegex: true, maxResults: 50 }, summary: 'Template formula error scan' });
await fs.writeFile(path.join(previewDir, 'inspection.json'), JSON.stringify({ font: 'Arial (installed on Windows; Japanese uses system fallback)', tables: inspection, formulaErrors: errors.ndjson }, null, 2));
const xlsx = await SpreadsheetFile.exportXlsx(workbook);
await xlsx.save(outputPath);
console.log(`Saved ${outputPath}`);
