import {base, yaml, noteProperty, updateBaseView, updateBaseFilters, updateBaseFormula, removeBaseFormula, updateBaseProperty, updateBaseSummaryFormula,
  removeBaseView, moveBaseView, duplicateBaseView, propertyConfig, propertyTypes, columnType, columnValue, builtInLayouts, expression, evaluate} from './obsidian-model.js';
import {el, button, icon, iconButton, field, input, select, dialog, actions, popover, closePopover, menu, closeMenus, toggle, slider} from './obsidian-ui.js';
import {display, isEmptyValue, summaryOptions, CellError, defaultSummaries} from './bases-engine.js';
import {filterEditor, simpleRule} from './base-controls.js';
import {tableLayout} from './base-table.js';
import {cardsLayout, listLayout, kanbanLayout} from './base-layouts.js';
import {renderValue, editableText, rawValue} from './base-cells.js';

const states = new Map();
const layoutIcons = {table:'table', cards:'cards', list:'list', kanban:'kanban', map:'map'};
const layoutNames = {table:'Table', cards:'Cards', list:'List', kanban:'Kanban'};
const fileColumns = ['file.name', 'file.basename', 'file.path', 'file.folder', 'file.ext', 'file.size', 'file.ctime', 'file.mtime', 'file.tags', 'file.links', 'file.embeds', 'file.backlinks'];
const fileNames = {'file.name':'file name', 'file.basename':'file base name', 'file.path':'file path', 'file.folder':'folder', 'file.ext':'extension',
  'file.size':'size', 'file.ctime':'created time', 'file.mtime':'modified time', 'file.tags':'tags', 'file.links':'links', 'file.embeds':'embeds', 'file.backlinks':'backlinks'};
const functionNames = ['if','date','duration','now','today','number','list','link','file','image','icon','html','escapeHTML','max','min','random',
  'contains','containsAll','containsAny','startsWith','endsWith','isEmpty','lower','upper','title','trim','replace','repeat','reverse','slice','split','length',
  'abs','ceil','floor','round','toFixed','filter','map','reduce','flat','join','sort','unique','format','time','relative','asLink','asFile','hasTag','hasLink',
  'inFolder','hasProperty','linksTo','isTruthy','isType','toString','keys','values','matches','year','month','day','hour','minute','second'];

export function baseEditor(ctx) {
  const path = ctx.data.path;
  const state = states.get(path) ?? {viewIndex:ctx.data.selectedView ?? 0, search:'', selection:null, scroll:{}};
  states.set(path, state);
  let doc = yaml(ctx.data.source), result = null, types = {}, deferred = false;
  const header = el('header', null, 'document-toolbar base-toolbar');
  const viewButton = button(null, () => viewMenu(), 'view-button'), resultsButton = button(null, () => resultsMenu(), 'results-button');
  const sortButton = iconButton('sort', 'Sort', () => sortMenu()), filterButton = iconButton('filter', 'Filter', () => filterMenu());
  const propertiesButton = iconButton('properties', 'Properties', () => propertiesMenu());
  const searchField = input(state.search, 'search'); searchField.placeholder = 'Search'; searchField.className = 'base-search'; searchField.setAttribute('aria-label', 'Search results');
  const searchButton = iconButton('search', 'Search', () => { searchField.hidden = false; searchField.focus(); });
  searchField.hidden = !state.search;
  const newButton = iconButton('plus', 'New note', () => newNote(), 'New');
  for (const b of [viewButton, resultsButton, sortButton, filterButton, propertiesButton]) b.setAttribute('aria-haspopup', 'dialog');
  const cloudHint = el('span', '', 'base-cloud-hint muted'); cloudHint.hidden = true;
  header.append(viewButton, resultsButton, cloudHint, el('span', null, 'toolbar-spacer'), sortButton, filterButton, propertiesButton, searchField, searchButton, newButton);
  ctx.tools(header);
  const warning = el('div', '', 'warning'); warning.hidden = true;
  const body = el('div', null, 'base-body');
  ctx.main.append(header, warning, body);
  viewButton.oncontextmenu = e => { e.preventDefault(); viewSettings(viewButton, state.viewIndex); };

  const view = () => doc.views[state.viewIndex];
  const displayName = column => {
    const configured = propertyConfig(doc, column)?.displayName;
    if (configured != null && configured !== '') return String(configured);
    return fileNames[column] ?? column.replace(/^(note|formula)\./, '');
  };
  const B = {
    ctx, state, get view() { return view(); }, get result() { return result; }, get doc() { return doc; },
    displayName, columnType:column => column.startsWith('formula.') ? formulaType(column) : columnType(column, types),
    resolve:(target, from) => result?.context.shared.resolve(target, from) ?? null,
    open:target => ctx.open(target), openWiki:target => ctx.openWiki(target),
    asset:(target, holder) => ctx.asset(target, holder),
    notice:ctx.notice,
    editable:(row, column) => !!row && !ctx.data.loading && !!noteProperty(column) && /\.(md|markdown)$/i.test(row.path) && typeof row.record?.source?.text === 'string',
    write:(row, column, value) => ctx.property(row.path, column, value).catch(e => { ctx.notice(e.message, true); throw e; }),
    writeMany:async writes => {
      let failed = 0;
      for (const w of writes) { try { await ctx.property(w.row.path, w.column, w.value); } catch (e) { failed++; if (failed === 1) ctx.notice(e.message, true); } }
      if (failed > 1) ctx.notice(failed + ' cells could not be changed.', true);
    },
    apply, headerMenu, summaryMenu, newNote, rowMenu, columnMenu, groupMenu, renameNote, propertyIcon,
    redraw:() => draw(true), flush:() => { if (deferred) { deferred = false; refresh(); } }
  };
  function formulaType(column) {
    const index = result?.columns.indexOf(column) ?? -1, sample = index >= 0 ? result.rows.find(r => !isEmptyValue(r.cells[index]))?.cells[index] : null;
    return typeof sample === 'number' ? 'number' : sample instanceof Date ? 'datetime' : typeof sample === 'boolean' ? 'checkbox' : Array.isArray(sample) ? 'multitext' : 'formula';
  }
  function propertyIcon(column) {
    const type = B.columnType(column);
    const name = column === 'file.name' || column === 'file.basename' ? 'file' : column.startsWith('formula.') ? 'formula' :
      ({number:'number', checkbox:'checkbox', date:'calendar', datetime:'calendar', multitext:'list', tags:'hash', aliases:'link2', formula:'formula'})[type] ?? 'text';
    return icon(name);
  }
  function allColumns() {
    const values = new Set([...(result?.columns ?? []), ...fileColumns]);
    const keys = new Set(Object.keys(types));
    for (const r of result?.context.records ?? []) for (const key of Object.keys(r.raw)) keys.add(key);
    for (const key of [...keys].sort((a, b) => a.localeCompare(b))) if (![...values].some(c => noteProperty(c) === key)) values.add('note.' + key);
    for (const key of Object.keys(doc.formulas ?? {})) values.add('formula.' + key);
    return [...values];
  }
  function change(source) { closeMenus(); ctx.change(source); }
  function apply(patch, index = state.viewIndex) {
    try { change(updateBaseView(ctx.data.source, index, patch)); } catch (e) { ctx.notice(e.message, true); }
  }
  function selectView(index) { state.viewIndex = index; state.selection = null; state.renderedRows = 0; body.scrollTop = 0; ctx.selectView(index); closePopover(); refresh(); }

  // ---------------------------------------------------------------- views
  function viewMenu() {
    popover(viewButton, 'Views', (form, close) => {
      const list = el('div', null, 'view-list');
      doc.views.forEach((v, i) => {
        const row = el('div', null, 'view-row' + (i === state.viewIndex ? ' active' : '')); row.dataset.index = String(i);
        const grip = el('span', null, 'grip'); grip.append(icon('grip')); grip.title = 'Drag to reorder';
        const name = button(null, () => { close(); selectView(i); }, 'view-name');
        name.append(icon(layoutIcons[v.type] ?? 'layers'), el('span', v.name || layoutNames[v.type] || 'View'));
        const settings = iconButton('chevronRight', 'View settings', () => { close(); viewSettings(viewButton, i); });
        row.append(grip, name, settings); list.append(row);
        row.oncontextmenu = e => { e.preventDefault(); menu({x:e.clientX, y:e.clientY}, [
          {label:'View settings', icon:'settings', action:() => { close(); viewSettings(viewButton, i); }},
          {label:'Duplicate view', icon:'duplicate', action:() => change(duplicateBaseView(ctx.data.source, i))},
          {label:'Delete view', icon:'trash', danger:true, disabled:doc.views.length < 2, action:() => deleteView(i)}]); };
        grip.onpointerdown = e => {
          e.preventDefault(); row.classList.add('dragging'); let target = i;
          const move = m => { const rows = [...list.children]; target = rows.findIndex(r => m.clientY < r.getBoundingClientRect().top + r.offsetHeight / 2); if (target < 0) target = rows.length - 1; list.insertBefore(row, rows[target] === row ? row.nextSibling : rows[target] ?? null); };
          const up = () => {
            removeEventListener('pointermove', move); removeEventListener('pointerup', up); row.classList.remove('dragging');
            const to = [...list.children].indexOf(row);
            if (to !== i) { const current = doc.views[state.viewIndex]; const source = moveBaseView(ctx.data.source, i, to); state.viewIndex = yaml(source).views.indexOf(yaml(source).views.find(x => x.name === current.name && x.type === current.type)) ?? to; change(source); close(); }
          };
          addEventListener('pointermove', move); addEventListener('pointerup', up);
        };
      });
      form.append(list, button('+ Add view', () => {
        const names = new Set(doc.views.map(v => v.name)); let name = 'Table', n = 2; while (names.has(name)) name = 'Table ' + n++;
        const index = doc.views.length;
        try { change(updateBaseView(ctx.data.source, index, {type:'table', name, order:view()?.order ?? ['file.name']})); selectView(index); close(); viewSettings(viewButton, index); }
        catch (e) { ctx.notice(e.message, true); }
      }, 'popover-action'));
    });
  }
  function deleteView(index) {
    try { const source = removeBaseView(ctx.data.source, index); if (state.viewIndex >= index && state.viewIndex > 0) state.viewIndex--; change(source); ctx.selectView(state.viewIndex); }
    catch (e) { ctx.notice(e.message, true); }
  }
  function viewSettings(anchor, index) {
    popover(anchor, 'View settings', (form, close) => {
      const v = () => doc.views[index] ?? {};
      const set = patch => apply(patch, index);
      const name = input(v().name ?? ''); name.onchange = () => set({name:name.value.trim() || layoutNames[v().type] || 'View'});
      const layouts = [...builtInLayouts.map(t => [t, layoutNames[t]]), ...(!builtInLayouts.includes(v().type) && v().type ? [[v().type, v().type + ' (plugin)']] : [])];
      const layout = select(layouts, v().type ?? 'table'); layout.onchange = () => { set({type:layout.value}); close(); viewSettings(anchor, index); };
      form.append(el('strong', 'View settings'), field('Name', name), field('Layout', layout));
      const imageOptions = [['', 'None'], ...allColumns().filter(c => !c.startsWith('file.') || c === 'file.name').map(c => [c, displayName(c)])];
      const type = v().type ?? 'table';
      if (type === 'table') {
        const rowHeight = select([['', 'Default'], ['short', 'Short'], ['medium', 'Medium'], ['tall', 'Tall'], ['extra tall', 'Extra tall']], v().rowHeight ?? '');
        rowHeight.onchange = () => set({rowHeight:rowHeight.value || null}); form.append(field('Row height', rowHeight));
      }
      if (type === 'cards' || type === 'kanban') {
        if (type === 'cards') {
          const size = slider(v().cardSize ?? 200, 100, 600, 10, (value, final) => { if (final) set({cardSize:value}); }, 'Card size');
          form.append(field('Card size', size));
        } else {
          const width = slider(v().columnWidth ?? 280, 180, 520, 10, (value, final) => { if (final) set({columnWidth:value}); }, 'Column width');
          form.append(field('Column width', width), labeledToggle('Hide empty columns', v().hideEmptyColumns === true, value => set({hideEmptyColumns:value || null})));
        }
        const image = select(imageOptions, v().image ?? ''); image.onchange = () => set({image:image.value || null});
        const fit = select([['cover', 'Cover'], ['contain', 'Contain']], v().imageFit ?? 'cover'); fit.onchange = () => set({imageFit:fit.value === 'cover' ? null : fit.value});
        const ratio = slider(v().imageAspectRatio ?? 1, 0.25, 2.5, 0.05, (value, final) => { if (final) set({imageAspectRatio:value === 1 ? null : value}); }, 'Image aspect ratio');
        form.append(field('Image property', image), field('Image fit', fit), field('Image aspect ratio', ratio));
      }
      if (type === 'list') {
        const markers = select([['bullets', 'Bullets'], ['numbers', 'Numbers'], ['none', 'None']], v().markers ?? 'bullets');
        markers.onchange = () => set({markers:markers.value === 'bullets' ? null : markers.value});
        const separator = input(v().separator ?? ', '); separator.onchange = () => set({separator:separator.value === ', ' ? null : separator.value});
        form.append(field('Markers', markers), labeledToggle('Indent properties', v().indentProperties === true, value => set({indentProperties:value || null})), field('Separator', separator));
      }
      const limit = input(v().limit ?? '', 'number'); limit.min = '1'; limit.placeholder = 'No limit';
      limit.onchange = () => set({limit:Number(limit.value) > 0 ? Math.floor(Number(limit.value)) : null});
      form.append(field('Limit results', limit));
      const actions = el('div', null, 'popover-actions');
      actions.append(button('Duplicate view', () => { close(); change(duplicateBaseView(ctx.data.source, index)); selectView(index + 1); }, 'popover-action'),
        button('Delete view', () => { close(); deleteView(index); }, 'popover-action danger'));
      if (doc.views.length < 2) actions.lastChild.disabled = true;
      form.append(actions);
    }, {wide:true});
  }
  function labeledToggle(label, value, onchange) {
    const row = el('label', null, 'toggle-row'); row.append(el('span', label), toggle(value, onchange, label)); return row;
  }

  // ---------------------------------------------------------------- sort & group
  const directionLabels = column => {
    const type = B.columnType(column);
    return type === 'number' ? [['ASC', '0 → 1'], ['DESC', '1 → 0']] : type === 'date' || type === 'datetime' ? [['ASC', 'Old → New'], ['DESC', 'New → Old']] : [['ASC', 'A → Z'], ['DESC', 'Z → A']];
  };
  function sortMenu() {
    popover(sortButton, 'Sort', (form) => {
      const draw = () => {
        form.replaceChildren();
        const v = view(), sorts = [...(v.sort ?? [])], columns = allColumns();
        form.append(el('strong', 'Sort by'));
        const list = el('div', null, 'sort-rows');
        sorts.forEach((sort, i) => {
          const row = el('div', null, 'sort-row');
          const grip = el('span', null, 'grip'); grip.append(icon('grip'));
          const property = select(columns.map(c => [c, displayName(c)]), sort.property); property.setAttribute('aria-label', 'Sort property');
          const direction = select(directionLabels(sort.property), String(sort.direction).toUpperCase() === 'DESC' ? 'DESC' : 'ASC'); direction.setAttribute('aria-label', 'Sort direction');
          const commit = next => { apply({sort:next.length ? next : null}); queueMicrotask(draw); };
          property.onchange = () => { sorts[i] = {...sort, property:property.value}; commit(sorts); };
          direction.onchange = () => { sorts[i] = {...sort, direction:direction.value}; commit(sorts); };
          row.append(grip, property, direction, iconButton('trash', 'Remove sort', () => { sorts.splice(i, 1); commit(sorts); }));
          grip.onpointerdown = e => {
            e.preventDefault(); row.classList.add('dragging');
            const move = m => { const rows = [...list.children]; const over = rows.find(r => m.clientY < r.getBoundingClientRect().top + r.offsetHeight / 2); list.insertBefore(row, over === row ? row.nextSibling : over ?? null); };
            const up = () => { removeEventListener('pointermove', move); removeEventListener('pointerup', up); row.classList.remove('dragging');
              const to = [...list.children].indexOf(row); if (to !== i) { const [item] = sorts.splice(i, 1); sorts.splice(to, 0, item); commit(sorts); } };
            addEventListener('pointermove', move); addEventListener('pointerup', up);
          };
          list.append(row);
        });
        const add = button('+ Add sort', e => menu(e.currentTarget, columns.filter(c => !sorts.some(s => s.property === c)).map(c => ({label:displayName(c), action:() => { apply({sort:[...sorts, {property:c, direction:'ASC'}]}); queueMicrotask(draw); }}))), 'popover-action');
        form.append(list, add, el('strong', 'Group by'));
        const group = v.groupBy ?? null, groupRow = el('div', null, 'sort-row');
        const groupProperty = select([['', 'None'], ...columns.map(c => [c, displayName(c)])], group?.property ?? ''); groupProperty.setAttribute('aria-label', 'Group property');
        groupProperty.onchange = () => { apply({groupBy:groupProperty.value ? {property:groupProperty.value, direction:group?.direction ?? 'ASC'} : null}); queueMicrotask(draw); };
        groupRow.append(groupProperty);
        if (group?.property) {
          const groupDirection = select(directionLabels(group.property), String(group.direction).toUpperCase() === 'DESC' ? 'DESC' : 'ASC');
          groupDirection.setAttribute('aria-label', 'Group direction');
          groupDirection.onchange = () => { apply({groupBy:{...group, direction:groupDirection.value}}); queueMicrotask(draw); };
          groupRow.append(groupDirection, iconButton('trash', 'Remove group', () => { apply({groupBy:null}); queueMicrotask(draw); }));
        }
        form.append(groupRow);
      };
      draw();
    }, {wide:true});
  }
  function groupMenu(anchor) {
    menu(anchor, allColumns().map(c => ({label:displayName(c), icon:null, action:() => apply({groupBy:{property:c, direction:'ASC'}})})));
  }

  // ---------------------------------------------------------------- filters
  function filterMenu() {
    popover(filterButton, 'Filter', (form) => {
      const columns = allColumns(); let timer;
      const section = (title, scope, rule) => {
        const box = el('section', null, 'filter-section'), editor = filterEditor(rule, columns, displayName, types, () => {
          clearTimeout(timer);
          timer = setTimeout(() => {
            try {
              const next = editor.read(); const source = updateBaseFilters(ctx.data.source, state.viewIndex, scope, next);
              if (source !== ctx.data.source) ctx.change(source);
            } catch {}
          }, 350);
        });
        box.append(el('strong', title), editor.node); return box;
      };
      form.append(section('All views', 'all', doc.filters), section('This view', 'view', view().filters));
    }, {wide:true});
  }

  // ---------------------------------------------------------------- properties
  function propertiesMenu() {
    popover(propertiesButton, 'Properties', (form, close) => {
      const query = input('', 'search'); query.placeholder = 'Search properties'; query.setAttribute('aria-label', 'Search properties');
      const list = el('div', null, 'property-options');
      const create = button('', () => {
        const key = noteProperty(query.value.trim()); if (!key) return;
        const column = allColumns().find(c => noteProperty(c) === key) ?? key;
        if (!result.columns.includes(column)) apply({order:[...result.columns, column]});
        query.value = ''; queueMicrotask(draw);
      }, 'popover-action');
      const draw = () => {
        list.replaceChildren();
        const term = query.value.trim().toLocaleLowerCase(), visible = result.columns, others = allColumns().filter(c => !visible.includes(c));
        const match = c => !term || displayName(c).toLocaleLowerCase().includes(term) || c.toLocaleLowerCase().includes(term);
        const row = (column, shown) => {
          const item = el('div', null, 'property-option'); item.dataset.column = column;
          const check = input('', 'checkbox'); check.checked = shown; check.setAttribute('aria-label', 'Show ' + displayName(column));
          check.onchange = () => { apply({order:check.checked ? [...visible, column] : visible.filter(c => c !== column)}); queueMicrotask(draw); };
          const grip = el('span', null, 'grip'); if (shown && !term) grip.append(icon('grip'));
          item.append(grip, check, propertyIcon(column), el('span', displayName(column), 'property-option-name'));
          if (column.startsWith('formula.')) item.append(iconButton('pencil', 'Edit formula', () => { close(); formulaEditor(column.slice(8)); }));
          if (shown && !term) grip.onpointerdown = e => {
            e.preventDefault(); item.classList.add('dragging');
            const move = m => { const rows = [...list.querySelectorAll('.property-option.shown')]; const over = rows.find(r => m.clientY < r.getBoundingClientRect().top + r.offsetHeight / 2); list.insertBefore(item, over === item ? item.nextSibling : over ?? rows.at(-1)?.nextSibling ?? null); };
            const up = () => { removeEventListener('pointermove', move); removeEventListener('pointerup', up); item.classList.remove('dragging');
              const order = [...list.querySelectorAll('.property-option.shown')].map(r => r.dataset.column); if (order.join('\0') !== visible.join('\0')) { apply({order}); queueMicrotask(draw); } };
            addEventListener('pointermove', move); addEventListener('pointerup', up);
          };
          if (shown) item.classList.add('shown');
          list.append(item);
        };
        visible.filter(match).forEach(c => row(c, true));
        const rest = others.filter(match);
        if (rest.length && visible.some(match)) list.append(el('div', null, 'menu-separator'));
        rest.forEach(c => row(c, false));
        const key = noteProperty(query.value.trim());
        create.hidden = !term || !key || allColumns().some(c => displayName(c).toLocaleLowerCase() === term);
        create.textContent = 'Add property “' + query.value.trim() + '”';
      };
      query.oninput = draw;
      form.append(query, list, create, button('+ Add formula', () => { close(); formulaEditor(null); }, 'popover-action'),
        button('Hide all properties', () => { apply({order:['file.name']}); queueMicrotask(draw); }, 'popover-action'));
      draw();
    }, {wide:true});
  }
  function formulaEditor(name) {
    const existing = name != null ? String(doc.formulas?.[name] ?? '') : '';
    dialog(name != null ? 'Edit formula' : 'Add formula', (form, close) => {
      const nameField = input(name ?? ''); nameField.placeholder = 'Formula name';
      const area = el('textarea', null, 'formula-input'); area.value = existing; area.rows = 4; area.spellcheck = false;
      area.placeholder = 'e.g. if(price, (price / pages).toFixed(2), "")'; area.setAttribute('aria-label', 'Formula');
      const suggestions = el('div', null, 'formula-suggestions'), preview = el('div', null, 'formula-preview');
      const properties = allColumns().filter(c => !c.startsWith('formula.' + name));
      const words = [...new Set([...functionNames, ...properties.map(c => c.startsWith('note.') ? c.slice(5) : c), 'file', 'note', 'formula', 'this', 'values'])];
      let options = [], active = 0;
      const token = () => { const before = area.value.slice(0, area.selectionStart); const m = before.match(/[\p{L}\p{N}_.$-]*$/u); return m ? m[0] : ''; };
      const suggest = () => {
        const t = token(), last = t.split('.').pop();
        options = last.length ? words.filter(w => w.toLowerCase().startsWith(last.toLowerCase()) && w !== last).slice(0, 8) : [];
        active = 0; suggestions.replaceChildren(...options.map((o, i) => { const b = button(o, () => pick(i), 'suggestion' + (i === active ? ' active' : '')); b.tabIndex = -1; b.onpointerdown = e => e.preventDefault(); return b; }));
        suggestions.hidden = !options.length;
      };
      const pick = i => {
        const t = token(), last = t.split('.').pop(), word = options[i]; if (!word) return;
        const start = area.selectionStart - last.length, fn = functionNames.includes(word) && !properties.includes(word);
        area.setRangeText(word + (fn ? '()' : ''), start, area.selectionStart, 'end'); if (fn) area.selectionStart = area.selectionEnd = area.selectionEnd - 1;
        suggestions.hidden = true; area.focus(); update();
      };
      const update = () => {
        preview.replaceChildren();
        const source = area.value.trim(); if (!source) return;
        try {
          const tree = expression(source), rows = result?.rows.slice(0, 3) ?? [];
          for (const row of rows) {
            let value; try { value = evaluate(tree, {...row.ctx, formulas:{...row.ctx.formulas, [nameField.value.trim() || '__draft']:source}, memo:new Map()}); } catch (e) { value = new CellError(e.message); }
            const line = el('div', null, 'formula-sample'); line.append(el('span', row.file.basename, 'muted'), value instanceof CellError ? el('span', value.error, 'error') : renderValue(value, B, {from:row.path})); preview.append(line);
          }
        } catch (e) { preview.append(el('div', e.message, 'error')); }
      };
      area.oninput = () => { suggest(); update(); };
      area.onkeydown = e => {
        if (suggestions.hidden || !options.length) return;
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); active = (active + (e.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length; [...suggestions.children].forEach((b, i) => b.classList.toggle('active', i === active)); }
        else if (e.key === 'Tab' || e.key === 'Enter') { e.preventDefault(); pick(active); }
        else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); suggestions.hidden = true; }
      };
      suggestions.hidden = true;
      form.classList.add('formula-form');
      form.append(field('Name', nameField), field('Formula', area), suggestions, el('span', 'Preview', 'field-label'), preview);
      if (name != null) {
        const remove = button('Delete formula', () => { close(); change(removeBaseFormula(ctx.data.source, name)); }, 'danger-link'); form.append(remove);
      }
      actions(form, close, () => {
        const next = nameField.value.trim(), value = area.value.trim();
        if (!value) throw Error('Enter a formula.');
        change(updateBaseFormula(ctx.data.source, name != null ? null : state.viewIndex, next, value, name));
      }, 'Save');
      update(); requestAnimationFrame(() => (name != null ? area : nameField).focus());
    }).classList.add('wide');
  }

  // ---------------------------------------------------------------- column / row menus
  function headerMenu(column, at) {
    const v = view(), labels = directionLabels(column), formula = column.startsWith('formula.');
    const index = result.columns.indexOf(column);
    menu(at, [
      {label:'Sort ' + labels[0][1], icon:'arrowUp', action:() => apply({sort:[{property:column, direction:'ASC'}, ...(v.sort ?? []).filter(s => s.property !== column)]})},
      {label:'Sort ' + labels[1][1], icon:'arrowDown', action:() => apply({sort:[{property:column, direction:'DESC'}, ...(v.sort ?? []).filter(s => s.property !== column)]})},
      {label:'Group by', icon:'layers', checked:v.groupBy?.property === column, action:() => apply({groupBy:v.groupBy?.property === column ? null : {property:column, direction:'ASC'}})},
      {label:'Summarize…', icon:'calculator', submenu:summaryItems(column)},
      'separator',
      {label:'Rename', icon:'pencil', action:() => renameColumn(column)},
      formula ? {label:'Edit formula', icon:'formula', action:() => formulaEditor(column.slice(8))} : null,
      {label:'Move left', icon:'arrowLeft', disabled:index <= 0, action:() => move(-1)},
      {label:'Move right', icon:'arrowRight', disabled:index < 0 || index >= result.columns.length - 1, action:() => move(1)},
      {label:'Hide', icon:'eyeOff', action:() => apply({order:result.columns.filter(c => c !== column)})},
      formula ? {label:'Delete formula', icon:'trash', danger:true, action:() => change(removeBaseFormula(ctx.data.source, column.slice(8)))} : null
    ]);
    function move(delta) { const order = [...result.columns]; order.splice(index, 1); order.splice(index + delta, 0, column); apply({order}); }
  }
  function summaryItems(column) {
    const index = result.columns.indexOf(column), values = index >= 0 ? result.rows.map(r => r.cells[index]) : [];
    const current = view().summaries?.[column], custom = Object.keys(doc.summaries ?? {});
    const set = name => { const summaries = {...(view().summaries ?? {})}; if (name) summaries[column] = name; else delete summaries[column]; apply({summaries:Object.keys(summaries).length ? summaries : null}); };
    return [
      {label:'None', checked:!current, action:() => set(null)},
      ...summaryOptions(values).map(name => ({label:name, checked:current === name, action:() => set(name)})),
      ...(custom.length ? ['separator', ...custom.map(name => ({label:name, checked:current === name, action:() => set(name)}))] : []),
      'separator',
      {label:'Add summary…', icon:'formula', action:() => dialog('Add summary', (form, close) => {
        const name = input(), formula = el('textarea'); formula.rows = 3; formula.placeholder = 'values.filter(value > 0).length'; formula.spellcheck = false;
        form.append(field('Name', name), field('Formula', formula), el('p', 'values is the list of this column’s values in the current results.', 'muted'));
        actions(form, close, () => {
          const n = name.value.trim(); if (defaultSummaries.includes(n)) throw Error('Choose a name that is not a built-in summary.');
          const source = updateBaseSummaryFormula(ctx.data.source, n, formula.value.trim());
          const summaries = {...(view().summaries ?? {}), [column]:n};
          change(updateBaseView(source, state.viewIndex, {summaries}));
        }, 'Add');
      })}
    ];
  }
  function summaryMenu(column, anchor) { menu(anchor, summaryItems(column)); }
  function renameColumn(column) {
    dialog('Rename property', (form, close) => {
      const name = input(propertyConfig(doc, column)?.displayName ?? ''); name.placeholder = column.replace(/^(note|formula)\./, '');
      form.append(field('Display name', name), el('p', 'The display name is used in this Base only. Filters and formulas still use ' + column.replace(/^note\./, '') + '.', 'muted'));
      actions(form, close, () => change(updateBaseProperty(ctx.data.source, column, {displayName:name.value.trim() || null})), 'Rename');
    });
  }
  function rowMenu(row, at) {
    menu(at, [
      {label:'Open', icon:'file', action:() => ctx.open(row.path)},
      {label:'Rename…', icon:'pencil', disabled:!B.editable(row, 'note.x'), action:() => renameNote(row)},
      {label:'Copy link', icon:'link', action:() => copyText('[[' + row.file.basename + ']]')}
    ]);
  }
  function columnMenu(key, at) {
    menu(at, [{label:'Reset column order', icon:'refresh', disabled:!view().groupOrder, action:() => apply({groupOrder:null})}]);
  }
  function renameNote(row) {
    dialog('Rename note', (form, close) => {
      const name = input(row.file.basename); form.append(field('Name', name));
      actions(form, close, () => {
        const value = name.value.trim(); if (!value || /[\\/\x00-\x1f]/.test(value)) throw Error('Enter a name without slashes.');
        ctx.renameFile(row.path, value + (row.file.fields.ext ? '.' + row.file.fields.ext : ''));
      }, 'Rename');
      requestAnimationFrame(() => name.select());
    });
  }

  // ---------------------------------------------------------------- results
  let pendingCopy = null;
  function copyText(tsv, html = null) { pendingCopy = {tsv, html}; document.execCommand('copy'); if (pendingCopy) { pendingCopy = null; ctx.copy(tsv); } ctx.notice('Copied to clipboard'); }
  function viewTable() {
    const rows = visibleRows(), columns = result.columns;
    const text = (row, i) => columns[i] === 'file.name' ? row.file.basename : display(row.cells[i]);
    return {columns, rows, text};
  }
  function resultsMenu() {
    popover(resultsButton, 'Results', (form, close) => {
      const limit = input(view().limit ?? '', 'number'); limit.min = '1'; limit.placeholder = 'No limit';
      limit.onchange = () => apply({limit:Number(limit.value) > 0 ? Math.floor(Number(limit.value)) : null});
      form.append(field('Limit results', limit),
        button('Copy to clipboard', () => {
          const {columns, rows, text} = viewTable(), escape = s => s.replace(/[&<>]/g, ch => ({'&':'&amp;', '<':'&lt;', '>':'&gt;'})[ch]);
          const tsv = [columns.map(displayName).join('\t'), ...rows.map(r => columns.map((_, i) => text(r, i).replace(/[\t\n]/g, ' ')).join('\t'))].join('\n');
          const html = '<table><tr>' + columns.map(c => '<th>' + escape(displayName(c)) + '</th>').join('') + '</tr>' + rows.map(r => '<tr>' + columns.map((_, i) => '<td>' + escape(text(r, i)) + '</td>').join('') + '</tr>').join('') + '</table>';
          close(); copyText(tsv, html);
        }, 'popover-action'),
        button('Export CSV', () => {
          const {columns, rows, text} = viewTable(), cell = s => /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
          const csv = [columns.map(c => cell(displayName(c))), ...rows.map(r => columns.map((_, i) => cell(text(r, i))))].map(line => line.join(',')).join('\r\n') + '\r\n';
          const baseName = path.split('/').pop().replace(/\.base$/i, '');
          close(); ctx.exportFile(baseName + ' - ' + (view().name || 'View') + '.csv', '﻿' + csv);
        }, 'popover-action'));
    });
  }
  const onCopy = e => {
    if (pendingCopy) { e.clipboardData.setData('text/plain', pendingCopy.tsv); if (pendingCopy.html) e.clipboardData.setData('text/html', pendingCopy.html); e.preventDefault(); pendingCopy = null; return; }
    if (!body.contains(document.activeElement) || document.activeElement.matches('input,textarea') || !state.copy) return;
    const data = state.copy(); if (!data) return;
    e.clipboardData.setData('text/plain', data.tsv); e.clipboardData.setData('text/html', data.html); e.preventDefault();
  };
  const onPaste = e => {
    if (!body.contains(document.activeElement) || document.activeElement.matches('input,textarea') || !state.paste) return;
    const text = e.clipboardData.getData('text/plain'); if (!text) return;
    e.preventDefault(); state.paste(text);
  };
  document.addEventListener('copy', onCopy); document.addEventListener('paste', onPaste);

  // ---------------------------------------------------------------- new notes
  // New notes inherit properties that make them match the view's simple filters.
  function newNote(extra = {}) {
    const properties = {}, tags = new Set(); let folder = null;
    const collect = rule => {
      if (rule == null) return;
      if (typeof rule === 'string') {
        const parsed = simpleRule(rule); if (!parsed) return;
        if (parsed.op === 'hasTag') String(parsed.value).split(',').map(t => t.trim()).filter(Boolean).slice(0, 1).forEach(t => tags.add(t.replace(/^#/, '')));
        else if (parsed.op === 'inFolder') folder = String(parsed.value).trim();
        else if (parsed.op === '==' && noteProperty(parsed.column)) properties[noteProperty(parsed.column)] = parsed.value;
        else if (parsed.op === 'contains' && noteProperty(parsed.column) && ['multitext', 'tags', 'aliases'].includes(types[noteProperty(parsed.column)])) properties[noteProperty(parsed.column)] = [parsed.value];
        return;
      }
      if (rule.and) rule.and.forEach(collect);
    };
    collect(doc.filters); collect(view().filters);
    if (tags.size) properties.tags = [...new Set([...(properties.tags ?? []), ...tags])];
    Object.assign(properties, Object.fromEntries(Object.entries(extra).filter(([, v]) => v != null)));
    if (folder == null) {
      const location = ctx.data.newFileLocation ?? 'root';
      folder = location === 'current' ? (path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : '') : location === 'folder' ? String(ctx.data.newFileFolder ?? '').replace(/^\/+|\/+$/g, '') : '';
    }
    ctx.createNote(folder, properties);
  }

  // ---------------------------------------------------------------- render
  function visibleRows() {
    const term = state.search.trim().toLocaleLowerCase(); if (!term) return result.rows;
    return result.rows.filter(row => (row.file.basename + '\t' + row.cells.map(display).join('\t')).toLocaleLowerCase().includes(term));
  }
  function toolbar() {
    const v = view();
    viewButton.replaceChildren(icon(layoutIcons[v.type] ?? 'layers'), el('span', v.name || layoutNames[v.type] || 'View', 'view-button-name'), icon('chevronDown'));
    const shown = visibleRows().length, total = result?.total ?? 0;
    resultsButton.replaceChildren(el('span', (state.search ? shown + ' of ' : '') + (v.limit && total > v.limit ? v.limit + ' of ' + total : total) + (total === 1 ? ' result' : ' results') + (ctx.data.loading ? ' · Loading…' : '')), icon('chevronDown'));
    filterButton.classList.toggle('active', !!(doc.filters || v.filters));
    sortButton.classList.toggle('active', !!(v.sort?.length || v.groupBy));
  }
  function draw(keepScroll = true) {
    const top = body.scrollTop, left = body.scrollLeft;
    body.replaceChildren(); body.className = 'base-body layout-' + (builtInLayouts.includes(view().type) ? view().type : 'table');
    toolbar();
    const rows = visibleRows();
    if (!rows.length && view().type !== 'kanban') {
      body.append(el('div', ctx.data.loading ? 'Reading workspace notes…' : state.search ? 'No results match “' + state.search + '”' : 'No files match this view', 'empty'));
      if (!ctx.data.loading) { const tail = el('div', null, 'table-new'); tail.append(button('+ New', () => newNote(), 'table-new-button')); body.append(tail); }
      return;
    }
    const type = view().type;
    if (type === 'cards') cardsLayout(B, body, rows);
    else if (type === 'list') listLayout(B, body, rows);
    else if (type === 'kanban') kanbanLayout(B, body, rows);
    else tableLayout(B, body, rows);
    if (keepScroll) { body.scrollTop = top; body.scrollLeft = left; }
  }
  function refresh() {
    if (state.editing || ctx.busy) { deferred = true; return; }
    doc = yaml(ctx.data.source);
    if (!Array.isArray(doc.views) || !doc.views.length) { body.replaceChildren(el('div', 'This Base has no views. Add one to start.', 'empty')); return; }
    state.viewIndex = Math.max(0, Math.min(state.viewIndex, doc.views.length - 1));
    try {
      result = base(ctx.data.source, ctx.data.files ?? [], path, state.viewIndex, {types:ctx.data.types ?? null, thisPath:ctx.data.thisPath ?? undefined});
      types = propertyTypes(result.context.records, ctx.data.types ?? null);
      cloudHint.hidden = true;
      const inventoryWarning = (ctx.data.warning ?? '').replace(/(\d+) iCloud notes are not downloaded\.(?: Their properties and tags will be available after downloading and refreshing the index\.)?/, (message, count) => {
        cloudHint.textContent = 'iCloud: ' + count + ' not downloaded'; cloudHint.title = message; cloudHint.hidden = false; return '';
      }).trim();
      warning.textContent = [inventoryWarning, ...result.warnings].filter(Boolean).join(' '); warning.hidden = !warning.textContent;
      draw();
    } catch (e) {
      result = {doc, view:view(), columns:view().order ?? ['file.name'], rows:[], total:0, warnings:[], context:{records:[], shared:{resolve:() => null}}};
      toolbar(); warning.textContent = e.message; warning.hidden = false;
      body.replaceChildren(el('div', 'This view could not be evaluated. Adjust its filters or options, or open Source.', 'empty'));
    }
  }
  searchField.oninput = () => { state.search = searchField.value; state.selection = null; state.renderedRows = 0; if (result) draw(false); };
  searchField.onblur = () => { if (!searchField.value) searchField.hidden = true; };
  searchField.onkeydown = e => { if (e.key === 'Escape') { searchField.value = ''; searchField.oninput(); searchField.blur(); } };
  refresh();
  let lastFiles = ctx.data.files, lastSource = ctx.data.source, lastLoading = ctx.data.loading, lastWarning = ctx.data.warning;
  return {
    update() {
      if (ctx.data.kind !== 'base' || ctx.data.path !== path) return false;
      if (lastSource === ctx.data.source && lastFiles === ctx.data.files && lastLoading === ctx.data.loading && lastWarning === ctx.data.warning) { toolbar(); return true; }
      lastSource = ctx.data.source; lastFiles = ctx.data.files; lastLoading = ctx.data.loading; lastWarning = ctx.data.warning;
      refresh(); return true;
    },
    key(e) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); searchField.hidden = false; searchField.focus(); searchField.select(); }
    },
    destroy() { closePopover(); closeMenus(); document.removeEventListener('copy', onCopy); document.removeEventListener('paste', onPaste); }
  };
}
