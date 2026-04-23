import { ReportTable } from './ReportTable.jsx';

const COLUMNS = [
  {
    key: 'id',
    label: 'Example ID',
    sortable: true,
    render: (item) => (
      <td class="cell-id">
        <code>{item.id}</code>
      </td>
    ),
  },
  {
    key: 'description',
    label: 'Description',
    sortable: true,
    render: (item) => <td class="cell-description">{item.description || ''}</td>,
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
  },
];

export function FlakyExamples({ items }) {
  return (
    <ReportTable
      id="flaky-examples"
      caption="Flaky examples"
      columns={COLUMNS}
      items={items}
      emptyMessage="No flaky examples detected."
    />
  );
}
