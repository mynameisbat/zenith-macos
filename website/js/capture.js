// Screen capture with the loupe, the annotation editor, and text/QR recognition ("OCR") over this page.
// A browser cannot read its own pixels, so the "screen" is repainted from the page: backgrounds, images,
// canvases and every word, at their real positions. Recognition reads the words straight from the page.
import {
  $, $$, bus, esc, icon, html, settings, notify, registerAction, registerWindow, openWindow, closeWindow,
  isWindowOpen, playSound, captureKeys, clamp, isMac, frontWindow, reduceMotion, codeOf,
} from './core.js';
import { sample } from './desktop.js';

// ---------------------------------------------------------------- reading words off the page

const SKIP_TEXT = 'script, style, svg, .sr-only, .scrim, .capture-overlay, .menu-layer, .toast-layer, noscript, [aria-hidden="true"]';

function visibleText(node) {
  const p = node.parentElement;
  if (!p || p.closest(SKIP_TEXT)) return false;
  return node.nodeValue.trim().length > 0;
}

/** Every word under `root` with its on-screen rectangle. */
function pageWords(root = $('#screen'), within = null) {
  const out = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => (visibleText(n) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT),
  });
  const range = document.createRange();
  let node;
  let guard = 0;
  while ((node = walker.nextNode()) && guard < 12000) {
    const pr = node.parentElement.getBoundingClientRect();
    if (!pr.width || !pr.height) continue;
    if (within && !intersects(pr, within)) continue;
    const re = /\S+/g;
    let m;
    while ((m = re.exec(node.nodeValue))) {
      guard++;
      range.setStart(node, m.index);
      range.setEnd(node, m.index + m[0].length);
      const r = range.getClientRects()[0];
      if (!r || !r.width) continue;
      out.push({ text: m[0], rect: r, el: node.parentElement });
    }
  }
  return out;
}

/** Words inside a textarea, measured with a mirror element laid over it. */
function textareaWords(ta) {
  const cs = getComputedStyle(ta);
  const r = ta.getBoundingClientRect();
  const mirror = document.createElement('div');
  ['fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'lineHeight', 'letterSpacing', 'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'borderTopWidth', 'borderLeftWidth', 'boxSizing', 'tabSize'].forEach((p) => { mirror.style[p] = cs[p]; });
  Object.assign(mirror.style, { position: 'fixed', left: `${r.left}px`, top: `${r.top - ta.scrollTop}px`, width: `${ta.clientWidth}px`, whiteSpace: 'pre-wrap', overflowWrap: 'break-word', visibility: 'hidden', pointerEvents: 'none' });
  mirror.textContent = ta.value;
  document.body.append(mirror);
  const out = [];
  const range = document.createRange();
  const text = mirror.firstChild;
  const re = /\S+/g;
  let m;
  while (text && (m = re.exec(ta.value))) {
    range.setStart(text, m.index);
    range.setEnd(text, m.index + m[0].length);
    const rr = range.getClientRects()[0];
    if (rr && rr.top >= r.top - 2 && rr.bottom <= r.bottom + 2) out.push({ text: m[0], rect: rr, el: ta, color: cs.color, font: cs.font });
  }
  mirror.remove();
  return out;
}

const intersects = (a, b) => a.left < b.left + b.width && a.left + a.width > b.left && a.top < b.top + b.height && a.top + a.height > b.top;

/** Canvas texts of Sample.png, in screen coordinates. */
function sampleWords() {
  const cv = $('#win-viewer canvas.sample');
  if (!cv || !isWindowOpen('viewer')) return [];
  const r = cv.getBoundingClientRect();
  const k = r.width / sample.size.w;
  return sample.texts.map((t) => ({ text: t.text, rect: new DOMRect(r.left + t.x * k, r.top + t.y * k, t.w * k, t.h * k), el: cv }));
}

function topElementIs(word) {
  const cx = word.rect.left + word.rect.width / 2;
  const cy = word.rect.top + word.rect.height / 2;
  if (cx < 0 || cy < 0 || cx > window.innerWidth || cy > window.innerHeight) return false;
  const hit = document.elementFromPoint(cx, cy);
  return !!hit && (hit === word.el || word.el.contains(hit) || hit.contains(word.el));
}

function linesFrom(words) {
  const sorted = [...words].sort((a, b) => a.rect.top - b.rect.top || a.rect.left - b.rect.left);
  const lines = [];
  for (const w of sorted) {
    const cy = w.rect.top + w.rect.height / 2;
    const line = lines.find((l) => Math.abs(l.cy - cy) < Math.max(4, w.rect.height * 0.45) && l.el === (w.el.tagName === 'CANVAS' ? w.el : l.el));
    if (line) line.words.push(w); else lines.push({ cy, words: [w], el: w.el.tagName === 'CANVAS' ? w.el : null });
  }
  return lines
    .sort((a, b) => a.cy - b.cy)
    .map((l) => l.words.sort((a, b) => a.rect.left - b.rect.left).map((w) => w.text).join(' '));
}

function recognize(sel) {
  // QR code first: if most of it is inside the selection, its payload is the result.
  const cv = $('#win-viewer canvas.sample');
  if (cv && isWindowOpen('viewer')) {
    const r = cv.getBoundingClientRect();
    const k = r.width / sample.size.w;
    const q = new DOMRect(r.left + sample.qr.x * k, r.top + sample.qr.y * k, sample.qr.w * k, sample.qr.h * k);
    const ix = Math.max(0, Math.min(q.right, sel.left + sel.width) - Math.max(q.left, sel.left));
    const iy = Math.max(0, Math.min(q.bottom, sel.top + sel.height) - Math.max(q.top, sel.top));
    const centre = { rect: new DOMRect(q.left + q.width / 2 - 1, q.top + q.height / 2 - 1, 2, 2), el: cv };
    if ((ix * iy) / (q.width * q.height) > 0.7 && topElementIs(centre)) return { kind: 'qr', text: sample.qr.payload };
  }
  const inside = (w) => {
    const cx = w.rect.left + w.rect.width / 2;
    const cy = w.rect.top + w.rect.height / 2;
    return cx >= sel.left && cx <= sel.left + sel.width && cy >= sel.top && cy <= sel.top + sel.height;
  };
  const words = [
    ...pageWords($('#screen'), sel),
    ...$$('#screen textarea').filter((t) => t.offsetParent).flatMap(textareaWords),
    ...sampleWords(),
  ].filter(inside).filter(topElementIs);
  const lines = linesFrom(words);
  return lines.length ? { kind: 'text', text: lines.join('\n'), lines: lines.length } : null;
}

// ---------------------------------------------------------------- repainting the screen

function cssColorAlpha(c) {
  const m = c.match(/rgba?\(([^)]+)\)/);
  if (!m) return c === 'transparent' ? 0 : 1;
  const parts = m[1].split(/[ ,/]+/).filter(Boolean);
  return parts.length > 3 ? Number(parts[3]) : 1;
}

function rr(g, r, radius) {
  const rad = Math.min(radius, r.width / 2, r.height / 2);
  g.beginPath();
  if (g.roundRect) g.roundRect(r.left, r.top, r.width, r.height, rad);
  else g.rect(r.left, r.top, r.width, r.height);
}

function paintText(g, node) {
  if (!visibleText(node)) return;
  const p = node.parentElement;
  const cs = getComputedStyle(p);
  if (cs.visibility === 'hidden') return;
  const size = parseFloat(cs.fontSize);
  g.font = `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
  g.fillStyle = cs.color;
  g.textBaseline = 'alphabetic';
  const range = document.createRange();
  const re = /\S+/g;
  let m;
  while ((m = re.exec(node.nodeValue))) {
    range.setStart(node, m.index);
    range.setEnd(node, m.index + m[0].length);
    const r = range.getClientRects()[0];
    if (!r || !r.width) continue;
    g.fillText(cs.textTransform === 'uppercase' ? m[0].toUpperCase() : m[0], r.left, r.top + r.height / 2 + size * 0.34);
  }
}

function paintElement(g, el) {
  if (el.nodeType === 3) { paintText(g, el); return; }
  if (el.nodeType !== 1 || el.hidden) return;
  if (el.matches('script, style, .capture-overlay, .sr-only, noscript, #menu-layer, #toast-layer')) return;
  const cs = getComputedStyle(el);
  if (cs.display === 'none' || cs.visibility === 'hidden' || Number(cs.opacity) === 0) return;
  const r = el.getBoundingClientRect();
  const radius = parseFloat(cs.borderTopLeftRadius) || 0;
  g.save();
  g.globalAlpha *= Number(cs.opacity);
  if (el.classList.contains('win')) {
    g.shadowColor = 'rgba(0,0,0,.35)';
    g.shadowBlur = 40;
    g.shadowOffsetY = 12;
  }
  const art = cs.getPropertyValue('--art').trim();
  if (art) { g.fillStyle = art; rr(g, r, radius); g.fill(); } else if (cssColorAlpha(cs.backgroundColor) > 0) {
    g.fillStyle = cs.backgroundColor;
    rr(g, r, radius);
    g.fill();
  }
  g.shadowColor = 'transparent';
  if (parseFloat(cs.borderTopWidth) > 0 && cssColorAlpha(cs.borderTopColor) > 0 && r.width && r.height) {
    g.strokeStyle = cs.borderTopColor;
    g.lineWidth = parseFloat(cs.borderTopWidth);
    rr(g, r, radius);
    g.stroke();
  }
  const tag = el.tagName;
  if (tag === 'IMG' || tag === 'CANVAS') {
    try { if (r.width && r.height) { rr(g, r, radius); g.clip(); g.drawImage(el, r.left, r.top, r.width, r.height); } } catch { /* not ready */ }
    g.restore();
    return;
  }
  if (tag === 'svg') {
    if (r.width && r.height && el.querySelector('use')) {
      g.strokeStyle = cs.color;
      g.lineWidth = 1.6;
      g.globalAlpha *= 0.55;
      g.beginPath();
      g.arc(r.left + r.width / 2, r.top + r.height / 2, Math.min(r.width, r.height) * 0.32, 0, Math.PI * 2);
      g.stroke();
    }
    g.restore();
    return;
  }
  if (tag === 'TEXTAREA') {
    for (const w of textareaWords(el)) { g.font = w.font; g.fillStyle = w.color; g.fillText(w.text, w.rect.left, w.rect.top + w.rect.height * 0.78); }
    g.restore();
    return;
  }
  if (tag === 'INPUT' && /text|search/.test(el.type)) {
    g.font = `${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
    g.fillStyle = el.value ? cs.color : 'rgba(128,128,128,.8)';
    g.fillText(el.value || el.placeholder, r.left + parseFloat(cs.paddingLeft), r.top + r.height / 2 + parseFloat(cs.fontSize) * 0.34);
    g.restore();
    return;
  }
  if (cs.overflow !== 'visible' || el.classList.contains('win')) { rr(g, r, radius); g.clip(); }
  let kids = Array.from(el.childNodes);
  if (el.id === 'windows') kids = kids.filter((k) => k.nodeType === 1).sort((a, b) => Number(a.style.zIndex || 0) - Number(b.style.zIndex || 0));
  kids.forEach((k) => paintElement(g, k));
  g.restore();
}

/** A bitmap of the pretend screen at device resolution. */
function paintScreen() {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const w = window.innerWidth;
  const h = window.innerHeight;
  const c = document.createElement('canvas');
  c.width = Math.round(w * dpr);
  c.height = Math.round(h * dpr);
  const g = c.getContext('2d', { willReadFrequently: true });
  g.scale(dpr, dpr);
  g.drawImage($('#wallpaper'), 0, 0, w, h);
  for (const el of Array.from($('#screen').children)) {
    if (el.id === 'wallpaper') continue;
    paintElement(g, el);
  }
  return { canvas: c, dpr };
}

// ---------------------------------------------------------------- selecting an area (capture and OCR)

function selectArea(mode) {
  return new Promise((resolve) => {
    const screen = mode === 'capture' ? paintScreen() : null;
    const ctx = screen?.canvas.getContext('2d', { willReadFrequently: true });
    const overlay = html`<div class="capture-overlay mode-${mode}" role="dialog" aria-modal="true" aria-label="${mode === 'ocr' ? 'Select text to copy' : 'Select an area to capture'}">
      <div class="cap-hint">${mode === 'ocr' ? 'Drag over text or a QR code to copy it' : 'Drag to capture an area · Return captures the whole screen'} · <kbd>esc</kbd> cancels</div>
      <div class="cap-sel" hidden><span class="cap-dim"></span></div>
      ${mode === 'capture' ? '<div class="loupe" hidden><canvas width="132" height="132"></canvas><span class="loupe-read"></span></div>' : ''}
    </div>`;
    document.body.append(overlay);
    const selEl = $('.cap-sel', overlay);
    const dim = $('.cap-dim', overlay);
    const loupe = $('.loupe', overlay);
    const lg = loupe?.querySelector('canvas').getContext('2d');
    let start = null;
    let rect = null;

    const finish = (value) => {
      release();
      overlay.remove();
      resolve(value);
    };
    const release = captureKeys((e) => {
      if (e.key === 'Escape') { finish(null); return true; }
      if (e.key === 'Enter' && mode === 'capture') { finish({ full: true, screen }); return true; }
      return e.type === 'keydown' && !e.metaKey;
    });

    const showLoupe = (x, y) => {
      if (!loupe) return;
      loupe.hidden = false;
      const { dpr } = screen;
      const n = 11;
      const px = Math.round(x * dpr);
      const py = Math.round(y * dpr);
      lg.imageSmoothingEnabled = false;
      lg.clearRect(0, 0, 132, 132);
      lg.drawImage(screen.canvas, px - 5, py - 5, n, n, 0, 0, 132, 132);
      lg.strokeStyle = 'rgba(255,255,255,.18)';
      lg.lineWidth = 1;
      for (let i = 1; i < n; i++) { lg.beginPath(); lg.moveTo(i * 12, 0); lg.lineTo(i * 12, 132); lg.moveTo(0, i * 12); lg.lineTo(132, i * 12); lg.stroke(); }
      lg.strokeStyle = '#fff';
      lg.lineWidth = 2;
      lg.strokeRect(60, 60, 12, 12);
      const [r, g, b] = ctx.getImageData(clamp(px, 0, screen.canvas.width - 1), clamp(py, 0, screen.canvas.height - 1), 1, 1).data;
      const hex = `#${[r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('').toUpperCase()}`;
      loupe.querySelector('.loupe-read').innerHTML = `<i style="background:${hex}"></i>${hex}<span>${Math.round(x)}, ${Math.round(y)}</span>`;
      const lx = x + 24 + 150 > window.innerWidth ? x - 24 - 150 : x + 24;
      const ly = y + 24 + 170 > window.innerHeight ? y - 24 - 170 : y + 24;
      loupe.style.transform = `translate(${lx}px, ${ly}px)`;
    };

    overlay.addEventListener('pointermove', (e) => {
      if (e.pointerType === 'mouse' || start) showLoupe(e.clientX, e.clientY);
      if (!start) return;
      const x = Math.min(start.x, e.clientX);
      const y = Math.min(start.y, e.clientY);
      rect = new DOMRect(x, y, Math.abs(e.clientX - start.x), Math.abs(e.clientY - start.y));
      Object.assign(selEl.style, { left: `${x}px`, top: `${y}px`, width: `${rect.width}px`, height: `${rect.height}px` });
      selEl.hidden = false;
      dim.textContent = `${Math.round(rect.width)} × ${Math.round(rect.height)}`;
    });
    overlay.addEventListener('pointerdown', (e) => {
      overlay.setPointerCapture(e.pointerId);
      start = { x: e.clientX, y: e.clientY };
      rect = null;
      showLoupe(e.clientX, e.clientY);
    });
    overlay.addEventListener('pointerup', () => {
      if (!start) return;
      start = null;
      if (!rect || rect.width < 6 || rect.height < 6) { selEl.hidden = true; return; }
      finish({ rect, screen });
    });
  });
}

// ---------------------------------------------------------------- OCR

async function copyText() {
  const res = await selectArea('ocr');
  if (!res) return;
  const found = recognize(res.rect);
  if (!found) {
    playSound('error');
    notify({ icon: 'textscan', title: 'No text found', subtitle: 'Drag over words, or over the QR code in Sample.png.', tint: 'plain' });
    return;
  }
  bus.emit('copy', { text: found.text, app: 'Zenith' });
  navigator.clipboard?.writeText(found.text).catch(() => {});
  const preview = found.text.replace(/\s+/g, ' ');
  if (found.kind === 'qr') {
    bus.emit('tour', 'qr');
    notify({ icon: 'textscan', title: 'Copied the QR code', subtitle: preview, tint: 'green', duration: 3600 });
  } else {
    bus.emit('tour', 'ocr');
    notify({ icon: 'textscan', title: found.lines === 1 ? 'Copied 1 line of text' : `Copied ${found.lines} lines of text`, subtitle: preview.length > 70 ? `${preview.slice(0, 70)}…` : preview, tint: 'green', duration: 3600 });
  }
}

// ---------------------------------------------------------------- capture

function flash() {
  if (reduceMotion()) return;
  const f = html`<div class="cap-flash"></div>`;
  document.body.append(f);
  setTimeout(() => f.remove(), 350);
}

async function captureArea() {
  const res = await selectArea('capture');
  if (!res) return;
  const { canvas, dpr } = res.screen;
  if (res.full) { finishCapture(canvas, dpr); return; }
  const r = res.rect;
  const out = document.createElement('canvas');
  out.width = Math.round(r.width * dpr);
  out.height = Math.round(r.height * dpr);
  out.getContext('2d').drawImage(canvas, Math.round(r.left * dpr), Math.round(r.top * dpr), out.width, out.height, 0, 0, out.width, out.height);
  finishCapture(out, dpr);
}

function captureScreen() {
  const { canvas, dpr } = paintScreen();
  finishCapture(canvas, dpr);
}

function finishCapture(canvas, dpr) {
  canvas.dpr = dpr;
  flash();
  playSound('capture');
  bus.emit('tour', 'capture-taken');
  openWindow('editor', canvas);
}

// ---------------------------------------------------------------- the annotation editor

const COLORS = ['#ff3b30', '#ff9500', '#ffcc00', '#34c759', '#007aff', '#af52de', '#ffffff', '#1c1c1e'];
const WIDTHS = [2, 4, 8];
const TOOLS = [['pen', 'pen', 'Pen', 'P'], ['arrow', 'arrow', 'Arrow', 'A'], ['rect', 'rect', 'Rectangle', 'R'], ['text', 'textA', 'Text', 'T'], ['pixelate', 'pixel', 'Pixelate', 'B'], ['redact', 'redact', 'Redact', 'X'], ['crop', 'crop', 'Crop', 'C']];

const ed = { base: null, ops: [], redo: [], tool: 'arrow', color: COLORS[0], width: 1, draft: null };

function buildEditor(body, win) {
  win.classList.add('win-editor');
  body.innerHTML = `<div class="ed-stage"><canvas class="ed-canvas" aria-label="Capture being annotated"></canvas><input class="ed-text" type="text" hidden aria-label="Text"></div>
    <div class="ed-bar" role="toolbar" aria-label="Annotation tools">
      <div class="ed-row">
        <span class="ed-group">${TOOLS.map(([id, ic, label, key]) => `<button type="button" class="ed-btn" data-tool="${id}" aria-label="${label} (${key})" title="${label} (${key})">${icon(ic)}</button>`).join('')}</span>
        <span class="ed-group">${WIDTHS.map((w, i) => `<button type="button" class="ed-btn ed-w" data-width="${i}" aria-label="Line width ${i + 1}"><span style="height:${w + 1}px"></span></button>`).join('')}</span>
        <span class="ed-group plain">
          <button type="button" class="ed-btn" data-ed="undo" aria-label="Undo (⌘Z)" title="Undo (⌘Z)">${icon('undo')}</button>
          <button type="button" class="ed-btn" data-ed="redo" aria-label="Redo (⇧⌘Z)" title="Redo (⇧⌘Z)">${icon('redo')}</button>
        </span>
      </div>
      <div class="ed-row">
        <span class="ed-group">${COLORS.map((c) => `<button type="button" class="ed-color" data-color="${c}" style="--c:${c}" aria-label="Colour ${c}"></button>`).join('')}</span>
        <span class="ed-group plain">
          <button type="button" class="btn" data-ed="save">Save…</button>
          <button type="button" class="btn" data-ed="copy">${icon('copy')}Copy</button>
        </span>
      </div>
    </div>`;
  const cv = $('.ed-canvas', body);
  body.addEventListener('click', (e) => {
    const t = e.target.closest?.('[data-tool]');
    if (t) { ed.tool = t.dataset.tool; syncBar(); return; }
    const c = e.target.closest?.('[data-color]');
    if (c) { ed.color = c.dataset.color; syncBar(); return; }
    const w = e.target.closest?.('[data-width]');
    if (w) { ed.width = Number(w.dataset.width); syncBar(); return; }
    const a = e.target.closest?.('[data-ed]')?.dataset.ed;
    if (a === 'undo') undo();
    if (a === 'redo') redo();
    if (a === 'save') saveCapture();
    if (a === 'copy') copyCapture();
  });
  cv.addEventListener('pointerdown', onDraw);
  const input = $('.ed-text', body);
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); commitText(); }
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); input.hidden = true; ed.textAt = null; }
  });
  input.addEventListener('blur', commitText);
}

function syncBar() {
  const body = $('#win-editor');
  $$('[data-tool]', body).forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.tool === ed.tool)));
  $$('[data-color]', body).forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.color === ed.color)));
  $$('[data-width]', body).forEach((b) => b.setAttribute('aria-pressed', String(Number(b.dataset.width) === ed.width)));
  $('[data-ed="undo"]', body).disabled = !ed.ops.length;
  $('[data-ed="redo"]', body).disabled = !ed.redo.length;
  $('.ed-canvas', body).dataset.tool = ed.tool;
}

function cropRect() {
  const crops = ed.ops.filter((o) => o.type === 'crop');
  return crops.length ? crops[crops.length - 1].rect : { x: 0, y: 0, w: ed.base.width, h: ed.base.height };
}

function drawOp(g, o) {
  g.save();
  g.strokeStyle = o.color;
  g.fillStyle = o.color;
  g.lineWidth = o.lw;
  g.lineCap = 'round';
  g.lineJoin = 'round';
  if (o.type === 'pen') {
    g.beginPath();
    o.points.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y)));
    g.stroke();
  } else if (o.type === 'arrow') {
    const ang = Math.atan2(o.y2 - o.y1, o.x2 - o.x1);
    const head = Math.max(14, o.lw * 4.2);
    const bx = o.x2 - Math.cos(ang) * head * 0.8;
    const by = o.y2 - Math.sin(ang) * head * 0.8;
    g.beginPath();
    g.moveTo(o.x1, o.y1);
    g.lineTo(bx, by);
    g.stroke();
    g.beginPath();
    g.moveTo(o.x2, o.y2);
    g.lineTo(o.x2 - Math.cos(ang - 0.45) * head, o.y2 - Math.sin(ang - 0.45) * head);
    g.quadraticCurveTo(bx, by, o.x2 - Math.cos(ang + 0.45) * head, o.y2 - Math.sin(ang + 0.45) * head);
    g.closePath();
    g.fill();
  } else if (o.type === 'rect') {
    g.strokeRect(o.x, o.y, o.w, o.h);
  } else if (o.type === 'text') {
    g.font = `600 ${o.size}px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif`;
    g.textBaseline = 'top';
    g.lineWidth = Math.max(3, o.size / 6);
    g.strokeStyle = o.color === '#ffffff' || o.color === '#ffcc00' ? 'rgba(0,0,0,.55)' : 'rgba(255,255,255,.85)';
    g.strokeText(o.text, o.x, o.y);
    g.fillText(o.text, o.x, o.y);
  } else if (o.type === 'redact') {
    g.fillStyle = '#000';
    g.fillRect(o.x, o.y, o.w, o.h);
  } else if (o.type === 'pixelate' && o.w > 2 && o.h > 2) {
    const block = Math.max(6, Math.round(Math.min(o.w, o.h) / 12));
    const small = document.createElement('canvas');
    small.width = Math.max(1, Math.round(o.w / block));
    small.height = Math.max(1, Math.round(o.h / block));
    small.getContext('2d').drawImage(g.canvas, o.x, o.y, o.w, o.h, 0, 0, small.width, small.height);
    g.imageSmoothingEnabled = false;
    g.drawImage(small, 0, 0, small.width, small.height, o.x, o.y, o.w, o.h);
  }
  g.restore();
}

/** The flattened image (annotations burnt in, crop applied). */
function flatten(includeDraft = false) {
  const full = document.createElement('canvas');
  full.width = ed.base.width;
  full.height = ed.base.height;
  const g = full.getContext('2d');
  g.drawImage(ed.base, 0, 0);
  ed.ops.filter((o) => o.type !== 'crop').forEach((o) => drawOp(g, o));
  if (includeDraft && ed.draft && ed.draft.type !== 'crop') drawOp(g, ed.draft);
  const c = cropRect();
  const out = document.createElement('canvas');
  out.width = Math.max(1, Math.round(c.w));
  out.height = Math.max(1, Math.round(c.h));
  out.getContext('2d').drawImage(full, c.x, c.y, c.w, c.h, 0, 0, out.width, out.height);
  return out;
}

function redraw() {
  const cv = $('#win-editor .ed-canvas');
  const img = flatten(true);
  cv.width = img.width;
  cv.height = img.height;
  const g = cv.getContext('2d');
  g.drawImage(img, 0, 0);
  if (ed.draft?.type === 'crop') {
    const c = cropRect();
    const d = ed.draft;
    g.fillStyle = 'rgba(0,0,0,.5)';
    g.fillRect(0, 0, cv.width, cv.height);
    g.drawImage(img, d.x - c.x, d.y - c.y, d.w, d.h, d.x - c.x, d.y - c.y, d.w, d.h);
    g.strokeStyle = '#fff';
    g.setLineDash([8, 6]);
    g.lineWidth = 2;
    g.strokeRect(d.x - c.x, d.y - c.y, d.w, d.h);
  }
  fitCanvas();
  syncBar();
}

function fitCanvas() {
  const stage = $('#win-editor .ed-stage');
  const cv = $('.ed-canvas', stage);
  const sw = stage.clientWidth - 32;
  const sh = stage.clientHeight - 146; // 16 above, and room under for the floating toolbar
  // Never larger than the capture was on screen.
  const k = Math.min(sw / cv.width, sh / cv.height, 1 / (ed.base?.dpr || 1));
  cv.style.width = `${Math.max(40, cv.width * k)}px`;
  cv.style.height = `${Math.max(30, cv.height * k)}px`;
}

function toImage(e) {
  const cv = $('#win-editor .ed-canvas');
  const r = cv.getBoundingClientRect();
  const c = cropRect();
  return [((e.clientX - r.left) / r.width) * cv.width + c.x, ((e.clientY - r.top) / r.height) * cv.height + c.y];
}

function onDraw(e) {
  if (ed.textAt) commitText();
  const cv = e.currentTarget;
  const [x, y] = toImage(e);
  const lw = WIDTHS[ed.width] * (ed.base.width > 1600 ? 2 : 1.3);
  if (ed.tool === 'text') {
    e.preventDefault();
    const input = $('#win-editor .ed-text');
    const r = cv.getBoundingClientRect();
    ed.textAt = { x, y };
    Object.assign(input.style, { left: `${e.clientX - r.left + cv.offsetLeft}px`, top: `${e.clientY - r.top + cv.offsetTop - 4}px`, color: ed.color });
    input.value = '';
    input.hidden = false;
    setTimeout(() => input.focus());
    return;
  }
  cv.setPointerCapture(e.pointerId);
  const box = (x2, y2) => ({ x: Math.min(x, x2), y: Math.min(y, y2), w: Math.abs(x2 - x), h: Math.abs(y2 - y) });
  if (ed.tool === 'pen') ed.draft = { type: 'pen', points: [[x, y]], color: ed.color, lw };
  const move = (ev) => {
    const [x2, y2] = toImage(ev);
    if (ed.tool === 'pen') ed.draft.points.push([x2, y2]);
    else if (ed.tool === 'arrow') ed.draft = { type: 'arrow', x1: x, y1: y, x2, y2, color: ed.color, lw };
    else if (ed.tool === 'crop') ed.draft = { type: 'crop', ...box(x2, y2) };
    else ed.draft = { type: ed.tool, ...box(x2, y2), color: ed.color, lw };
    redraw();
  };
  const up = () => {
    cv.removeEventListener('pointermove', move);
    cv.removeEventListener('pointerup', up);
    const d = ed.draft;
    ed.draft = null;
    if (d && (d.type === 'pen' ? d.points.length > 1 : d.type === 'arrow' ? Math.hypot(d.x2 - d.x1, d.y2 - d.y1) > 6 : d.w > 4 && d.h > 4)) {
      if (d.type === 'crop') {
        const c = cropRect();
        d.rect = { x: clamp(d.x, c.x, c.x + c.w), y: clamp(d.y, c.y, c.y + c.h), w: Math.min(d.w, c.x + c.w - d.x), h: Math.min(d.h, c.y + c.h - d.y) };
      }
      ed.ops.push(d);
      ed.redo = [];
      bus.emit('tour', 'annotate');
    }
    redraw();
  };
  cv.addEventListener('pointermove', move);
  cv.addEventListener('pointerup', up);
}

function commitText() {
  const input = $('#win-editor .ed-text');
  if (!ed.textAt || input.hidden) return;
  const text = input.value.trim();
  input.hidden = true;
  if (text) {
    ed.ops.push({ type: 'text', x: ed.textAt.x, y: ed.textAt.y, text, color: ed.color, size: [20, 30, 44][ed.width] * (ed.base.width > 1600 ? 2 : 1.3) });
    ed.redo = [];
    bus.emit('tour', 'annotate');
  }
  ed.textAt = null;
  redraw();
}

function undo() { if (ed.ops.length) { ed.redo.push(ed.ops.pop()); redraw(); } }
function redo() { if (ed.redo.length) { ed.ops.push(ed.redo.pop()); redraw(); } }

function fileName() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `Zenith Capture ${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} at ${p(d.getHours())}.${p(d.getMinutes())}.${p(d.getSeconds())}.png`;
}

function saveCapture() {
  const img = flatten();
  img.toBlob((blob) => {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = fileName();
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    notify({ icon: 'download', title: 'Saved', subtitle: a.download, tint: 'green' });
    bus.emit('tour', 'capture');
  }, 'image/png');
}

async function copyCapture() {
  const img = flatten();
  const thumb = document.createElement('canvas');
  const k = Math.min(1, 640 / img.width);
  thumb.width = Math.max(1, Math.round(img.width * k));
  thumb.height = Math.max(1, Math.round(img.height * k));
  thumb.getContext('2d').drawImage(img, 0, 0, thumb.width, thumb.height);
  const blob = await new Promise((r) => img.toBlob(r, 'image/png'));
  let real = false;
  try {
    if (window.ClipboardItem && navigator.clipboard?.write) { await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]); real = true; }
  } catch { /* not allowed here */ }
  const label = `Image ${img.width} × ${img.height}`;
  bus.emit('copy-image', { img: thumb.toDataURL('image/png'), w: img.width, h: img.height, size: blob.size, label });
  closeWindow('editor');
  bus.emit('tour', 'capture');
  notify({ icon: 'copy', title: 'Copied the capture', subtitle: real ? 'In the clipboard history, and on your own clipboard too' : 'In the clipboard history', tint: 'green' });
}

function editorKeys(e) {
  if (frontWindow() !== 'editor' || !isWindowOpen('editor') || e.target.closest?.('input')) return;
  const meta = isMac ? e.metaKey : (e.metaKey || e.ctrlKey);
  if (meta && codeOf(e) === 'KeyZ') { e.preventDefault(); e.shiftKey ? redo() : undo(); return; }
  if (meta && codeOf(e) === 'KeyC') { e.preventDefault(); copyCapture(); return; }
  if (meta && codeOf(e) === 'KeyS') { e.preventDefault(); saveCapture(); return; }
  if (e.key === 'Escape') { closeWindow('editor'); return; }
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const t = TOOLS.find(([, , , key]) => key === e.key.toUpperCase());
  if (t) { ed.tool = t[0]; syncBar(); }
}

export function initCapture() {
  registerWindow('editor', {
    app: 'Zenith', title: 'Annotate', width: Math.min(1000, window.innerWidth - 40), height: Math.min(680, window.innerHeight - 120), build: buildEditor,
    onOpen: (canvas) => {
      if (canvas) { ed.base = canvas; ed.ops = []; ed.redo = []; ed.draft = null; }
      requestAnimationFrame(redraw);
    },
  });
  registerAction('captureArea', captureArea);
  registerAction('captureScreen', captureScreen);
  registerAction('ocr', copyText);
  document.addEventListener('keydown', editorKeys);
  window.addEventListener('resize', () => { if (isWindowOpen('editor')) fitCanvas(); });
}

