import {base, yaml, record, noteProperty, updateBaseView} from './obsidian-model.js';
import {el, button, iconButton, field, input, select, dialog, actions} from './obsidian-ui.js';

let currentPath, viewIndex = 0, search = '';
export function baseEditor(ctx) {
  if (currentPath !== ctx.data.path) { currentPath = ctx.data.path; viewIndex = 0; search = ''; }
  const doc = yaml(ctx.data.source);
  viewIndex = Math.min(viewIndex, doc.views.length - 1);
  const result = base(ctx.data.source, ctx.data.files ?? [], ctx.data.path, viewIndex);
  const header = el('header', null, 'document-toolbar base-toolbar'), body = el('div', null, 'base-body');
  const viewSelect = select(doc.views.map((v, i) => [String(i), v.name || 'View ' + (i + 1)]), String(viewIndex));
  viewSelect.className = 'view-select'; viewSelect.setAttribute('aria-label', 'Base view');
  viewSelect.onchange = () => { viewIndex = Number(viewSelect.value); ctx.render(); };
  header.append(viewSelect, iconButton('plus', 'Add view', () => configure(true)), iconButton('settings', 'View options', () => configure(false)));
  ctx.tools(header); ctx.main.append(header);
  const subhead = el('div', null, 'base-subhead'), query = input(search, 'search');
  query.placeholder = 'Search notes'; query.setAttribute('aria-label', 'Search notes'); query.className = 'base-search';
  const count = el('span', '', 'muted'); subhead.append(query, count); ctx.main.append(subhead);
  if (ctx.data.warning) ctx.main.append(el('div', ctx.data.warning, 'warning'));
  if (result.view.summaries && Object.keys(result.view.summaries).length) {
    ctx.main.append(el('div', 'Summary calculations are not supported. The original summary settings are preserved.', 'warning'));
  }
  ctx.main.append(body);
  const displayName = column => result.doc.properties?.[column]?.displayName ?? column.replace(/^(note|file|formula)\./, '');
  const allColumns = new Set(['file.name', ...result.columns, 'file.folder', 'file.ext', 'file.mtime']);
  for (const file of ctx.data.files ?? []) {
    for (const key of Object.keys(record(file).note)) {
      if (![...allColumns].some(column => noteProperty(column) === key)) allColumns.add('note.' + key);
    }
  }
  Object.keys(doc.formulas ?? {}).forEach(key => allColumns.add('formula.' + key));

  function configure(adding) {
    const index = adding ? doc.views.length : viewIndex, current = adding ? {name:'New view', type:'table', order:['file.name']} : result.view;
    dialog(adding ? 'New view' : 'View options', (form, close) => {
      const name = input(current.name || ''), layout = select([['table','Table'],['cards','Cards'],['list','List']], current.type);
      const sort = select([['','None'], ...Array.from(allColumns).map(c => [c, displayName(c)])], current.sort?.[0]?.property || '');
      const direction = select([['ASC','Ascending'],['DESC','Descending']], current.sort?.[0]?.direction || 'ASC');
      const group = select([['','None'], ...Array.from(allColumns).map(c => [c, displayName(c)])], current.groupBy?.property || '');
      const filter = input(typeof current.filters === 'string' ? current.filters : '');
      filter.placeholder = 'e.g. status == "reading"';
      const checks = el('div', null, 'column-options'), boxes = [];
      const columns = [...new Set([...(current.order ?? ['file.name']), ...allColumns])];
      for (const column of columns) {
        const check = input('', 'checkbox'); check.checked = (current.order ?? ['file.name']).includes(column);
        const row = el('label'); row.append(check, el('span', displayName(column)));
        checks.append(row); boxes.push([column, check]);
      }
      const extra = input(); extra.placeholder = 'New property name';
      form.append(field('Name', name), field('Layout', layout), field('Columns', checks), field('Add note property', extra),
        field('Sort by', sort), field('Direction', direction), field('Group by', group));
      if (current.filters && typeof current.filters !== 'string') {
        form.append(el('p', 'This view uses an advanced filter. It will be preserved.', 'muted'));
      } else form.append(field('Filter', filter));
      actions(form, close, () => {
        const order = boxes.filter(([, check]) => check.checked).map(([column]) => column);
        if (extra.value.trim()) {
          const key = noteProperty(extra.value.trim());
          if (!key) throw Error('Enter a note property name.');
          order.push('note.' + key);
        }
        if (!order.length) throw Error('Select at least one column.');
        const patch = {name:name.value.trim() || 'View', type:layout.value, order};
        if (adding || sort.value !== (current.sort?.[0]?.property || '') || direction.value !== (current.sort?.[0]?.direction || 'ASC')) {
          patch.sort = sort.value ? [{property:sort.value, direction:direction.value}] : null;
        }
        if (adding || group.value !== (current.groupBy?.property || '')) patch.groupBy = group.value ? {property:group.value, direction:'ASC'} : null;
        if (!current.filters || typeof current.filters === 'string') patch.filters = filter.value.trim() || null;
        const source = updateBaseView(ctx.data.source, index, patch);
        // Validate against real rows as well; an unknown function must not replace a working view.
        base(source, ctx.data.files ?? [], ctx.data.path, index);
        viewIndex = index; ctx.change(source);
      }, adding ? 'Create view' : 'Apply');
    });
  }
  function valueView(value) {
    const span = el('span', null, 'cell-value');
    if (value && typeof value === 'object' && Object.hasOwn(value, 'link')) span.append(button(value.label ?? value.link, () => ctx.open(value.link), 'file-link'));
    else if (Array.isArray(value)) value.forEach(v => span.append(el('span', String(v), 'tag')));
    else if (value instanceof Date) span.textContent = value.toLocaleDateString();
    else if (typeof value === 'string' && /^\[\[.*\]\]$/.test(value)) {
      const [path, label] = value.slice(2,-2).split('|'); span.append(button(label ?? path, () => ctx.open(path), 'file-link'));
    } else if (typeof value === 'boolean') span.textContent = value ? '✓' : '—';
    else span.textContent = value == null ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value);
    return span;
  }
  function editable(row, column) {
    return !ctx.data.loading && noteProperty(column) && /\.(md|markdown)$/i.test(row.path) &&
      typeof ctx.data.files.find(f => f.path === row.path)?.text === 'string';
  }
  function propertyCell(holder, row, column, value) {
    holder.dataset.column = column; holder.dataset.path = row.path;
    if (column === 'file.name') { holder.append(button(value, () => ctx.open(row.path), 'file-link note-link')); return; }
    const canEdit = editable(row, column);
    if (typeof value === 'boolean') {
      const checkbox = input('', 'checkbox'); checkbox.checked = value; checkbox.disabled = !canEdit || ctx.busy;
      checkbox.setAttribute('aria-label', displayName(column) + ' · ' + row.path);
      checkbox.onchange = async () => {
        checkbox.disabled = true;
        try { await ctx.property(row.path, column, checkbox.checked); }
        catch (e) { checkbox.checked = value; checkbox.disabled = false; ctx.notice(e.message, true); }
      };
      holder.append(checkbox);
    } else holder.append(valueView(value));
    if (canEdit) {
      holder.classList.add('editable-cell'); holder.tabIndex = 0;
      const edit = iconButton('edit', 'Edit ' + displayName(column), () => editCell(holder, row, column, value)); edit.classList.add('cell-edit-trigger');
      holder.append(edit); holder.ondblclick = () => editCell(holder, row, column, value);
      holder.onkeydown = e => { if (e.key === 'Enter' && !e.target.closest('input,select,textarea,button')) { e.preventDefault(); editCell(holder, row, column, value); } };
    }
  }
  function editCell(holder, row, column, value) {
    if (ctx.busy || holder.querySelector('.property-editor')) return;
    const wrapper = el('div', null, 'property-editor');
    const initialKind = typeof value === 'boolean' ? 'boolean' : typeof value === 'number' ? 'number' : Array.isArray(value) ? 'list' : /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') ? 'date' : 'text';
    const kind = select([['text','Text'],['number','Number'],['boolean','Checkbox'],['list','List'],['date','Date']], initialKind);
    kind.setAttribute('aria-label','Property type'); let editor, saving = false;
    const mount = () => {
      editor?.remove();
      editor = kind.value === 'list' ? el('textarea') : input('', kind.value === 'boolean' ? 'checkbox' : kind.value === 'number' ? 'number' : kind.value === 'date' ? 'date' : 'text');
      if (kind.value === 'boolean') editor.checked = !!value;
      else editor.value = Array.isArray(value) ? value.join('\n') : value ?? '';
      editor.setAttribute('aria-label', displayName(column)); editor.dataset.propertyEditor = column;
      wrapper.insertBefore(editor, wrapper.firstChild);
      editor.onkeydown = e => {
        if (e.key === 'Escape') { e.preventDefault(); draw(); }
        else if (e.key === 'Enter' && (kind.value !== 'list' || e.metaKey || e.ctrlKey)) { e.preventDefault(); save(); }
      };
      editor.focus();
    };
    async function save() {
      if (saving) return;
      try {
        let next = editor.value;
        if (kind.value === 'boolean') next = editor.checked;
        else if (!next.trim()) next = null;
        else if (kind.value === 'number') { next = Number(next); if (!Number.isFinite(next)) throw Error('Enter a valid number.'); }
        else if (kind.value === 'list') next = next.split(/\r?\n/).map(v => v.trim()).filter(Boolean);
        saving = true; wrapper.classList.add('saving');
        await ctx.property(row.path, column, next);
      } catch (e) { saving = false; wrapper.classList.remove('saving'); ctx.notice(e.message, true); }
    }
    const controls = el('div', null, 'property-editor-actions');
    controls.append(kind, button('Save', save, 'primary'), iconButton('close','Cancel edit',draw));
    wrapper.append(controls); kind.onchange = mount;
    holder.replaceChildren(wrapper); holder.ondblclick = null; mount();
  }
  function draw() {
    body.replaceChildren();
    const rows = result.rows.filter(row => !search || (row.path + ' ' + row.cells.map(v => JSON.stringify(v) ?? '').join(' ')).toLocaleLowerCase().includes(search.toLocaleLowerCase()));
    count.textContent = rows.length + (rows.length === 1 ? ' file' : ' files') + (ctx.data.loading ? ' · Loading…' : '');
    if (!rows.length) { body.append(el('div', ctx.data.loading ? 'Reading workspace notes…' : 'No files match this view', 'empty')); return; }
    let currentGroup = Symbol(), holder, tbody;
    for (const row of rows) {
      const group = JSON.stringify(row.group);
      if (currentGroup !== group) {
        currentGroup = group;
        if (result.view.groupBy) body.append(el('h3', row.group ?? 'No value', 'group-heading'));
        holder = el('div', null, result.view.type); body.append(holder);
        if (result.view.type === 'table') {
          const table = el('table'), head = el('tr'), thead = el('thead'); tbody = el('tbody');
          for (const column of result.columns) {
            const th = el('th'), active = result.view.sort?.[0]?.property === column;
            const title = button(displayName(column) + (active ? result.view.sort[0].direction === 'DESC' ? ' ↓' : ' ↑' : ''), () => {
              const direction = active && result.view.sort[0].direction !== 'DESC' ? 'DESC' : 'ASC';
              ctx.change(updateBaseView(ctx.data.source, viewIndex, {sort:[{property:column, direction}]}));
            });
            title.title = 'Sort by ' + displayName(column); th.append(title); head.append(th);
          }
          thead.append(head); table.append(thead, tbody); holder.append(table);
        }
      }
      if (result.view.type === 'table') {
        const tr = el('tr'); tr.dataset.path = row.path;
        row.cells.forEach((value, i) => { const td = el('td'); propertyCell(td, row, result.columns[i], value); tr.append(td); });
        tbody.append(tr);
      } else {
        const item = el('article', null, 'base-item'); item.dataset.path = row.path;
        item.append(button(row.path.split('/').pop().replace(/\.(md|markdown)$/i,''), () => ctx.open(row.path), 'file-link card-title'));
        row.cells.forEach((value, i) => {
          const column = result.columns[i]; if (column === 'file.name') return;
          const line = el('div', null, 'property'), cell = el('div', null, 'property-value');
          line.append(el('span', displayName(column), 'property-name'), cell); propertyCell(cell, row, column, value); item.append(line);
        }); holder.append(item);
      }
    }
  }
  query.oninput = () => { search = query.value; draw(); }; draw();
  return {};
}
