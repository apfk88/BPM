import Head from 'next/head';
import type { GetServerSideProps } from 'next';
import { useRouter } from 'next/router';
import { useEffect, useMemo, useRef, useState } from 'react';
import type { KeyboardEvent, PointerEvent } from 'react';
import type { WorkoutPageExport, WorkoutPageZone } from '../../lib/workout-page-schema';
import { clampRange, descriptionBlocks, elapsedToActive, formatDuration, heartRateCSV, panWorkoutViewport, plotPoints,
  rangeMetricsAvailable, sampleAt, setsCSV, workoutDateLabel, workoutJSON, workoutPreviewImageURL, workoutTimeline, ZONE_COLORS } from '../../lib/workout-page-viewer';
import type { WorkoutRange } from '../../lib/workout-page-viewer';
import styles from '../../styles/workout-page.module.css';

type LoadState = { status: 'loading' } | { status: 'ready'; workout: WorkoutPageExport }
  | { status: 'error'; message: string; retry: boolean };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const KEY = /^[A-Za-z0-9_-]{43}$/;
const LINK_CODE = /^[A-Za-z0-9_-]{21}[AQgw]$/;
const fullRange = (workout: WorkoutPageExport) => ({ start: 0, end: workout.durationSeconds });
type WorkoutPageProps = { initialPageID: string; previewImageURL: string | null };

export const getServerSideProps: GetServerSideProps<WorkoutPageProps> = async ({ params, query, res }) => {
  res.setHeader('Cache-Control', 'private, no-store');
  res.setHeader('Vercel-CDN-Cache-Control', 'no-store');
  res.setHeader('CDN-Cache-Control', 'no-store');
  res.setHeader('X-Robots-Tag', 'noindex, nofollow, noarchive, nosnippet');
  res.setHeader('Referrer-Policy', 'no-referrer');
  const initialPageID = typeof params?.pageID === 'string' ? params.pageID : '';
  // The image route validates the capability. This shell never fetches workout data or creates a capability.
  return { props: { initialPageID, previewImageURL: workoutPreviewImageURL(initialPageID, query.p) } };
};

function saveFile(contents: string, fileName: string, type: string) {
  const url = URL.createObjectURL(new Blob([contents], { type }));
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = fileName;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function zoneLabel(zone: WorkoutPageZone): string {
  if (zone.zone === 1 && zone.upperBPM != null) return `< ${zone.upperBPM} BPM`;
  if (zone.zone === 5 && zone.lowerBPM != null) return `≥ ${zone.lowerBPM} BPM`;
  return zone.lowerBPM != null && zone.upperBPM != null ? `${zone.lowerBPM}–<${zone.upperBPM} BPM` : 'Thresholds not saved';
}

function WorkoutDescription({ text }: { text: string }) {
  return <div className={styles.description}>{descriptionBlocks(text).map((block, index) => {
    if (block.kind === 'paragraph') return <p key={index}>{block.text}</p>;
    if (block.kind === 'ordered') return <ol key={index} start={block.items[0]?.number}>
      {block.items.map((item, itemIndex) => <li key={itemIndex} value={item.number}>{item.text}</li>)}
    </ol>;
    return <ul key={index}>{block.items.map((item, itemIndex) => <li key={itemIndex}>{item.text}</li>)}</ul>;
  })}</div>;
}

function Zones({ workout }: { workout: WorkoutPageExport }) {
  const duration = workout.durationSeconds;
  const zones = workout.zones;
  const assigned = zones.reduce((total, zone) => total + zone.durationSeconds, 0);
  const remaining = Math.max(0, duration - assigned);
  return <section className={styles.panel} aria-labelledby="zones-heading">
    <div className={styles.sectionHeader}><div><h2 id="zones-heading">Time in zones</h2>
      <p className={styles.hint}>Active workout time</p></div></div>
    {zones.length === 0 ? <p className={styles.hint}>Zone data is not available for this workout.</p> : <>
      <div className={styles.zones}>{zones.map(zone => <div className={styles.zone} key={zone.zone}>
        <div className={styles.zoneLabel}>Zone {zone.zone}<span>{zoneLabel(zone)}</span></div>
        <div className={styles.zoneValue}>{formatDuration(zone.durationSeconds)}<span>{duration > 0 ? (zone.durationSeconds / duration * 100).toFixed(1) : '0.0'}%</span></div>
        <div className={styles.bar}><i style={{ width: `${Math.min(100, duration > 0 ? zone.durationSeconds / duration * 100 : 0)}%`, background: ZONE_COLORS[zone.zone - 1] }} /></div>
      </div>)}</div>
      {remaining > 0 && <p className={styles.hint} style={{ marginTop: 20 }}>{formatDuration(remaining)} unmeasured or outside zones.</p>}
    </>}
  </section>;
}

function WorkoutChart({ workout, focusedRange }: { workout: WorkoutPageExport; focusedRange: WorkoutRange | null }) {
  const [viewport, setViewport] = useState<WorkoutRange>(fullRange(workout));
  const [cursor, setCursor] = useState<number | null>(null);
  const [dragging, setDragging] = useState(false);
  const [chartWidth, setChartWidth] = useState(980);
  const chartElement = useRef<SVGSVGElement>(null);
  const drag = useRef<{ pointerID: number; startX: number; viewport: WorkoutRange; plotWidth: number; moved: boolean } | null>(null);
  const points = useMemo(() => workoutTimeline(workout), [workout]);
  const trusted = rangeMetricsAvailable(workout);
  const plotted = useMemo(() => plotPoints(points, viewport), [points, viewport]);
  const sample = cursor == null ? null : sampleAt(points, cursor, trusted);
  const { min, max } = useMemo(() => points.length
    ? points.reduce((limits, point) => ({ min: Math.min(limits.min, point.bpm), max: Math.max(limits.max, point.bpm) }), { min: Infinity, max: -Infinity })
    : { min: 60, max: 160 }, [points]);
  const bottom = Math.max(0, Math.floor((min - 8) / 20) * 20);
  const top = Math.ceil((max + 8) / 20) * 20;
  const chart = { left: 38, right: chartWidth - 12, top: 15, bottom: 245, width: chartWidth, height: 285 };
  const width = Math.max(.01, viewport.end - viewport.start);
  const x = (time: number) => chart.left + (time - viewport.start) / width * (chart.right - chart.left);
  const y = (bpm: number) => chart.bottom - (bpm - bottom) / (top - bottom) * (chart.bottom - chart.top);
  const zoomed = viewport.end - viewport.start < workout.durationSeconds;
  const path = useMemo(() => trusted ? plotted.map((point, index) => {
    const start = Math.max(viewport.start, point.activeSeconds);
    const end = Math.min(viewport.end, point.validUntil);
    const previous = plotted[index - 1];
    const next = plotted[index + 1];
    const command = previous?.segment === point.segment ? 'L' : 'M';
    const tail = next?.segment !== point.segment && end > start ? `H${x(end).toFixed(2)}` : '';
    return `${command}${x(start).toFixed(2)},${y(point.bpm).toFixed(2)}${tail}`;
  }).join(' ') : '', [plotted, viewport, trusted, bottom, top, chartWidth]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (focusedRange && focusedRange.end > focusedRange.start) setViewport(focusedRange);
  }, [focusedRange]);
  useEffect(() => {
    setCursor(value => value == null ? null : Math.max(viewport.start, Math.min(viewport.end, value)));
  }, [viewport.start, viewport.end]);
  useEffect(() => {
    const element = chartElement.current;
    if (!element) return;
    const observer = new ResizeObserver(entries => setChartWidth(Math.max(260, Math.round(entries[0].contentRect.width))));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  function zoom(factor: number) {
    const nextWidth = Math.min(workout.durationSeconds, Math.max(Math.min(10, workout.durationSeconds), width * factor));
    const center = cursor ?? (viewport.start + viewport.end) / 2;
    const start = Math.max(0, Math.min(workout.durationSeconds - nextWidth, center - nextWidth / 2));
    setViewport({ start, end: start + nextWidth });
  }
  function pan(direction: number) {
    setViewport(panWorkoutViewport(viewport, workout.durationSeconds, -direction * .6, 1));
  }
  function inspect(event: PointerEvent<SVGSVGElement>) {
    const rect = event.currentTarget.getBoundingClientRect();
    const unit = (event.clientX - rect.left) / rect.width * chart.width;
    setCursor(Math.max(viewport.start, Math.min(viewport.end, viewport.start + (unit - chart.left) / (chart.right - chart.left) * width)));
  }
  function beginPointer(event: PointerEvent<SVGSVGElement>) {
    if (!event.isPrimary || event.button !== 0) return;
    inspect(event);
    if (!zoomed) return;
    const rect = event.currentTarget.getBoundingClientRect();
    drag.current = { pointerID: event.pointerId, startX: event.clientX, viewport,
      plotWidth: rect.width * (chart.right - chart.left) / chart.width, moved: false };
    event.currentTarget.setPointerCapture(event.pointerId);
  }
  function movePointer(event: PointerEvent<SVGSVGElement>) {
    const gesture = drag.current;
    if (gesture?.pointerID === event.pointerId) {
      const delta = event.clientX - gesture.startX;
      if (gesture.moved || Math.abs(delta) >= 4) {
        gesture.moved = true;
        setDragging(true);
        setViewport(panWorkoutViewport(gesture.viewport, workout.durationSeconds, delta, gesture.plotWidth));
        return;
      }
    }
    if (event.isPrimary) inspect(event);
  }
  function endPointer(event: PointerEvent<SVGSVGElement>) {
    if (drag.current?.pointerID !== event.pointerId) return;
    drag.current = null;
    setDragging(false);
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
  }
  function keyboard(event: KeyboardEvent<SVGSVGElement>) {
    const step = event.shiftKey ? width / 10 : Math.max(.1, width / 100);
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault();
      setCursor(value => Math.max(viewport.start, Math.min(viewport.end, (value ?? viewport.start) + (event.key === 'ArrowLeft' ? -step : step))));
    } else if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault();
      setCursor(event.key === 'Home' ? viewport.start : viewport.end);
    } else if (event.key === 'PageUp' || event.key === 'PageDown') {
      event.preventDefault();
      pan(event.key === 'PageUp' ? -1 : 1);
    }
  }

  return <section className={styles.panel} aria-labelledby="heart-rate-heading">
    <div className={styles.sectionHeader}><div><h2 id="heart-rate-heading">Heart rate</h2>
      <p className={styles.hint}>Active workout time</p></div>
    </div>
    <div className={styles.readout} aria-live="off"><strong>{cursor == null ? (workout.summary.avgBPM ?? '—') : sample?.bpm ?? '—'} <span>BPM</span></strong>
      <span>{cursor == null ? 'Average · touch or hover to inspect' : sample ? `Reading at ${formatDuration(sample.activeSeconds, true)}` : `No reading at ${formatDuration(cursor, true)}`}</span></div>
    <svg ref={chartElement} className={`${styles.chart} ${zoomed ? styles.zoomedChart : ''} ${dragging ? styles.draggingChart : ''}`} viewBox={`0 0 ${chart.width} ${chart.height}`} role="slider" tabIndex={0}
      aria-label="Inspect heart rate by workout time" aria-valuemin={viewport.start} aria-valuemax={viewport.end}
      aria-valuenow={cursor ?? viewport.start} aria-valuetext={sample ? `${formatDuration(sample.activeSeconds)}, ${sample.bpm} BPM` : 'No reading selected'}
      aria-describedby="workout-chart-help" onPointerMove={movePointer} onPointerDown={beginPointer} onPointerUp={endPointer}
      onPointerCancel={endPointer} onLostPointerCapture={endPointer} onKeyDown={keyboard}>
      <title>Recorded heart rate over active workout time</title>
      <desc>Use left and right arrow keys to inspect readings. Shift moves faster. When zoomed, Page Up and Page Down pan through the workout.</desc>
      <defs><clipPath id="workout-plot-clip"><rect x={chart.left} y={chart.top} width={chart.right - chart.left} height={chart.bottom - chart.top} /></clipPath></defs>
      {[0, 1, 2, 3, 4].map(tick => {
        const value = bottom + (top - bottom) * tick / 4;
        return <g key={tick}><line x1={chart.left} x2={chart.right} y1={y(value)} y2={y(value)} stroke="#29312b" strokeDasharray="3 5" /><text x={chart.left - 10} y={y(value) + 4} textAnchor="end">{Math.round(value)}</text></g>;
      })}
      <g clipPath="url(#workout-plot-clip)">
        {workout.sets.filter(set => set.endActiveSeconds >= viewport.start && set.startActiveSeconds <= viewport.end).map(set => <g key={set.index}>
          {set.kind !== 'work' && <rect x={x(set.startActiveSeconds)} y={chart.top} width={Math.max(0, x(set.endActiveSeconds) - x(set.startActiveSeconds))}
            height={chart.bottom - chart.top} fill={set.kind === 'rest' ? '#8b9bda' : '#61bfbc'} opacity=".07" />}
          <line x1={x(set.startActiveSeconds)} x2={x(set.startActiveSeconds)} y1={chart.top} y2={chart.bottom} stroke="#89978c" strokeOpacity=".2" />
        </g>)}
        {workout.intervals.filter(interval => interval.kind === 'pause').map((pause, index) => {
          const time = elapsedToActive(workout, pause.startElapsedSeconds);
          return <line key={index} x1={x(time)} x2={x(time)} y1={chart.top} y2={chart.bottom} stroke="#e7bd6e" strokeDasharray="3 5" strokeOpacity=".7"><title>Paused {formatDuration(pause.endElapsedSeconds - pause.startElapsedSeconds)} at {formatDuration(time)}</title></line>;
        })}
        {trusted ? <path d={path} fill="none" stroke="#43e275" strokeWidth="2" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
          : plotted.map(point => <circle key={point.index} cx={x(point.activeSeconds)} cy={y(point.bpm)} r="1.7" fill="#43e275" />)}
        {cursor != null && <line x1={x(cursor)} x2={x(cursor)} y1={chart.top} y2={chart.bottom} stroke="#e5f3e9" strokeOpacity=".6" />}
        {cursor != null && sample && <circle cx={x(sample.activeSeconds)} cy={y(sample.bpm)} r="4" fill="#43e275" stroke="#f4fff7" strokeWidth="2" />}
      </g>
      {[0, 1, 2, 3, 4].map(tick => <text key={tick} x={x(viewport.start + width * tick / 4)} y={chart.bottom + 26} textAnchor={tick === 0 ? 'start' : tick === 4 ? 'end' : 'middle'}>{formatDuration(viewport.start + width * tick / 4)}</text>)}
    </svg>
    <div className={styles.legend}><span><i style={{ background: '#43e275' }} />Heart rate</span><span><i style={{ background: '#8b9bda' }} />Rest</span><span><i style={{ background: '#61bfbc' }} />Cooldown</span><span><i style={{ background: '#e7bd6e' }} />Pause</span></div>
    <div className={styles.toolbar}>
      <button className={styles.button} onClick={() => zoom(.5)} disabled={workout.durationSeconds <= 0 || width <= Math.min(10, workout.durationSeconds)}>Zoom in</button>
      <button className={styles.button} onClick={() => zoom(2)} disabled={width >= workout.durationSeconds}>Zoom out</button>
      <button className={styles.button} aria-label="Pan chart earlier" onClick={() => pan(-1)} disabled={viewport.start <= 0}>←</button>
      <button className={styles.button} aria-label="Pan chart later" onClick={() => pan(1)} disabled={viewport.end >= workout.durationSeconds}>→</button>
      <button className={styles.button} onClick={() => { setViewport(fullRange(workout)); setCursor(null); }}>Reset view</button>
    </div>
    <p className={styles.hint} id="workout-chart-help">{zoomed ? 'Drag left or right to move through the workout. Use Page Up or Page Down with the keyboard.' : 'Touch or hover to inspect a reading. Zoom in to drag through the workout.'}</p>
    {points.length === 0 && <p className={styles.hint}>No heart-rate samples were saved for this workout.</p>}
  </section>;
}

function WorkoutContent({ workout }: { workout: WorkoutPageExport }) {
  const [focusedRange, setFocusedRange] = useState<WorkoutRange | null>(null);
  const stats = [
    { label: 'Workout time', value: formatDuration(workout.durationSeconds), unit: '' },
    { label: 'Average heart rate', value: workout.summary.avgBPM, unit: 'BPM' },
    { label: 'Maximum heart rate', value: workout.summary.maxBPM, unit: 'BPM' },
    { label: 'Minimum heart rate', value: workout.summary.minBPM, unit: 'BPM' },
    { label: 'Recovery · 2 min', value: workout.summary.recoveryBPM, unit: 'BPM' },
    { label: workout.summary.activeCalories != null ? 'Est. active calories' : 'Est. total calories', value: workout.summary.activeCalories != null ? Math.round(workout.summary.activeCalories) : workout.summary.calories != null ? Math.round(workout.summary.calories) : null, unit: 'kcal' },
  ].filter(stat => stat.value != null);
  const dateLabel = workoutDateLabel(workout);
  const date = workout.recordedAt ? new Date(workout.recordedAt) : null;
  return <>
    <header className={styles.hero}>{dateLabel && <p className={styles.eyebrow}>Workout on {dateLabel}</p>}<h1 className={styles.title}>{workout.title || 'Workout'}</h1>
      {workout.description && <WorkoutDescription text={workout.description} />}
      {date && !Number.isNaN(date.getTime()) && <p className={styles.date}>{date.toLocaleString(undefined, { dateStyle: 'long', timeStyle: 'short' })} · your local time</p>}
    </header>
    <dl className={styles.stats} aria-label="Saved workout summary">{stats.map(stat => <div className={styles.stat} key={stat.label}><dt>{stat.label}</dt><dd>{stat.value}{stat.unit && <small>{stat.unit}</small>}</dd></div>)}</dl>
    <WorkoutChart workout={workout} focusedRange={focusedRange} />
    <div className={styles.columns}>
      <Zones workout={workout} />
      <section className={styles.panel} aria-labelledby="sets-heading"><div className={styles.sectionHeader}><div><h2 id="sets-heading">Workout breakdown</h2><p className={styles.hint}>Select a set to inspect.</p></div></div>
        {workout.sets.length ? <div className={styles.tableWrap}><table className={styles.table}><thead><tr><th scope="col">Set</th><th scope="col">Time</th><th scope="col">Avg</th><th scope="col">Min / max</th></tr></thead>
          <tbody>{workout.sets.map(set => <tr key={set.index}><td><button onClick={() => { setFocusedRange(clampRange({ start: set.startActiveSeconds, end: set.endActiveSeconds }, workout.durationSeconds)); document.getElementById('heart-rate-heading')?.scrollIntoView({ block: 'start', behavior: 'auto' }); }}>
            {set.label || `Set ${set.index + 1}`}<span className={styles.setKind}>{set.kind === 'cooldown' ? 'Cooldown' : set.kind === 'rest' ? 'Rest' : 'Work'}</span></button></td>
            <td>{formatDuration(set.durationSeconds)}</td><td>{set.avgBPM ?? '—'}</td><td>{set.minBPM ?? '—'} / {set.maxBPM ?? '—'}</td></tr>)}</tbody></table></div>
          : <p className={styles.hint}>No set breakdown was saved.</p>}
      </section>
    </div>
    <section className={`${styles.panel} ${styles.download}`} aria-labelledby="download-heading"><h2 id="download-heading">Download workout</h2>
      <div className={styles.toolbar}><button className={`${styles.button} ${styles.primary}`} onClick={() => saveFile(workoutJSON(workout), 'bpm-workout.json', 'application/json;charset=utf-8')}>Workout JSON ↓</button>
        <button className={styles.button} onClick={() => saveFile(heartRateCSV(workout), 'bpm-heart-rate.csv', 'text/csv;charset=utf-8')}>Heart-rate CSV ↓</button>
        {workout.sets.length > 0 && <button className={styles.button} onClick={() => saveFile(setsCSV(workout), 'bpm-sets.csv', 'text/csv;charset=utf-8')}>Sets CSV ↓</button>}</div>
    </section>
  </>;
}

export default function WorkoutPage({ initialPageID, previewImageURL }: WorkoutPageProps) {
  const router = useRouter();
  const pageID = typeof router.query.pageID === 'string' ? router.query.pageID : initialPageID;
  const [state, setState] = useState<LoadState>({ status: 'loading' });
  const [attempt, setAttempt] = useState(0);
  const [hashRevision, setHashRevision] = useState(0);
  const request = useRef<{ identity: string; promise: Promise<LoadState> } | null>(null);
  useEffect(() => {
    const changed = () => setHashRevision(value => value + 1);
    window.addEventListener('hashchange', changed);
    return () => window.removeEventListener('hashchange', changed);
  }, []);
  useEffect(() => {
    if (!router.isReady) return;
    let current = true;
    const viewKey = window.location.hash.slice(1);
    const identity = `${pageID}:${viewKey}:${attempt}`;
    setState({ status: 'loading' });
    if (process.env.NODE_ENV === 'development' && process.env.NEXT_PUBLIC_WORKOUT_PAGE_PREVIEW === '1'
      && ['localhost', '127.0.0.1', '[::1]'].includes(window.location.hostname) && pageID === 'preview') {
      import('../../lib/workout-page-fixture').then(({ workoutPageFixture }) => {
        const fidelity = router.query.fidelity === 'reduced' || router.query.fidelity === 'unknown' ? router.query.fidelity : 'full';
        const workout = workoutPageFixture(fidelity);
        if (router.query.variant === 'empty' || router.query.variant === 'zero') {
          workout.title = 'Workout without saved heart rate';
          workout.samples = [];
          workout.summary = {};
          workout.zones = [];
          workout.intervals = [];
          workout.sets = [];
          workout.quality = { sampleFidelity: 'full', rangeMetricsAvailable: true, exportedSampleCount: 0, originalSampleCount: 0 };
          if (router.query.variant === 'zero') workout.durationSeconds = workout.elapsedDurationSeconds = 0;
        }
        if (current) setState({ status: 'ready', workout });
      });
      return () => { current = false; };
    }
    if ((!UUID.test(pageID) && !LINK_CODE.test(pageID)) || !KEY.test(viewKey)) {
      setState({ status: 'error', message: 'This link is incomplete. Ask the person who shared it to copy the full private link from BPM.', retry: false });
      return;
    }
    // Reuse the in-flight read during React's development effect replay. No polling, route cache, or stored payload.
    if (request.current?.identity !== identity) {
      request.current = { identity, promise: (async (): Promise<LoadState> => {
        try {
          const response = await fetch(`/api/workout-pages/${encodeURIComponent(pageID)}`, {
            headers: { Authorization: `Bearer ${viewKey}` }, cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer', redirect: 'error',
          });
          if (response.status === 404 || response.status === 401 || response.status === 403) return { status: 'error', message: 'This page is unavailable. The owner may have deleted it or replaced the private link.', retry: false };
          if (response.status === 429) return { status: 'error', message: 'This page has received too many requests. Please try again in a moment.', retry: true };
          if (!response.ok) return { status: 'error', message: 'The workout could not be loaded. Please try again.', retry: true };
          const workout = await response.json() as WorkoutPageExport;
          if (workout.schemaVersion !== 1 || workout.calculationVersion !== 1 || !workout.quality || !Array.isArray(workout.samples)
            || !Array.isArray(workout.zones) || !Array.isArray(workout.sets) || !Array.isArray(workout.intervals)) {
            return { status: 'error', message: 'This workout uses a format this viewer does not support yet.', retry: false };
          }
          return { status: 'ready', workout };
        } catch {
          return { status: 'error', message: 'The workout could not be loaded. Check your connection and try again.', retry: true };
        }
      })() };
    }
    request.current.promise.then(result => { if (current) setState(result); });
    return () => { current = false; };
  }, [router.isReady, pageID, attempt, hashRevision, router.query.fidelity, router.query.variant]);

  return <>
    <Head><title>Private workout · BPM</title><meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta name="robots" content="noindex, nofollow, noarchive, nosnippet" /><meta name="referrer" content="no-referrer" />
      <meta name="description" content="A workout shared privately with BPM. Open the full link to view it." />
      <meta property="og:title" content="Private workout · BPM" /><meta property="og:description" content="Open the full private link to view this workout." />
      <meta property="og:type" content="website" /><meta name="twitter:card" content={previewImageURL ? 'summary_large_image' : 'summary'} />
      {previewImageURL && <><meta property="og:image" content={previewImageURL} /><meta property="og:image:type" content="image/png" />
        <meta property="og:image:width" content="1080" /><meta property="og:image:height" content="1350" />
        <meta property="og:image:alt" content="BPM workout card" /><meta name="twitter:image" content={previewImageURL} /></>}
      <link rel="icon" href="/favicon-dark-32x32.png" />
    </Head>
    <div className={styles.page}><div className={styles.shell}>
      <nav className={styles.nav} aria-label="BPM"><a href="/" className={styles.brand} aria-label="BPM home"><img src="/app-icon-dark.png" width="34" height="34" alt="" />BPM<span>.</span></a>
        <div className={styles.private}><svg viewBox="0 0 16 16" fill="none" aria-hidden="true"><rect x="3.5" y="7" width="9" height="7" rx="2" stroke="currentColor" /><path d="M5.5 7V4.5a2.5 2.5 0 0 1 5 0V7" stroke="currentColor" /></svg>Private workout link</div>
      </nav>
      <main>{state.status === 'ready' ? <WorkoutContent key={pageID} workout={state.workout} /> : <div className={styles.state} role="status">
        <p className={styles.eyebrow}>BPM workout</p><h1>{state.status === 'loading' ? 'Loading your workout…' : 'Workout unavailable'}</h1>
        {state.status === 'error' && <p>{state.message}</p>}
        {state.status === 'error' && state.retry && <button className={styles.button} onClick={() => setAttempt(value => value + 1)}>Try again</button>}
        <noscript>JavaScript is required to view this workout.</noscript>
      </div>}</main>
      <footer className={styles.footer}><p>This workout is private. Only people with the link can view it.</p>
        <div className={styles.footerLinks}><a href="/">Made with BPM</a><a href="/privacy.html">Privacy</a><a href={`mailto:vibecodeinc@proton.me?subject=${encodeURIComponent(`Report a BPM workout page${UUID.test(pageID) || LINK_CODE.test(pageID) ? `: ${pageID}` : ''}`)}`}>Report this page</a></div>
      </footer>
    </div></div>
    <style jsx global>{`html, body { margin: 0; background: #080a09; }`}</style>
  </>;
}
