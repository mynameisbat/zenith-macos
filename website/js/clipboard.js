// Clipboard history (two panes, filters, keyboard), copies made on this page, the ignored-app and concealed rules,
// auto-clear, clean links, and text snippets.
import {
  $, $$, bus, esc, icon, html, settings, notify, registerAction, runAction, frontWindow, windowSpec, store,
  showContextMenu, playSound, formatBytes, isMac, shortcutText, closeMenus, isNarrow, codeOf,
} from './core.js';
import { seedClipboard, sampleCardImage, cleanLink, webHost, SNIPPETS } from './data.js';
import { scratchpad } from './desktop.js';

// ---------------------------------------------------------------- the history

let nextId = 1;
const withIds = (list) => list.map((it) => ({ id: nextId++, pinned: false, ...it }));
let items = [];

function loadItems() {
  const saved = store.get('clipboard', null);
  if (saved) {
    items = withIds(saved.map(({ id, ...rest }) => rest));
  } else {
    const c = sampleCardImage(640, 360);
    items = withIds(seedClipboard(c.toDataURL('image/jpeg', 0.85)).map((i) => (i.kind === 'image' ? { ...i, seed: true } : i)));
  }
}

function save() {
  // Images from captures are large; keep the seed picture and text only.
  store.set('clipboard', items.filter((i) => i.kind !== 'image' || i.seed).map(({ id, ...rest }) => rest));
}

function kindOf(text) {
  if (webHost(text)) return 'link';
  if (/^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i.test(text.trim())) return 'color';
  return 'text';
}

export const clipboardStore = {
  get items() { return items; },
  clearUnpinned() { items = items.filter((i) => i.pinned); save(); render(); },
  add,
};

function add(item) {
  const existing = item.kind !== 'image' ? items.find((i) => i.kind === item.kind && i.text === item.text) : null;
  if (existing) {
    existing.at = Date.now();
    items = [existing, ...items.filter((i) => i !== existing)];
  } else {
    items.unshift({ id: nextId++, pinned: false, at: Date.now(), ...item });
  }
  // Bounded like the app: unpinned items beyond the limit go first.
  while (items.length > settings.historyLimit) {
    const victim = [...items].reverse().find((i) => !i.pinned);
    if (!victim) break;
    items = items.filter((i) => i !== victim);
  }
  save();
  if (panel) render();
}

// ---------------------------------------------------------------- the system clipboard of the pretend Mac, and auto-clear

let pasteboard = null;
let clearTimer = 0;

function setPasteboard(text, label = text) {
  pasteboard = { text, label, at: Date.now() };
  scheduleClear();
  updateFoot();
}

function scheduleClear() {
  clearTimeout(clearTimer);
  if (!pasteboard || !settings.clearAfter) return;
  const mine = pasteboard;
  clearTimer = setTimeout(() => {
    if (pasteboard !== mine) return;
    pasteboard = null;
    updateFoot();
    notify({ icon: 'clipboard', title: 'Clipboard emptied', subtitle: 'The history still has the item.' });
  }, settings.clearAfter * 1000);
}

bus.on('setting:clearAfter', scheduleClear);
bus.on('lock', () => {
  if (!settings.clearOnLock || !pasteboard) return;
  pasteboard = null;
  updateFoot();
  const off = bus.on('unlock', () => {
    off();
    notify({ icon: 'lock', title: 'Clipboard emptied when the Mac locked', subtitle: 'The history still has the item.' });
  });
});

export function currentPasteboardText() { return pasteboard?.text ?? ''; }

// ---------------------------------------------------------------- copies

function appForNode(node) {
  const el = node?.nodeType === 1 ? node : node?.parentElement;
  const win = el?.closest?.('.win');
  return win?.dataset.app ?? 'Finder';
}

function selectedText() {
  const a = document.activeElement;
  if (a && (a.tagName === 'TEXTAREA' || (a.tagName === 'INPUT' && /text|search|url/.test(a.type)))) {
    return a.value.slice(a.selectionStart, a.selectionEnd);
  }
  return String(window.getSelection() ?? '');
}

function onDocumentCopy(e) {
  let text = selectedText();
  if (!text.trim()) return;
  const sel = window.getSelection();
  const app = appForNode(document.activeElement?.closest('.win') ? document.activeElement : sel?.anchorNode);
  if (settings.cleanLinksOnCopy && !settings.ignoredApps.includes(app)) {
    const c = cleanLink(text);
    if (c.removed && webHost(text)) {
      e.clipboardData.setData('text/plain', c.url);
      e.preventDefault();
      text = c.url;
      notify({ icon: 'link', title: 'Link cleaned as you copied it', subtitle: c.removed === 1 ? 'Removed 1 tracking parameter' : `Removed ${c.removed} tracking parameters`, tint: 'green' });
      bus.emit('tour', 'clean-link');
    }
  }
  bus.emit('copy', { text, app, fromPage: true });
}

bus.on('copy', ({ text, app, concealed }) => {
  setPasteboard(text, concealed ? '••••••••' : text);
  if (concealed) {
    notify({ icon: 'lock', title: 'Not kept in the history', subtitle: `${app} marked the copy as concealed.`, tint: 'plain' });
    bus.emit('tour', 'privacy-copy');
    return;
  }
  if (settings.ignoredApps.includes(app)) {
    notify({ icon: 'lock', title: 'Not kept in the history', subtitle: `Copied in ${app}, which is on your ignored list.`, tint: 'plain' });
    bus.emit('tour', 'privacy-copy');
    return;
  }
  add({ kind: kindOf(text), text, source: app });
  playSound('copy');
});

bus.on('copy-image', ({ img, w, h, size, label }) => {
  setPasteboard(label, label);
  add({ kind: 'image', text: label, img, w, h, size, source: 'Zenith' });
});

// ---------------------------------------------------------------- the panel

let panel = null;
let filter = 'all';
let query = '';
let selectedId = null;
let pasteTarget = null;

const FILTERS = [['all', 'tray', 'All'], ['text', 'lines', 'Text'], ['link', 'link', 'Links'], ['image', 'photo', 'Images'], ['pinned', 'pin', 'Pinned']];

function matches(item) {
  if (filter === 'pinned' && !item.pinned) return false;
  if (filter === 'text' && !(item.kind === 'text' || item.kind === 'color')) return false;
  if (filter === 'link' && item.kind !== 'link') return false;
  if (filter === 'image' && item.kind !== 'image') return false;
  if (!query) return true;
  const hay = item.text.toLowerCase();
  const q = query.toLowerCase();
  if (hay.includes(q)) return true;
  let i = 0;
  for (const ch of hay) if (ch === q[i]) i++;
  return i === q.length && q.length > 2;
}

function visibleItems() { return items.filter(matches); }

function dayGroup(at) {
  const d = new Date(at);
  const today = new Date();
  const start = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
  if (at >= start) return 'Today';
  if (at >= start - 86400000) return 'Yesterday';
  return 'Earlier';
}

function rowIcon(item) {
  if (item.kind === 'image') return `<img class="cb-thumb" src="${item.img}" alt="">`;
  if (item.kind === 'color') return `<span class="cb-swatch" style="background:${esc(item.text)}"></span>`;
  return `<span class="cb-ic">${icon(item.kind === 'link' ? 'link' : 'lines')}</span>`;
}

function render() {
  if (!panel) return;
  const list = visibleItems();
  if (!list.some((i) => i.id === selectedId)) selectedId = list[0]?.id ?? null;
  const groups = [];
  for (const it of list) {
    const g = dayGroup(it.at);
    if (!groups.length || groups[groups.length - 1].name !== g) groups.push({ name: g, items: [] });
    groups[groups.length - 1].items.push(it);
  }
  let n = 0;
  $('.cb-list', panel).innerHTML = list.length
    ? groups.map((g) => `<div class="cb-group" role="presentation">${g.name}</div>${g.items.map((it) => {
      n++;
      return `<div class="cb-row ${it.id === selectedId ? 'sel' : ''}" role="option" id="cb-${it.id}" data-id="${it.id}" aria-selected="${it.id === selectedId}">
        ${rowIcon(it)}<span class="cb-text">${esc(it.text.replace(/\s+/g, ' ').slice(0, 140))}</span>
        ${it.pinned ? `<span class="cb-pin" aria-label="Pinned">${icon('pin')}</span>` : ''}
        ${n <= 9 ? `<span class="cb-key">⌘${n}</span>` : ''}
      </div>`;
    }).join('')}`).join('')
    : `<div class="cb-empty">${query ? `Nothing matches “${esc(query)}”.` : 'Nothing here yet.'}</div>`;
  $$('.cb-filter', panel).forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.filter === filter)));
  $('.cb-input', panel).setAttribute('aria-activedescendant', selectedId ? `cb-${selectedId}` : '');
  renderPreview();
  updateFoot();
  $(`#cb-${selectedId}`, panel)?.scrollIntoView({ block: 'nearest' });
}

function renderPreview() {
  const it = items.find((i) => i.id === selectedId);
  const box = $('.cb-preview', panel);
  if (!it) { box.innerHTML = '<div class="cb-empty">Select an item to see it here.</div>'; return; }
  let view = '';
  const meta = [['Type', { text: 'Text', link: 'Link', image: 'Image', color: 'Color' }[it.kind]], ['Copied', new Date(it.at).toLocaleString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })]];
  if (it.source) meta.push(['From', it.source]);
  if (it.kind === 'image') {
    view = `<img class="cb-big" src="${it.img}" alt="${esc(it.text)}">`;
    meta.push(['Dimensions', `${it.w} × ${it.h}`], ['Size', formatBytes(it.size ?? 0)]);
  } else if (it.kind === 'color') {
    view = `<div class="cb-color" style="background:${esc(it.text)}"><b>${esc(it.text.toUpperCase())}</b></div>`;
  } else {
    view = `<pre class="cb-full">${esc(it.text.slice(0, 20000))}</pre>`;
    const words = it.text.trim().split(/\s+/).filter(Boolean).length;
    meta.push(['Characters', it.text.length.toLocaleString('en-GB')], ['Words', words.toLocaleString('en-GB')], ['Lines', String(it.text.split('\n').length)]);
    if (it.kind === 'link') {
      const c = cleanLink(it.text);
      if (c.removed) meta.push(['Clean link', `${c.removed} tracking parameter${c.removed === 1 ? '' : 's'} removed with ⇧↵`]);
    }
  }
  box.innerHTML = `<div class="cb-view">${view}</div>
    <dl class="cb-meta">${meta.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl>
    <div class="cb-actions">
      <button type="button" class="btn" data-cb="paste">Paste</button>
      ${it.kind === 'link' && cleanLink(it.text).removed ? '<button type="button" class="btn" data-cb="clean">Paste Clean Link</button>' : ''}
      <span class="grow"></span>
      <button type="button" class="btn btn-icon" data-cb="pin" aria-label="${it.pinned ? 'Unpin' : 'Pin'}" aria-pressed="${it.pinned}">${icon('pin')}</button>
      <button type="button" class="btn btn-icon" data-cb="delete" aria-label="Delete">${icon('trash')}</button>
    </div>`;
}

function updateFoot() {
  if (!panel) return;
  const list = visibleItems();
  const count = list.length === 1 ? '1 item' : `${list.length} items`;
  let pb = 'The clipboard is empty';
  if (pasteboard) {
    const label = pasteboard.label.replace(/\s+/g, ' ');
    pb = `On the clipboard: “${label.length > 26 ? `${label.slice(0, 26)}…` : label}”`;
    if (settings.clearAfter) {
      const left = Math.max(0, Math.round((pasteboard.at + settings.clearAfter * 1000 - Date.now()) / 1000));
      pb += ` · empties in ${left} s`;
    }
  }
  $('.cb-count', panel).textContent = `${count} · ${pb}`;
}

function select(delta) {
  const list = visibleItems();
  if (!list.length) return;
  const i = list.findIndex((x) => x.id === selectedId);
  selectedId = list[Math.max(0, Math.min(list.length - 1, (i < 0 ? 0 : i) + delta))].id;
  render();
}

function paste(item, variant = 'normal') {
  if (!item) return;
  let text = item.text;
  let note = '';
  if (variant === 'clean' || (variant === 'plain' && item.kind === 'link')) {
    const c = cleanLink(item.text);
    text = c.url;
    if (c.removed) { note = c.removed === 1 ? 'Without 1 tracking parameter' : `Without ${c.removed} tracking parameters`; bus.emit('tour', 'clean-link'); }
  } else if (variant === 'plain') {
    note = 'As plain text';
  }
  setPasteboard(text, item.kind === 'image' ? item.text : text);
  const target = pasteTarget;
  closePanel();
  playSound('paste');
  bus.emit('tour', 'clipboard');
  if (target === 'scratchpad') {
    if (item.kind === 'image') scratchpad.insertImage(item.img, item.text);
    else scratchpad.insert(text);
    notify({ icon: 'clipboard', title: 'Pasted into Scratchpad', subtitle: note || undefined });
    return;
  }
  if (item.kind !== 'image') navigator.clipboard?.writeText(text).catch(() => {});
  notify({ icon: 'clipboard', title: 'Copied', subtitle: `${note ? `${note}. ` : ''}Nothing to paste into here: click Scratchpad first, or press ⌘V where you like.` });
}

function togglePin(item) {
  item.pinned = !item.pinned;
  playSound('pin');
  save();
  render();
}

function remove(item) {
  items = items.filter((i) => i !== item);
  playSound('delete');
  save();
  render();
}

function onPanelKey(e) {
  const meta = isMac ? e.metaKey : (e.metaKey || e.ctrlKey);
  const item = items.find((i) => i.id === selectedId);
  if (e.key === 'Escape') { e.preventDefault(); closePanel(); return; }
  if (e.key === 'ArrowDown' || (e.ctrlKey && codeOf(e) === 'KeyN')) { e.preventDefault(); select(1); return; }
  if (e.key === 'ArrowUp' || (e.ctrlKey && codeOf(e) === 'KeyP')) { e.preventDefault(); select(-1); return; }
  if (e.key === 'Enter') { e.preventDefault(); paste(item, e.shiftKey ? 'plain' : 'normal'); return; }
  if (meta && /^Digit[1-9]$/.test(codeOf(e))) { e.preventDefault(); paste(visibleItems()[Number(codeOf(e).slice(5)) - 1]); return; }
  if (meta && codeOf(e) === 'KeyP' && item) { e.preventDefault(); togglePin(item); return; }
  if (meta && e.key === 'Backspace' && item) { e.preventDefault(); remove(item); }
}

function openPanel() {
  if (panel) { closePanel(); return; }
  const front = frontWindow();
  pasteTarget = front === 'scratchpad' ? 'scratchpad' : null;
  closeMenus();
  query = '';
  filter = 'all';
  selectedId = null;
  panel = html`<div class="scrim cb-scrim"><div class="cb-panel" role="dialog" aria-modal="true" aria-label="Clipboard history">
    <div class="cb-search">${icon('search')}<input class="cb-input" type="text" placeholder="Search clipboard history" aria-label="Search clipboard history" role="combobox" aria-controls="cb-list" aria-expanded="true" autocomplete="off" spellcheck="false"></div>
    <div class="cb-filters" role="toolbar" aria-label="Filters">${FILTERS.map(([id, ic, label]) => `<button type="button" class="cb-filter" data-filter="${id}" aria-pressed="false">${icon(ic)}${label}</button>`).join('')}</div>
    <div class="cb-main"><div class="cb-list" id="cb-list" role="listbox" aria-label="History"></div><div class="cb-preview"></div></div>
    <div class="cb-foot"><span class="cb-count"></span><span class="cb-keys"><kbd>↵</kbd> Paste <kbd>⇧↵</kbd> Plain / clean link <kbd>⌘P</kbd> Pin <kbd>⌘⌫</kbd> Delete <kbd>esc</kbd> Close</span></div>
  </div></div>`;
  document.body.append(panel);
  const input = $('.cb-input', panel);
  input.addEventListener('input', () => { query = input.value; selectedId = null; render(); });
  input.addEventListener('keydown', onPanelKey);
  panel.addEventListener('click', (e) => {
    if (e.target === panel) { closePanel(); return; }
    const f = e.target.closest?.('[data-filter]');
    if (f) { filter = f.dataset.filter; selectedId = null; render(); input.focus(); return; }
    const row = e.target.closest?.('.cb-row');
    if (row) { selectedId = Number(row.dataset.id); render(); input.focus(); return; }
    const act = e.target.closest?.('[data-cb]')?.dataset.cb;
    const item = items.find((i) => i.id === selectedId);
    if (act === 'paste') paste(item);
    if (act === 'clean') paste(item, 'clean');
    if (act === 'pin') togglePin(item);
    if (act === 'delete') remove(item);
  });
  panel.addEventListener('dblclick', (e) => {
    const row = e.target.closest?.('.cb-row');
    if (row) paste(items.find((i) => i.id === Number(row.dataset.id)));
  });
  panel.addEventListener('contextmenu', (e) => {
    const row = e.target.closest?.('.cb-row');
    if (!row) return;
    e.preventDefault();
    const item = items.find((i) => i.id === Number(row.dataset.id));
    selectedId = item.id;
    render();
    showContextMenu(e.clientX, e.clientY, [
      { label: 'Paste', shortcut: '↵', action: () => paste(item) },
      { label: 'Paste as Plain Text', shortcut: '⇧↵', disabled: item.kind === 'image', action: () => paste(item, 'plain') },
      ...(item.kind === 'link' ? [{ label: 'Paste Clean Link', disabled: !cleanLink(item.text).removed, action: () => paste(item, 'clean') }] : []),
      { separator: true },
      { label: item.pinned ? 'Unpin' : 'Pin', shortcut: '⌘P', action: () => togglePin(item) },
      { label: 'Delete', shortcut: '⌘⌫', action: () => remove(item) },
    ]);
  });
  render();
  input.focus();
  footTimer = setInterval(updateFoot, 1000);
  if (isNarrow()) panel.classList.add('narrow');
}

let footTimer = 0;
function closePanel() {
  if (!panel) return;
  clearInterval(footTimer);
  panel.remove();
  panel = null;
  if (pasteTarget === 'scratchpad') windowSpec('scratchpad')?.el?.querySelector('textarea')?.focus();
}

// ---------------------------------------------------------------- snippets

export const snippetStore = {
  list: store.get('snippets', SNIPPETS),
  save() { store.set('snippets', this.list); bus.emit('snippets'); },
};

function pad2(n) { return String(n).padStart(2, '0'); }
function formatDate(d, fmt) {
  return fmt.replace(/yyyy|MM|dd|HH|mm/g, (t) => ({ yyyy: d.getFullYear(), MM: pad2(d.getMonth() + 1), dd: pad2(d.getDate()), HH: pad2(d.getHours()), mm: pad2(d.getMinutes()) })[t]);
}

/** Expands {clipboard}, {date}, {date:fmt}, {time}, {datetime}; returns the text and where {cursor} was. */
export function expandSnippet(template) {
  const d = new Date();
  let text = template
    .replace(/\{clipboard\}/g, currentPasteboardText())
    .replace(/\{date:([^}]+)\}/g, (_, f) => formatDate(d, f))
    .replace(/\{date\}/g, d.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' }))
    .replace(/\{time\}/g, d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }))
    .replace(/\{datetime\}/g, `${d.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })} ${d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}`);
  const cursor = text.indexOf('{cursor}');
  text = text.replace(/\{cursor\}/g, '');
  return { text, cursor: cursor < 0 ? text.length : cursor };
}

function onScratchpadInput(e) {
  if (!settings.snippetsOn || e.inputType === 'insertFromPaste') return;
  const ta = e.target;
  const caret = ta.selectionStart;
  const before = ta.value.slice(0, caret);
  for (const s of snippetStore.list) {
    if (!s.trigger || !before.endsWith(s.trigger)) continue;
    const start = caret - s.trigger.length;
    if (start > 0 && !/[\s([{"'“]/.test(before[start - 1])) continue;
    const { text, cursor } = expandSnippet(s.text);
    ta.setRangeText(text, start, caret, 'end');
    ta.selectionStart = ta.selectionEnd = start + cursor;
    bus.emit('tour', 'snippet');
    return;
  }
}

function snippetPicker() {
  const target = frontWindow() === 'scratchpad' ? 'scratchpad' : null;
  let q = '';
  let sel = 0;
  const scrim = html`<div class="scrim sp-scrim"><div class="sp-panel" role="dialog" aria-modal="true" aria-label="Snippets">
    <div class="cb-search">${icon('search')}<input type="text" placeholder="Search snippets" aria-label="Search snippets" autocomplete="off"></div>
    <div class="sp-list" role="listbox"></div>
    <div class="cb-foot"><span>${target ? 'Return types it into Scratchpad' : 'Return puts it in Scratchpad'}</span><span><kbd>esc</kbd> Close</span></div>
  </div></div>`;
  const list = () => snippetStore.list.filter((s) => `${s.name} ${s.trigger} ${s.text}`.toLowerCase().includes(q.toLowerCase()));
  const draw = () => {
    const l = list();
    sel = Math.min(sel, Math.max(0, l.length - 1));
    $('.sp-list', scrim).innerHTML = l.length ? l.map((s, i) => `<div class="sp-row ${i === sel ? 'sel' : ''}" role="option" data-i="${i}" aria-selected="${i === sel}"><b>${esc(s.name)}</b><code>${esc(s.trigger)}</code><span>${esc(expandSnippet(s.text).text.replace(/\s+/g, ' '))}</span></div>`).join('') : '<div class="cb-empty">No snippet matches.</div>';
  };
  const choose = (s) => {
    if (!s) return;
    scrim.remove();
    const { text, cursor } = expandSnippet(s.text);
    scratchpad.insert(text);
    const ta = scratchpad.el;
    ta.selectionStart = ta.selectionEnd = ta.selectionStart - (text.length - cursor);
    bus.emit('tour', 'snippet');
  };
  const input = $('input', scrim);
  input.addEventListener('input', () => { q = input.value; sel = 0; draw(); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); sel++; draw(); }
    if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(0, sel - 1); draw(); }
    if (e.key === 'Enter') { e.preventDefault(); choose(list()[sel]); }
    if (e.key === 'Escape') { e.preventDefault(); scrim.remove(); }
  });
  scrim.addEventListener('click', (e) => {
    if (e.target === scrim) { scrim.remove(); return; }
    const row = e.target.closest?.('.sp-row');
    if (row) choose(list()[Number(row.dataset.i)]);
  });
  document.body.append(scrim);
  draw();
  input.focus();
}

// ---------------------------------------------------------------- setup

export function initClipboard() {
  loadItems();
  document.addEventListener('copy', onDocumentCopy);
  document.addEventListener('cut', onDocumentCopy);
  registerAction('clipboard', openPanel);
  registerAction('snippets', snippetPicker);
  document.addEventListener('input', (e) => { if (e.target === scratchpad.el) onScratchpadInput(e); });
  bus.on('setting:historyLimit', () => {
    let unpinnedSeen = 0;
    const keepUnpinned = Math.max(0, settings.historyLimit - items.filter((i) => i.pinned).length);
    items = items.filter((i) => i.pinned || ++unpinnedSeen <= keepUnpinned);
    save();
  });
}

export { openPanel as openClipboard };
