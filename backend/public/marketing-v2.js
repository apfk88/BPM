(() => {
  const screen = document.getElementById('app-screen');
  const controls = document.querySelector('.screen-controls');
  const caption = document.getElementById('screen-caption');
  const index = document.querySelector('.screen-index');
  if (!screen || !controls || !caption || !index) return;

  const screens = {
    live: { src: '/screens/live.png', alt: 'BPM live display with a large 122 BPM reading, heart rate statistics, and zone 2 indicator', caption: 'Big numbers. Your current zone. Nothing in the way.', index: '01' },
    workout: { src: '/screens/workout.png', alt: 'BPM workout timer showing set times, average heart rate, and work and rest controls', caption: 'Time your sets. Track your effort. Take your rest.', index: '02' },
    hrv: { src: '/screens/hrv.png', alt: 'BPM HRV result showing 22 milliseconds with average, minimum, and maximum readings', caption: 'A two-minute HRV check, calculated on your device.', index: '03' },
    sharing: { src: '/screens/sharing.png', alt: 'BPM live sharing screen with a temporary six-digit code above the heart rate display', caption: 'Your live heart rate, shared with a simple code.', index: '04' }
  };
  let request = 0;
  controls.hidden = false;
  controls.addEventListener('click', async (event) => {
    const button = event.target.closest('button[data-screen]');
    if (!button || !controls.contains(button)) return;
    const next = screens[button.dataset.screen];
    if (!next) return;
    const currentRequest = ++request;
    const preload = new Image();
    preload.src = next.src;
    try {
      await preload.decode();
      if (currentRequest !== request) return;
      screen.src = next.src;
      screen.alt = next.alt;
      caption.textContent = next.caption;
      index.textContent = `${next.index} / 04`;
      controls.querySelectorAll('button').forEach((control) => {
        control.setAttribute('aria-pressed', String(control === button));
      });
    } catch {
      if (currentRequest === request) caption.textContent = 'That screenshot couldn’t load. Please try again.';
    }
  });
})();
