// Table layout: Obsidian-style cell selection, keyboard navigation, clipboard,
// summaries, column reordering and resizing.
import {el, button, icon, menu} from './obsidian-ui.js';
import {display, isEmptyValue, CellError} from './bases-engine.js';
import {groupRows, summaryValue} from './obsidian-model.js';
import {renderValue, openEditor, rawValue, editableText, valueFromText} from './base-cells.js';

const rowHeights = {short:1, medium:2, tall:4, 'extra tall':8, extraTall:8};
export function columnWidth(view, column) {
  const width = view.columnSize?.[column];
  return Number.isFinite(width) ? Math.max(60, Math.min(1600, width)) : column === 'file.name' ? 260 : 180;
}

export function tableLayout(B, body, rows) {
  const {view} = B, columns = B.result.columns;
  const table = el('table', null, 'base-table'), cols = el('colgroup'), thead = el('thead'), head = el('tr');
  const clamp = rowHeights[view.rowHeight];
  if (clamp) { table.classList.add('clamped'); table.style.setProperty('--row-lines', clamp); }
  const widthOf = column => columnWidth(view, column);
  const setWidth = () => { table.style.width = columns.reduce((sum, c) => sum + widthOf(c), 0) + 'px'; };
  for (const column of columns) { const col = el('col'); col.dataset.column = column; col.style.width = widthOf(column) + 'px'; cols.append(col); }
  setWidth(); table.append(cols);
  const sorted = new Map((view.sort ?? []).map((s, i) => [s.property, {dir:String(s.direction).toUpperCase(), index:i}]));
  columns.forEach((column, index) => {
    const th = el('th'); th.dataset.column = column;
    const title = button(null, e => B.headerMenu(column, title), 'column-title');
    title.append(B.propertyIcon(column), el('span', B.displayName(column), 'column-name'));
    const sort = sorted.get(column);
    if (sort) { const mark = icon(sort.dir === 'DESC' ? 'arrowDown' : 'arrowUp'); mark.classList.add('sort-mark'); title.append(mark); }
    title.title = B.displayName(column); title.oncontextmenu = e => { e.preventDefault(); B.headerMenu(column, {x:e.clientX, y:e.clientY}); };
    dragColumn(title, th, column, index);
    const resize = el('span', null, 'column-resize'); resize.tabIndex = 0; resize.setAttribute('role', 'separator');
    resize.setAttribute('aria-label', 'Resize ' + B.displayName(column)); resizeColumn(resize, column);
    th.append(title, resize); head.append(th);
  });
  thead.append(head); table.append(thead);

  // --- rows, grouped with per-group summaries
  const grid = [], groups = view.groupBy?.property ? groupRows(rows) : [{key:null, rows}];
  const summaries = view.summaries && typeof view.summaries === 'object' ? view.summaries : {};
  const hasSummaries = columns.some(c => summaries[c]);
  let rendered = 0; const limit = {value:Math.max(200, B.state.renderedRows ?? 0)};
  const bodies = [];
  for (const group of groups) {
    const tbody = el('tbody'); bodies.push({tbody, group});
    if (view.groupBy?.property) {
      const tr = el('tr', null, 'group-row'), td = el('td'); td.colSpan = columns.length;
      const label = el('div', null, 'group-label');
      label.append(el('span', B.displayName(view.groupBy.property), 'group-property'));
      label.append(isEmptyValue(group.key) ? el('span', 'None', 'group-empty') : renderValue(group.key, B, {column:view.groupBy.property}));
      label.append(el('span', String(group.rows.length), 'group-count'));
      td.append(label); tr.append(td); tbody.append(tr);
      if (hasSummaries) tbody.append(summaryRow(group.rows, 'group-summary'));
    }
    table.append(tbody);
  }
  const more = button('Load more results', () => { limit.value += 500; B.state.renderedRows = limit.value; fill(); }, 'load-more');
  function fill() {
    more.remove();
    let index = 0;
    for (const {tbody, group} of bodies) {
      for (const row of group.rows) {
        if (index < rendered) { index++; continue; }
        if (index >= limit.value) break;
        const tr = el('tr', null, 'data-row'); tr.dataset.path = row.path; tr.dataset.index = String(index);
        const cells = [];
        columns.forEach((column, c) => {
          const td = el('td'); td.dataset.row = String(index); td.dataset.col = String(c); td.dataset.column = column;
          drawCell(td, row, column, c); tr.append(td); cells.push(td);
        });
        grid[index] = {row, cells}; tbody.append(tr); index++;
      }
    }
    rendered = Math.min(index, limit.value);
    if (rendered < rows.length) body.append(more);
  }
  function drawCell(td, row, column, c) {
    td.replaceChildren(); td.className = ''; td.removeAttribute('title');
    const value = row.cells[c], editable = B.editable(row, column), type = B.columnType(column);
    if (editable) td.classList.add('editable');
    if (value instanceof CellError) td.title = value.error;
    const content = el('div', null, 'cell');
    if (column === 'file.name') {
      const link = el('a', row.file.basename, 'internal-link note-title'); link.href = '#';
      link.onclick = e => { e.preventDefault(); e.stopPropagation(); B.open(row.path); };
      content.append(link);
    } else content.append(renderValue(value, B, {from:row.path, column, type, toggle:editable && typeof value === 'boolean' || editable && type === 'checkbox' ? checked => B.write(row, column, checked) : null}));
    if (editable && type === 'checkbox' && value == null) {
      const box = el('input'); box.type = 'checkbox'; box.className = 'cell-checkbox'; box.tabIndex = -1;
      box.onclick = e => { e.stopPropagation(); B.write(row, column, box.checked); }; content.replaceChildren(box);
    }
    td.append(content);
  }
  const tfoot = el('tfoot');
  function summaryRow(groupRowsList, cls) {
    const tr = el('tr', null, 'summary-row ' + cls);
    columns.forEach(column => {
      const td = el('td'), name = summaries[column];
      const cell = button(null, () => B.summaryMenu(column, cell), 'summary-cell');
      if (name) { cell.append(el('span', name, 'summary-name'), el('span', display(summaryValue(B.result, groupRowsList, column, name)), 'summary-value')); }
      else cell.append(el('span', 'Summarize', 'summary-add'));
      td.append(cell); tr.append(td);
    });
    return tr;
  }
  if (hasSummaries && !view.groupBy?.property) { tfoot.append(summaryRow(rows, 'total-summary')); table.append(tfoot); }
  const newRow = el('div', null, 'table-new');
  newRow.append(button('+ New', () => B.newNote(), 'table-new-button'));
  body.append(table); fill(); body.append(newRow);
  body.addEventListener('scroll', () => { if (rendered < rows.length && body.scrollHeight - body.scrollTop - body.clientHeight < 300) { limit.value += 300; B.state.renderedRows = limit.value; fill(); } });

  // --- selection
  const sel = B.state.selection ??= {anchor:null, focus:null};
  table.tabIndex = 0; table.setAttribute('role', 'grid'); table.setAttribute('aria-label', 'Base results');
  const within = (r, c) => {
    if (!sel.anchor || !sel.focus) return false;
    return r >= Math.min(sel.anchor[0], sel.focus[0]) && r <= Math.max(sel.anchor[0], sel.focus[0]) && c >= Math.min(sel.anchor[1], sel.focus[1]) && c <= Math.max(sel.anchor[1], sel.focus[1]);
  };
  function paint() {
    table.querySelectorAll('td.selected,td.focused').forEach(td => td.classList.remove('selected', 'focused'));
    if (!sel.anchor) return;
    for (const [r, entry] of grid.entries()) if (entry) entry.cells.forEach((td, c) => { if (within(r, c)) td.classList.add('selected'); });
    grid[sel.focus[0]]?.cells[sel.focus[1]]?.classList.add('focused');
  }
  function focusCell(r, c, extend = false) {
    r = Math.max(0, Math.min(rows.length - 1, r)); c = Math.max(0, Math.min(columns.length - 1, c));
    while (r >= rendered && rendered < rows.length) { limit.value += 300; fill(); }
    if (!extend || !sel.anchor) sel.anchor = [r, c];
    sel.focus = [r, c]; paint();
    grid[r]?.cells[c]?.scrollIntoView({block:'nearest', inline:'nearest'});
  }
  table.addEventListener('pointerdown', e => {
    const td = e.target.closest('td[data-row]');
    if (!td || td.classList.contains('editing') || e.button !== 0) return;
    if (e.target.closest('a,input,button,.chip-remove')) { if (!e.target.closest('input[type=checkbox]')) return; }
    focusCell(Number(td.dataset.row), Number(td.dataset.col), e.shiftKey);
    table.focus({preventScroll:true});
    const drag = move => {
      const over = document.elementFromPoint(move.clientX, move.clientY)?.closest('td[data-row]');
      if (over && table.contains(over)) { sel.focus = [Number(over.dataset.row), Number(over.dataset.col)]; paint(); }
    };
    const up = () => { removeEventListener('pointermove', drag); removeEventListener('pointerup', up); };
    addEventListener('pointermove', drag); addEventListener('pointerup', up);
  });
  table.addEventListener('dblclick', e => {
    const td = e.target.closest('td[data-row]'); if (!td || e.target.closest('a,input')) return;
    edit(Number(td.dataset.row), Number(td.dataset.col));
  });
  table.addEventListener('cell-tab', e => { const back = e.detail.back; const [r, c] = sel.focus ?? [0, 0]; table.focus({preventScroll:true}); step(r, c, back); });
  function step(r, c, back) {
    let nr = r, nc = c + (back ? -1 : 1);
    if (nc >= columns.length) { nc = 0; nr++; } if (nc < 0) { nc = columns.length - 1; nr--; }
    if (nr >= 0 && nr < rows.length) focusCell(nr, nc);
  }
  function edit(r, c, initial = null) {
    const entry = grid[r]; if (!entry) return;
    const column = columns[c], row = entry.row, td = entry.cells[c];
    if (!B.editable(row, column)) { if (column === 'file.name') B.renameNote(row); return; }
    const type = B.columnType(column);
    if (type === 'checkbox') { B.write(row, column, !(row.cells[c] === true)); return; }
    focusCell(r, c); B.state.editing = true;
    openEditor(td, {type, raw:rawValue(row, column) ?? row.cells[c], initial, label:B.displayName(column) + ' · ' + row.file.basename,
      commit:value => B.write(row, column, value, {render:false}),
      finish:() => { B.state.editing = false; td.classList.remove('editing', 'edit-error'); drawCell(td, row, column, c); paint(); table.focus({preventScroll:true}); B.flush(); }});
  }
  table.addEventListener('keydown', e => {
    if (e.target !== table || !sel.focus) return;
    const [r, c] = sel.focus, meta = e.metaKey || e.ctrlKey, page = Math.max(1, Math.floor(body.clientHeight / 36));
    const moves = {ArrowUp:[-1, 0], ArrowDown:[1, 0], ArrowLeft:[0, -1], ArrowRight:[0, 1]};
    if (moves[e.key]) {
      e.preventDefault(); const [dr, dc] = moves[e.key];
      if (meta) focusCell(dr ? (dr < 0 ? 0 : rows.length - 1) : r, dc ? (dc < 0 ? 0 : columns.length - 1) : c, e.shiftKey);
      else focusCell(r + dr, c + dc, e.shiftKey);
    } else if (e.key === 'Tab') { e.preventDefault(); step(r, c, e.shiftKey); }
    else if (e.key === 'Home') { e.preventDefault(); focusCell(meta ? 0 : r, 0, e.shiftKey); }
    else if (e.key === 'End') { e.preventDefault(); focusCell(meta ? rows.length - 1 : r, columns.length - 1, e.shiftKey); }
    else if (e.key === 'PageDown' || e.key === 'PageUp') { e.preventDefault(); focusCell(r + (e.key === 'PageDown' ? page : -page), c, e.shiftKey); }
    else if (e.key === 'Enter') { e.preventDefault(); if (e.shiftKey) focusCell(r - 1, c); else edit(r, c); }
    else if (e.key === 'Escape') { sel.anchor = sel.focus = null; paint(); }
    else if ((e.key === 'Backspace' || e.key === 'Delete') && !meta) { e.preventDefault(); clearSelection(); }
    else if (meta && e.key.toLowerCase() === 'a') { e.preventDefault(); sel.anchor = [0, 0]; sel.focus = [rows.length - 1, columns.length - 1]; while (rendered < rows.length) { limit.value += 500; fill(); } paint(); }
    else if (e.key === ' ' && e.shiftKey) { e.preventDefault(); sel.anchor = [r, 0]; sel.focus = [r, columns.length - 1]; paint(); }
    else if (e.key === ' ' && e.ctrlKey) { e.preventDefault(); sel.anchor = [0, c]; sel.focus = [rows.length - 1, c]; paint(); }
    else if (e.key.length === 1 && !meta && !e.altKey && !e.isComposing) {
      const type = B.columnType(columns[c]);
      if (B.editable(grid[r]?.row, columns[c]) && !['checkbox', 'date', 'datetime'].includes(type)) { e.preventDefault(); edit(r, c, ['multitext', 'tags', 'aliases'].includes(type) ? e.key : e.key); }
    }
  });
  // Korean/Japanese input starts with a composition; begin editing on its first character.
  table.addEventListener('compositionstart', () => { if (sel.focus && !B.state.editing) edit(sel.focus[0], sel.focus[1], ''); });
  function selectedCells() {
    if (!sel.anchor) return [];
    const [r0, r1] = [Math.min(sel.anchor[0], sel.focus[0]), Math.max(sel.anchor[0], sel.focus[0])];
    const [c0, c1] = [Math.min(sel.anchor[1], sel.focus[1]), Math.max(sel.anchor[1], sel.focus[1])];
    const out = [];
    for (let r = r0; r <= r1; r++) { const line = []; for (let c = c0; c <= c1; c++) line.push({r, c}); out.push(line); }
    return out;
  }
  async function clearSelection() {
    const targets = selectedCells().flat().filter(({r, c}) => grid[r] && B.editable(grid[r].row, columns[c]) && !isEmptyValue(grid[r].row.cells[c]));
    await B.writeMany(targets.map(({r, c}) => ({row:grid[r].row, column:columns[c], value:null})));
  }
  B.state.copy = () => {
    const cells = selectedCells(); if (!cells.length) return null;
    const textOf = ({r, c}) => { const row = grid[r]?.row; if (!row) return ''; const column = columns[c]; return column === 'file.name' ? row.file.basename : editableText(rawValue(row, column) ?? row.cells[c]); };
    const tsv = cells.map(line => line.map(cell => textOf(cell).replace(/[\t\n]/g, ' ')).join('\t')).join('\n');
    const escape = s => s.replace(/[&<>]/g, ch => ({'&':'&amp;', '<':'&lt;', '>':'&gt;'})[ch]);
    const html = '<table>' + cells.map(line => '<tr>' + line.map(cell => '<td>' + escape(textOf(cell)) + '</td>').join('') + '</tr>').join('') + '</table>';
    return {tsv, html};
  };
  B.state.paste = async textValue => {
    if (!sel.focus) return false;
    const lines = textValue.replace(/\r\n?/g, '\n').replace(/\n$/, '').split('\n').map(l => l.split('\t'));
    const [r0, c0] = [Math.min(sel.anchor[0], sel.focus[0]), Math.min(sel.anchor[1], sel.focus[1])];
    const single = lines.length === 1 && lines[0].length === 1, writes = [];
    const targets = single ? selectedCells().flat() : lines.flatMap((line, dr) => line.map((_, dc) => ({r:r0 + dr, c:c0 + dc})));
    for (const {r, c} of targets) {
      const entry = grid[r], column = columns[c]; if (!entry || column == null || !B.editable(entry.row, column)) continue;
      const cellText = single ? lines[0][0] : lines[r - r0][c - c0];
      try { writes.push({row:entry.row, column, value:valueFromText(cellText, B.columnType(column))}); } catch (e) { B.notice(e.message, true); return true; }
    }
    if (!writes.length) { B.notice('These cells cannot be edited.', true); return true; }
    await B.writeMany(writes); return true;
  };
  if (sel.anchor) { const [r, c] = sel.focus; if (r >= rows.length || c >= columns.length) sel.anchor = sel.focus = null; else paint(); }

  // --- column drag & resize
  function dragColumn(handle, th, column, index) {
    handle.addEventListener('pointerdown', e => {
      if (e.button !== 0) return;
      const startX = e.clientX; let moved = false, marker = null, target = index;
      const move = m => {
        if (!moved && Math.abs(m.clientX - startX) < 5) return;
        if (!moved) { moved = true; th.classList.add('dragging'); marker = el('div', null, 'column-drop'); document.body.append(marker); }
        const ths = [...head.children]; target = ths.length;
        for (const [i, cell] of ths.entries()) { const r = cell.getBoundingClientRect(); if (m.clientX < r.left + r.width / 2) { target = i; break; } }
        const ref = ths[Math.min(target, ths.length - 1)].getBoundingClientRect();
        marker.style.left = (target >= ths.length ? ref.right : ref.left) - 1 + 'px'; marker.style.top = ref.top + 'px'; marker.style.height = Math.min(body.clientHeight, 600) + 'px';
      };
      const up = () => {
        removeEventListener('pointermove', move); removeEventListener('pointerup', up); marker?.remove(); th.classList.remove('dragging');
        if (!moved) return;
        handle.addEventListener('click', stop => { stop.stopImmediatePropagation(); stop.preventDefault(); }, {capture:true, once:true});
        const order = [...columns]; order.splice(index, 1); order.splice(target > index ? target - 1 : target, 0, column);
        if (order.join('\0') !== columns.join('\0')) B.apply({order});
      };
      addEventListener('pointermove', move); addEventListener('pointerup', up);
    });
  }
  function resizeColumn(handle, column) {
    const paintWidth = width => { cols.querySelector('[data-column="' + CSS.escape(column) + '"]').style.width = width + 'px'; table.style.width = [...cols.children].reduce((s, c) => s + parseFloat(c.style.width), 0) + 'px'; };
    handle.onpointerdown = e => {
      if (e.button !== 0) return; e.preventDefault(); e.stopPropagation();
      const start = e.clientX, initial = widthOf(column); let width = initial;
      handle.setPointerCapture(e.pointerId);
      handle.onpointermove = m => { width = Math.round(Math.max(60, Math.min(1600, initial + m.clientX - start))); paintWidth(width); };
      handle.onpointerup = handle.onpointercancel = m => {
        handle.onpointermove = handle.onpointerup = handle.onpointercancel = null;
        if (m.type === 'pointercancel') paintWidth(initial); else if (width !== initial) B.apply({columnSize:{...(view.columnSize ?? {}), [column]:width}});
      };
    };
    handle.ondblclick = e => { e.stopPropagation(); const size = {...(view.columnSize ?? {})}; delete size[column]; B.apply({columnSize:Object.keys(size).length ? size : null}); };
    handle.onclick = e => e.stopPropagation();
    handle.onkeydown = e => { if (['ArrowLeft', 'ArrowRight'].includes(e.key)) { e.preventDefault(); e.stopPropagation(); B.apply({columnSize:{...(view.columnSize ?? {}), [column]:Math.max(60, widthOf(column) + (e.key === 'ArrowLeft' ? -10 : 10))}}); } };
  }
  return {focus:() => table.focus({preventScroll:true})};
}
