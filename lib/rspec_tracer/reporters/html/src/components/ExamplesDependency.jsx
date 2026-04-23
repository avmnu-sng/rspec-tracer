import { ReportTable } from './ReportTable.jsx';

const COLUMNS = [
  {
    key: 'example_id',
    label: 'Example ID',
    sortable: true,
    render: (item) => (
      <td class="cell-id">
        <code>{item.example_id}</code>
      </td>
    ),
  },
  {
    key: 'files_count',
    label: 'Files',
    sortable: true,
    className: 'is-numeric',
    render: (item) => <td class="cell-count is-numeric">{(item.files || []).length}</td>,
    sortValue: (item) => (item.files || []).length,
    searchValue: (item) => String((item.files || []).length),
  },
  {
    key: 'env_keys_count',
    label: 'Env keys',
    sortable: true,
    className: 'is-numeric',
    render: (item) => <td class="cell-count is-numeric">{(item.env_keys || []).length}</td>,
    sortValue: (item) => (item.env_keys || []).length,
    searchValue: (item) => (item.env_keys || []).join(' '),
  },
  {
    key: 'files',
    label: 'Dependencies',
    sortable: false,
    render: (item) => (
      <td class="cell-deps">
        {(item.files || []).length > 0 && (
          <details class="deps-details">
            <summary>{(item.files || []).length} files</summary>
            <ul class="deps-list">
              {(item.files || []).map((file) => (
                <li key={file}>
                  <code>{file}</code>
                </li>
              ))}
            </ul>
          </details>
        )}
        {(item.env_keys || []).length > 0 && (
          <details class="deps-details deps-env">
            <summary>{(item.env_keys || []).length} env keys</summary>
            <ul class="deps-list">
              {(item.env_keys || []).map((key) => (
                <li key={key}>
                  <code>{key}</code>
                </li>
              ))}
            </ul>
          </details>
        )}
      </td>
    ),
    searchValue: (item) => [...(item.files || []), ...(item.env_keys || [])].join(' '),
  },
];

export function ExamplesDependency({ items }) {
  return (
    <ReportTable
      id="examples-dependency"
      caption="Examples dependency"
      columns={COLUMNS}
      items={items}
      emptyMessage="No dependencies tracked."
    />
  );
}
