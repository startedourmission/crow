import {expression, propertyExpression, columnType} from './obsidian-model.js';
import {el, button, iconButton, input, select, menu} from './obsidian-ui.js';

// Operators offered per property type, mirroring Obsidian's filter menu.
const operators = {
  text: [['==','is'],['!=','is not'],['contains','contains'],['!contains','does not contain'],['startsWith','starts with'],['endsWith','ends with'],['isEmpty','is empty'],['!isEmpty','is not empty']],
  number: [['==','='],['!=','≠'],['<','<'],['<=','≤'],['>','>'],['>=','≥'],['isEmpty','is empty'],['!isEmpty','is not empty']],
  date: [['==','on'],['!=','not on'],['<','before'],['<=','on or before'],['>','after'],['>=','on or after'],['isEmpty','is empty'],['!isEmpty','is not empty']],
  checkbox: [['==','is']],
  list: [['contains','contains'],['!contains','does not contain'],['containsAny','contains any of'],['containsAll','contains all of'],['isEmpty','is empty'],['!isEmpty','is not empty']],
  tags: [['hasTag','has tag'],['!hasTag','does not have tag']],
  folder: [['inFolder','is in folder'],['!inFolder','is not in folder'],['==','is'],['!=','is not']],
  links: [['hasLink','links to'],['!hasLink','does not link to']]
};
const kindOf = (column, types) => {
  if (column === 'file.tags') return 'tags';
  if (column === 'file.folder') return 'folder';
  if (column === 'file.links') return 'links';
  const type = columnType(column, types);
  return type === 'number' ? 'number' : type === 'date' || type === 'datetime' ? 'date' : type === 'checkbox' ? 'checkbox' :
    ['multitext', 'tags', 'aliases'].includes(type) ? 'list' : 'text';
};
const literal = value => value?.string ?? value?.number ?? (value?.id === 'true' ? true : value?.id === 'false' ? false : value?.id === 'null' ? null : undefined);
function columnOf(node) {
  if (node?.id && !['file', 'note', 'formula', 'this'].includes(node.id)) return node.id;
  if (['note', 'file', 'formula'].includes(node?.member?.id) && typeof node.key?.string === 'string') return node.member.id + '.' + node.key.string;
  return null;
}
function valueOf(node) {
  const v = literal(node); if (v !== undefined) return v;
  if (node?.call?.id === 'date' && node.args.length === 1 && typeof node.args[0].string === 'string') return node.args[0].string;
  if (node?.call?.id === 'link' && node.args.length >= 1 && typeof node.args[0].string === 'string') return node.args[0].string;
  return undefined;
}
// Parse an expression into a point-and-click condition when it has that shape.
export function simpleRule(rule) {
  try {
    let tree = expression(rule), negated = false;
    if (tree.unary === '!') { negated = true; tree = tree.value; }
    if (tree.call?.member) {
      const name = tree.call.key.string, target = tree.call.member;
      if (target.id === 'file' && ['hasTag', 'inFolder', 'hasLink'].includes(name)) {
        const values = tree.args.map(valueOf); if (values.some(v => v === undefined)) return;
        return {column:name === 'hasTag' ? 'file.tags' : name === 'inFolder' ? 'file.folder' : 'file.links', op:(negated ? '!' : '') + name, value:values.map(String).join(', ')};
      }
      const column = columnOf(target); if (!column) return;
      if (name === 'isEmpty' && !tree.args.length) return {column, op:(negated ? '!' : '') + 'isEmpty', value:''};
      if (['contains', 'startsWith', 'endsWith', 'containsAny', 'containsAll'].includes(name)) {
        const values = tree.args.map(valueOf); if (!values.length || values.some(v => v === undefined)) return;
        if (negated && name !== 'contains') return;
        return {column, op:(negated ? '!' : '') + name, value:values.length > 1 || name.startsWith('containsA') ? values.map(String).join(', ') : values[0]};
      }
      return;
    }
    if (negated || !['==', '!=', '<', '<=', '>', '>='].includes(tree.op)) return;
    const column = columnOf(tree.left), value = valueOf(tree.right);
    if (!column || value === undefined) return;
    return {column, op:tree.op, value};
  } catch {}
}
function quote(value) { return JSON.stringify(String(value)); }
// Write references the way Obsidian does: `status`, `file.name`, `formula.price`.
const identifier = /^[\p{L}_$][\p{L}\p{N}_$]*$/u;
const reserved = new Set(['file', 'note', 'formula', 'this', 'true', 'false', 'null', 'values']);
function reference(column) {
  const m = /^(file|formula|note)\.(.*)$/s.exec(column), prefix = m?.[1] ?? 'note', name = m ? m[2] : column;
  if (!identifier.test(name)) return propertyExpression(column);
  return prefix === 'note' ? (reserved.has(name) ? 'note.' + name : name) : prefix + '.' + name;
}
function build(column, op, value, kind) {
  const ref = reference(column), neg = op.startsWith('!'), bare = op.replace('!', '');
  const list = String(value ?? '').split(',').map(v => v.trim()).filter(Boolean);
  if (bare === 'isEmpty') return (neg ? '!' : '') + ref + '.isEmpty()';
  // An unfinished condition does not filter anything yet.
  if (kind !== 'checkbox' && String(value ?? '').trim() === '') return null;
  if (['hasTag', 'inFolder', 'hasLink'].includes(bare)) {
    if (!list.length) throw Error('Enter a value for this filter.');
    return (neg ? '!' : '') + 'file.' + bare + '(' + (bare === 'inFolder' ? quote(value.trim()) : list.map(quote).join(', ')) + ')';
  }
  if (['contains', 'startsWith', 'endsWith'].includes(bare)) return (neg ? '!' : '') + ref + '.' + bare + '(' + quote(value ?? '') + ')';
  if (bare === 'containsAny' || bare === 'containsAll') { if (!list.length) throw Error('Enter at least one value.'); return ref + '.' + bare + '(' + list.map(quote).join(', ') + ')'; }
  if (kind === 'checkbox') return ref + ' == ' + (value === true || value === 'true');
  if (kind === 'number') { if (value === '' || !Number.isFinite(Number(value))) throw Error('Enter a valid number.'); return ref + ' ' + op + ' ' + Number(value); }
  if (kind === 'date') { if (!/^\d{4}-\d{2}-\d{2}/.test(String(value))) throw Error('Choose a date.'); return ref + ' ' + op + ' date(' + quote(value) + ')'; }
  return ref + ' ' + op + ' ' + quote(value ?? '');
}

// Keeps nested groups and arbitrary expressions authored in Obsidian editable
// without flattening them. `onchange` fires after every valid edit.
export function filterEditor(rule, columns, displayName, types = {}, onchange = () => {}) {
  const wrapper = el('div', null, 'filter-editor');
  const notify = () => { try { root.read(); wrapper.classList.remove('invalid'); onchange(); } catch (e) { wrapper.classList.add('invalid'); } };
  function node(value, parent, remove, depth) {
    const row = el('div', null, 'filter-rule'); parent.append(row);
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      row.classList.add('filter-group');
      const key = Object.keys(value)[0] ?? 'and';
      const mode = select([['and', 'All the following are true'], ['or', 'Any of the following are true'], ['not', 'None of the following are true']], key);
      mode.setAttribute('aria-label', 'Match conditions'); mode.onchange = notify;
      const bar = el('div', null, 'filter-group-heading'), children = el('div', null, 'filter-children'), getters = [];
      bar.append(mode); if (remove) bar.append(iconButton('trash', 'Remove group', () => { remove(); notify(); }));
      row.append(bar, children);
      const add = v => { let get; get = node(v, children, () => { get.node.remove(); getters.splice(getters.indexOf(get), 1); }, depth + 1); getters.push(get); };
      (value[key] ?? []).forEach(add);
      const controls = el('div', null, 'filter-add');
      controls.append(button('+ Add filter', () => { add(''); }), ...(depth < 4 ? [button('+ Add filter group', () => { add({and:['']}); })] : []));
      row.append(controls);
      return {node:row, read:() => ({[mode.value]:getters.map(get => get.read()).filter(v => v != null)})};
    }
    let parsed = value ? simpleRule(value) : {column:columns[0] ?? 'file.name', op:null, value:''}, advanced = !parsed, source = value || '';
    const content = el('div', null, 'filter-condition'), bar = el('div', null, 'filter-rule-actions');
    const code = iconButton('code', 'Advanced filter', () => {
      try {
        const current = read();
        if (!advanced) { advanced = true; source = current ?? ''; }
        else { const next = simpleRule(current ?? ''); if (current && !next) throw Error('This filter is too complex for the point-and-click editor.'); advanced = false; parsed = next ?? {column:columns[0], op:null, value:''}; }
        mount();
      } catch (e) { code.title = e.message; code.classList.add('error'); setTimeout(() => { code.classList.remove('error'); code.title = 'Advanced filter'; }, 2200); }
    });
    bar.append(code); if (remove) bar.append(iconButton('trash', 'Remove filter', () => { remove(); notify(); }));
    row.append(content, bar);
    let read;
    function mount() {
      content.replaceChildren(); code.classList.toggle('active', advanced);
      if (advanced) {
        const field = el('textarea'); field.value = source; field.rows = 1; field.placeholder = 'status != "done"'; field.className = 'filter-expression';
        field.setAttribute('aria-label', 'Filter expression'); field.spellcheck = false;
        const error = el('div', '', 'filter-error');
        field.oninput = () => { source = field.value; try { if (field.value.trim()) expression(field.value); error.textContent = ''; notify(); } catch (e) { error.textContent = e.message; } };
        content.append(field, error); read = () => { const v = field.value.trim(); if (v) expression(v); return v || null; }; return;
      }
      const options = [...new Set([...(parsed?.column ? [parsed.column] : []), ...columns])];
      const property = select(options.map(c => [c, displayName(c)]), parsed.column ?? options[0]); property.setAttribute('aria-label', 'Filter property');
      let kind = kindOf(property.value, types);
      const operator = select(operators[kind], parsed.op ?? operators[kind][0][0]); operator.setAttribute('aria-label', 'Filter operator');
      const valueHolder = el('span', null, 'filter-value');
      let valueField;
      const makeValue = () => {
        valueHolder.replaceChildren();
        if (operator.value.endsWith('isEmpty')) { valueField = null; return; }
        if (kind === 'checkbox') valueField = select([['true', 'Checked'], ['false', 'Unchecked']], String(parsed.value ?? true));
        else { valueField = input(parsed.value ?? '', kind === 'date' ? 'date' : 'text'); if (kind === 'number') valueField.inputMode = 'decimal';
          valueField.placeholder = ['list', 'tags', 'links'].includes(kind) || operator.value.startsWith('containsA') ? 'value, value…' : kind === 'folder' ? 'Folder' : 'Value'; }
        valueField.setAttribute('aria-label', 'Filter value'); valueField.oninput = valueField.onchange = notify; valueHolder.append(valueField);
      };
      property.onchange = () => {
        kind = kindOf(property.value, types); parsed = {column:property.value, op:null, value:''};
        operator.replaceChildren(...operators[kind].map(([k, label]) => { const o = el('option', label); o.value = k; return o; }));
        operator.value = operators[kind][0][0]; makeValue(); notify();
      };
      operator.onchange = () => { parsed = {...parsed, op:operator.value, value:valueField?.value ?? parsed.value}; makeValue(); notify(); };
      makeValue(); content.append(property, operator, valueHolder);
      read = () => build(property.value, operator.value, valueField ? valueField.value : '', kind);
    }
    mount(); return {node:row, read:() => read()};
  }
  const root = node(rule == null ? {and:[]} : typeof rule === 'string' ? {and:[rule]} : rule, wrapper, null, 0);
  return {node:wrapper, read:() => { const value = root.read(); return Object.keys(value)[0] === 'and' && !value.and.length ? null : value; }};
}
export {menu};
