// Made-up data for the demo. No real person's tracks, processes, files or clipboard.

export const TRACKS = [
  { title: 'Dawn Chorus', artist: 'Example Band', album: 'Field Notes', duration: 215, app: 'Music', tint: '#fa2d48', art: ['#ff7a59', '#ff2d78'], canSkip: true, canSeek: true },
  { title: 'Night Ferry', artist: 'The Placeholders', album: 'Harbour Lights', duration: 252, app: 'Spotify', tint: '#1ed760', art: ['#1c3d5a', '#3fb8af'], canSkip: true, canSeek: true },
  { title: 'Folding a paper crane, step by step', artist: 'Craft Corner', album: '', duration: 488, app: 'Chrome', tint: '#8ab4f8', art: ['#f6d365', '#fda085'], canSkip: false, canSeek: true },
  { title: 'Low Tide', artist: 'Example Band', album: 'Field Notes', duration: 198, app: 'Music', tint: '#fa2d48', art: ['#6a11cb', '#2575fc'], canSkip: true, canSeek: true },
];

/** Square artwork drawn from two colours, as a data URL. */
export function artwork([a, b], size = 128) {
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d');
  const grad = g.createLinearGradient(0, 0, size, size);
  grad.addColorStop(0, a);
  grad.addColorStop(1, b);
  g.fillStyle = grad;
  g.fillRect(0, 0, size, size);
  g.globalAlpha = 0.25;
  g.fillStyle = '#fff';
  g.beginPath();
  g.arc(size * 0.72, size * 0.3, size * 0.22, 0, Math.PI * 2);
  g.fill();
  g.globalAlpha = 0.18;
  g.beginPath();
  g.arc(size * 0.25, size * 0.8, size * 0.35, 0, Math.PI * 2);
  g.fill();
  return c.toDataURL('image/png');
}

export const PROCESSES = [
  { name: 'Video Editor', icon: 'film', mem: 2.4e9, cpu: 38.5 },
  { name: 'Design Tool', icon: 'brush', mem: 1.3e9, cpu: 21.0 },
  { name: 'Chat App', icon: 'chat', mem: 8.2e8, cpu: 9.5 },
  { name: 'Notes', icon: 'notes', mem: 3.1e8, cpu: 3.2 },
  { name: 'Code Editor', icon: 'code', mem: 1.1e9, cpu: 2.1 },
];

export const PORTS = [
  { port: 3000, proto: 'TCP', process: 'node', pid: 48211, address: '127.0.0.1', app: 'Code Editor' },
  { port: 5173, proto: 'TCP', process: 'node', pid: 48390, address: '127.0.0.1', app: 'Code Editor' },
  { port: 5432, proto: 'TCP', process: 'postgres', pid: 812, address: '127.0.0.1', app: 'postgres' },
  { port: 6379, proto: 'TCP', process: 'redis-server', pid: 913, address: '127.0.0.1', app: 'redis-server' },
  { port: 8000, proto: 'TCP', process: 'python3', pid: 50122, address: '0.0.0.0', app: 'Terminal' },
  { port: 5353, proto: 'UDP', process: 'Chat App', pid: 2210, address: '*', app: 'Chat App' },
];

// Cleaner: one list per tab, as Settings → Cleaner has them.
export const CLEANER = {
  system: {
    title: 'System', note: 'Caches, logs and temporary files in your home folder.', verb: 'Trash',
    categories: [
      { name: 'Application Caches', selected: true, items: [['Code Editor cache', 1.21e9], ['Design Tool cache', 6.4e8], ['Chat App cache', 2.3e8]] },
      { name: 'Developer Caches', selected: true, items: [['Xcode DerivedData', 2.4e9], ['SwiftPM cache', 5.1e8], ['npm cache', 3.8e8]] },
      { name: 'Logs', selected: true, items: [['Diagnostic logs', 1.2e8], ['App logs', 4.4e7]] },
      { name: 'Partial Downloads', selected: true, items: [['Holiday photos.zip.download (untouched for 3 days)', 2.1e8]] },
      { name: 'Trash', selected: false, items: [['3 items in the Trash', 7.6e8]] },
    ],
  },
  projects: {
    title: 'Projects', note: 'Build folders that the project can rebuild. bin, obj, build and dist only when Git ignores them.', verb: 'Trash',
    categories: [
      { name: '~/Code/shop-frontend', selected: true, items: [['node_modules (untouched 41 days)', 6.8e8]] },
      { name: '~/Code/zenith-macos', selected: true, items: [['.build (untouched 12 days)', 1.9e9]] },
      { name: '~/Projects/rust-tool', selected: true, items: [['target (untouched 64 days)', 2.6e9]] },
    ],
  },
  installers: {
    title: 'Installers', note: 'Disk images and installers in Downloads and Desktop that nothing has touched for three days. A mounted image is left out.', verb: 'Trash',
    categories: [
      { name: 'Downloads', selected: true, items: [['Example-App-4.2.dmg', 1.8e8], ['Printer-Driver.pkg', 9.4e7], ['Example-IDE.zip', 6.2e8]] },
    ],
  },
  leftovers: {
    title: 'Leftovers', note: 'Folders of apps that are gone, untouched for 30 days. Nothing is ticked for you: they can hold data you would want back.', verb: 'Trash',
    categories: [
      { name: 'com.example.oldeditor', selected: false, items: [['Application Support', 3.4e8], ['Caches', 6.1e7]] },
      { name: 'com.sample.photoapp', selected: false, items: [['Application Support', 1.2e9]] },
    ],
  },
  drives: {
    title: 'Drives', note: 'Finder and Windows junk on mounted external drives. These are deleted, not moved to the Trash.', verb: 'Delete',
    categories: [
      { name: 'BACKUP (external)', selected: true, items: [['.DS_Store files (214)', 1.3e6], ['._* AppleDouble files (1,032)', 4.2e6], ['Thumbs.db (12)', 2.8e6]] },
    ],
  },
};

// Installed apps for Settings → Cleaner → Uninstall. `files` is what each keeps in ~/Library; a file that only carries the
// app's display name (not its bundle identifier) starts unticked.
export const APPS = [
  { id: 'sketchbook', name: 'Sketchbook', file: 'Sketchbook.app', version: '3.2', bundle: 'com.example.sketchbook', path: '/Applications/Sketchbook.app', size: 4.12e8, icon: 'brush', running: false, files: [
    { path: '~/Library/Application Support/com.example.sketchbook', size: 8.8e7 },
    { path: '~/Library/Caches/com.example.sketchbook', size: 3.1e7 },
    { path: '~/Library/Preferences/com.example.sketchbook.plist', size: 4e3 },
    { path: '~/Library/Saved Application State/com.example.sketchbook.savedState', size: 2.1e5 },
    { path: '~/Library/Application Support/Sketchbook', size: 1.2e7, nameOnly: true },
  ] },
  { id: 'chat', name: 'Chat App', file: 'Chat App.app', version: '8.1', bundle: 'com.example.chat', path: '/Applications/Chat App.app', size: 3.4e8, icon: 'chat', running: true, files: [
    { path: '~/Library/Application Support/com.example.chat', size: 5.2e8 },
    { path: '~/Library/Caches/com.example.chat', size: 2.3e8 },
    { path: '~/Library/Preferences/com.example.chat.plist', size: 9e3 },
    { path: '~/Library/Logs/Chat App', size: 1.4e6, nameOnly: true },
  ] },
  { id: 'design', name: 'Design Tool', file: 'Design Tool.app', version: '12.4', bundle: 'com.example.designtool', path: '/Applications/Design Tool.app', size: 7.6e8, icon: 'brush', running: true, files: [
    { path: '~/Library/Application Support/com.example.designtool', size: 2.1e8 },
    { path: '~/Library/Caches/com.example.designtool', size: 6.4e8 },
    { path: '~/Library/Preferences/com.example.designtool.plist', size: 6e3 },
  ] },
  { id: 'ide', name: 'Example IDE', file: 'Example IDE.app', version: '2025.2', bundle: 'com.example.ide', path: '/Applications/Example IDE.app', size: 1.9e9, icon: 'code', running: false, files: [
    { path: '~/Library/Application Support/com.example.ide', size: 3.3e8 },
    { path: '~/Library/Caches/com.example.ide', size: 9.1e8 },
    { path: '~/Library/Logs/com.example.ide', size: 4.8e7 },
    { path: '~/Library/Preferences/com.example.ide.plist', size: 12e3 },
  ] },
  { id: 'photo', name: 'Photo Lab', file: 'Photo Lab.app', version: '5.0', bundle: 'com.sample.photolab', path: '/Applications/Photo Lab.app', size: 5.2e8, icon: 'photo', running: false, files: [
    { path: '~/Library/Application Support/com.sample.photolab', size: 1.1e9 },
    { path: '~/Library/Caches/com.sample.photolab', size: 2.8e8 },
    { path: '~/Library/Containers/com.sample.photolab', size: 4.4e7 },
  ] },
  { id: 'notesplus', name: 'Notes Plus', file: 'Notes Plus.app', version: '1.9', bundle: 'com.example.notesplus', path: '~/Applications/Notes Plus.app', size: 9.8e7, icon: 'notes', running: false, files: [
    { path: '~/Library/Application Support/com.example.notesplus', size: 2.4e7 },
    { path: '~/Library/Preferences/com.example.notesplus.plist', size: 5e3 },
  ] },
];

export const BREW_INSTALLED = [
  { name: 'git', version: '2.47.1', latest: '2.47.1', desc: 'Distributed revision control system', size: 5.4e7, cask: false },
  { name: 'node', version: '22.11.0', latest: '22.12.0', desc: 'Platform built on V8 to build network applications', size: 7.9e7, cask: false },
  { name: 'ripgrep', version: '14.1.1', latest: '14.1.1', desc: 'Search tool like grep and The Silver Searcher', size: 6.1e6, cask: false },
  { name: 'wget', version: '1.24.5', latest: '1.25.0', desc: 'Internet file retriever', size: 4.3e6, cask: false },
  { name: 'example-browser', version: '131.0', latest: '132.0', desc: 'Web browser (made up for this demo)', size: 4.1e8, cask: true },
];

export const BREW_SEARCH = [
  { name: 'jq', latest: '1.7.1', desc: 'Lightweight and flexible command-line JSON processor', cask: false },
  { name: 'fd', latest: '10.2.0', desc: 'Simple, fast and user-friendly alternative to find', cask: false },
  { name: 'htop', latest: '3.3.0', desc: 'Improved top (interactive process viewer)', cask: false },
  { name: 'ffmpeg', latest: '7.1', desc: 'Play, record, convert, and stream audio and video', cask: false },
  { name: 'tree', latest: '2.2.1', desc: 'Display directories as trees', cask: false },
  { name: 'example-notes', latest: '3.0', desc: 'Note-taking app (made up for this demo)', cask: true },
];

export const SNIPPETS = [
  { name: 'Signature', trigger: ';sig', text: 'Best regards,\nAlex Example\n{date}' },
  { name: 'Address', trigger: ';addr', text: '1 Example Street, Springfield 12345' },
  { name: 'Quote the clipboard', trigger: ';q', text: '“{clipboard}” ({time})' },
  { name: 'Meeting note', trigger: ';mtg', text: 'Meeting {date:yyyy-MM-dd}: {cursor}' },
];

const now = Date.now();
const DAY = 86400000;

export function seedClipboard(imageURL) {
  return [
    { kind: 'link', text: 'https://shop.example.com/lamp?id=42&utm_source=newsletter&utm_medium=email&fbclid=IwAR0demo', source: 'Safari', at: now - 4 * 60000 },
    { kind: 'text', text: 'Meeting notes: ship the island fix on Friday, then review the cleaner copy with the team.', source: 'Notes', at: now - 26 * 60000 },
    { kind: 'color', text: '#0F62FE', source: 'Design Tool', at: now - 50 * 60000, pinned: true },
    { kind: 'image', text: 'Image 1280 × 720', img: imageURL, w: 1280, h: 720, size: 682800, source: 'Zenith', at: now - 70 * 60000 },
    { kind: 'link', text: 'https://youtu.be/demo1234567?si=Xy12AbCdEfGh&t=42', source: 'Safari', at: now - 3 * 3600000 },
    { kind: 'text', text: 'swift build -c release', source: 'Terminal', at: now - DAY - 3600000 },
    { kind: 'text', text: 'Invoice 2026-114, due 30 November', source: 'Mail', at: now - DAY - 5 * 3600000 },
    { kind: 'text', text: 'brew install --cask example-app', source: 'Terminal', at: now - 4 * DAY },
  ];
}

/** The picture the clipboard and the annotation screenshots use: a card and a circle on a gradient. */
export function sampleCardImage(w = 1280, h = 720) {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  const g = c.getContext('2d');
  const grad = g.createLinearGradient(0, h, w, 0);
  grad.addColorStop(0, '#6f7ff7');
  grad.addColorStop(0.5, '#56a3e9');
  grad.addColorStop(1, '#5ccfe0');
  g.fillStyle = grad;
  g.fillRect(0, 0, w, h);
  g.fillStyle = 'rgba(240,246,255,.95)';
  roundRect(g, w * 0.11, h * 0.28, w * 0.41, h * 0.44, 28);
  g.fill();
  g.fillStyle = '#a8b2f7';
  [0.36, 0.44, 0.52].forEach((y) => { roundRect(g, w * 0.15, h * y, w * 0.33, 22, 11); g.fill(); });
  roundRect(g, w * 0.15, h * 0.6, w * 0.19, 22, 11);
  g.fill();
  g.fillStyle = '#f0994a';
  g.beginPath();
  g.arc(w * 0.705, h * 0.5, h * 0.19, 0, Math.PI * 2);
  g.fill();
  return c;
}

export function roundRect(g, x, y, w, h, r) {
  g.beginPath();
  g.moveTo(x + r, y);
  g.arcTo(x + w, y, x + w, y + h, r);
  g.arcTo(x + w, y + h, x, y + h, r);
  g.arcTo(x, y + h, x, y, r);
  g.arcTo(x, y, x + w, y, r);
  g.closePath();
}

// The same rules as TrackingLinkCleaner in ZenithCore.
const TRACKING = new Set(['gclid', 'gclsrc', 'dclid', 'wbraid', 'gbraid', '_ga', '_gl', 'srsltid', 'fbclid', 'igshid', 'igsh',
  'msclkid', 'yclid', 'twclid', 'ttclid', 'li_fat_id', 'epik', 'rdt_cid', 'mc_cid', 'mc_eid', '_hsenc', '_hsmi', 'mkt_tok',
  'vero_id', 'vero_conv', '_openstat', 'oly_anon_id', 'oly_enc_id']);
const HOST_SPECIFIC = [
  [['youtube.com', 'youtu.be', 'spotify.com', 'spotify.link'], ['si']],
  [['twitter.com', 'x.com'], ['ref_src', 'ref_url']],
];

export function webHost(text) {
  const s = String(text).trim();
  if (!/^https?:\/\/[^\s/?#]+[^\s]*$/i.test(s) || s.length > 8192) return null;
  return s.replace(/^https?:\/\//i, '').split(/[/?#]/)[0].split('@').pop().split(':')[0].toLowerCase();
}

export function isTrackingParameter(name, host) {
  let decoded = name;
  try { decoded = decodeURIComponent(name); } catch { /* keep */ }
  decoded = decoded.toLowerCase();
  if (!decoded) return false;
  if (TRACKING.has(decoded)) return true;
  if (decoded.startsWith('utm_') && decoded.length > 4) return true;
  return HOST_SPECIFIC.some(([domains, names]) => names.includes(decoded) && domains.some((d) => host === d || host.endsWith(`.${d}`)));
}

/** Returns { url, removed } — the link without tracking parameters and how many went. */
export function cleanLink(text) {
  const s = String(text).trim();
  const host = webHost(s);
  if (!host) return { url: s, removed: 0 };
  const hashAt = s.indexOf('#');
  const fragment = hashAt >= 0 ? s.slice(hashAt) : '';
  const beforeHash = hashAt >= 0 ? s.slice(0, hashAt) : s;
  const q = beforeHash.indexOf('?');
  if (q < 0) return { url: s, removed: 0 };
  const base = beforeHash.slice(0, q);
  const pieces = beforeHash.slice(q + 1).split('&');
  const kept = pieces.filter((p) => !isTrackingParameter(p.split('=')[0], host));
  const removed = pieces.length - kept.length;
  if (!removed) return { url: s, removed: 0 };
  return { url: base + (kept.some((p) => p) ? `?${kept.join('&')}` : '') + fragment, removed };
}
