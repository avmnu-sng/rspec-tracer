import { render } from 'preact';
import { App } from './app.jsx';
import './styles.css';

// Hydration entry point. Parse the JSON payload Ruby injected into the
// `<script id="report-data">` tag, render the interactive Preact view
// into `#app`, and strip the server-side fallback tables (rendered by
// HtmlReporter for the no-JS case). If parsing fails for any reason,
// leave the fallback tables in place - graceful degradation matches
// the AC "report works with JavaScript disabled."
function boot() {
  const mount = document.getElementById('app');
  if (!mount) return;

  const dataNode = document.getElementById('report-data');
  if (!dataNode) return;

  let payload;
  try {
    payload = JSON.parse(dataNode.textContent || '{}');
  } catch (err) {
    console.error('rspec-tracer: failed to parse embedded report data', err);
    return;
  }

  render(<App payload={payload} />, mount);
  mount.setAttribute('data-hydrate', 'ready');

  const fallback = document.getElementById('fallback');
  if (fallback) fallback.remove();
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}
