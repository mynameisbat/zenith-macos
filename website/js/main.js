// Starts the demo desktop.
import { applyAppearance, bus } from './core.js';
import { initDesktop } from './desktop.js';
import { initIsland } from './island.js';
import { initClipboard } from './clipboard.js';
import { initCapture } from './capture.js';
import { initHub } from './hub.js';
import { initSettings } from './settings.js';
import { initPages } from './pages.js';

applyAppearance();
initIsland();
initClipboard();
initCapture();
initHub();
initPages();
initSettings();
initDesktop();
document.documentElement.classList.add('ready');
bus.emit('focus');
