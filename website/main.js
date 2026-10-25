// Zenith 2.0 - Interactive Motion & Live Product Fragments
// Conforms to taste-skill v2.1 House Rules

document.addEventListener('DOMContentLoaded', () => {
  initStaggeredMotion();
  initLiveCommandHub();
  initDynamicIsland();
  initLoupeMagnifier();
  initTerminalCopy();
});

// 1. Staggered Motion Entrances
function initStaggeredMotion() {
  const elements = document.querySelectorAll('.fade-up');
  if (!('IntersectionObserver' in window)) {
    elements.forEach(el => el.classList.add('visible'));
    return;
  }

  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add('visible');
        observer.unobserve(entry.target);
      }
    });
  }, {
    threshold: 0.15,
    rootMargin: '0px 0px -40px 0px'
  });

  elements.forEach((el, index) => {
    el.style.transitionDelay = `${(index % 4) * 75}ms`;
    observer.observe(el);
  });
}

// 2. Interactive Live Command Hub Demo
function initLiveCommandHub() {
  const searchInput = document.getElementById('hub-search-input');
  const clipsContainer = document.getElementById('hub-clips-list');
  const clipRows = document.querySelectorAll('.clip-row');

  if (!searchInput || !clipsContainer) return;

  searchInput.addEventListener('input', (e) => {
    const query = e.target.value.toLowerCase().trim();
    clipRows.forEach(row => {
      const text = row.getAttribute('data-search') || '';
      if (!query || text.toLowerCase().includes(query)) {
        row.style.display = 'flex';
      } else {
        row.style.display = 'none';
      }
    });
  });

  clipRows.forEach(row => {
    row.addEventListener('click', () => {
      const textToCopy = row.getAttribute('data-clip') || '';
      if (navigator.clipboard) {
        navigator.clipboard.writeText(textToCopy);
      }
      showToast(`Copied: "${textToCopy.substring(0, 24)}..."`);
    });
  });
}

// 3. Interactive Dynamic Island Notch
function initDynamicIsland() {
  const notch = document.getElementById('notch-hud');
  const notchText = document.getElementById('notch-text');
  if (!notch || !notchText) return;

  let isAlerting = false;
  const messages = [
    'Screenshot Saved (1920 × 1080)',
    'DoH Shield Active · Cloudflare',
    'Freed 1.2 GB System Cache',
    'Clipboard Synced · 32 items'
  ];
  let msgIndex = 0;

  notch.addEventListener('click', () => {
    if (isAlerting) return;
    isAlerting = true;
    notch.classList.add('expanded');
    notchText.textContent = messages[msgIndex % messages.length];
    msgIndex++;

    setTimeout(() => {
      notch.classList.remove('expanded');
      setTimeout(() => {
        notchText.textContent = 'Zenith 2.0';
        isAlerting = false;
      }, 250);
    }, 2400);
  });
}

// 4. Interactive Loupe Magnifier Canvas
function initLoupeMagnifier() {
  const canvasArea = document.getElementById('loupe-canvas');
  const lens = document.getElementById('loupe-lens');
  const hexTag = document.getElementById('loupe-hex');

  if (!canvasArea || !lens || !hexTag) return;

  const colors = ['#090A0F', '#147BFA', '#1FC16B', '#F59E0B', '#EF4444', '#F4F5F9', '#8B92A5'];

  canvasArea.addEventListener('mousemove', (e) => {
    const rect = canvasArea.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    lens.style.left = `${x - 65}px`;
    lens.style.top = `${y - 65}px`;

    // Calculate sample hex
    const colorIdx = Math.floor((x / rect.width) * colors.length) % colors.length;
    hexTag.textContent = colors[colorIdx];
  });
}

// 5. Terminal One-Click Copy
function initTerminalCopy() {
  const terminalPill = document.getElementById('terminal-pill');
  if (!terminalPill) return;

  terminalPill.addEventListener('click', () => {
    const cmd = terminalPill.getAttribute('data-copy') || 'git clone https://github.com/mynameisbat/zenith-macos.git';
    if (navigator.clipboard) {
      navigator.clipboard.writeText(cmd);
      showToast('Copied command to clipboard!');
    }
  });
}

// Lightweight Toast notification
function showToast(message) {
  let toast = document.getElementById('site-toast');
  if (!toast) {
    toast = document.createElement('div');
    toast.id = 'site-toast';
    toast.style.position = 'fixed';
    toast.style.bottom = '24px';
    toast.style.right = '24px';
    toast.style.backgroundColor = '#13151f';
    toast.style.color = '#f4f5f9';
    toast.style.padding = '10px 18px';
    toast.style.borderRadius = '8px';
    toast.style.fontSize = '13px';
    toast.style.fontWeight = '500';
    toast.style.border = '1px solid rgba(255, 255, 255, 0.12)';
    toast.style.boxShadow = '0 8px 24px rgba(0,0,0,0.5)';
    toast.style.zIndex = '9999';
    toast.style.transition = 'opacity 0.2s ease, transform 0.2s ease';
    document.body.appendChild(toast);
  }

  toast.textContent = message;
  toast.style.opacity = '1';
  toast.style.transform = 'translateY(0)';

  clearTimeout(window.__toastTimer);
  window.__toastTimer = setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transform = 'translateY(8px)';
  }, 2200);
}
