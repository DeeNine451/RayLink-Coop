// Anomaly Coop: the icon atlas of the HUD «Визор» (TZ Р55-Р70, temp/hud3/CONTRACT.md): textures\ui\coop\ui_coop_hud3.dds
// (A8R8G8B8, one level) + configs\ui\textures_descr\ui_coop_hud3.xml. Icons come from the design's SVGs (white: the scripts
// tint them with SetTextureColor), the service sprites (dot, cross, brackets, the panel bracket, pulse frames, white) are
// drawn here. Rendered by the headless Edge of playwright-core (raylink-launcher), as tools/make_font_atlas.mjs does.
//   node tools/make_hud3_atlas.mjs [--icons E:/coop-hud-design/vizor/icons_v2] [--preview temp/hud3/atlas.png]
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire('D:/Projects/ForEverything/raylink-launcher/package.json');
const { chromium } = require('playwright-core');
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const arg = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const ICONS = arg('--icons', 'E:/coop-hud-design/vizor/icons_v2');
const PREVIEW = arg('--preview', '');
const W = 512, H = 512, CELL = 32;

const svgs = fs.readdirSync(ICONS).filter((f) => f.endsWith('.svg')).sort().map((f) => ({
  id: 'coop_h3_' + f.slice(0, -4),
  svg: fs.readFileSync(path.join(ICONS, f), 'utf8')
    .replace(/style="color:[^"]*"/, 'style="color:#ffffff"')
    .replace(/<title>[\s\S]*?<\/title>/, ''),
}));

async function render(a) {
  const c = document.createElement('canvas');
  c.width = a.W; c.height = a.H;
  const g = c.getContext('2d');
  const rects = [];
  let x = 0, y = 0;
  const place = (w, h) => {
    if (x + w > a.W) { x = 0; y += a.rowH; }
    const r = { x, y, w, h };
    x += w;
    return r;
  };
  // icons, one 32x32 cell each (the SVGs are on a 24 grid)
  for (const s of a.svgs) {
    const r = place(a.CELL, a.CELL);
    const img = new Image();
    const url = 'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(s.svg.replace('<svg ', `<svg width="${a.CELL}" height="${a.CELL}" `).replace(/width="24" height="24" /, ''))));
    await new Promise((ok, bad) => { img.onload = ok; img.onerror = bad; img.src = url; });
    g.drawImage(img, r.x, r.y, a.CELL, a.CELL);
    rects.push({ id: s.id, ...r });
  }
  // service sprites in white, on their own row
  x = 0; y += a.rowH;
  const sprite = (id, w, h, draw) => {
    const r = place(w, h);
    g.save(); g.translate(r.x, r.y); g.strokeStyle = '#fff'; g.fillStyle = '#fff'; draw(g, w, h); g.restore();
    rects.push({ id, ...r });
  };
  sprite('coop_h3_white', 8, 8, (g) => g.fillRect(0, 0, 8, 8));
  sprite('coop_h3_dot', 16, 16, (g) => { g.beginPath(); g.arc(8, 8, 5, 0, Math.PI * 2); g.fill(); });
  sprite('coop_h3_cross', 24, 24, (g) => { g.lineWidth = 3; g.lineCap = 'square'; g.beginPath(); g.moveTo(5, 5); g.lineTo(19, 19); g.moveTo(19, 5); g.lineTo(5, 19); g.stroke(); });
  const corner = (id, flipX, flipY) => sprite(id, 16, 16, (g) => {
    g.lineWidth = 2;
    g.translate(flipX ? 16 : 0, flipY ? 16 : 0); g.scale(flipX ? -1 : 1, flipY ? -1 : 1);
    g.beginPath(); g.moveTo(1, 14); g.lineTo(1, 1); g.lineTo(14, 1); g.stroke();
  });
  corner('coop_h3_bracket_tl', false, false);
  corner('coop_h3_bracket_tr', true, false);
  corner('coop_h3_bracket_bl', false, true);
  corner('coop_h3_bracket_br', true, true);
  sprite('coop_h3_bracket_l', 8, 48, (g) => { g.lineWidth = 2; g.beginPath(); g.moveTo(7, 1); g.lineTo(1, 1); g.lineTo(1, 47); g.lineTo(7, 47); g.stroke(); });
  // pulse frames for the team panel's dying row (coop_core_hud.script UICoopParty:Beat, V.pulse_w/h/base): ONE heart beat in a
  // 23x21 cell, its baseline 15 px from the top; frame k draws the beat from the left up to (k+1)/8 of the width.
  const beat = (p) => { // p in [0,1] -> y offset in px from the baseline (negative = up)
    if (p < 0.18) return 0;
    if (p < 0.30) return -2 * Math.sin((p - 0.18) / 0.12 * Math.PI);
    if (p < 0.38) return 0;
    if (p < 0.43) return 3 * (p - 0.38) / 0.05;
    if (p < 0.50) return 3 - 17 * (p - 0.43) / 0.07;
    if (p < 0.57) return -14 + 16 * (p - 0.50) / 0.07;
    if (p < 0.62) return 2 - 2 * (p - 0.57) / 0.05;
    if (p < 0.82) return -3 * Math.sin((p - 0.62) / 0.20 * Math.PI);
    return 0;
  };
  for (let f = 0; f < 8; f++) {
    sprite('coop_h3_pulse_' + f, 23, 21, (g) => {
      const upto = 23 * (f + 1) / 8;
      g.lineWidth = 1.5; g.lineJoin = 'round'; g.beginPath();
      for (let px = 0; px <= upto + 0.001; px += 0.5) { const yy = 15 + beat(px / 23); if (px === 0) g.moveTo(px, yy); else g.lineTo(px, yy); }
      g.stroke();
    });
  }
  const d = g.getImageData(0, 0, a.W, a.H).data;
  let bin = '';
  for (let i = 0; i < d.length; i += 0x8000) bin += String.fromCharCode.apply(null, d.subarray(i, i + 0x8000));
  return { rgba: btoa(bin), rects, png: c.toDataURL('image/png').split(',')[1] };
}

function dds(w, h, rgba) {
  const hdr = Buffer.alloc(128);
  hdr.write('DDS ', 0, 'latin1');
  hdr.writeUInt32LE(124, 4); hdr.writeUInt32LE(0x100f, 8); hdr.writeUInt32LE(h, 12); hdr.writeUInt32LE(w, 16);
  hdr.writeUInt32LE(w * 4, 20); hdr.writeUInt32LE(1, 28); hdr.writeUInt32LE(32, 76); hdr.writeUInt32LE(0x41, 80);
  hdr.writeUInt32LE(32, 88); hdr.writeUInt32LE(0x00ff0000, 92); hdr.writeUInt32LE(0x0000ff00, 96);
  hdr.writeUInt32LE(0x000000ff, 100); hdr.writeUInt32LE(0xff000000, 104); hdr.writeUInt32LE(0x1000, 108);
  const px = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const a = rgba[i * 4 + 3];
    // canvas gives straight (unpremultiplied) RGBA; white glyphs: keep the colour white where any alpha
    px[i * 4] = a ? rgba[i * 4 + 2] : 0; px[i * 4 + 1] = a ? rgba[i * 4 + 1] : 0; px[i * 4 + 2] = a ? rgba[i * 4] : 0; px[i * 4 + 3] = a;
  }
  return Buffer.concat([hdr, px]);
}

const b = await chromium.launch({ channel: 'msedge', headless: true });
try {
  const p = await b.newPage();
  await p.setContent('<!doctype html><meta charset="utf-8"><body></body>');
  const r = await p.evaluate(render, { svgs, W, H, CELL, rowH: CELL });
  const rgba = Buffer.from(r.rgba, 'base64');
  const out = path.join(ROOT, 'gamedata/textures/ui/coop/ui_coop_hud3.dds');
  fs.writeFileSync(out, dds(W, H, rgba));
  const xml = ['<?xml version="1.0" encoding="windows-1251"?>',
    '<!-- Anomaly Coop HUD «Визор» (TZ Р55-Р70, temp\\hud3\\CONTRACT.md): textures\\ui\\coop\\ui_coop_hud3.dds, 512x512 A8R8G8B8.',
    '     Generated by tools\\make_hud3_atlas.mjs from the design SVGs (white, tinted by the scripts) and drawn service sprites. -->',
    '<w>', '\t<file name="ui\\coop\\ui_coop_hud3">',
    ...r.rects.map((q) => `\t\t<texture id="${q.id}" x="${q.x}" y="${q.y}" width="${q.w}" height="${q.h}"/>`),
    '\t</file>', '</w>', ''].join('\r\n');
  fs.writeFileSync(path.join(ROOT, 'gamedata/configs/ui/textures_descr/ui_coop_hud3.xml'), Buffer.from(xml.replace('«Визор»', 'Vizor'), 'latin1'));
  if (PREVIEW) fs.writeFileSync(path.join(ROOT, PREVIEW), Buffer.from(r.png, 'base64'));
  console.log(`ui_coop_hud3: ${r.rects.length} sprites, max y ${Math.max(...r.rects.map((q) => q.y + q.h))}`);
} finally {
  await b.close();
}
