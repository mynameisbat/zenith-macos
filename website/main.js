// Zenith 2.0 - Interactive Motion & Native Product Simulations
// Designed strictly for taste-skill v2.1 House Rules

document.addEventListener('DOMContentLoaded', () => {
  initBrewCopy();
  initCommandHubInteractive();
  initLoupeSimulation();
  initNotchInteractive();
  initCleanerSimulation();
});

// 1. Homebrew Command Copy Box
function initBrewCopy() {
  const brewBox = document.getElementById('brew-box');
  const brewCopyBtn = document.getElementById('brew-copy');

  const copyAction = () => {
    const text = 'brew install --cask zenith';
    if (navigator.clipboard) {
      navigator.clipboard.writeText(text);
    }
    showToast('Copied: brew install --cask zenith');
  };

  if (brewBox) brewBox.addEventListener('click', copyAction);
  if (brewCopyBtn) brewCopyBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    copyAction();
  });
}

// 2. Interactive macOS Command Hub (Search + Category Filter + Copy)
function initCommandHubInteractive() {
  const searchInput = document.getElementById('hub-search-input');
  const clipCards = document.querySelectorAll('.clip-card');
  const filterChips = document.querySelectorAll('.action-chip');

  let activeCategory = 'all';

  const filterClips = () => {
    const query = (searchInput?.value || '').toLowerCase().trim();

    clipCards.forEach(card => {
      const category = card.getAttribute('data-category');
      const text = (card.getAttribute('data-clip') || '') + ' ' + (card.textContent || '');
      const matchesCategory = activeCategory === 'all' || category === activeCategory;
      const matchesQuery = !query || text.toLowerCase().includes(query);

      if (matchesCategory && matchesQuery) {
        card.style.display = 'flex';
      } else {
        card.style.display = 'none';
      }
    });
  };

  if (searchInput) {
    searchInput.addEventListener('input', filterClips);
  }

  filterChips.forEach(chip => {
    chip.addEventListener('click', () => {
      filterChips.forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      activeCategory = chip.getAttribute('data-filter') || 'all';
      filterClips();
    });
  });

  clipCards.forEach(card => {
    card.addEventListener('click', () => {
      const text = card.getAttribute('data-clip') || '';
      if (navigator.clipboard) {
        navigator.clipboard.writeText(text);
      }
      showToast(`Pasted to clipboard: "${text.substring(0, 32)}..."`);
    });
  });
}

// 3. Interactive Shottr-Style Loupe Magnifier Tracking
function initLoupeSimulation() {
  const stage = document.getElementById('loupe-stage');
  const lens = document.getElementById('loupe-lens');

  if (!stage || !lens) return;

  stage.addEventListener('mousemove', (e) => {
    const rect = stage.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    // Clamp inside stage bounds
    const clampedX = Math.max(70, Math.min(rect.width - 70, x));
    const clampedY = Math.max(70, Math.min(rect.height - 70, y));

    lens.style.left = `${clampedX - 70}px`;
    lens.style.top = `${clampedY - 70}px`;
  });

  stage.addEventListener('mouseleave', () => {
    // Reset to center
    lens.style.left = '240px';
    lens.style.top = '120px';
  });
}

// 4. Interactive MacBook Dynamic Island Notch Shelf
function initNotchInteractive() {
  const notch = document.getElementById('interactive-notch');
  const notchLabel = document.getElementById('interactive-notch-label');
  const drawer = document.getElementById('shelf-drawer');
  const btnAlert = document.getElementById('btn-trigger-alert');
  const btnToggle = document.getElementById('btn-toggle-shelf');

  let isAlerting = false;
  let isDrawerOpen = true;

  const alerts = [
    'Copied · #0F62FE Sapphire Blue',
    'Retina Screenshot Saved (2880 × 1800)',
    'DoH Shield Active · Cloudflare 1.1.1.1',
    'Freed 42.0 GB Developer Caches'
  ];
  let alertIdx = 0;

  const triggerAlert = () => {
    if (isAlerting || !notch || !notchLabel) return;
    isAlerting = true;
    notch.style.transform = 'scale(1.08)';
    notchLabel.textContent = alerts[alertIdx % alerts.length];
    alertIdx++;

    setTimeout(() => {
      notch.style.transform = 'scale(1)';
      setTimeout(() => {
        notchLabel.textContent = 'Zenith Shelf · 2 items parked';
        isAlerting = false;
      }, 200);
    }, 2000);
  };

  const toggleDrawer = () => {
    if (!drawer) return;
    isDrawerOpen = !isDrawerOpen;
    drawer.style.display = isDrawerOpen ? 'flex' : 'none';
  };

  if (notch) notch.addEventListener('click', triggerAlert);
  if (btnAlert) btnAlert.addEventListener('click', triggerAlert);
  if (btnToggle) btnToggle.addEventListener('click', toggleDrawer);
}

// 5. Developer System Purge Simulation
function initCleanerSimulation() {
  const checkboxes = document.querySelectorAll('.cleaner-checkbox');
  const badge = document.getElementById('cleaner-badge');
  const btnClean = document.getElementById('btn-clean-action');

  const sizes = [18.4, 12.6, 7.8, 3.2];

  const updateCleanTotal = () => {
    let total = 0;
    checkboxes.forEach((cb, idx) => {
      if (cb.checked) {
        total += sizes[idx] || 0;
      }
    });

    const formatted = total.toFixed(1);
    if (badge) badge.textContent = `${formatted} GB Cleanable`;
    if (btnClean) btnClean.textContent = `Purge Selected (${formatted} GB)`;
  };

  checkboxes.forEach(cb => {
    cb.addEventListener('change', updateCleanTotal);
  });

  if (btnClean) {
    btnClean.addEventListener('click', () => {
      btnClean.textContent = 'Purging safely...';
      btnClean.style.opacity = '0.7';

      setTimeout(() => {
        if (badge) {
          badge.textContent = '0.0 GB · Clean';
          badge.style.backgroundColor = 'rgba(31, 193, 107, 0.15)';
          badge.style.color = '#1fc16b';
        }
        btnClean.textContent = '42.0 GB Reclaimed';
        btnClean.style.backgroundColor = '#1fc16b';
        btnClean.style.opacity = '1';
        showToast('Successfully purged 42.0 GB developer caches into Trash!');
      }, 900);
    });
  }
}

// Toast HUD Utility
function showToast(message) {
  const toast = document.getElementById('toast-hud');
  if (!toast) return;

  toast.textContent = message;
  toast.classList.add('show');

  setTimeout(() => {
    toast.classList.remove('show');
  }, 2400);
}
