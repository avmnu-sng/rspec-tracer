import { useMemo, useState } from 'preact/hooks';
import { SearchBar } from './SearchBar.jsx';

// Shared tabular primitive. Columns are declarative:
//   { key, label, sortable?: bool, className?: string,
//     render: (item) => <td>...</td>, sortValue?: (item) => Comparable,
//     searchValue?: (item) => string }
//
// sortValue defaults to the cell's searchValue; searchValue defaults to
// the string form of item[key]. Sort is ascending by default; clicking
// an already-sorted column toggles descending, clicking again clears.
export function ReportTable({ id, caption, columns, items, emptyMessage }) {
  const [filter, setFilter] = useState('');
  const [sort, setSort] = useState({ key: null, direction: 'asc' });

  const searchableColumns = useMemo(
    () => columns.map((col) => ({ ...col, searchValue: searchFn(col) })),
    [columns]
  );

  const filtered = useMemo(() => {
    if (!filter) return items;
    const needle = filter.toLowerCase();
    return items.filter((item) =>
      searchableColumns.some((col) => {
        const value = col.searchValue(item);
        return value && value.toLowerCase().includes(needle);
      })
    );
  }, [items, filter, searchableColumns]);

  const sorted = useMemo(() => {
    if (!sort.key) return filtered;
    const col = columns.find((c) => c.key === sort.key);
    if (!col) return filtered;
    const extractor = col.sortValue || searchFn(col);
    const direction = sort.direction === 'desc' ? -1 : 1;
    return [...filtered].sort((a, b) => {
      const av = extractor(a);
      const bv = extractor(b);
      if (av === bv) return 0;
      if (av === null || av === undefined) return 1;
      if (bv === null || bv === undefined) return -1;
      return av > bv ? direction : -direction;
    });
  }, [filtered, sort, columns]);

  const handleSort = (key, sortable) => {
    if (!sortable) return;
    if (sort.key !== key) {
      setSort({ key, direction: 'asc' });
    } else if (sort.direction === 'asc') {
      setSort({ key, direction: 'desc' });
    } else {
      setSort({ key: null, direction: 'asc' });
    }
  };

  return (
    <div class="report-table">
      <SearchBar
        id={`${id}-search`}
        value={filter}
        onInput={setFilter}
        placeholder={`Filter ${caption.toLowerCase()}...`}
      />
      <p class="report-table__counts" aria-live="polite">
        Showing {sorted.length} of {items.length}
      </p>
      <table class="data-table" aria-describedby={`${id}-search`}>
        <caption class="visually-hidden">{caption}</caption>
        <thead>
          <tr>
            {columns.map((col) => {
              const isSorted = sort.key === col.key;
              const sortState = isSorted ? sort.direction : 'none';
              return (
                <th
                  key={col.key}
                  scope="col"
                  class={`${col.className || ''} ${col.sortable ? 'is-sortable' : ''}`.trim()}
                  aria-sort={
                    isSorted ? (sort.direction === 'asc' ? 'ascending' : 'descending') : 'none'
                  }
                >
                  {col.sortable ? (
                    <button
                      type="button"
                      class="sort-button"
                      onClick={() => handleSort(col.key, col.sortable)}
                      data-sort={sortState}
                    >
                      {col.label}
                      <span class="sort-indicator" aria-hidden="true">
                        {isSorted ? (sort.direction === 'asc' ? '\u25B2' : '\u25BC') : '\u2195'}
                      </span>
                    </button>
                  ) : (
                    col.label
                  )}
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {sorted.length === 0 && (
            <tr>
              <td class="report-table__empty" colSpan={columns.length}>
                {emptyMessage || 'No rows to display.'}
              </td>
            </tr>
          )}
          {sorted.map((item, index) => (
            <tr key={item.id || item.example_id || item.file_name || index}>
              {columns.map((col) => col.render(item))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function searchFn(col) {
  if (col.searchValue) return col.searchValue;
  return (item) => {
    const value = item[col.key];
    return value === null || value === undefined ? '' : String(value);
  };
}
