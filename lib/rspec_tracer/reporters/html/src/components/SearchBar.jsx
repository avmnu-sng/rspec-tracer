export function SearchBar({ value, onInput, placeholder, id }) {
  return (
    <div class="search-bar">
      <label class="search-label" htmlFor={id}>
        Filter
      </label>
      <input
        id={id}
        class="search-input"
        type="search"
        value={value}
        placeholder={placeholder || 'Type to filter rows...'}
        autoComplete="off"
        spellCheck={false}
        onInput={(event) => onInput(event.currentTarget.value)}
      />
    </div>
  );
}
