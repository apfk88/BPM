(() => {
  const screen = document.getElementById('app-screen');
  const controls = document.querySelector('.screen-controls');
  const error = document.getElementById('screen-error');
  if (!screen || !controls || !error) return;

  const screens = {
    live: { src: '/screens/live.png', alt: 'BPM live display with a large 122 BPM reading, heart rate statistics, and zone 2 indicator' },
    workout: { src: '/screens/workout.png', alt: 'BPM workout timer showing set times, average heart rate, and work and rest controls' },
    hrv: { src: '/screens/hrv.png', alt: 'BPM HRV result showing 22 milliseconds with average, minimum, and maximum readings' },
    sharing: { src: '/screens/sharing.png', alt: 'BPM live sharing screen with a temporary six-digit code above the heart rate display' }
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
