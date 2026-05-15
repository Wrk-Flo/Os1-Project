// Boot orchestrator — runs the OS-1 InfinityLoader (Three.js helix→ring
// morph) inside a WKWebView, plays the OS-1 init sound in sync, then
// signals Swift via webkit.messageHandlers.boot when finished.
//
// Timing is a verbatim port of the original OS-1 webapp's
// SceneManager.onProgressComplete / onHelixComplete (commit a28f137,
// 2026-01-17). The audio file (14.16 s) is hand-tuned to the helix→ring
// transition: triggerTransition() and playAudio() fire on the same
// frame, the loader's default step rate (~12 s) carries the visual to
// the ring snap, then morphToDot + fadeOut play out, and the boot
// awaits the audio's natural end before unmounting. The Mac app adds a
// short front-loaded load hold before the helix/audio sequence starts so
// the app has a calmer cold-start phase.

import { InfinityLoader } from './infinity-loader.js';

const BRAND_DELAY_MS = 0;
const LOAD_LEAD_IN_MS = 4000;
const TAGLINE_DELAY_MS = 1400;
const HELIX_START_MS = 100;
// Window between helix appearing and the simultaneous
// triggerTransition + playAudio fire. Keep tight — this is dead time
// before the audio begins.
const TRIGGER_TRANSITION_MS = 1500;
const MORPH_TO_DOT_MS = 600;
const FADE_OUT_MS = 600;
const TAGLINE = 'We believe in infinity';

function signalSwift(name) {
  try {
    window.webkit?.messageHandlers?.boot?.postMessage({ event: name });
  } catch (_) {
    // Swift bridge missing in plain-browser preview — boot.js still works
    // standalone for local testing.
  }
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function revealTagline() {
  const el = document.getElementById('tagline');
  el.replaceChildren();
  for (const character of TAGLINE) {
    const span = document.createElement('span');
    span.className = 'char';
    // Non-breaking space — a literal ' ' inside an inline-block span
    // collapses to zero width, which renders the tagline as
    // "Webelieveininfinity".
    span.textContent = character === ' ' ? ' ' : character;
    el.appendChild(span);
  }
  Array.from(el.children).forEach((child, index) => {
    setTimeout(() => child.classList.add('revealed'), index * 35);
  });
}

function showBrand() {
  document.querySelector('.brand-lockup').classList.add('visible');
}

function hideBrandAndTagline(durationMs = 600) {
  const lockup = document.querySelector('.brand-lockup');
  const tagline = document.getElementById('tagline');
  for (const el of [lockup, tagline]) {
    if (!el) continue;
    el.style.transition = `opacity ${durationMs}ms ease`;
    el.style.opacity = '0';
  }
}

// Mirrors OS-1's playAudio (src/utils/audioPlayer.js) — fire-and-track
// with a Promise that resolves when the file finishes playing. Boot
// awaits this Promise before signalling Swift, so unmount lands on the
// natural end of the audio rather than a hand-tuned offset.
function playInitSound() {
  const audio = new Audio('init_sound.mp3');
  audio.preload = 'auto';
  const ended = new Promise((resolve) => {
    audio.addEventListener('ended', () => resolve(), { once: true });
    audio.addEventListener('error', () => resolve(), { once: true });
  });
  audio.play().catch(() => {
    // If autoplay is blocked or the file fails, resolve immediately so
    // the boot doesn't hang on the await below.
  });
  return { audio, ended };
}

document.addEventListener('DOMContentLoaded', async () => {
  const canvas = document.getElementById('infinity-canvas');
  // Default step rate (+1 per frame, ~12 s helix→ring) — matches the
  // OS-1 webapp's pacing exactly, which is what the audio file was
  // tuned against.
  const loader = new InfinityLoader(canvas);

  signalSwift('mounted');

  setTimeout(showBrand, BRAND_DELAY_MS);

  // Front-load the extra boot time before the helix and audio begin.
  await delay(LOAD_LEAD_IN_MS);

  setTimeout(revealTagline, TAGLINE_DELAY_MS);
  setTimeout(() => loader.start(), HELIX_START_MS);

  const helixComplete = new Promise((resolve) => {
    loader.onComplete = resolve;
  });

  // Idle helix → triggerTransition + playAudio fire on the same beat,
  // exactly as SceneManager.onProgressComplete does.
  await delay(TRIGGER_TRANSITION_MS);
  const { audio, ended: audioEnded } = playInitSound();
  loader.triggerTransition();

  await helixComplete;

  // Mirrors SceneManager.onHelixComplete: hide loading-scene UI, then
  // morphToDot, then fadeOut. We run the brand/tagline fade in parallel
  // with morphToDot so the viewport is clean for the dot collapse.
  hideBrandAndTagline(MORPH_TO_DOT_MS);
  await loader.morphToDot(MORPH_TO_DOT_MS);
  await loader.fadeOut(FADE_OUT_MS);

  // Wait for the init sound's natural end — this is the load-bearing
  // sync point. The 14.16 s audio extends ~2 s past the visual, and
  // unmounting before it finishes would clip the closing chord.
  await audioEnded;

  // Defensive: ensure audio is stopped before we tear down (in case
  // 'ended' fired from an error path).
  try {
    audio.pause();
    audio.currentTime = 0;
  } catch (_) {}

  signalSwift('finished');
});

document.addEventListener('click', () => signalSwift('skipped'));
