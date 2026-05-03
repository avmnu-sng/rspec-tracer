# Accessibility audit — HTML reporter

This doc records the accessibility-audit baseline for rspec-tracer's
HTML reporter (`rspec_tracer_report/index.html`). Re-run the audit
on any PR that materially changes the HTML reporter's markup or
styling.

## Standards

The reporter targets **WCAG 2.1 AA** (which is a superset of WCAG
2.0 AA). The audit uses [`axe-core`](https://github.com/dequelabs/axe-core)
4.11.x — the de-facto industry baseline for automated WCAG
checking.

## Latest audit

**Date:** 2026-05-04
**Tooling:** axe-core 4.11.4 via `@axe-core/cli`, headless Chrome 147.
**Tags:** `wcag2aa,wcag21aa`
**Result:** **0 violations**.

Pages audited:
- `rspec_tracer_report/index.html` (single-page HTML report; the
  reporter ships as one self-contained page with assets bundled
  under `rspec_tracer_report/assets/`).

## How to re-run

```sh
task docs:wcag
```

(or directly:)

```sh
npx --yes @axe-core/cli "file://$(pwd)/rspec_tracer_report/index.html" \
  --tags wcag2aa,wcag21aa \
  --timeout 240
```

You'll need a generated HTML report on disk — run any of the
fixture-driving integration specs first:

```sh
task test:features:rails              # generates fixture report
ls spec/fixtures/rails_app/rspec_tracer_report/index.html
```

Then point axe at the path above instead.

## Important caveat — automated scope

axe-core's documentation notes: **"only 20% to 50% of all
accessibility issues can be automatically detected"**. A passing
axe run is necessary but not sufficient.

Issues axe-core CANNOT catch automatically:
- **Color choice meaning**: red-only-vs-green semantic distinctions
  (color-blind users see no difference).
- **Reading order**: visual layout vs DOM order mismatches.
- **Cognitive load**: dense data tables, jargon, lack of summaries.
- **Keyboard navigation flow**: tab order coherence, focus traps.
- **Screen reader announcements**: whether the surfaced text
  matches user mental model.

The automated audit is the floor — manual testing with a screen
reader (VoiceOver on macOS, NVDA on Windows) catches the rest.

## Manual checklist

When making material HTML reporter changes, walk this list manually:

- [ ] Tab through every interactive element (links, buttons,
      sortable column headers, search inputs); focus indicator is
      visible at every stop.
- [ ] Activate every interactive element via keyboard (Enter /
      Space) without using the mouse.
- [ ] Open the page with a screen reader. Verify:
  - The page title announces meaningfully.
  - Headings (`h1` / `h2` / `h3`) form a logical outline.
  - Tables have `<th scope>` annotations and announce row + column
    headers when navigating cells.
  - Status indicators (passed / failed / flaky / skipped) have
    text-equivalent meaning, not just color.
- [ ] Increase browser zoom to 200%; layout doesn't break, text
      doesn't get clipped.
- [ ] Use [axe DevTools browser extension](https://www.deque.com/axe/browser-extensions/)
      for an interactive walkthrough — surfaces issues axe-cli's
      headless run misses.

## Browser support

The reporter is tested on:

- Chrome / Edge (Chromium-based; current + previous major).
- Firefox (current ESR + current).
- Safari (current major + current macOS).

No support for browsers older than the above.

## Commitment

We treat accessibility violations as P1 bugs:

- A new violation introduced by a PR blocks merge.
- A pre-existing violation discovered by audit gets fixed in the
  next docs-touching PR.
- Major reporter redesigns get a manual + automated audit BEFORE
  ship, not after.

If you find a violation not surfaced by `task docs:wcag`, open an
issue with the violation rule + the screen reader / browser combo
that surfaced it.
