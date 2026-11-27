// Makes WSLCRMTests/Fixtures/template_builder_compile.json from the web's own designer code, so the app's port
// (Features/Invoices/Templates/TemplateBuilder.swift) is checked against it (TemplateBuilderTests).
//
//   node scripts/gen-template-builder-fixtures.mjs <opsapi>/opsapi-dashboard/components/templates/builder \
//        WSLCRMTests/Fixtures/template_builder_compile.json
//
// Needs Node 23.6 or later (it runs the TypeScript directly).
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [builderDir, outFile] = process.argv.slice(2);
const dir = mkdtempSync(join(tmpdir(), 'builder-'));
writeFileSync(join(dir, 'model.ts'), readFileSync(join(builderDir, 'model.ts')));
writeFileSync(join(dir, 'compile.ts'), readFileSync(join(builderDir, 'compile.ts'), 'utf8').replace("from './model'", "from './model.ts'"));
const { PRESETS, makePiece } = await import(join(dir, 'model.ts'));
const { compile } = await import(join(dir, 'compile.ts'));

// Deterministic piece ids: p1, p2… in order.
const stable = (d) => { let i = 0; d.pieces = d.pieces.map((p) => ({ ...p, id: `p${++i}` })); return d; };
const out = [];
const add = (name, d) => {
  const c = compile(d);
  const e = compile(d, { editor: true });
  out.push({ name, doc: d, html: c.html, css: c.css, footer_html: c.footer_html, margins: c.margins, editor_html: e.html });
};
for (const kind of ['invoice', 'order']) {
  for (const pr of PRESETS) add(`${pr.key}-${kind}`, stable(pr.make(kind)));
}
// A page that uses what the presets don't.
const k = 'invoice';
const d = stable(PRESETS[0].make(k));
d.page = { font: 'times', size: 10.5, color: '', margins: { tb: 12.5, lr: 18 }, paper: 'Letter' };
d.header.h = 81.333;
d.pieces.push(
  { ...makePiece('text', k, 'header', 10.126, 3.3333, 50.5, 7.25), id: 'x1', text: 'VAT number: {{ company.vat_number }} & <b>"x"</b>\nSecond {% if %} line {{ invoice.number | upper }}',
    style: { size: 9, italic: true, underline: true, opacity: 85, valign: 'middle', borderWidth: 0.75, borderColor: 'accent', borderStyle: 'dashed', radius: 3, padding: 1.5, spacing: 0.1, lineHeight: 1.2, font: 'mono' } },
  { ...makePiece('text', k, 'header', 0, 0, 30, 5), id: 'x2', text: 'Always {{ customer.name }}', show: { whenFilled: false }, style: { valign: 'bottom', color: '' } },
  { ...makePiece('image', k, 'header', 120, 40, 40, 20), id: 'x3', src: 'data:image/png;base64,iVBORw0KGgo="&', style: { align: 'center' } },
  { ...makePiece('image', k, 'after', 0, 0, 20, 10), id: 'x4' },
  { ...makePiece('vat', k, 'after', 0, 20, 90, 14), id: 'x5' },
  { ...makePiece('amount', k, 'header', 0, 60, 70, 18), id: 'x6', show: { label: false, due: true } },
  { ...makePiece('box', k, 'header', 5, 5, 20, 20), id: 'x7', hidden: true },
  { ...makePiece('details', k, 'header', 100, 0, 80, 30), id: 'x8', names: { number: 'Inv <#>', due: 'Pay by' }, show: { number: true, date: false, due: true, po: true, project: false, by: true },
    style: { table: 'grid', gridColor: '', labelBg: '#eeeeee', valueWidth: 27.35, plain: true } },
  { ...makePiece('totals', k, 'after', 100, 40, 80, 30), id: 'x9', names: { balance: 'Owing now' }, style: { highlight: '#0f172a', highlightText: '' } },
  { ...makePiece('payment', k, 'after', 0, 40, 95, 30), id: 'x10', text: 'Pay us:', note: 'Thanks\nreally', show: { label: false, method: true, reference: false } },
  { ...makePiece('terms', k, 'after', 0, 70, 180, 12), id: 'x11', show: { label: true, days: false } },
  { ...makePiece('customer', k, 'header', 0, 30, 80, 24), id: 'x12', label: undefined, show: { label: true, name: false, email: true, address: false } },
  { ...makePiece('logo', k, 'header', 0, 0, 40, 15), id: 'x13', style: { align: 'center' } },
);
d.items = { ...d.items, lines: 'none', stripe: '', headerBg: '', headerColor: '', upper: false, headerCenter: true, size: 9.25, padding: 4.5, marginTop: 3.5, marginBottom: 0, color: '' };
d.items.columns[1].label = 'What & <why>';
d.items.columns[6].show = true;
d.footer = { left: 'Thanks & bye\n{{ company.name }}', pageNumbers: false, size: 8, color: '', center: true, line: true };
add('custom-invoice', d);
const o = stable(PRESETS[2].make('order'));
o.footer = { left: '', pageNumbers: true, size: 7, color: 'accent', center: false, line: false };
o.items = { ...o.items, lines: 'grid' };
o.pieces.push({ ...makePiece('amount', 'order', 'header', 0, 60, 70, 18), id: 'y1' }, { ...makePiece('status', 'order', 'header', 0, 70, 30, 6), id: 'y2' });
add('custom-order', o);
// Awkward numbers: rounding to 0.01 and JavaScript's own number printing.
const w = stable(PRESETS[1].make('invoice'));
w.page.size = 9.1; w.page.margins = { tb: 12.345, lr: 14.995 }; w.header.h = 92.005; w.after.h = 70.125;
w.pieces[0] = { ...w.pieces[0], x: 12.345, y: 0.125, w: 44.995, h: 16.004, style: { ...w.pieces[0].style, opacity: 100, spacing: 0, lineHeight: 1, weight: 650, size: 7.1, radius: 0.333, borderWidth: 0.1, borderColor: '#000000', borderStyle: 'dotted' } };
w.pieces[1] = { ...w.pieces[1], style: { ...w.pieces[1].style, opacity: 33.3, padding: 1/3, table: 'grid', valueWidth: 26.666 } };
w.items = { ...w.items, size: 8.75, padding: 4.1, marginTop: 1/3, marginBottom: 2.5 };
w.items.columns[3].width = 14.5;
w.footer = { ...w.footer, size: 7.25 };
add('numbers-invoice', w);
writeFileSync(outFile, JSON.stringify(out));
console.log('wrote', out.length);
