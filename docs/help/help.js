(() => {
  const search = document.querySelector('[data-help-search]');
  if (!search) return;

  const items = [...document.querySelectorAll('[data-search-item]')];
  const empty = document.querySelector('[data-search-empty]');

  const normalize = value =>
    value.toLocaleLowerCase('uk-UA').replace(/\s+/g, ' ').trim();

  search.addEventListener('input', () => {
    const query = normalize(search.value);
    let visible = 0;

    for (const item of items) {
      const haystack = normalize(
        `${item.dataset.search || ''} ${item.textContent || ''}`
      );
      const match = !query || haystack.includes(query);
      item.classList.toggle('hidden', !match);
      if (match) visible += 1;
    }

    if (empty) empty.classList.toggle('hidden', visible !== 0);
  });
})();
