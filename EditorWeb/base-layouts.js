// Cards, list and kanban layouts.
import {el, button, icon, iconButton} from './obsidian-ui.js';
import {display, isEmptyValue, Link} from './bases-engine.js';
import {groupRows, columnValue, noteProperty} from './obsidian-model.js';
import {renderValue, openEditor, rawValue, imageSource, imageNode} from './base-cells.js';

function groupHeading(B, group) {
  const heading = el('div', null, 'layout-group');
  heading.append(el('span', B.displayName(B.view.groupBy.property), 'group-property'));
  heading.append(isEmptyValue(group.key) ? el('span', 'None', 'group-empty') : renderValue(group.key, B, {column:B.view.groupBy.property}));
  heading.append(el('span', String(group.rows.length), 'group-count'));
  return heading;
}
function titleNode(B, row, column, value) {
  if (column === 'file.name' || column == null) {
    const link = el('a', row.file.basename, 'internal-link card-title'); link.href = '#';
    link.onclick = e => { e.preventDefault(); e.stopPropagation(); B.open(row.path); }; return link;
  }
  const node = el('div', null, 'card-title'); node.append(renderValue(value, B, {from:row.path, column, type:B.columnType(column)})); return node;
}
function propertyLine(B, row, column, index, options = {}) {
  const line = el('div', null, 'card-property'), value = row.cells[index];
  line.dataset.column = column;
  if (options.labels !== false) line.append(el('span', B.displayName(column), 'card-label'));
  const holder = el('div', null, 'card-value'), type = B.columnType(column), editable = B.editable(row, column);
  const draw = () => {
    holder.replaceChildren(renderValue(value, B, {from:row.path, column, type, toggle:editable && (typeof value === 'boolean' || type === 'checkbox') ? checked => B.write(row, column, checked) : null}));
    if (isEmptyValue(value) && editable && type !== 'checkbox') holder.append(el('span', 'Empty', 'card-empty'));
  };
  draw();
  if (editable && type !== 'checkbox') {
    holder.classList.add('editable'); holder.tabIndex = 0;
    const start = e => {
      if (e?.target?.closest?.('a,input')) return; e?.stopPropagation?.();
      B.state.editing = true;
      openEditor(holder, {type, raw:rawValue(row, column) ?? value, label:B.displayName(column) + ' · ' + row.file.basename,
        commit:v => B.write(row, column, v), finish:() => { B.state.editing = false; holder.classList.remove('editing', 'edit-error'); draw(); B.flush(); }});
    };
    holder.ondblclick = start; holder.onkeydown = e => { if (e.key === 'Enter' && e.target === holder) { e.preventDefault(); start(e); } };
  }
  line.append(holder);
  return line;
}
function cover(B, row, card) {
  const view = B.view; if (!view.image) return;
  const ratio = Number(view.imageAspectRatio) > 0 ? Number(view.imageAspectRatio) : 1;
  const box = el('div', null, 'card-cover'); box.style.aspectRatio = String(1 / ratio);
  const value = columnValue(row.ctx, view.image), source = imageSource(value, row.path, B);
  if (source) {
    const image = imageNode(source, B, 'cover-image'); image.dataset.fit = view.imageFit === 'contain' ? 'contain' : 'cover';
    if (source.color) box.style.background = source.color; else box.append(image);
  } else box.classList.add('empty-cover');
  card.append(box);
}
function card(B, row, options = {}) {
  const columns = B.result.columns, node = el('article', null, 'base-card');
  node.dataset.path = row.path; cover(B, row, node);
  const content = el('div', null, 'card-content');
  const titleIndex = columns.indexOf('file.name') >= 0 ? columns.indexOf('file.name') : options.titleFirst ? 0 : -1;
  content.append(titleNode(B, row, titleIndex >= 0 ? columns[titleIndex] : null, row.cells[titleIndex]));
  columns.forEach((column, i) => { if (i !== titleIndex && column !== B.view.image) content.append(propertyLine(B, row, column, i)); });
  node.append(content);
  node.onclick = e => { if (!e.target.closest('a,input,textarea,button,.editable,.editing')) B.open(row.path); };
  node.oncontextmenu = e => { e.preventDefault(); B.rowMenu(row, {x:e.clientX, y:e.clientY}); };
  return node;
}

export function cardsLayout(B, body, rows) {
  const size = Number(B.view.cardSize) > 0 ? Number(B.view.cardSize) : 200;
  const groups = B.view.groupBy?.property ? groupRows(rows) : [{key:null, rows}];
  let budget = Math.max(300, B.state.renderedRows ?? 0);
  for (const group of groups) {
    if (B.view.groupBy?.property) body.append(groupHeading(B, group));
    const grid = el('div', null, 'cards-grid'); grid.style.setProperty('--card-size', size + 'px');
    for (const row of group.rows) { if (budget-- <= 0) break; grid.append(card(B, row, {titleFirst:true})); }
    body.append(grid);
  }
  if (budget < 0) body.append(button('Load more results', () => { B.state.renderedRows = (B.state.renderedRows ?? 300) + 500; B.redraw(); }, 'load-more'));
  const tail = el('div', null, 'table-new'); tail.append(button('+ New', () => B.newNote(), 'table-new-button')); body.append(tail);
}

export function listLayout(B, body, rows) {
  const view = B.view, columns = B.result.columns, markers = view.markers ?? 'bullets';
  const indent = view.indentProperties === true, separator = typeof view.separator === 'string' ? view.separator : ', ';
  const groups = view.groupBy?.property ? groupRows(rows) : [{key:null, rows}];
  let budget = Math.max(500, B.state.renderedRows ?? 0);
  for (const group of groups) {
    if (view.groupBy?.property) body.append(groupHeading(B, group));
    const list = el(markers === 'numbers' ? 'ol' : 'ul', null, 'base-list markers-' + markers);
    for (const row of group.rows) {
      if (budget-- <= 0) break;
      const item = el('li', null, 'base-list-item'); item.dataset.path = row.path;
      const primary = el('div', null, 'list-primary');
      primary.append(titleNode(B, row, columns[0] ?? 'file.name', row.cells[0]));
      const rest = columns.slice(1).map((column, i) => ({column, i:i + 1})).filter(({i}) => !isEmptyValue(row.cells[i]));
      if (indent) {
        item.append(primary);
        if (rest.length) {
          const sub = el('ul', null, 'list-properties');
          for (const {column, i} of rest) { const li = el('li'); li.append(propertyLine(B, row, column, i, {labels:true})); sub.append(li); }
          item.append(sub);
        }
      } else {
        rest.forEach(({column, i}) => {
          primary.append(el('span', separator, 'list-separator'));
          const value = el('span', null, 'list-inline'); value.title = B.displayName(column);
          value.append(renderValue(row.cells[i], B, {from:row.path, column, type:B.columnType(column)})); primary.append(value);
        });
        item.append(primary);
      }
      item.oncontextmenu = e => { e.preventDefault(); B.rowMenu(row, {x:e.clientX, y:e.clientY}); };
      list.append(item);
    }
    body.append(list);
  }
  if (budget < 0) body.append(button('Load more results', () => { B.state.renderedRows = (B.state.renderedRows ?? 500) + 1000; B.redraw(); }, 'load-more'));
}

// Kanban: one column per group value. Dragging a card writes the grouped property.
export function kanbanLayout(B, body, rows) {
  const view = B.view, property = view.groupBy?.property;
  if (!property) {
    const empty = el('div', null, 'kanban-setup');
    empty.append(el('p', 'Kanban groups notes into columns by a property.'), button('Choose group property', e => B.groupMenu(e.currentTarget), 'primary'));
    body.append(empty); return;
  }
  const writable = !!noteProperty(property);
  const groups = groupRows(rows), keyOf = value => isEmptyValue(value) ? '' : display(value);
  const byKey = new Map(groups.map(g => [keyOf(g.key), g]));
  const order = Array.isArray(view.groupOrder) ? view.groupOrder.map(String) : [];
  const keys = [...new Set([...order.filter(k => byKey.has(k) || !view.hideEmptyColumns), ...groups.map(g => keyOf(g.key))])];
  if (keys.includes('')) { keys.splice(keys.indexOf(''), 1); if (byKey.has('') || !view.hideEmptyColumns) keys.push(''); }
  const board = el('div', null, 'kanban-board'), width = Number(view.columnWidth) > 0 ? Number(view.columnWidth) : 280;
  board.style.setProperty('--column-width', width + 'px');
  for (const key of keys) {
    const group = byKey.get(key) ?? {key:null, rows:[]};
    const column = el('section', null, 'kanban-column'); column.dataset.key = key;
    const head = el('header', null, 'kanban-head');
    const label = el('div', null, 'kanban-title');
    label.append(key === '' ? el('span', 'None', 'group-empty') : renderValue(group.key ?? key, B, {column:property}), el('span', String(group.rows.length), 'group-count'));
    head.append(label);
    if (writable) head.append(iconButton('plus', 'New note in ' + (key || 'None'), () => B.newNote({[noteProperty(property)]:key === '' ? null : rawGroupValue(group, key)})));
    head.oncontextmenu = e => { e.preventDefault(); B.columnMenu(key, {x:e.clientX, y:e.clientY}); };
    dragColumn(head, column, key);
    const cards = el('div', null, 'kanban-cards');
    for (const row of group.rows) {
      const node = card(B, row, {titleFirst:true}); node.classList.add('kanban-card');
      if (writable && /\.(md|markdown)$/i.test(row.path)) dragCard(node, row, key);
      cards.append(node);
    }
    column.append(head, cards);
    if (writable) { const add = button('+ New', () => B.newNote({[noteProperty(property)]:key === '' ? null : rawGroupValue(group, key)}), 'kanban-new'); column.append(add); }
    board.append(column);
  }
  body.append(board);
  function rawGroupValue(group, key) {
    const sample = group.rows[0], raw = sample ? rawValue(sample, property) : null;
    if (raw != null && !Array.isArray(raw)) return raw;
    const value = group.key;
    if (value instanceof Link) return '[[' + value.path + value.subpath + ']]';
    if (typeof value === 'boolean' || typeof value === 'number') return value;
    return key;
  }
  function dragCard(node, row, fromKey) {
    node.addEventListener('pointerdown', e => {
      if (e.button !== 0 || e.target.closest('a,input,textarea,button,.editable,.editing')) return;
      const start = {x:e.clientX, y:e.clientY}; let ghost = null, target = null;
      const move = m => {
        if (!ghost && Math.hypot(m.clientX - start.x, m.clientY - start.y) < 6) return;
        if (!ghost) { ghost = node.cloneNode(true); ghost.classList.add('kanban-ghost'); ghost.style.width = node.offsetWidth + 'px'; document.body.append(ghost); node.classList.add('dragging'); }
        ghost.style.transform = 'translate(' + (m.clientX - 20) + 'px,' + (m.clientY - 16) + 'px)';
        const over = document.elementFromPoint(m.clientX, m.clientY)?.closest('.kanban-column');
        board.querySelectorAll('.drop-target').forEach(c => c.classList.remove('drop-target'));
        target = over && board.contains(over) ? over : null; target?.classList.add('drop-target');
      };
      const up = async () => {
        removeEventListener('pointermove', move); removeEventListener('pointerup', up);
        if (!ghost) return;
        ghost.remove(); node.classList.remove('dragging'); board.querySelectorAll('.drop-target').forEach(c => c.classList.remove('drop-target'));
        node.addEventListener('click', s => { s.stopImmediatePropagation(); s.preventDefault(); }, {capture:true, once:true});
        const key = target?.dataset.key;
        if (key == null || key === fromKey) return;
        const group = byKey.get(key) ?? {key, rows:[]};
        const current = rawValue(row, property);
        let value = key === '' ? null : rawGroupValue(group, key);
        // A list property keeps its other values; only the grouped value moves.
        if (Array.isArray(current)) value = [...current.filter(v => display(v) !== fromKey), ...(value == null ? [] : [value])];
        await B.write(row, property, Array.isArray(value) && !value.length ? null : value);
      };
      addEventListener('pointermove', move); addEventListener('pointerup', up);
    });
  }
  function dragColumn(head, column, key) {
    head.addEventListener('pointerdown', e => {
      if (e.button !== 0 || e.target.closest('button,a')) return;
      const startX = e.clientX; let moved = false;
      const move = m => {
        if (!moved && Math.abs(m.clientX - startX) < 6) return;
        moved = true; column.classList.add('dragging');
        const cols = [...board.children]; const over = cols.find(c => { const r = c.getBoundingClientRect(); return m.clientX < r.left + r.width / 2; });
        if (over !== column) board.insertBefore(column, over ?? null);
      };
      const up = () => {
        removeEventListener('pointermove', move); removeEventListener('pointerup', up); column.classList.remove('dragging');
        if (moved) B.apply({groupOrder:[...board.children].map(c => c.dataset.key)});
      };
      addEventListener('pointermove', move); addEventListener('pointerup', up);
    });
  }
}
