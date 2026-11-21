// The island's tools and pages, as IslandTool / IslandPage / IslandDockLayout describe them in ZenithCore.
import { settings, setSetting } from './core.js';

/** A named group of the Tools page. Settings and Quit are not in a group: the page keeps them in its top strip. */
export const TOOL_GROUPS = [
  { id: 'capture', title: 'Capture', tools: ['area', 'screen', 'record', 'ocr'] },
  { id: 'everyday', title: 'Everyday', tools: ['clipboard', 'cleaning', 'privacyShield', 'keepAwake'] },
  { id: 'cleanup', title: 'Clean Up', tools: ['clean', 'uninstall', 'cleaner', 'boost'] },
  { id: 'system', title: 'System', tools: ['system', 'ports', 'homebrew'] },
];

// `shortcut` is the id of the shortcut that does the same (Settings → Shortcuts); `page` is the island page it opens.
// A switch (`toggle`) shows whether it is on: grey while off.
export const TOOLS = {
  area: { title: 'Capture Area', detail: 'Drag over part of the screen and copy or annotate it', icon: 'crop', tint: '#3d8bff', action: 'captureArea', shortcut: 'captureArea' },
  screen: { title: 'Capture Screen', detail: 'Capture the whole screen', icon: 'screen', tint: '#6f7bff', action: 'captureScreen', shortcut: 'captureScreen' },
  record: { title: 'Record Screen', detail: 'Record an area, a window or the whole screen', icon: 'record', tint: '#f0524f', action: 'record', shortcut: 'record' },
  ocr: { title: 'Copy Text', detail: 'Copy text and QR codes from anywhere on the screen', icon: 'textscan', tint: '#55d0dc', action: 'ocr', shortcut: 'ocr' },
  clipboard: { title: 'Clipboard', detail: 'Your clipboard history, searchable', icon: 'clipboard', tint: '#f39c48', action: 'clipboard', shortcut: 'clipboard' },
  cleaning: { title: 'Cleaning Mode', detail: 'Block the keyboard and pointer while you wipe them', icon: 'keyboard', tint: '#8e8e93', action: 'cleaningMode', shortcut: 'cleaningMode' },
  privacyShield: { title: 'Privacy Shield', detail: 'Look sites up over encrypted DNS through a local proxy', icon: 'lockshield', tint: '#34c759', toggle: true },
  keepAwake: { title: 'Keep Awake', detail: 'Keep the Mac from going to sleep on its own', icon: 'mug', tint: '#f5c93a', toggle: true },
  clean: { title: 'Quick Clean', detail: 'Scan for system junk; you confirm what to delete before anything goes', icon: 'sparkles', tint: '#c040f0', run: 'quickClean' },
  uninstall: { title: 'Uninstall App', detail: 'Pick an app and move it and its files to the Trash', icon: 'trash', tint: '#f0506e', page: 'cleaner' },
  cleaner: { title: 'Cleaner', detail: 'System junk, project build folders, old installers and leftovers', icon: 'drive', tint: '#5cd6c0', page: 'cleaner' },
  boost: { title: 'Boost', detail: 'Free inactive memory and flush the DNS cache', icon: 'bolt', tint: '#f8d84a', run: 'boost' },
  system: { title: 'System', detail: 'Running apps, CPU, memory, storage and network speed', icon: 'cpu', tint: '#8e8e93', page: 'system' },
  ports: { title: 'Ports', detail: 'Processes listening on network ports', icon: 'globe', tint: '#64c4f8', page: 'ports' },
  homebrew: { title: 'Homebrew', detail: 'Installed and outdated Homebrew packages', icon: 'box', tint: '#a98467', page: 'homebrew' },
  settings: { title: 'Settings', detail: 'Open Zenith’s settings', icon: 'gear', tint: '#3d3d3f', page: 'settings' },
  quit: { title: 'Quit Zenith', detail: 'Quit Zenith', icon: 'power', tint: '#3d3d3f', run: 'quit' },
  allTools: { title: 'All Tools', detail: 'Every tool, in groups', icon: 'grid', tint: '#3d3d3f', page: 'tools' },
};

/** `size` is the page's content, below the island's top strip, in points (IslandPage.contentSize). */
export const PAGES = {
  system: { title: 'System', icon: 'cpu', size: [420, 392] },
  cleaner: { title: 'Cleaner', icon: 'sparkles', size: [580, 480] },
  ports: { title: 'Ports', icon: 'globe', size: [580, 440] },
  homebrew: { title: 'Homebrew', icon: 'box', size: [620, 480] },
  settings: { title: 'Settings', icon: 'gear', size: [720, 500] },
  tools: { title: 'Tools', icon: 'grid', size: [520, 264] },
};

// ---------------------------------------------------------------- the dock layout (IslandDockLayout)

export const DOCK_MAX = 6;
export const DEFAULT_DOCK = ['area', 'clipboard', 'clean', 'uninstall', 'privacyShield', 'keepAwake'];
const pinnable = new Set(TOOL_GROUPS.flatMap((g) => g.tools));

/** Each tool once, only tools that have a tile on the Tools page, at most six. */
export function sanitizeDock(list) {
  const seen = new Set();
  return (Array.isArray(list) ? list : DEFAULT_DOCK).filter((id) => pinnable.has(id) && !seen.has(id) && seen.add(id)).slice(0, DOCK_MAX);
}

export const dockPinned = () => sanitizeDock(settings.dockLayout ?? DEFAULT_DOCK);
export const dockIsFull = () => dockPinned().length >= DOCK_MAX;
export const dockIsDefault = () => dockPinned().join() === DEFAULT_DOCK.join();
export const saveDock = (list) => setSetting('dockLayout', sanitizeDock(list));

export const dockLayout = {
  contains: (id) => dockPinned().includes(id),
  /** Removes the tool if it is on the dock, else adds it. Adding to a full dock changes nothing. */
  toggle(id) {
    const list = dockPinned();
    if (list.includes(id)) { saveDock(list.filter((x) => x !== id)); return true; }
    if (list.length >= DOCK_MAX || !pinnable.has(id)) return false;
    saveDock([...list, id]);
    return true;
  },
  unpin: (id) => saveDock(dockPinned().filter((x) => x !== id)),
  canMove(id, by) { const i = dockPinned().indexOf(id); return i >= 0 && by !== 0 && i + by >= 0 && i + by < dockPinned().length; },
  moveTo(id, index) {
    const list = dockPinned();
    const i = list.indexOf(id);
    if (i < 0) return;
    const target = Math.min(Math.max(index, 0), list.length - 1);
    if (target === i) return;
    list.splice(i, 1);
    list.splice(target, 0, id);
    saveDock(list);
  },
  moveBy(id, by) { if (this.canMove(id, by)) this.moveTo(id, dockPinned().indexOf(id) + by); },
  reset: () => saveDock(DEFAULT_DOCK),
};
