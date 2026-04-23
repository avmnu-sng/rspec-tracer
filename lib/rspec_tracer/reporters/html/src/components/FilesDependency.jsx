import { ReportTable } from './ReportTable.jsx';

const COLUMNS = [
  {
    key: 'file_name',
    label: 'File',
    sortable: true,
    render: (item) => (
      <td class="cell-file">
        <code>{item.file_name}</code>
      </td>
    ),
  },
  {
    key: 'example_count',
    label: 'Examples',
    sortable: true,
    className: 'is-numeric',
    render: (item) => <td class="cell-count is-numeric">{item.example_count || 0}</td>,
    sortValue: (item) => item.example_count || 0,
  },
  {
    key: 'spec_file_count',
    label: 'Spec files',
    sortable: true,
    className: 'is-numeric',
    render: (item) => (
      <td class="cell-count is-numeric">{Object.keys(item.spec_files || {}).length}</td>
    ),
    sortValue: (item) => Object.keys(item.spec_files || {}).length,
    searchValue: (item) => Object.keys(item.spec_files || {}).join(' '),
  },
  {
    key: 'spec_files',
    label: 'Dependent spec files',
    sortable: false,
    render: (item) => {
      const entries = Object.entries(item.spec_files || {});
      if (entries.length === 0) {
        return <td class="cell-deps" />;
      }
      return (
        <td class="cell-deps">
          <details class="deps-details">
            <summary>{entries.length} spec files</summary>
            <ul class="deps-list">
              {entries.map(([spec, count]) => (
                <li key={spec}>
                  <code>{spec}</code>
                  <span class="dep-count">&times;{count}</span>
                </li>
              ))}
            </ul>
          </details>
        </td>
      );
    },
    searchValue: (item) => Object.keys(item.spec_files || {}).join(' '),
  },
];

export function FilesDependency({ items }) {
  return (
    <ReportTable
      id="files-dependency"
      caption="Files dependency"
      columns={COLUMNS}
      items={items}
      emptyMessage="No file dependencies tracked."
    />
  );
}
