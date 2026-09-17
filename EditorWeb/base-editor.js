import {base, yaml, record, noteProperty, updateBaseView, updateBaseFilters, updateBaseFormula} from './obsidian-model.js';
import {el, button, icon, iconButton, field, input, select, dialog, actions, popover, closePopover} from './obsidian-ui.js';

import {filterEditor} from './base-controls.js';

let currentPath, viewIndex = 0, search = '';
export function baseEditor(ctx) {
  if (currentPath !== ctx.data.path) { currentPath = ctx.data.path; viewIndex = 0; search = ''; }
  let doc = yaml(ctx.data.source);
  const path = ctx.data.path;
  viewIndex = Math.min(viewIndex, doc.views.length - 1);
  let result = {doc, view:doc.views[viewIndex], columns:doc.views[viewIndex].order ?? ['file.name'], rows:[]};
  const header = el('header', null, 'document-toolbar base-toolbar'), body = el('div', null, 'base-body');
  const viewSelect = select(doc.views.map((v, i) => [String(i), v.name || 'View ' + (i + 1)]), String(viewIndex));
  viewSelect.className = 'view-select'; viewSelect.setAttribute('aria-label', 'Base view');
  viewSelect.onchange = () => { closePopover(); viewIndex = Number(viewSelect.value); body.scrollTop=0; renderedRows=0; refresh(); };
  const count = el('span', '', 'base-count muted');
  const sortButton = iconButton('sort', 'Sort', () => sorting(), 'Sort');
  const filterButton = iconButton('filter', 'Filter', () => filtering(), 'Filter');
  const propertiesButton = iconButton('properties', 'Properties', () => properties(), 'Properties');
  for (const control of [sortButton,filterButton,propertiesButton]) control.setAttribute('aria-haspopup','dialog');
  header.append(viewSelect, count, el('span', null, 'toolbar-spacer'), sortButton, filterButton, propertiesButton,
    iconButton('plus', 'New note', () => dialog('New note', (form, close) => {
      const name = input(); name.placeholder = 'Untitled';
      form.append(field('Note name', name), el('p','Created beside this Base. Its properties must match the view’s filters to appear here.','muted'));
      actions(form,close,()=>{
        const value=name.value.trim();
        if (!value || /[\x00-\x1f/\\]/.test(value) || ['.','..'].includes(value)) throw Error('Enter a note name without slashes.');
        ctx.createNote(/\.(md|markdown)$/i.test(value) ? value : value + '.md');
      }, 'Create note');
    }), 'New'));
  ctx.main.append(header);
  const subhead = el('div', null, 'base-subhead'), query = input(search, 'search');
  query.placeholder = 'Search notes'; query.setAttribute('aria-label', 'Search notes'); query.className = 'base-search';
  subhead.append(query, iconButton('plus', 'Add view', () => configure(true)), iconButton('settings', 'View options', () => configure(false)));
  ctx.tools(subhead); ctx.main.append(subhead);
  const warning = el('div', '', 'warning'); warning.hidden = true; ctx.main.append(warning, body);
  const displayName = column => doc.properties?.[column]?.displayName ?? column.replace(/^(note|file|formula)\./, '');
  let fileMap = new Map(), lastSource, lastFiles, lastLoading, lastWarning, pageRows = [], renderedRows = 0, appendRows;
  function columns() {
    const values = new Set(['file.name', ...result.columns, 'file.folder', 'file.ext', 'file.mtime', 'file.ctime', 'file.size']);
    const keys = new Set([...values].map(noteProperty));
    for (const file of ctx.data.files ?? []) {
      try { for (const key of Object.keys(record(file).note)) if (!keys.has(key)) { keys.add(key); values.add('note.' + key); } }
      catch {} // The results display a warning for unreadable frontmatter.
    }
    Object.keys(doc.formulas ?? {}).forEach(key => values.add('formula.' + key));
    return [...values];
  }
  function apply(patch) {
    const source = updateBaseView(ctx.data.source, viewIndex, patch);
    base(source, ctx.data.files ?? [], path, viewIndex); body.scrollTop=0; ctx.change(source);
  }
  function propertyIcon(column) {
    if (column.startsWith('formula.')) return icon('formula');
    if (['file.mtime','file.ctime'].includes(column)) return icon('calendar');
    const index=result.columns.indexOf(column), value=result.rows.find(row=>row.cells[index]!=null)?.cells[index];
    return icon(column==='file.size' || typeof value==='number' ? 'number' : Array.isArray(value) ? 'properties' : 'type');
  }
  function properties() {
    popover(propertiesButton, 'Properties', (form, close) => {
      const query = input('', 'search'); query.placeholder = 'Find or create…'; query.setAttribute('aria-label','Find property');
      const list = el('div', null, 'property-options'), items = [];
      const available = [...new Set([...result.columns, ...columns()])];
      for (const column of available) {
        const check = input('', 'checkbox'); check.checked = result.columns.includes(column);
        const row = el('label', null, 'property-option'); row.append(check, propertyIcon(column), el('span', displayName(column)));
        check.onchange = () => {
          try { apply({order:check.checked ? [...result.columns, column] : result.columns.filter(c => c !== column)}); }
          catch(e) { check.checked = !check.checked; ctx.notice(e.message, true); }
        };
        list.append(row); items.push({row,check,column});
      }
      const add = button('Create property', () => {
        const key = noteProperty(query.value.trim()); if (!key) return;
        const column = 'note.' + key;
        if (!result.columns.some(c => noteProperty(c) === key)) apply({order:[...result.columns,column]});
        close();
      }, 'popover-action'); add.hidden = true;
      query.oninput = () => {
        const term = query.value.toLocaleLowerCase().trim();
        items.forEach(({row,column}) => row.hidden = !displayName(column).toLocaleLowerCase().includes(term));
        add.hidden = !term || !noteProperty(query.value.trim()) || items.some(({column}) => displayName(column).toLocaleLowerCase() === term);
        add.textContent = 'Create “' + query.value.trim() + '”';
      };
      form.append(query,list,add, button('Add formula', () => {
        close(); dialog('Add formula', (form, close) => {
          const name = input(), formula = input(); formula.placeholder = 'e.g. price / pages';
          form.append(field('Name',name),field('Expression',formula));
          actions(form,close,()=>{ const source = updateBaseFormula(ctx.data.source,viewIndex,name.value.trim(),formula.value.trim()); base(source,ctx.data.files ?? [],path,viewIndex); ctx.change(source); });
        });
      }, 'popover-action'), button('Hide all', () => { apply({order:[]}); items.forEach(({check})=>check.checked=false); }, 'popover-action'));
    });
  }
  function sorting() {
    popover(sortButton, 'Sort', (form, close) => {
      const rows = el('div', null, 'sort-rows'), getters = [], available = [...new Set([...columns(), ...(result.view.sort ?? []).map(s=>s.property)])];
      const add = value => {
        const row = el('div', null, 'sort-row');
        const property = select(available.map(c => [c,displayName(c)]), value.property ?? available[0]); property.setAttribute('aria-label','Sort property');
        const direction = select([['ASC','Ascending'],['DESC','Descending']], value.direction ?? 'ASC'); direction.setAttribute('aria-label','Sort direction');
        const get = () => ({property:property.value,direction:direction.value}); getters.push(get);
        row.append(property,direction,iconButton('close','Remove sort',()=>{row.remove();getters.splice(getters.indexOf(get),1);})); rows.append(row);
      };
      (result.view.sort ?? []).forEach(add);
      form.append(el('strong','Sort by'),rows,button('+ Add sort',()=>add({}), 'popover-action'));
      actions(form,close,()=>apply({sort:getters.length ? getters.map(get=>get()) : null}));
    });
  }
  function filtering() {
    popover(filterButton, 'Filter', (form, close) => {
      const scope = select([['view','This view'],['all','All views']], 'view'); scope.setAttribute('aria-label','Filter scope');
      const content = el('div'), available = columns(); let editor, drafts = {view:result.view.filters,all:doc.filters}, previous = 'view';
      const mount = () => { editor = filterEditor(drafts[scope.value],available,displayName); content.replaceChildren(editor.node); };
      scope.onchange = () => { try { drafts[previous] = editor.read(); previous = scope.value; mount(); } catch(e) { scope.value=previous; ctx.notice(e.message,true); } };
      form.append(field('Apply filters to',scope),el('p','All-view filters and this view’s filters both apply.', 'muted'),content);
      mount();
      actions(form,close,()=>{
        drafts[scope.value] = editor.read();
        let source = ctx.data.source;
        for (const target of ['all','view']) source = updateBaseFilters(source,viewIndex,target,drafts[target] ?? null);
        base(source,ctx.data.files ?? [],path,viewIndex); ctx.change(source);
      });
    });
  }

  function configure(adding) {
    const allColumns = columns();
    const index = adding ? doc.views.length : viewIndex, current = adding ? {name:'New view', type:'table', order:['file.name']} : result.view;
    dialog(adding ? 'New view' : 'View options', (form, close) => {
      const name = input(current.name || ''), layout = select([['table','Table'],['cards','Cards'],['list','List']], current.type);
      const sort = select([['','None'], ...Array.from(allColumns).map(c => [c, displayName(c)])], current.sort?.[0]?.property || '');
      const direction = select([['ASC','Ascending'],['DESC','Descending']], current.sort?.[0]?.direction || 'ASC');
      const group = select([['','None'], ...Array.from(allColumns).map(c => [c, displayName(c)])], current.groupBy?.property || '');
      const filter = input(typeof current.filters === 'string' ? current.filters : '');
      filter.placeholder = 'e.g. status == "reading"';
      const checks = el('div', null, 'column-options'), boxes = [];
      const visibleColumns = [...new Set([...(current.order ?? ['file.name']), ...allColumns])];
      for (const column of visibleColumns) {
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
    else if (Array.isArray(value)) value.forEach(v => { const tag=el('span',null,'tag'); tag.append(valueView(v)); span.append(tag); });
    else if (value instanceof Date) span.textContent = value.toLocaleDateString();
    else if (typeof value === 'string' && /^\[\[.*\]\]$/.test(value)) {
      const [path, label] = value.slice(2,-2).split('|'); span.append(button(label ?? path, () => ctx.open(path), 'file-link'));
    } else if (typeof value === 'boolean') span.textContent = value ? '✓' : '—';
    else span.textContent = value == null ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value);
    return span;
  }
  function editable(row, column) {
    return !ctx.data.loading && noteProperty(column) && /\.(md|markdown)$/i.test(row.path) &&
      typeof fileMap.get(row.path)?.text === 'string';
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
    const visibleCount=Math.max(100,renderedRows), scrollTop=body.scrollTop;
    body.replaceChildren();
    pageRows = []; renderedRows = 0; appendRows = null;
    const rows = result.rows.filter(row => !search || (row.path + ' ' + row.cells.map(v => JSON.stringify(v) ?? '').join(' ')).toLocaleLowerCase().includes(search.toLocaleLowerCase()));
    count.textContent = rows.length + (rows.length === 1 ? ' result' : ' results') + (ctx.data.loading ? ' · Loading…' : '');
    if (!rows.length) { body.append(el('div', ctx.data.loading ? 'Reading workspace notes…' : 'No files match this view', 'empty')); return; }
    let currentGroup = Symbol(), holder, tbody;
    pageRows = rows; renderedRows = 0;
    const more = button('Load more results', () => appendRows(), 'load-more');
    appendRows = (batchSize = 100) => {
    more.remove();
    for (const row of pageRows.slice(renderedRows, renderedRows + batchSize)) {
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
            title.title = 'Sort by ' + displayName(column); title.prepend(propertyIcon(column)); th.append(title); head.append(th);
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
    renderedRows += batchSize;
    if (renderedRows < pageRows.length) body.append(more);
    };
    appendRows(visibleCount); body.scrollTop=scrollTop;
  }
  function refresh() {
    const files = ctx.data.files ?? [];
    doc = yaml(ctx.data.source); viewIndex = Math.min(viewIndex, doc.views.length - 1);
    const options = doc.views.map((v,i) => [String(i),v.name || 'View ' + (i + 1)]);
    if (JSON.stringify(options) !== viewSelect.dataset.options) {
      viewSelect.replaceChildren(...options.map(([value,name]) => { const node=el('option',name); node.value=value; return node; }));
      viewSelect.dataset.options = JSON.stringify(options);
    }
    if (viewSelect.value !== String(viewIndex)) viewSelect.value = String(viewIndex);
    lastSource=ctx.data.source; lastFiles=files; lastLoading=ctx.data.loading; lastWarning=ctx.data.warning;
    fileMap = new Map(files.map(file => [file.path,file]));
    result = {doc, view:doc.views[viewIndex], columns:doc.views[viewIndex].order ?? ['file.name'], rows:[]};
    try {
      result = base(ctx.data.source, files, path, viewIndex);
      const warnings = [ctx.data.warning, ...(result.warnings ?? [])];
      if (result.view.summaries && Object.keys(result.view.summaries).length) warnings.push('Summary calculations are not supported. Original settings are preserved.');
      warning.textContent = warnings.filter(Boolean).join(' '); warning.hidden = !warning.textContent;
      filterButton.classList.toggle('active', !!(doc.filters || result.view.filters));
      sortButton.classList.toggle('active', !!result.view.sort?.length);
      draw();
    } catch(e) {
      pageRows=[]; renderedRows=0; appendRows=null; count.textContent='Unable to load results';
      warning.textContent=e.message; warning.hidden=false;
      body.replaceChildren(el('div','This view could not be evaluated. Adjust its filters or options.','empty'));
    }
  }
  body.addEventListener('scroll', () => {
    if (renderedRows < pageRows.length && body.scrollHeight - body.scrollTop - body.clientHeight < 240) appendRows?.();
  });
  query.oninput = () => { search = query.value; body.scrollTop=0; renderedRows=0; draw(); }; refresh();
  return {
    update() {
      if (ctx.data.kind !== 'base' || ctx.data.path !== path) return false;
      const files=ctx.data.files ?? [], sameFiles=files.length === lastFiles.length && files.every((f,i)=>f===lastFiles[i]);
      if (lastSource !== ctx.data.source || !sameFiles || lastLoading !== ctx.data.loading || lastWarning !== ctx.data.warning) refresh();
      return true;
    },
    destroy() { closePopover(); }
  };
}
