import { useMemo, useState } from 'preact/hooks';
import { AllExamples } from './components/AllExamples.jsx';
import { DuplicateExamples } from './components/DuplicateExamples.jsx';
import { FlakyExamples } from './components/FlakyExamples.jsx';
import { ExamplesDependency } from './components/ExamplesDependency.jsx';
import { FilesDependency } from './components/FilesDependency.jsx';

function buildTabs(payload) {
  const reports = (payload && payload.reports) || {};
  const tabs = [
    {
      id: 'all_examples',
      label: 'All Examples',
      count: (reports.all_examples || []).length,
      render: () => <AllExamples items={reports.all_examples || []} />,
    },
  ];

  if ((reports.duplicate_examples || []).length > 0) {
    tabs.push({
      id: 'duplicate_examples',
      label: 'Duplicate Examples',
      count: reports.duplicate_examples.length,
      render: () => <DuplicateExamples items={reports.duplicate_examples} />,
    });
  }

  if ((reports.flaky_examples || []).length > 0) {
    tabs.push({
      id: 'flaky_examples',
      label: 'Flaky Examples',
      count: reports.flaky_examples.length,
      render: () => <FlakyExamples items={reports.flaky_examples} />,
    });
  }

  tabs.push({
    id: 'examples_dependency',
    label: 'Examples Dependency',
    count: (reports.examples_dependency || []).length,
    render: () => <ExamplesDependency items={reports.examples_dependency || []} />,
  });

  tabs.push({
    id: 'files_dependency',
    label: 'Files Dependency',
    count: (reports.files_dependency || []).length,
    render: () => <FilesDependency items={reports.files_dependency || []} />,
  });

  return tabs;
}

export function App({ payload }) {
  const tabs = useMemo(() => buildTabs(payload), [payload]);
  const [activeId, setActiveId] = useState(tabs[0] ? tabs[0].id : null);
  const summary = (payload && payload.summary) || {};
  const generatedAt = (payload && payload.generated_at) || '';
  const runId = (payload && payload.run_id) || '';
  const active = tabs.find((t) => t.id === activeId) || tabs[0];

  return (
    <div class="report-root">
      <header class="report-header">
        <h1>RSpec Tracer Report</h1>
        <dl class="summary">
          <div class="summary-item">
            <dt>Total</dt>
            <dd>{summary.total_examples ?? 0}</dd>
          </div>
          <div class="summary-item summary-passed">
            <dt>Passed</dt>
            <dd>{summary.passed_examples ?? 0}</dd>
          </div>
          <div class="summary-item summary-failed">
            <dt>Failed</dt>
            <dd>{summary.failed_examples ?? 0}</dd>
          </div>
          <div class="summary-item summary-pending">
            <dt>Pending</dt>
            <dd>{summary.pending_examples ?? 0}</dd>
          </div>
          <div class="summary-item summary-skipped">
            <dt>Skipped</dt>
            <dd>{summary.skipped_examples ?? 0}</dd>
          </div>
          <div class="summary-item">
            <dt>Flaky</dt>
            <dd>{summary.flaky_examples ?? 0}</dd>
          </div>
        </dl>
        <p class="report-meta">
          <span>
            Run <code>{runId}</code>
          </span>
          <span>Generated {generatedAt}</span>
        </p>
      </header>

      <nav class="tab-bar" role="tablist" aria-label="Report sections">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            type="button"
            role="tab"
            class={`tab-button${tab.id === (active && active.id) ? ' is-active' : ''}`}
            aria-selected={tab.id === (active && active.id)}
            aria-controls={`panel-${tab.id}`}
            id={`tab-${tab.id}`}
            onClick={() => setActiveId(tab.id)}
          >
            {tab.label}
            <span class="tab-count">{tab.count}</span>
          </button>
        ))}
      </nav>

      {active && (
        <section
          class="report-panel"
          role="tabpanel"
          id={`panel-${active.id}`}
          aria-labelledby={`tab-${active.id}`}
        >
          {active.render()}
        </section>
      )}
    </div>
  );
}
