(() => {
  const screen = document.getElementById('app-screen');
  const controls = document.querySelector('.screen-controls');
  const error = document.getElementById('screen-error');
  if (!screen || !controls || !error) return;

  const screens = {
    live: { src: '/screens/live.png?v=2.2-24', alt: 'BPM live display with a large heart rate reading, average, minimum, maximum, and current zone' },
    workout: { src: '/screens/workout-stats.png?v=2.2-24', alt: 'BPM workout stats showing heart rate, total time, set number, set time, average and maximum heart rate, zone, and calories' },
    hrv: { src: '/screens/hrv.png?v=2.2-24', alt: 'BPM shared HRV result showing 46 milliseconds with average, minimum, and maximum heart rate' },
    stream: { src: '/screens/sharing.png?v=2.2-24', alt: 'BPM shared workout on a viewer’s iPhone with live heart rate, work and rest sets, and remote workout controls' },
    share: { src: '/screens/share.png?v=2.2-24', alt: 'BPM Share drawer with the workout chart card and Share Chart button' },
    presets: { src: '/screens/presets.png?v=2.2-24', alt: 'BPM workout presets with Norwegian 4x4 and three HIIT interval routines, showing work, rest, and total durations' }
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
