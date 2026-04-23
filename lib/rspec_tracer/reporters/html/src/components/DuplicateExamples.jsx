import { ReportTable } from './ReportTable.jsx';

function flatten(items) {
  const rows = [];
  items.forEach((group) => {
    (group.entries || []).forEach((entry, index) => {
      rows.push({
        id: `${group.id}-${index}`,
        groupId: group.id,
        count: group.count,
        description: entry.description || '',
        location: entry.location || '',
      });
    });
  });
  return rows;
}

const COLUMNS = [
  {
    key: 'groupId',
    label: 'Example ID',
    sortable: true,
    render: (item) => (
      <td class="cell-id">
        <code>{item.groupId}</code>
      </td>
    ),
    searchValue: (item) => item.groupId || '',
  },
  {
    key: 'count',
    label: 'Occurrences',
    sortable: true,
    className: 'is-numeric',
    render: (item) => <td class="cell-count is-numeric">{item.count}</td>,
    sortValue: (item) => item.count,
  },
  {
    key: 'description',
    label: 'Description',
    sortable: true,
    render: (item) => <td class="cell-description">{item.description}</td>,
  },
  {
    key: 'location',
    label: 'Location',
    sortable: true,
    render: (item) => (
      <td class="cell-location">
        <code>{item.location}</code>
      </td>
    ),
  },
];

export function DuplicateExamples({ items }) {
  const rows = flatten(items || []);
  return (
    <ReportTable
      id="duplicate-examples"
      caption="Duplicate examples"
      columns={COLUMNS}
      items={rows}
      emptyMessage="No duplicate examples detected."
    />
  );
}
