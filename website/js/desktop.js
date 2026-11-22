// The pretend Mac around Zenith: wallpaper, menu bar, dock, desktop icons, the small demo apps, lock screen,
// Cleaning Mode and Keep Awake, plus the Read Me's "Try it here" list.
import {
  $, $$, bus, esc, icon, html, settings, setSetting, notify, registerWindow, openWindow, closeWindow, minimizeWindow,
  focusWindow, isWindowOpen, windowSpec, allWindows, frontAppName, showMenu, closeMenus, menuIsOpen, menuAnchor,
  runAction, registerAction, shortcutText, store, ask, confirmDestructive, formatBytes, captureKeys, clamp, app,
  setZenithRunning, isTouch, tourDone, VERSION, playSound, reduceMotion, codeOf,
} from './core.js';
import { island } from './island.js';
import { keepAwake } from './models.js';
import { encodeQR, drawQR } from './qr.js';
import { roundRect } from './data.js';

// ---------------------------------------------------------------- wallpaper

export function drawWallpaper() {
  const c = $('#wallpaper');
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const w = window.innerWidth;
  const h = window.innerHeight;
  c.width = Math.round(w * dpr);
  c.height = Math.round(h * dpr);
  const g = c.getContext('2d');
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  const dark = document.documentElement.dataset.theme === 'dark';
  const base = g.createLinearGradient(0, 0, w, h);
  if (dark) { base.addColorStop(0, '#0b1026'); base.addColorStop(0.55, '#16224a'); base.addColorStop(1, '#0d3a4a'); } else { base.addColorStop(0, '#8fb8ff'); base.addColorStop(0.5, '#c7c9ff'); base.addColorStop(1, '#ffd3e2'); }
  g.fillStyle = base;
  g.fillRect(0, 0, w, h);
  const blob = (x, y, r, color) => {
    const rg = g.createRadialGradient(x, y, 0, x, y, r);
    rg.addColorStop(0, color);
    rg.addColorStop(1, 'rgba(0,0,0,0)');
    g.fillStyle = rg;
    g.fillRect(0, 0, w, h);
  };
  if (dark) {
    blob(w * 0.18, h * 0.85, Math.max(w, h) * 0.55, 'rgba(94,72,214,.55)');
    blob(w * 0.85, h * 0.2, Math.max(w, h) * 0.5, 'rgba(26,160,170,.45)');
    blob(w * 0.6, h * 1.05, Math.max(w, h) * 0.4, 'rgba(230,90,140,.28)');
  } else {
    blob(w * 0.15, h * 0.8, Math.max(w, h) * 0.55, 'rgba(120,110,255,.45)');
    blob(w * 0.88, h * 0.15, Math.max(w, h) * 0.5, 'rgba(80,200,230,.45)');
    blob(w * 0.65, h * 1.0, Math.max(w, h) * 0.4, 'rgba(255,150,120,.4)');
  }
  // A few soft waves, so the loupe has something to show.
  g.globalAlpha = dark ? 0.08 : 0.16;
  g.strokeStyle = '#fff';
  for (let i = 0; i < 7; i++) {
    g.lineWidth = 1.5 + i * 0.6;
    g.beginPath();
    for (let x = 0; x <= w; x += 12) {
      const y = h * (0.58 + i * 0.045) + Math.sin(x / (170 + i * 30) + i) * (28 + i * 6);
      x === 0 ? g.moveTo(x, y) : g.lineTo(x, y);
    }
    g.stroke();
  }
  g.globalAlpha = 1;
}

// ---------------------------------------------------------------- the sample picture (OCR and QR targets)

export const SOURCE_URL = 'https://github.com/mynameisbat/zenith-macos';
export const sample = { canvas: null, texts: [], qr: null };

function drawSample() {
  const W = 760;
  const H = 500;
  const c = document.createElement('canvas');
  c.width = W * 2;
  c.height = H * 2;
  const g = c.getContext('2d');
  g.scale(2, 2);
  g.fillStyle = '#fbfaf6';
  g.fillRect(0, 0, W, H);
  g.fillStyle = '#ece6da';
  g.fillRect(0, 0, W, 10);
  const texts = [];
  const text = (t, x, y, font, color = '#222') => {
    g.font = font;
    g.fillStyle = color;
    g.fillText(t, x, y);
    const m = g.measureText(t);
    texts.push({ text: t, x, y: y - m.actualBoundingBoxAscent, w: m.width, h: m.actualBoundingBoxAscent + m.actualBoundingBoxDescent });
  };
  const sans = '-apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif';
  text('Order 2026-0412', 44, 76, `700 32px ${sans}`);
  text('Example Home Goods · Springfield', 44, 108, `400 17px ${sans}`, '#666');
  text('Walnut desk lamp', 44, 168, `400 21px ${sans}`);
  text('€89.00', 340, 168, `600 21px ${sans}`);
  text('Linen shade, sand', 44, 204, `400 21px ${sans}`);
  text('€24.00', 340, 204, `600 21px ${sans}`);
  g.fillStyle = '#ddd';
  g.fillRect(44, 226, 360, 1.5);
  text('Total', 44, 260, `700 21px ${sans}`);
  text('€113.00', 330, 260, `700 21px ${sans}`);
  text('Delivery: Thursday 19 November', 44, 326, `400 19px ${sans}`);
  text('Guest Wi-Fi: Example-Guest', 44, 372, `400 19px ${sans}`);
  text('Password: sunflower-42', 44, 404, `400 19px ${sans}`);
  text('Thank you for your order!', 44, 462, `italic 400 18px Georgia, serif`, '#8a6d3b');
  const qx = 478;
  const qy = 74;
  const qs = 230;
  drawQR(g, encodeQR(SOURCE_URL), qx, qy, qs);
  g.strokeStyle = '#e4e0d6';
  g.strokeRect(qx - 0.5, qy - 0.5, qs + 1, qs + 1);
  text('Scan for the source code', 497, qy + qs + 34, `400 16px ${sans}`, '#555');
  sample.canvas = c;
  sample.size = { w: W, h: H };
  sample.texts = texts;
  sample.qr = { x: qx, y: qy, w: qs, h: qs, payload: SOURCE_URL };
}

// ---------------------------------------------------------------- menu bar

const power = { level: 85, plugged: false };

function updateClock() {
  const d = new Date();
  const day = d.toLocaleDateString('en-GB', { weekday: 'short' });
  const date = d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
  const time = d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  $('#mb-clock').textContent = window.innerWidth < 720 ? time : `${day} ${date}  ${time}`;
  $('#mb-clock').setAttribute('datetime', d.toISOString());
}

function updateBattery() {
  const b = $('#mb-battery');
  b.querySelector('.batt-fill').style.width = `${power.level}%`;
  b.querySelector('.batt-pct').textContent = `${power.level}%`;
  b.classList.toggle('charging', power.plugged);
  b.classList.toggle('low', power.level <= 20 && !power.plugged);
  b.setAttribute('aria-label', `Battery ${power.level}%${power.plugged ? ', charging' : ''}`);
}

export function setPlugged(plugged) {
  power.plugged = plugged;
  updateBattery();
  if (plugged) {
    notify({ icon: 'bolt', tint: 'green', accessory: `${power.level}%`, title: `Charging · ${power.level}%`, subtitle: '67W charger', duration: 3200 });
  } else {
    notify({ icon: 'battery', tint: 'plain', accessory: `${power.level}%`, title: 'On battery', subtitle: `${power.level}% · about 6 h 40 min left` });
  }
  bus.emit('tour', 'hud');
}

function lowBattery() {
  power.level = 20;
  power.plugged = false;
  updateBattery();
  notify({ icon: 'battery', tint: 'red', accessory: '20%', title: 'Low battery', subtitle: 'Plug in your Mac soon.', duration: 3600 });
  bus.emit('tour', 'hud');
}

function fullyCharged() {
  power.level = 100;
  power.plugged = true;
  updateBattery();
  notify({ icon: 'bolt', tint: 'green', accessory: '100%', title: 'Fully charged', subtitle: 'Maximum capacity 92%', duration: 3200 });
  bus.emit('tour', 'hud');
}

/** Zenith's menu bar icon is there only if Settings asks for it, or the island has no tool dock (needsMenuBarIcon). */
const menuBarIconShown = () => app.running && (settings.menuBarIcon || !settings.toolDock);
function updateMenuBarIcon() {
  const el = $('#mb-zenith');
  el.hidden = !menuBarIconShown();
  if (el.hidden) { el.classList.remove('open'); bus.emit('menu-bar-icon', false); }
}

function menuItems(name) {
  const front = frontAppName();
  switch (name) {
    case 'demo': return [
      { label: 'About This Demo', action: () => { openWindow('readme'); readmeTab('try'); } },
      { label: 'Events…', action: () => setTimeout(() => showMenu($('.mb-logo'), menuItems('events'))) },
      { label: 'Download Zenith', action: () => { location.href = 'https://github.com/mynameisbat/zenith-macos/releases/latest'; } },
      { separator: true },
      { label: 'Lock Screen', shortcut: '⌃⌘Q', action: lockScreen },
      { separator: true },
      { label: 'Reset Demo…', action: resetDemo },
    ];
    case 'app': return [
      { label: `About ${front}`, action: () => { if (front === 'Zenith') runAction('settings', 'general'); else openWindow('readme'); } },
      { separator: true },
      ...(front === 'Finder' ? [{ label: 'Open Trash', action: () => openWindow('trash') }] : [
        { label: `Hide ${front}`, action: () => allWindows().filter((w) => w.app === front && isWindowOpen(w.id)).forEach((w) => minimizeWindow(w.id)) },
        { label: `Quit ${front}`, action: () => allWindows().filter((w) => w.app === front).forEach((w) => closeWindow(w.id)) },
      ]),
    ];
    case 'try': return [
      { header: 'Zenith' },
      { label: 'Clipboard History', shortcut: shortcutText('clipboard'), action: () => runAction('clipboard') },
      { label: 'Capture Area', shortcut: shortcutText('captureArea'), action: () => runAction('captureArea') },
      { label: 'Capture Screen', shortcut: shortcutText('captureScreen'), action: () => runAction('captureScreen') },
      { label: 'Copy Text (OCR)', shortcut: shortcutText('ocr'), action: () => runAction('ocr') },
      { label: 'Snippets', shortcut: shortcutText('snippets'), action: () => runAction('snippets') },
      { label: 'Record Screen', shortcut: shortcutText('record'), action: () => runAction('record') },
      { label: 'Scrolling Capture', shortcut: shortcutText('scrolling'), action: () => runAction('scrolling') },
      { label: 'Cleaning Mode', shortcut: shortcutText('cleaningMode'), action: () => runAction('cleaningMode') },
      { separator: true },
      { label: 'All Tools', action: () => island.openPage('tools') },
      { label: 'Open the Island', action: () => island.open() },
      ...(menuBarIconShown() ? [{ label: 'Command Hub', action: () => runAction('hub') }] : []),
      { label: 'Settings…', shortcut: '⌘,', action: () => runAction('settings') },
    ];
    case 'events': return [
      { header: 'Make the Mac do something' },
      { label: power.plugged ? 'Unplug the Charger' : 'Plug In the Charger', action: () => setPlugged(!power.plugged) },
      { label: 'Battery Gets Low', action: lowBattery },
      { label: 'Battery Is Full', action: fullyCharged },
      { label: 'Connect Headphones', action: () => { notify({ icon: 'headphones', accessory: '74%', title: 'Example Headphones', subtitle: 'Connected · 74%', tint: 'accent' }); bus.emit('tour', 'hud'); } },
      { separator: true },
      { label: 'Next Track (media key)', shortcut: 'F9', action: () => island.nextTrack(true) },
      { separator: true },
      { label: 'Lock Screen', action: lockScreen },
    ];
    case 'view': return [
      { header: 'Appearance' },
      { label: 'Automatic', checked: settings.appearance === 'auto', action: () => setSetting('appearance', 'auto') },
      { label: 'Light', checked: settings.appearance === 'light', action: () => setSetting('appearance', 'light') },
      { label: 'Dark', checked: settings.appearance === 'dark', action: () => setSetting('appearance', 'dark') },
      { separator: true },
      { label: 'Display Has a Notch', checked: settings.notch, action: () => setSetting('notch', !settings.notch) },
    ];
    case 'help': return [
      { label: 'Zenith on GitHub', action: () => window.open(SOURCE_URL, '_blank', 'noopener') },
      { label: 'Report an Issue', action: () => window.open(`${SOURCE_URL}/issues`, '_blank', 'noopener') },
      { label: 'Release Notes', action: () => window.open(`${SOURCE_URL}/releases`, '_blank', 'noopener') },
      { separator: true },
      { label: 'Read Me', action: () => openWindow('readme') },
    ];
    case 'battery': return [
      { header: `Battery ${power.level}%` },
      { label: power.plugged ? 'Power Source: Power Adapter' : 'Power Source: Battery', disabled: true },
      { separator: true },
      { label: power.plugged ? 'Unplug the Charger' : 'Plug In the Charger', action: () => setPlugged(!power.plugged) },
    ];
    default: return [];
  }
}

function openBarMenu(btn) {
  const name = btn.dataset.menu;
  const right = btn.closest('.mb-right');
  showMenu(btn, menuItems(name), { align: right ? 'right' : 'left' });
}

function initMenuBar() {
  $$('#menubar [data-menu]').forEach((btn) => {
    btn.setAttribute('aria-haspopup', 'menu');
    btn.setAttribute('aria-expanded', 'false');
    btn.addEventListener('click', () => {
      if (menuIsOpen() && menuAnchor() === btn) { closeMenus(); return; }
      openBarMenu(btn);
    });
    btn.addEventListener('pointerenter', () => {
      if (menuIsOpen() && menuAnchor() !== btn && menuAnchor()?.closest?.('#menubar')) openBarMenu(btn);
    });
  });
  $('#mb-zenith').addEventListener('click', () => runAction('hub'));
  updateMenuBarIcon();
  ['setting:menuBarIcon', 'setting:toolDock'].forEach((t) => bus.on(t, updateMenuBarIcon));
  $$('[data-open]').forEach((el) => {
    if (el.closest('#desktop-icons')) return;
    el.addEventListener('click', () => {
      const [id, arg] = el.dataset.open.split(':');
      openWindow(id, arg);
    });
  });
  bus.on('focus', () => { $('#mb-app-name').textContent = frontAppName(); });
  bus.on('zenith-running', updateMenuBarIcon);
  updateClock();
  updateBattery();
  setInterval(updateClock, 10000);
  window.addEventListener('resize', updateClock);
  // Hardware keys a browser can see (most keyboards send these as F-keys).
  document.addEventListener('keydown', (e) => {
    if (e.target.closest?.('input, textarea, [contenteditable]')) return;
    if (e.key === 'MediaTrackNext') island.nextTrack(true);
    if (e.key === 'MediaTrackPrevious') island.previousTrack(true);
    if (e.key === 'MediaPlayPause') island.togglePlay();
    if (e.ctrlKey && e.metaKey && codeOf(e) === 'KeyQ') { e.preventDefault(); lockScreen(); }
  });
}

// ---------------------------------------------------------------- desktop icons and dock

const DOCK = [
  { id: 'readme', label: 'Read Me', icon: 'doc', art: 'art-doc' },
  { id: 'scratchpad', label: 'Scratchpad', icon: 'notes', art: 'art-notes' },
  { id: 'viewer', label: 'Sample.png', icon: 'photo', art: 'art-photo' },
  { id: 'vault', label: 'Vault', icon: 'key', art: 'art-vault' },
  { id: 'sketchbook', label: 'Sketchbook', icon: 'brush', art: 'art-app' },
  { sep: true },
  { href: SOURCE_URL, label: 'Source on GitHub', icon: 'github', art: 'art-github' },
  { id: 'trash', label: 'Trash', icon: 'trash', art: 'art-trash' },
];

function renderDock() {
  const dock = $('#dock');
  dock.innerHTML = '';
  for (const d of DOCK) {
    if (d.sep) { dock.append(html`<span class="dock-sep" aria-hidden="true"></span>`); continue; }
    if (d.id === 'sketchbook' && removedApps.has('Sketchbook.app')) continue;
    const el = d.href
      ? html`<a class="dock-item" href="${d.href}" target="_blank" rel="noopener" aria-label="${esc(d.label)}"><span class="dock-art ${d.art}">${icon(d.icon)}</span><span class="dock-tip">${esc(d.label)}</span></a>`
      : html`<button type="button" class="dock-item" data-dock="${d.id}" aria-label="${esc(d.label)}"><span class="dock-art ${d.art} ${d.id === 'trash' && trash.length ? 'full' : ''}">${icon(d.icon)}</span><span class="dock-tip">${esc(d.label)}</span><span class="dock-dot"></span></button>`;
    if (!d.href) el.addEventListener('click', () => { openWindow(d.id); bounce(el); });
    dock.append(el);
  }
  updateDockDots();
}

function bounce(el) {
  if (reduceMotion()) return;
  el.classList.remove('bounce');
  void el.offsetWidth;
  el.classList.add('bounce');
}

function updateDockDots() {
  $$('#dock [data-dock]').forEach((el) => {
    const w = windowSpec(el.dataset.dock);
    el.classList.toggle('running', !!w?.el && (!w.el.hidden || w.el.classList.contains('minimized')));
  });
}

const removedApps = new Set(store.get('removedApps', []));

function initDesktopIcons() {
  $$('#desktop-icons .dicon').forEach((icn) => {
    if (icn.tagName === 'A') return;
    const id = icn.dataset.open;
    icn.addEventListener('click', (e) => {
      $$('#desktop-icons .dicon.sel').forEach((x) => x.classList.remove('sel'));
      icn.classList.add('sel');
      if (isTouch() || e.detail === 0) openWindow(id);
    });
    icn.addEventListener('dblclick', () => openWindow(id));
  });
  $('#screen').addEventListener('pointerdown', (e) => {
    if (!e.target.closest?.('.dicon')) $$('#desktop-icons .dicon.sel').forEach((x) => x.classList.remove('sel'));
  });
  const sk = $('#dicon-sketchbook');
  sk.addEventListener('dragstart', (e) => {
    e.dataTransfer.setData('application/x-zenith-app', 'Sketchbook.app');
    e.dataTransfer.setData('text/plain', 'Sketchbook.app');
    e.dataTransfer.effectAllowed = 'copy';
  });
  applyRemovedApps();
  bus.on('app-removed', (name) => {
    removedApps.add(name);
    store.set('removedApps', [...removedApps]);
    applyRemovedApps();
    if (name === 'Sketchbook.app') closeWindow('sketchbook');
  });
}

function applyRemovedApps() {
  $('#dicon-sketchbook').closest('li').hidden = removedApps.has('Sketchbook.app');
  renderDock();
}

// ---------------------------------------------------------------- Trash

let trash = store.get('trash', []);
bus.on('trash:add', (items) => {
  trash = [...trash, ...items.map((i) => ({ ...i, at: Date.now() }))];
  store.set('trash', trash);
  renderTrash();
  renderDock();
});

function renderTrash() {
  const body = $('#win-trash .win-body');
  if (!body) return;
  body.innerHTML = trash.length
    ? `<ul class="list">${trash.map((t) => `<li><span class="list-ic">${icon('doc')}</span><span class="grow">${esc(t.name)}</span><span class="dim">${formatBytes(t.size)}</span></li>`).join('')}</ul>
       <div class="win-foot"><span class="dim">${trash.length === 1 ? '1 item' : `${trash.length} items`}, ${formatBytes(trash.reduce((a, t) => a + t.size, 0))}</span><button type="button" class="btn" data-empty-trash>Empty Trash…</button></div>`
    : `<div class="empty">${icon('trash')}<b>The Trash is empty</b><span>What the cleaner and the uninstaller move here shows up in this window.</span></div>`;
  body.querySelector('[data-empty-trash]')?.addEventListener('click', async () => {
    if (!await confirmDestructive({ title: 'Delete these items permanently?', message: 'You can’t undo this action. (Nothing real is deleted: this is a demo.)', confirm: 'Empty Trash', iconName: 'trash' })) return;
    trash = [];
    store.set('trash', trash);
    renderTrash();
    renderDock();
  });
}

// ---------------------------------------------------------------- Scratchpad (paste and snippet target)

let pad;
export const scratchpad = {
  get el() { return pad; },
  insert(text) {
    openWindow('scratchpad');
    pad.focus();
    pad.setRangeText(text, pad.selectionStart, pad.selectionEnd, 'end');
    pad.dispatchEvent(new Event('input', { bubbles: true }));
  },
  insertImage(src, label) {
    openWindow('scratchpad');
    const strip = $('#win-scratchpad .attachments');
    strip.hidden = false;
    strip.append(html`<figure><img src="${src}" alt="${esc(label)}"><figcaption>${esc(label)}</figcaption></figure>`);
  },
};

function buildScratchpad(body) {
  body.innerHTML = `<textarea class="pad" spellcheck="false" aria-label="Scratchpad text">Scratchpad

Paste here from the clipboard history (${shortcutText('clipboard')}), or type ;sig, ;addr, ;q or ;mtg and a snippet takes its place.

A link to copy, with tracking on it:
https://news.example.org/story?id=7&utm_source=social&utm_campaign=fall&gclid=Cj0demo

</textarea><div class="attachments" hidden></div>`;
  pad = body.querySelector('textarea');
}

// ---------------------------------------------------------------- Vault (an app on the ignored list)

function buildVault(body) {
  body.innerHTML = `<div class="vault">
    <div class="vault-item">
      <span class="vault-ic">${icon('lock')}</span>
      <div class="grow"><b>Example Bank</b><span class="dim">alex@example.com</span></div>
    </div>
    <div class="vault-field"><span class="dim">Password</span><code>••••••••••••</code><button type="button" class="btn btn-small" data-copy-password>Copy Password</button></div>
    <div class="vault-field"><span class="dim">Note</span><span class="vault-note">Recovery code is in the blue notebook, page 12.</span><button type="button" class="btn btn-small" data-copy-note>Copy</button></div>
    <p class="fine">Vault marks a copied password as concealed, and Vault is on Zenith's ignored list, so neither copy is kept in the history. Remove Vault from the list in Settings → General and copy the note again.</p>
  </div>`;
  body.querySelector('[data-copy-password]').addEventListener('click', () => {
    bus.emit('copy', { text: 'correct-horse-battery-demo', app: 'Vault', concealed: true });
  });
  body.querySelector('[data-copy-note]').addEventListener('click', () => {
    bus.emit('copy', { text: 'Recovery code is in the blue notebook, page 12.', app: 'Vault' });
  });
}

// ---------------------------------------------------------------- Viewer (Sample.png)

function buildViewer(body) {
  const cv = document.createElement('canvas');
  cv.className = 'sample';
  cv.width = sample.canvas.width;
  cv.height = sample.canvas.height;
  cv.getContext('2d').drawImage(sample.canvas, 0, 0);
  cv.setAttribute('role', 'img');
  cv.setAttribute('aria-label', 'A receipt for a desk lamp and a shade, with a QR code to the Zenith source code');
  body.append(cv);
  body.append(html`<p class="viewer-hint">Press ${esc(shortcutText('ocr'))} and drag over the text or the QR code.</p>`);
}

// ---------------------------------------------------------------- Sketchbook (an app to uninstall)

function buildSketchbook(body) {
  body.innerHTML = `<canvas class="sketch" width="600" height="300" aria-label="Drawing area"></canvas><p class="fine">A made-up app. Drag <b>Sketchbook.app</b> from the desktop onto the notch to try Deep Uninstall and Slim.</p>`;
  const cv = body.querySelector('canvas');
  const g = cv.getContext('2d');
  g.lineCap = 'round';
  g.lineWidth = 4;
  cv.addEventListener('pointerdown', (e) => {
    cv.setPointerCapture(e.pointerId);
    const r = cv.getBoundingClientRect();
    const k = cv.width / r.width;
    g.strokeStyle = `hsl(${Math.random() * 360} 80% 55%)`;
    g.beginPath();
    g.moveTo((e.clientX - r.left) * k, (e.clientY - r.top) * k);
    const move = (ev) => { g.lineTo((ev.clientX - r.left) * k, (ev.clientY - r.top) * k); g.stroke(); };
    const up = () => { cv.removeEventListener('pointermove', move); cv.removeEventListener('pointerup', up); };
    cv.addEventListener('pointermove', move);
    cv.addEventListener('pointerup', up);
  });
}

// ---------------------------------------------------------------- lock screen

function lockScreen() {
  if ($('.lock')) return;
  closeMenus();
  bus.emit('lock');
  const d = new Date();
  const el = html`<div class="lock" role="dialog" aria-modal="true" aria-label="Locked">
    <div class="lock-time">${d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</div>
    <div class="lock-date">${d.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })}</div>
    <button type="button" class="btn lock-btn">Click to unlock</button>
  </div>`;
  const release = captureKeys((e) => { if (e.key === 'Enter' || e.key === ' ' || e.key === 'Escape') unlock(); return true; });
  const unlock = () => { release(); el.remove(); bus.emit('unlock'); };
  el.addEventListener('click', unlock);
  document.body.append(el);
  el.querySelector('button').focus();
}

// ---------------------------------------------------------------- Cleaning Mode

function cleaningMode() {
  if ($('.cleaning')) return;
  const total = settings.cleaningSeconds;
  let left = total;
  const el = html`<div class="cleaning ${settings.cleaningScreen}" role="dialog" aria-modal="true" aria-label="Cleaning Mode">
    <div class="cleaning-box">
      ${icon('sparkles')}
      <b>Cleaning Mode</b>
      <span class="cleaning-left">${left} s</span>
      <span class="dim">Keyboard and pointer are blocked. Wipe away.<br>Hold ⌃ Control, ⌥ Option and ⌘ Command for 2 seconds to stop early.</span>
      <span class="hold"><span></span></span>
    </div>
  </div>`;
  document.body.append(el);
  bus.emit('tour', 'cleaning');
  let holdStart = null;
  let holdRaf = 0;
  const holdBar = el.querySelector('.hold span');
  const holdLoop = () => {
    if (holdStart == null) { holdBar.style.width = '0%'; return; }
    const p = Math.min((performance.now() - holdStart) / 2000, 1);
    holdBar.style.width = `${p * 100}%`;
    if (p >= 1) { end('Stopped early'); return; }
    holdRaf = requestAnimationFrame(holdLoop);
  };
  const onModifiers = (e) => {
    const exact = e.ctrlKey && e.altKey && e.metaKey && !e.shiftKey && ['Control', 'Alt', 'Meta', 'OS'].includes(e.key);
    if (exact && holdStart == null && e.type === 'keydown') { holdStart = performance.now(); holdRaf = requestAnimationFrame(holdLoop); }
    if (!exact || e.type === 'keyup') { holdStart = null; cancelAnimationFrame(holdRaf); holdBar.style.width = '0%'; }
  };
  const release = captureKeys((e) => { onModifiers(e); return true; });
  const up = (e) => { e.preventDefault(); onModifiers(e); };
  document.addEventListener('keyup', up, true);
  const block = (e) => { e.preventDefault(); e.stopPropagation(); };
  ['pointerdown', 'click', 'wheel', 'contextmenu'].forEach((t) => el.addEventListener(t, block, { passive: false }));
  const timer = setInterval(() => {
    left -= 1;
    el.querySelector('.cleaning-left').textContent = `${left} s`;
    if (left <= 0) end('Time is up');
  }, 1000);
  function end(reason) {
    clearInterval(timer);
    cancelAnimationFrame(holdRaf);
    release();
    document.removeEventListener('keyup', up, true);
    el.remove();
    notify({ icon: 'sparkles', title: 'Cleaning Mode ended', subtitle: reason });
  }
}

// ---------------------------------------------------------------- quitting and reopening Zenith

function quitZenith() {
  setZenithRunning(false);
  island.close();
  const el = html`<div class="relaunch" role="status">${icon('zenith')}<span>Zenith has quit. Its shortcuts and island are gone. Privacy Shield and Keep Awake are off.</span><button type="button" class="btn btn-small btn-primary">Open Zenith</button></div>`;
  if (settings.shieldOn) setSetting('shieldOn', false);
  keepAwake.set(null, { quiet: true });
  el.querySelector('button').addEventListener('click', () => { el.remove(); setZenithRunning(true); notify({ icon: 'zenith', title: 'Zenith is running', subtitle: 'In the notch' }); });
  document.body.append(el);
}

// ---------------------------------------------------------------- Read Me: tabs and "Try it here"

function readmeTab(tab) {
  $$('[data-readme-tab]').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.readmeTab === tab)));
  $$('[data-readme-pane]').forEach((p) => { p.hidden = p.dataset.readmePane !== tab; });
}

function tourItems() {
  const k = (id) => `<kbd>${esc(shortcutText(id) || 'no shortcut')}</kbd>`;
  return [
    { id: 'island-hover', title: 'Rest the pointer on the notch', how: `The island swells, then opens after ${settings.hoverDelay} s if the pointer stays: what is going on, and a dock of tools under it. A click opens it at once.`, go: () => island.open() },
    { id: 'island-swipe', title: 'Swipe on the island', how: 'Two fingers on a trackpad: pull down to open, push up to close, sideways for the next or previous track.' },
    { id: 'island-seek', title: 'Seek and skip', how: 'Drag the progress bar. The video playing in Chrome has no next or previous, so those buttons are dimmed.', go: () => island.open('music') },
    { id: 'timer', title: 'Start a focus timer', how: 'In the island’s Widgets tab, the second small tab beside the notch. The time left stays beside the notch.', go: () => island.open('widgets') },
    { id: 'tools', title: 'Open All Tools', how: 'The last icon on the dock opens every tool, with its full name, in four groups inside the island. A page stays open until you press ✕, Esc or click elsewhere. Settings, Cleaner, Ports and Homebrew open the Settings window instead.', go: () => island.openPage('tools') },
    { id: 'dock-edit', title: 'Edit the dock', how: 'On the Tools page press Edit Dock: click a tool to add or remove it (six at most), drag the icons on the strip to reorder. Right-click an icon on the dock for Move Left, Move Right and Remove.', go: () => island.editDock() },
    { id: 'awake', title: 'Keep the Mac awake', how: 'Click the mug on the dock: 15 min, 1 h, 2 h, 5 h or ∞ (until turned off) appear right there. Hover it while it is on to see the time left; click it to turn it off.', go: () => island.open() },
    { id: 'hud', title: 'Plug in the charger', how: 'From the Events menu or the battery icon in the menu bar. The island shows the charge and the charger.', go: () => setTimeout(() => showMenu($('[data-menu="events"]').offsetParent ? $('[data-menu="events"]') : $('.mb-logo'), menuItems('events'))) },
    { id: 'shelf', title: 'Drop a file on the notch', how: 'Drag any file from your computer, or some text, to the top of the screen. It stays in your browser.' },
    { id: 'uninstall', title: 'Uninstall an app', how: 'Uninstall App on the dock: pick an app, see the files it keeps with their sizes, untick what you want to keep, confirm. Or drag Sketchbook.app from the desktop onto the notch for Deep Uninstall or Slim.', go: () => runAction('settings', { tab: 'cleaner', cleanTab: 'uninstall' }) },
    { id: 'hub', title: 'Bring back the menu bar icon', how: 'Settings → Dynamic Island → Behavior → Menu Bar Icon. The Command Hub then opens from it: Privacy Shield and Keep Awake tiles, gauges and running apps.', go: () => runAction('settings', 'island') },
    { id: 'clipboard', title: 'Paste from the clipboard history', how: `Press ${k('clipboard')}, browse the cards with ← →, press Return. It lands in Scratchpad.`, go: () => runAction('clipboard') },
    { id: 'clean-link', title: 'Paste a link without its tracking', how: 'In the history, select the shop link card and press ⇧Return, or right-click it.', go: () => runAction('clipboard') },
    { id: 'privacy-copy', title: 'Copy a password', how: 'Copy Password in Vault. The history does not keep it.', go: () => openWindow('vault') },
    { id: 'ocr', title: 'Copy text from the screen', how: `Press ${k('ocr')} and drag over any text, such as this list.`, go: () => runAction('ocr') },
    { id: 'qr', title: 'Read a QR code', how: `Open Sample.png, press ${k('ocr')} and drag over the code.`, go: () => openWindow('viewer') },
    { id: 'capture', title: 'Capture and annotate', how: `Press ${k('captureArea')}, or Capture Area on the dock. Drag an area, draw an arrow, then Copy or Save.`, go: () => runAction('captureArea') },
    { id: 'snippet', title: 'Expand a snippet', how: 'Type ;sig in Scratchpad, or press ' + k('snippets') + ' to pick one.', go: () => openWindow('scratchpad') },
    { id: 'cleaner', title: 'Scan and clean', how: 'Quick Clean on the dock, or All Tools → Cleaner, which opens Settings. Nothing goes until you confirm.', go: () => runAction('settings', { tab: 'cleaner', cleanTab: 'system' }) },
    { id: 'shield', title: 'Turn on Privacy Shield', how: 'The shield on the dock is a switch. Then type a tracker’s name in Settings → Privacy Shield to see it refused.', go: () => runAction('settings', 'privacy') },
    { id: 'shortcut', title: 'Change a shortcut', how: 'Settings → Shortcuts. The new keys work on this page at once.', go: () => runAction('settings', 'shortcuts') },
    { id: 'cleaning', title: 'Try Cleaning Mode', how: `${k('cleaningMode')} blocks the keyboard and pointer for ${settings.cleaningSeconds} s. Hold ⌃⌥⌘ for 2 s to stop.`, go: () => runAction('cleaningMode') },
    { id: 'fullscreen', title: 'Make a window full screen', how: 'Its green button. The island hides and notices move to a floating panel.', go: () => { openWindow('readme'); } },
  ];
}

function renderTour() {
  const list = $('#tour');
  const items = tourItems();
  list.innerHTML = items.map((t) => `<li class="${tourDone.has(t.id) ? 'done' : ''}" data-tour="${t.id}">
    <span class="tour-check" aria-label="${tourDone.has(t.id) ? 'Done' : 'Not tried yet'}">${tourDone.has(t.id) ? icon('check') : ''}</span>
    <span class="grow"><b>${esc(t.title)}</b><span>${t.how}</span></span>
    ${t.go ? `<button type="button" class="btn btn-small" data-tour-go="${t.id}">Try</button>` : ''}
  </li>`).join('');
  const done = items.filter((t) => tourDone.has(t.id)).length;
  $('#tour-count').textContent = `${done} of ${items.length} tried`;
  $('#tour-bar').style.width = `${(done / items.length) * 100}%`;
  list.querySelectorAll('[data-tour-go]').forEach((b) => b.addEventListener('click', (e) => {
    e.stopPropagation();
    items.find((t) => t.id === b.dataset.tourGo)?.go();
  }));
}

function initReadme() {
  $$('[data-readme-tab]').forEach((b) => b.addEventListener('click', () => readmeTab(b.dataset.readmeTab)));
  $('.seg[aria-label="Read Me sections"]').addEventListener('keydown', (e) => {
    if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return;
    const tabs = $$('[data-readme-tab]');
    const i = tabs.indexOf(document.activeElement);
    const next = tabs[(i + (e.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length];
    next.focus();
    next.click();
  });
  $$('[data-copy-target]').forEach((b) => b.addEventListener('click', async () => {
    const text = $(`#${b.dataset.copyTarget}`).textContent;
    try { await navigator.clipboard.writeText(text); b.textContent = 'Copied'; } catch { b.textContent = 'Select and copy'; }
    bus.emit('copy', { text, app: 'Read Me', fromPage: true });
    setTimeout(() => { b.textContent = 'Copy'; }, 1600);
  }));
  renderTour();
  bus.on('tour-changed', renderTour);
  bus.on('setting', ({ key }) => { if (['shortcuts', 'hoverDelay', 'cleaningSeconds'].includes(key)) renderTour(); });
}

async function resetDemo() {
  if (await ask({ title: 'Reset the demo?', message: 'Settings, clipboard items, tried features and the Trash go back to how they were.', buttons: ['Cancel', 'Reset'] }) !== 1) return;
  store.clear();
  location.reload();
}

// ---------------------------------------------------------------- setup

export function initDesktop() {
  drawSample();
  drawWallpaper();
  let resizeTimer = 0;
  window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(drawWallpaper, 120); });
  bus.on('appearance', drawWallpaper);

  registerWindow('readme', { app: 'Read Me', title: 'Read Me', width: 720, height: 600, x: 24, y: 48 });
  registerWindow('scratchpad', { app: 'Scratchpad', title: 'Scratchpad', width: 520, height: 400, build: buildScratchpad });
  registerWindow('vault', { app: 'Vault', title: 'Vault', width: 460, build: buildVault });
  registerWindow('viewer', { app: 'Preview', title: 'Sample.png', width: 640, build: buildViewer });
  registerWindow('sketchbook', { app: 'Sketchbook', title: 'Sketchbook', width: 560, build: buildSketchbook });
  registerWindow('trash', { app: 'Finder', title: 'Trash', width: 480, height: 340, onOpen: renderTrash });

  initMenuBar();
  initDesktopIcons();
  initReadme();
  bus.on('windows', updateDockDots);

  registerAction('cleaningMode', cleaningMode);
  registerAction('lock', lockScreen);
  registerAction('quit', quitZenith);
  registerAction('record', () => notify({ icon: 'record', title: 'Screen recording is not in the web demo', subtitle: 'In the app: drag an area, click a window or press Return for the whole screen.', duration: 4200 }));
  registerAction('scrolling', () => notify({ icon: 'screen', title: 'Scrolling Capture is not in the web demo', subtitle: 'In the app: drag over a page and Zenith joins the frames as it scrolls.', duration: 4200 }));

  // Snippet expansion and copies inside Scratchpad are wired by clipboard.js; the Read Me opens first.
  openWindow('readme');
  if (window.innerWidth >= 1100) openWindow('scratchpad');
  if (window.innerWidth >= 1100) {
    const sp = windowSpec('scratchpad').el;
    sp.style.left = `${window.innerWidth - 560 - 120}px`;
    sp.style.top = `${window.innerHeight - 470}px`;
    focusWindow('readme');
  }
}

export { readmeTab, power, VERSION, playSound };
