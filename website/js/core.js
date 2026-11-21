// Shared pieces of the demo desktop: helpers, settings, windows, menus, dialogs, shortcuts, sounds and notices.
// Everything is made up and stays in the browser; nothing here talks to a server.

// Keep equal to Sources/ZenithCore/Models/ZenithVersion.swift.
export const VERSION = '2.6.0';

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
export const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
export const reduceMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;
export const isNarrow = () => window.matchMedia('(max-width: 720px)').matches;
export const isTouch = () => window.matchMedia('(hover: none)').matches;

export function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

export function icon(name, cls = 'ic') {
  return `<svg class="${cls}" aria-hidden="true"><use href="#i-${name}"/></svg>`;
}

export function html(strings, ...values) {
  const t = document.createElement('template');
  t.innerHTML = String.raw(strings, ...values).trim();
  return t.content.firstElementChild;
}

export function formatBytes(bytes) {
  if (bytes < 1000) return `${bytes} bytes`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = bytes;
  let i = -1;
  do { v /= 1000; i++; } while (v >= 1000 && i < units.length - 1);
  return `${v >= 100 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

export function formatClock(seconds) {
  const s = Math.max(0, Math.round(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = String(s % 60).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${r}` : `${m}:${r}`;
}

export function announce(text) {
  const live = $('#live');
  if (!live) return;
  live.textContent = '';
  requestAnimationFrame(() => { live.textContent = text; });
}

// ---------------------------------------------------------------- events

const target = new EventTarget();
export const bus = {
  on(type, fn) {
    const h = (e) => fn(e.detail);
    target.addEventListener(type, h);
    return () => target.removeEventListener(type, h);
  },
  emit(type, detail) { target.dispatchEvent(new CustomEvent(type, { detail })); },
};

// ---------------------------------------------------------------- storage (a convenience; the demo works without it)

const PREFIX = 'zenith-demo:';
export const store = {
  get(key, fallback) {
    try {
      const raw = localStorage.getItem(PREFIX + key);
      return raw == null ? fallback : JSON.parse(raw);
    } catch { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem(PREFIX + key, JSON.stringify(value)); } catch { /* private mode */ }
  },
  clear() {
    try {
      Object.keys(localStorage).filter((k) => k.startsWith(PREFIX)).forEach((k) => localStorage.removeItem(k));
    } catch { /* ignore */ }
  },
};

// ---------------------------------------------------------------- settings (defaults follow the app's)

const DEFAULTS = {
  appearance: 'auto',
  notch: true,
  islandEnabled: true,
  hoverDelay: 0.25,
  swipes: true,
  toolDock: true,
  menuBarIcon: false,
  dockLayout: null,
  aiAgents: false,
  hideInFullScreen: true,
  timerWidget: true,
  focusMinutes: 25,
  breakMinutes: 5,
  calendarWidget: false,
  calendarAccess: 'notDetermined',
  speedWidget: false,
  openAtLogin: true,
  checkUpdates: true,
  historyLimit: 200,
  clearAfter: 0,
  clearOnLock: false,
  cleanLinksOnCopy: false,
  ignoredApps: ['Vault'],
  soundsOn: false,
  soundVolume: 0.5,
  // The app's defaults (AudioFeedbackManager.standardSoundName).
  sounds: { capture: 'Hero', copy: 'Pop', paste: 'Tink', pin: 'Purr', delete: 'Basso', error: 'Basso', color: 'Ping' },
  snippetsOn: true,
  shieldOn: false,
  shieldProvider: 'cloudflare',
  shieldPort: 8080,
  blockTrackers: false,
  blocklist: ['tracker.example-ads.net', 'pixel.example-metrics.com'],
  neverBlock: [],
  scheduledScan: false,
  scanFrequency: 'weekly',
  cleaningSeconds: 15,
  cleaningScreen: 'dim',
  keepAwakeDisplay: true,
  shortcuts: null,
};

export const settings = { ...structuredClone(DEFAULTS), ...store.get('settings', {}) };
delete settings.levelHUD; // gone in 2.6.0: macOS draws the volume and brightness bars itself

export function setSetting(key, value) {
  settings[key] = value;
  store.set('settings', settings);
  bus.emit('setting', { key, value });
  bus.emit(`setting:${key}`, value);
}

export function resetSettings() {
  Object.keys(settings).forEach((k) => delete settings[k]);
  Object.assign(settings, structuredClone(DEFAULTS));
  store.set('settings', settings);
}

// ---------------------------------------------------------------- appearance

export function applyAppearance() {
  const mode = settings.appearance;
  const dark = mode === 'dark' || (mode === 'auto' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  bus.emit('appearance', dark ? 'dark' : 'light');
}
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyAppearance);
bus.on('setting:appearance', applyAppearance);

// ---------------------------------------------------------------- Zenith running or quit

export const app = { running: true };
export function setZenithRunning(running) {
  app.running = running;
  document.body.classList.toggle('zenith-quit', !running);
  bus.emit('zenith-running', running);
}

// ---------------------------------------------------------------- sounds (synthesised, short, off by default)

let audioCtx = null;
const SOUND_RECIPES = {
  Pop: [[880, 0.06, 'sine', 420]],
  Tink: [[2400, 0.08, 'triangle']],
  Glass: [[1568, 0.35, 'sine'], [2093, 0.3, 'sine']],
  Bottle: [[330, 0.18, 'sine', 300]],
  Funk: [[220, 0.12, 'square'], [165, 0.14, 'square']],
  Ping: [[1760, 0.4, 'sine']],
  Purr: [[140, 0.25, 'sawtooth', 120]],
  Submarine: [[523, 0.5, 'sine', 500]],
  Hero: [[523, 0.12, 'triangle'], [659, 0.12, 'triangle'], [784, 0.3, 'triangle']],
  Basso: [[98, 0.35, 'sawtooth']],
  Blow: [[300, 0.3, 'sine', 600]],
  Frog: [[180, 0.08, 'square'], [140, 0.1, 'square']],
  Morse: [[1000, 0.05, 'square'], [1000, 0.05, 'square']],
  Sosumi: [[880, 0.08, 'triangle'], [660, 0.18, 'triangle']],
};
export const SOUND_NAMES = Object.keys(SOUND_RECIPES);

export function playSound(nameOrEvent, { force = false } = {}) {
  if (!force && !settings.soundsOn) return;
  const name = settings.sounds[nameOrEvent] ?? nameOrEvent;
  const recipe = SOUND_RECIPES[name];
  if (!recipe) return;
  try {
    audioCtx ??= new (window.AudioContext || window.webkitAudioContext)();
    let t = audioCtx.currentTime + 0.01;
    for (const [freq, dur, type, glideTo] of recipe) {
      const osc = audioCtx.createOscillator();
      const gain = audioCtx.createGain();
      osc.type = type;
      osc.frequency.setValueAtTime(freq, t);
      if (glideTo) osc.frequency.exponentialRampToValueAtTime(glideTo, t + dur);
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.25 * settings.soundVolume + 0.0001, t + 0.01);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      osc.connect(gain).connect(audioCtx.destination);
      osc.start(t);
      osc.stop(t + dur + 0.02);
      t += dur * 0.8;
    }
  } catch { /* no audio */ }
}

// ---------------------------------------------------------------- notices: the island takes them, else a floating toast

let noticeHandler = null;
export function setNoticeHandler(fn) { noticeHandler = fn; }

export function notify(notice) {
  const n = { icon: 'zenith', tint: 'accent', duration: 2600, ...notice };
  announce([n.title, n.subtitle].filter(Boolean).join('. '));
  if (app.running && noticeHandler && noticeHandler(n)) return;
  floatingToast(n);
}

export function floatingToast(n) {
  const layer = $('#toast-layer');
  const el = html`<div class="toast tint-${esc(n.tint)}">${icon(n.icon)}<div><b>${esc(n.title)}</b>${n.subtitle ? `<span>${esc(n.subtitle)}</span>` : ''}</div></div>`;
  layer.append(el);
  requestAnimationFrame(() => el.classList.add('in'));
  setTimeout(() => { el.classList.remove('in'); setTimeout(() => el.remove(), 300); }, n.duration);
}

// ---------------------------------------------------------------- windows

const windows = new Map();
let zTop = 10;
let cascade = 0;

export function registerWindow(id, spec) {
  windows.set(id, { id, built: false, el: null, ...spec });
}

function buildWindow(w) {
  if (w.built) return w.el;
  let el = document.getElementById(`win-${w.id}`);
  if (!el) {
    el = html`<section class="win ${w.className ?? ''}" id="win-${w.id}" data-win="${w.id}" data-app="${esc(w.app)}" role="dialog" aria-label="${esc(w.title)}" tabindex="-1">
      <header class="win-bar">
        <div class="traffic">
          <button type="button" class="tl tl-close" data-win-action="close" aria-label="Close"></button>
          <button type="button" class="tl tl-min" data-win-action="min" aria-label="Minimize"></button>
          <button type="button" class="tl tl-zoom" data-win-action="zoom" aria-label="Full screen"></button>
        </div>
        <h2 class="win-title">${esc(w.title)}</h2>
        <div class="win-tools"></div>
      </header>
      <div class="win-body"></div>
    </section>`;
    $('#windows').append(el);
    w.build?.(el.querySelector('.win-body'), el);
  }
  el.hidden = true;
  w.el = el;
  w.built = true;
  wireWindow(w);
  return el;
}

function wireWindow(w) {
  const el = w.el;
  el.addEventListener('pointerdown', () => focusWindow(w.id), true);
  el.querySelector('[data-win-action="close"]').addEventListener('click', () => closeWindow(w.id));
  el.querySelector('[data-win-action="min"]').addEventListener('click', () => minimizeWindow(w.id));
  el.querySelector('[data-win-action="zoom"]').addEventListener('click', () => toggleFullScreen(w.id));
  const bar = el.querySelector('.win-bar');
  bar.addEventListener('dblclick', (e) => { if (!e.target.closest('button')) toggleFullScreen(w.id); });
  bar.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || e.target.closest('button, input, select, a') || el.classList.contains('fullscreen') || isNarrow()) return;
    const rect = el.getBoundingClientRect();
    const dx = e.clientX - rect.left;
    const dy = e.clientY - rect.top;
    bar.setPointerCapture(e.pointerId);
    el.classList.add('dragging');
    const move = (ev) => {
      const x = clamp(ev.clientX - dx, 80 - rect.width, window.innerWidth - 80);
      const y = clamp(ev.clientY - dy, 28, window.innerHeight - 40);
      el.style.left = `${x}px`;
      el.style.top = `${y}px`;
    };
    const up = () => {
      el.classList.remove('dragging');
      bar.removeEventListener('pointermove', move);
      bar.removeEventListener('pointerup', up);
      bar.removeEventListener('pointercancel', up);
    };
    bar.addEventListener('pointermove', move);
    bar.addEventListener('pointerup', up);
    bar.addEventListener('pointercancel', up);
  });
}

function placeWindow(w) {
  const el = w.el;
  if (el.dataset.placed) return;
  el.dataset.placed = '1';
  const width = Math.min(w.width ?? 640, window.innerWidth - 32);
  const height = Math.min(w.height ?? 460, window.innerHeight - 140);
  el.style.width = `${width}px`;
  if (w.height) el.style.height = `${height}px`;
  const offset = (cascade++ % 6) * 26;
  const x = w.x ?? Math.round((window.innerWidth - width) / 2 + offset - 60);
  const y = w.y ?? Math.round(Math.max(56, (window.innerHeight - height) / 2 - 30) + offset);
  el.style.left = `${clamp(x, 8, Math.max(8, window.innerWidth - width - 8))}px`;
  el.style.top = `${clamp(y, 40, Math.max(40, window.innerHeight - 120))}px`;
}

export function openWindow(id, arg) {
  const w = windows.get(id);
  if (!w) return;
  const el = buildWindow(w);
  placeWindow(w);
  const wasHidden = el.hidden;
  el.hidden = false;
  el.classList.remove('minimized');
  if (wasHidden && !reduceMotion()) {
    el.classList.add('opening');
    setTimeout(() => el.classList.remove('opening'), 260);
  }
  focusWindow(id);
  w.onOpen?.(arg, el);
  bus.emit('windows');
  return el;
}

export function closeWindow(id) {
  const w = windows.get(id);
  if (!w?.el || w.el.hidden) return;
  if (w.el.classList.contains('fullscreen')) toggleFullScreen(id);
  w.el.hidden = true;
  w.el.classList.remove('focused');
  w.onClose?.();
  const next = frontWindow();
  if (next) focusWindow(next); else bus.emit('focus', null);
  bus.emit('windows');
}

export function minimizeWindow(id) {
  const w = windows.get(id);
  if (!w?.el) return;
  if (w.el.classList.contains('fullscreen')) toggleFullScreen(id);
  w.el.classList.add('minimized');
  setTimeout(() => {
    w.el.hidden = true;
    w.el.classList.remove('focused');
    const next = frontWindow();
    if (next) focusWindow(next); else bus.emit('focus', null);
    bus.emit('windows');
  }, reduceMotion() ? 0 : 220);
}

export function toggleFullScreen(id) {
  const w = windows.get(id);
  if (!w?.el) return;
  const on = !w.el.classList.contains('fullscreen');
  w.el.classList.toggle('fullscreen', on);
  document.body.classList.toggle('has-fullscreen', !!$('.win.fullscreen:not([hidden])'));
  bus.emit('fullscreen', { id, on });
  if (on) bus.emit('tour', 'fullscreen');
}

export function focusWindow(id) {
  const w = windows.get(id);
  if (!w?.el || w.el.hidden) return;
  $$('.win.focused').forEach((el) => el !== w.el && el.classList.remove('focused'));
  if (!w.el.classList.contains('focused') || Number(w.el.style.zIndex) !== zTop) {
    w.el.style.zIndex = String(++zTop);
    w.el.classList.add('focused');
  }
  bus.emit('focus', id);
}

export function frontWindow() {
  let best = null;
  let z = -1;
  for (const w of windows.values()) {
    if (w.el && !w.el.hidden && Number(w.el.style.zIndex || 0) > z) { z = Number(w.el.style.zIndex || 0); best = w.id; }
  }
  return best;
}

export const isWindowOpen = (id) => !!windows.get(id)?.el && !windows.get(id).el.hidden;
export const windowSpec = (id) => windows.get(id);
export const allWindows = () => Array.from(windows.values());
export const anyFullScreen = () => !!$('.win.fullscreen:not([hidden])');

/** The app name of the frontmost window, as the menu bar shows it. */
export function frontAppName() {
  const id = frontWindow();
  return id ? windows.get(id).app : 'Finder';
}

// ---------------------------------------------------------------- menus

let openMenu = null;

export function closeMenus() {
  if (!openMenu) return;
  openMenu.el.remove();
  openMenu.anchor?.classList.remove('open');
  openMenu.anchor?.setAttribute('aria-expanded', 'false');
  openMenu.onClose?.();
  openMenu = null;
}

export const menuIsOpen = () => !!openMenu;
export const menuAnchor = () => openMenu?.anchor ?? null;

/**
 * items: { label, shortcut, action, checked, disabled, separator, header, html }
 * `html` puts custom content (a slider) in the menu.
 */
export function showMenu(anchor, items, { align = 'left', onClose, className = '' } = {}) {
  closeMenus();
  const el = html`<div class="menu ${className}" role="menu"></div>`;
  for (const item of items) {
    if (item.separator) { el.append(html`<div class="menu-sep" role="separator"></div>`); continue; }
    if (item.header) { el.append(html`<div class="menu-header">${esc(item.header)}</div>`); continue; }
    if (item.html) { const node = item.html(); node.classList.add('menu-custom'); el.append(node); continue; }
    const row = html`<button type="button" class="menu-item" role="menuitem${item.checked != null ? 'checkbox' : ''}" ${item.disabled ? 'disabled' : ''}>
      <span class="menu-check">${item.checked ? icon('check') : ''}</span>
      <span class="menu-label">${esc(item.label)}</span>
      ${item.shortcut ? `<span class="menu-key">${esc(item.shortcut)}</span>` : ''}
    </button>`;
    if (item.checked != null) row.setAttribute('aria-checked', String(!!item.checked));
    row.addEventListener('click', () => { closeMenus(); item.action?.(); });
    el.append(row);
  }
  $('#menu-layer').append(el);
  const r = anchor.getBoundingClientRect();
  const w = el.offsetWidth;
  let x = align === 'right' ? r.right - w : r.left;
  x = clamp(x, 6, window.innerWidth - w - 6);
  el.style.left = `${x}px`;
  el.style.top = `${Math.round(r.bottom + 2)}px`;
  anchor.classList.add('open');
  anchor.setAttribute('aria-expanded', 'true');
  openMenu = { el, anchor, onClose };
  el.addEventListener('keydown', (e) => {
    const rows = $$('.menu-item:not([disabled]), .menu-custom input', el);
    const i = rows.indexOf(document.activeElement);
    if (e.key === 'ArrowDown') { e.preventDefault(); rows[(i + 1) % rows.length]?.focus(); }
    if (e.key === 'ArrowUp') { e.preventDefault(); rows[(i - 1 + rows.length) % rows.length]?.focus(); }
    if (e.key === 'Escape') { e.preventDefault(); closeMenus(); anchor.focus(); }
  });
  return el;
}

/** A context menu at the pointer. */
export function showContextMenu(x, y, items) {
  const fake = { getBoundingClientRect: () => ({ left: x, right: x, bottom: y - 2 }), classList: { add() {}, remove() {} }, setAttribute() {}, focus() {} };
  return showMenu(fake, items);
}

document.addEventListener('pointerdown', (e) => {
  if (!openMenu) return;
  if (openMenu.el.contains(e.target) || openMenu.anchor === e.target || openMenu.anchor?.contains?.(e.target)) return;
  closeMenus();
}, true);
window.addEventListener('resize', closeMenus);

// ---------------------------------------------------------------- dialogs (like NSAlert / the app's DestructiveConfirmation)

export function ask({ title, message = '', details = [], buttons = ['Cancel', 'OK'], destructive = false, iconName = 'zenith' }) {
  return new Promise((resolve) => {
    const scrim = html`<div class="scrim" role="presentation">
      <div class="alert" role="alertdialog" aria-modal="true" aria-labelledby="alert-title">
        <div class="alert-icon">${icon(iconName)}</div>
        <h3 id="alert-title">${esc(title)}</h3>
        ${message ? `<p>${esc(message)}</p>` : ''}
        ${details.length ? `<ul class="alert-list">${details.map((d) => `<li>${esc(d)}</li>`).join('')}</ul>` : ''}
        <div class="alert-buttons"></div>
      </div>
    </div>`;
    const row = scrim.querySelector('.alert-buttons');
    const prevFocus = document.activeElement;
    const finish = (value) => {
      scrim.remove();
      document.removeEventListener('keydown', onKey, true);
      prevFocus?.focus?.();
      resolve(value);
    };
    buttons.forEach((label, i) => {
      const last = i === buttons.length - 1;
      const b = html`<button type="button" class="btn ${last ? (destructive ? 'btn-danger' : 'btn-primary') : ''}">${esc(label)}</button>`;
      b.addEventListener('click', () => finish(i));
      row.append(b);
    });
    const onKey = (e) => {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(0); }
    };
    document.addEventListener('keydown', onKey, true);
    document.body.append(scrim);
    // A destructive default is not the Return key: focus Cancel, as the app does.
    row.children[destructive ? 0 : buttons.length - 1].focus();
  });
}

export async function confirmDestructive(opts) {
  return (await ask({ buttons: ['Cancel', opts.confirm ?? 'Delete'], destructive: true, ...opts })) === 1;
}

// ---------------------------------------------------------------- keyboard shortcuts

export const SHORTCUT_DEFS = [
  { id: 'clipboard', title: 'Clipboard History', def: { meta: 1, shift: 1, code: 'KeyV' }, alt: { alt: 1, code: 'KeyV' } },
  { id: 'captureArea', title: 'Capture Area', def: { meta: 1, shift: 1, code: 'Digit2' }, alt: { meta: 1, shift: 1, code: 'KeyX' } },
  { id: 'captureScreen', title: 'Capture Screen', def: { meta: 1, shift: 1, code: 'Digit1' } },
  { id: 'ocr', title: 'Copy Text (OCR, QR codes)', def: { ctrl: 1, alt: 1, code: 'KeyT' } },
  { id: 'snippets', title: 'Snippets', def: { ctrl: 1, alt: 1, code: 'KeyS' } },
  { id: 'record', title: 'Record Screen', def: { ctrl: 1, alt: 1, code: 'KeyR' } },
  { id: 'scrolling', title: 'Scrolling Capture', def: { ctrl: 1, alt: 1, code: 'KeyL' } },
  { id: 'cleaningMode', title: 'Cleaning Mode', def: { ctrl: 1, alt: 1, shift: 1, code: 'KeyK' } },
];

export function shortcutFor(id) {
  const custom = settings.shortcuts?.[id];
  if (custom === null) return null;
  return custom ?? SHORTCUT_DEFS.find((d) => d.id === id)?.def ?? null;
}

export function setShortcut(id, combo) {
  setSetting('shortcuts', { ...(settings.shortcuts ?? {}), [id]: combo });
}

export function keyName(code) {
  if (!code) return '';
  if (code.startsWith('Key')) return code.slice(3);
  if (code.startsWith('Digit')) return code.slice(5);
  return ({ Space: 'Space', Comma: ',', Period: '.', Slash: '/', Semicolon: ';', Quote: "'", BracketLeft: '[', BracketRight: ']', Minus: '-', Equal: '=', Backquote: '`', Backslash: '\\' })[code] ?? code.replace(/^F(\d+)$/, 'F$1');
}

export function comboText(c) {
  if (!c) return '';
  return `${c.ctrl ? '⌃' : ''}${c.alt ? '⌥' : ''}${c.shift ? '⇧' : ''}${c.meta ? '⌘' : ''}${keyName(c.code)}`;
}

export const shortcutText = (id) => comboText(shortcutFor(id));

/** The physical key; some virtual keyboards and automation send no `code`, so fall back to the key. */
export function codeOf(e) {
  if (e.code) return e.code;
  const k = e.key || '';
  if (/^[a-z]$/i.test(k)) return `Key${k.toUpperCase()}`;
  if (/^\d$/.test(k)) return `Digit${k}`;
  return ({ ',': 'Comma', '.': 'Period', '/': 'Slash', ' ': 'Space', ';': 'Semicolon' })[k] ?? k;
}

/** On a PC keyboard, Ctrl stands in for ⌘. */
export function eventCombo(e) {
  const meta = isMac ? e.metaKey : (e.metaKey || (e.ctrlKey && !e.altKey));
  const ctrl = isMac ? e.ctrlKey : (e.ctrlKey && e.altKey);
  return { ctrl: ctrl ? 1 : 0, alt: e.altKey ? 1 : 0, shift: e.shiftKey ? 1 : 0, meta: meta ? 1 : 0, code: codeOf(e) };
}

export function comboMatches(c, e) {
  if (!c) return false;
  const k = eventCombo(e);
  return k.code === c.code && !!k.ctrl === !!c.ctrl && !!k.alt === !!c.alt && !!k.shift === !!c.shift && !!k.meta === !!c.meta;
}

const actions = new Map();
export function registerAction(id, fn) { actions.set(id, fn); }
export function runAction(id, arg) {
  const fn = actions.get(id);
  if (!fn) return;
  closeMenus();
  fn(arg);
}

let keyCapture = null;
/** While set, every keydown goes to `fn` first (shortcut recorder, Cleaning Mode). Return true to swallow it. */
export function captureKeys(fn) { keyCapture = fn; return () => { if (keyCapture === fn) keyCapture = null; }; }

document.addEventListener('keydown', (e) => {
  if (keyCapture && keyCapture(e)) { e.preventDefault(); e.stopPropagation(); return; }
  if (!app.running) return;
  for (const { id } of SHORTCUT_DEFS) {
    const combo = shortcutFor(id);
    if (combo && comboMatches(combo, e)) {
      e.preventDefault();
      runAction(id);
      return;
    }
  }
  if (comboMatches({ meta: 1, code: 'Comma' }, e)) { e.preventDefault(); runAction('settings'); }
});

// ---------------------------------------------------------------- tour progress

export const tourDone = new Set(store.get('tour', []));
bus.on('tour', (id) => {
  if (tourDone.has(id)) return;
  tourDone.add(id);
  store.set('tour', [...tourDone]);
  bus.emit('tour-changed', id);
});
