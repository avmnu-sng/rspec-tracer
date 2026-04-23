import { ReportTable } from './ReportTable.jsx';

const STATUS_CLASS = {
  passed: 'status-passed',
  failed: 'status-failed',
  pending: 'status-pending',
  skipped: 'status-skipped',
  flaky: 'status-flaky',
  interrupted: 'status-failed',
};

function statusClass(status) {
  return STATUS_CLASS[status] || 'status-unknown';
}

function durationText(item) {
  const result = item.execution_result || {};
  const value = result.run_time;
  if (typeof value !== 'number') return '';
  if (value < 0.001) return `${(value * 1000000).toFixed(0)} \u00B5s`;
  if (value < 1) return `${(value * 1000).toFixed(1)} ms`;
  return `${value.toFixed(3)} s`;
}

const COLUMNS = [
  {
    key: 'description',
    label: 'Description',
    sortable: true,
    render: (item) => <td class="cell-description">{item.description || ''}</td>,
    searchValue: (item) => `${item.description || ''} ${item.id || ''}`,
  },
  {
    key: 'location',
    label: 'Location',
    sortable: true,
    render: (item) => (
      <td class="cell-location">
        <code>{item.location || ''}</code>
      </td>
    ),
    searchValue: (item) => item.location || '',
  },
  {
    key: 'status',
    label: 'Status',
    sortable: true,
    render: (item) => (
      <td class="cell-status">
        <span class={`badge ${statusClass(item.status)}`}>{item.status || 'unknown'}</span>
      </td>
    ),
    searchValue: (item) => item.status || '',
  },
  {
    key: 'run_reason',
    label: 'Run reason',
    sortable: true,
    render: (item) => <td class="cell-reason">{item.run_reason || ''}</td>,
    searchValue: (item) => item.run_reason || '',
  },
  {
    key: 'duration',
    label: 'Duration',
    sortable: true,
    className: 'is-numeric',
    render: (item) => <td class="cell-duration is-numeric">{durationText(item)}</td>,
    sortValue: (item) => {
      const result = item.execution_result || {};
      return typeof result.run_time === 'number' ? result.run_time : -1;
    },
    searchValue: (item) => durationText(item),
  },
];

export function AllExamples({ items }) {
  return (
    <ReportTable
      id="all-examples"
      caption="All examples"
      columns={COLUMNS}
      items={items}
      emptyMessage="No examples tracked in this run."
    />
  );
}
