# HTML reporter frontend

Source for the single-page HTML report rendered by
`RSpecTracer::Reporters::HtmlReporter` into
`<report_dir>/index.html` at finalize-time.

## Stack

- **Preact 10** — React-identical API at ~3 KB runtime. Five report
  types share a `ReportTable` / `SearchBar` pair, so a component tree
  pays for itself. Users who fork to customize find a universal API;
  end users who open the report get a tiny bundle.
- **Vite** — zero-config JSX + CSS pipeline, deterministic output.
- **No TypeScript** — plain JSX keeps the toolchain surface small. Add
  `.ts` if a future widget earns it.

No test framework on the frontend side. The single source of truth for
rendered output is the Ruby-side golden spec
(`spec/fixtures/golden/html_reporter/index.html`) which compares the
byte-identical output of `HtmlReporter#generate` against a committed
baseline. Drift in components shows up there.

## Layout

```
lib/rspec_tracer/reporters/html/
├── package.json         # dependencies pinned, lock committed
├── package-lock.json
├── vite.config.js       # stable filenames, no hashing, deterministic
├── README.md            # this file
├── src/
│   ├── index.html       # template; Ruby injects payload + fallback
│   ├── main.jsx         # boot + hydrate
│   ├── app.jsx          # tab shell + summary
│   ├── styles.css       # all styles (single bundle)
│   └── components/
│       ├── ReportTable.jsx       # shared primitive: filter + sort
│       ├── SearchBar.jsx
│       ├── AllExamples.jsx
│       ├── DuplicateExamples.jsx
│       ├── FlakyExamples.jsx
│       ├── ExamplesDependency.jsx
│       └── FilesDependency.jsx
└── dist/                # COMMITTED build output; users never rebuild
    ├── index.html
    └── assets/
        ├── index.js
        └── index.css
```

## Rebuilding

```
task reporters:html:build   # npm ci + vite build
```

The Taskfile wires this into `task gem:build` so local gem builds
always pick up a fresh dist. On CI, the drift check
(`task reporters:html:check`) runs a fresh build and fails if
`git diff --exit-code dist/` is non-empty — committing a src/ change
without rebuilding fails fast.

## Integration with the Ruby reporter

At finalize-time, `HtmlReporter#generate`:

1. Reads `dist/index.html` (skeleton with marker comments).
2. Replaces `<!-- RSPEC_TRACER_FALLBACK -->` with server-rendered
   `<table>` HTML for each of the 5 report types. These tables
   satisfy the "works without JavaScript" AC and are removed from
   the DOM by `main.jsx` after Preact hydrates.
3. Replaces the `<script id="report-data">` body with the reporter
   payload (built by `Reporters::PayloadBuilder`, the same module
   `JsonReporter` uses).
4. Writes the finished HTML to `<report_dir>/index.html` and copies
   `dist/assets/` to `<report_dir>/assets/`.

The reporter emits identically whether JavaScript is available in the
end user's browser or not. The interactive version is strictly
additive.
