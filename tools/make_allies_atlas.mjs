// W6 map spots in the Vizor style. Uses the launcher's Playwright and the installed Edge.
// node tools/make_allies_atlas.mjs [--icons DIR] [--gamedata DIR] [--preview DIR]
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const root = fileURLToPath(new URL('../', import.meta.url));
const { values } = parseArgs({ options: {
  icons: { type: 'string', default: 'E:/coop-hud-design/vizor/icons_v2' },
  gamedata: { type: 'string', default: path.join(root, 'gamedata') },
  preview: { type: 'string' },
} });
const require = createRequire(path.resolve(root, '../raylink-launcher/package.json'));
const { chromium } = require('playwright-core');

const atlasSize = 256;
// The W6 texture ids and rects are also used by existing layouts. The white rect is inset into a 16 px block.
const cells = [
  ['arrow_64', 0, 0, 64, 'arrow'],
  ['down_64', 68, 0, 64, 'down'],
  ['dead_64', 136, 0, 64, 'dead'],
  ['badge_48', 204, 0, 48, 'badge'],
  ['arrow_32', 0, 68, 32, 'arrow'],
  ['dead_32', 36, 68, 32, 'dead'],
  ['ptr_32', 72, 68, 32, 'pointer'],
  ['star_32', 108, 68, 32, 'star'],
  ['down_48', 144, 68, 48, 'down'],
  ['white', 200, 72, 8, 'white'],
];

async function render({ sources, cells, atlasSize, preview }) {
  const ns = 'http://www.w3.org/2000/svg';
  const parse = (markup) => {
    const svg = new DOMParser().parseFromString(markup, 'image/svg+xml').documentElement;
    if (svg.localName !== 'svg' || svg.namespaceURI !== ns) throw new Error('Invalid SVG');
    return svg;
  };
  const read = (name) => parse(sources[name]);
  const outline = (shape, width) => {
    const dark = shape.cloneNode();
    dark.setAttribute('fill', 'none');
    dark.setAttribute('stroke', '#101010');
    dark.setAttribute('stroke-width', width);
    dark.setAttribute('stroke-linejoin', 'round');
    shape.before(dark);
    return dark;
  };

  const arrow = (name) => {
    const svg = read(name);
    // A single map-spot tint multiplies the whole glyph. The white rim and spine retain the
    // exact slot tint while the neutral fill and dark outline give them contrast.
    svg.setAttribute('style', 'color:#c6c6c6;--edge:#fff');
    const shape = svg.querySelector('path[fill="currentColor"]');
    const dark = outline(shape, '3.8');
    const spine = shape.nextElementSibling;
    if (name === 'map_arrow_dead') {
      const base = document.createElementNS(ns, 'g');
      base.setAttribute('opacity', '0.7');
      dark.before(base);
      base.append(dark, shape, spine);
      // The dead marker is 12 UI units on the minimap, so widen the slash for that size.
      const slash = svg.querySelector('[stroke="#B9B4A8"]');
      const slashShadow = slash.previousElementSibling;
      slashShadow.setAttribute('stroke', 'rgba(8,8,8,.85)');
      slashShadow.setAttribute('stroke-width', '4.6');
      slash.setAttribute('stroke', '#fff');
      slash.setAttribute('stroke-width', '2.8');
    }
    if (name === 'map_pointer') {
      const arc = svg.querySelector('path');
      arc.setAttribute('stroke', '#fff');
      arc.setAttribute('transform', 'translate(0 -.7)');
      outline(arc, '3.6');
    }
    svg.setAttribute('viewBox', '-1 -1 26 26');
    return svg;
  };

  const downBadge = (standalone) => {
    const svg = read('map_badge_down');
    const badge = document.createElementNS(ns, 'g');
    badge.setAttribute('transform', standalone
      ? 'translate(12 12) scale(1.65) translate(-18.6 -18.6)'
      : 'translate(18.6 18.6) scale(.8) translate(-18.6 -18.6)');
    badge.append(svg.querySelector('circle'), svg.querySelector('path'));
    if (!standalone) {
      // W6 draws this spot over the rotating arrow. Keep its centre clear and the badge upright.
      const ring = document.createElementNS(ns, 'circle');
      ring.setAttribute('cx', '12');
      ring.setAttribute('cy', '12');
      ring.setAttribute('r', '9.2');
      ring.setAttribute('stroke', 'var(--down,#E3412F)');
      ring.setAttribute('stroke-width', '1.4');
      svg.append(ring);
      outline(ring, '2.8');
    }
    svg.append(badge);
    return svg;
  };

  const star = () => {
    // The W6 compatibility cell, still an upright five-pointed host star.
    const points = Array.from({ length: 10 }, (_, i) => {
      const angle = Math.PI * (i / 5 - 0.5);
      const r = i % 2 ? 4.32 : 9.84;
      return `${12 + r * Math.cos(angle)},${12.72 + r * Math.sin(angle)}`;
    }).join(' ');
    return parse(`<svg xmlns="${ns}" viewBox="0 0 24 24"><polygon points="${points}"
      fill="#fff" stroke="#101010" stroke-width="1.6" stroke-linejoin="round" paint-order="stroke"/></svg>`);
  };

  const glyphs = {
    arrow: arrow('map_arrow'),
    dead: arrow('map_arrow_dead'),
    pointer: arrow('map_pointer'),
    down: downBadge(false),
    badge: downBadge(true),
    star: star(),
  };
  const canvas = (width, height) => Object.assign(document.createElement('canvas'), { width, height });
  const atlas = canvas(atlasSize, atlasSize);
  const ctx = atlas.getContext('2d');
  ctx.imageSmoothingQuality = 'high';

  async function draw(ctx, svg, x, y, size) {
    const copy = svg.cloneNode(true);
    copy.setAttribute('width', size * 4);
    copy.setAttribute('height', size * 4);
    const image = new Image();
    image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(copy));
    await image.decode();
    ctx.drawImage(image, x, y, size, size);
  }

  for (const [, x, y, size, glyph] of cells) {
    if (glyph === 'white') {
      ctx.fillStyle = '#fff';
      ctx.fillRect(x - 4, y - 4, size + 8, size + 8);
    } else {
      await draw(ctx, glyphs[glyph], x, y, size);
    }
  }

  const pixels = ctx.getImageData(0, 0, atlasSize, atlasSize).data;
  let binary = '';
  for (let i = 0; i < pixels.length; i += 0x8000) {
    binary += String.fromCharCode(...pixels.subarray(i, i + 0x8000));
  }
  const rgba = btoa(binary);
  if (!preview) return { rgba };

  // Render the full reference set separately. Only existing W6 map states consume this atlas in game.
  const sheet = canvas(640, Math.ceil(Object.keys(sources).length / 5) * 96);
  const sheetCtx = sheet.getContext('2d');
  sheetCtx.fillStyle = '#292a24';
  sheetCtx.fillRect(0, 0, sheet.width, sheet.height);
  sheetCtx.fillStyle = '#f1ecdf';
  sheetCtx.font = '10px monospace';
  sheetCtx.textAlign = 'center';
  for (const [index, name] of Object.keys(sources).entries()) {
    const x = (index % 5) * 128;
    const y = Math.floor(index / 5) * 96;
    await draw(sheetCtx, read(name), x + 30, y + 4, 68);
    sheetCtx.fillText(name, x + 64, y + 86);
  }
  return { rgba, atlas: atlas.toDataURL('image/png'), sheet: sheet.toDataURL('image/png') };
}

function encodeDds(rgba) {
  const header = Buffer.alloc(128);
  header.write('DDS ');
  const fields = {
    4: 124, 8: 0x100f, 12: atlasSize, 16: atlasSize, 20: atlasSize * 4, 28: 1,
    76: 32, 80: 0x41, 88: 32, 92: 0x00ff0000, 96: 0x0000ff00, 100: 0x000000ff,
    104: 0xff000000, 108: 0x1000,
  };
  for (const [offset, value] of Object.entries(fields)) header.writeUInt32LE(value, Number(offset));
  const bgra = Buffer.from(rgba, 'base64');
  for (let i = 0; i < bgra.length; i += 4) [bgra[i], bgra[i + 2]] = [bgra[i + 2], bgra[i]];
  return Buffer.concat([header, bgra]);
}

const sources = Object.fromEntries(fs.readdirSync(values.icons)
  .filter((name) => /^map_(?:arrow|badge|pointer|self)(?:_\w+)?\.svg$/.test(name))
  .sort()
  .map((name) => [path.basename(name, '.svg'), fs.readFileSync(path.join(values.icons, name), 'utf8')]));

const browser = await chromium.launch({ channel: 'msedge', headless: true });
let rendered;
try {
  const page = await browser.newPage();
  rendered = await page.evaluate(render, { sources, cells, atlasSize, preview: Boolean(values.preview) });
} finally {
  await browser.close();
}

const ddsDir = path.join(values.gamedata, 'textures/ui/coop');
const xmlDir = path.join(values.gamedata, 'configs/ui/textures_descr');
fs.mkdirSync(ddsDir, { recursive: true });
fs.mkdirSync(xmlDir, { recursive: true });
fs.writeFileSync(path.join(ddsDir, 'ui_coop_allies.dds'), encodeDds(rendered.rgba));
const xml = [
  '<?xml version="1.0" encoding="windows-1251"?>',
  '<!-- Anomaly Coop (W6 allies UI, Vizor): textures\\ui\\coop\\ui_coop_allies.dds, 256x256 A8R8G8B8, no mips.',
  '     Generated by tools\\make_allies_atlas.mjs. White and grey icons take the map spot tint.',
  '     coop_ally_down_* and coop_ally_badge_48 are pre-coloured; coop_ally_white is inset 4 px. -->',
  '<w>', '\t<file name="ui\\coop\\ui_coop_allies">',
  ...cells.map(([id, x, y, size]) =>
    `\t\t<texture id="coop_ally_${id}" x="${x}" y="${y}" width="${size}" height="${size}"/>`),
  '\t</file>', '</w>', '',
].join('\r\n');
fs.writeFileSync(path.join(xmlDir, 'ui_coop_allies.xml'), xml);

if (values.preview) {
  fs.mkdirSync(values.preview, { recursive: true });
  for (const [filename, data] of [['ui_coop_allies.png', rendered.atlas], ['vizor_svg_sources.png', rendered.sheet]]) {
    fs.writeFileSync(path.join(values.preview, filename), Buffer.from(data.split(',')[1], 'base64'));
  }
}
console.log(`ui_coop_allies: ${cells.length} W6 cells, ${Object.keys(sources).length} Vizor SVGs found`);
