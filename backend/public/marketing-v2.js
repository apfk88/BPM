(() => {
  const screen = document.getElementById('app-screen');
  const controls = document.querySelector('.screen-controls');
  const error = document.getElementById('screen-error');
  const index = document.querySelector('.screen-index');
  if (!screen || !controls || !error || !index) return;

  const screens = {
    live: { src: '/screens/live.png', alt: 'BPM live display with a large 122 BPM reading, heart rate statistics, and zone 2 indicator', index: '01' },
    workout: { src: '/screens/workout.png', alt: 'BPM workout timer showing set times, average heart rate, and work and rest controls', index: '02' },
    hrv: { src: '/screens/hrv.png', alt: 'BPM HRV result showing 22 milliseconds with average, minimum, and maximum readings', index: '03' },
    sharing: { src: '/screens/sharing.png', alt: 'BPM live sharing screen with a temporary six-digit code above the heart rate display', index: '04' }
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
      error.hidden = true;
      error.textContent = '';
      index.textContent = `${next.index} / 04`;
      controls.querySelectorAll('button').forEach((control) => {
        control.setAttribute('aria-pressed', String(control === button));
      });
    } catch {
      if (currentRequest === request) {
        error.hidden = false;
        error.textContent = 'That screenshot couldn’t load. Please try again.';
      }
    }
  });
})();
