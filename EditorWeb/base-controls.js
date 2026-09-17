import {expression, propertyExpression} from './obsidian-model.js';
import {el, button, iconButton, field, input, select} from './obsidian-ui.js';

const operators = [['==','is'],['!=','is not'],['contains','contains'],['!contains','does not contain'],['startsWith','starts with'],['>','greater than'],['<','less than'],['>=','at least'],['<=','at most'],['isEmpty','is empty'],['!isEmpty','is not empty']];
const reference = propertyExpression;
function simpleRule(rule) {
  try {
    let tree = expression(rule), op = tree.op, target = tree.left, value = tree.right;
    const negated = tree.unary === '!'; if (negated) tree = tree.value;
    if (tree.call?.object) {
      op = (negated ? '!' : '') + tree.call.key.string; target = tree.call.object; value = tree.args[0];
    }
    if (!operators.some(([key]) => key === op)) return;
    const column = target?.id && !['file','note','formula'].includes(target.id) ? target.id :
      ['note','file','formula'].includes(target?.object?.id) && typeof target.key?.string === 'string' ? target.object.id + '.' + target.key.string : null;
    if (!column) return;
    const literal = value == null ? '' : Object.hasOwn(value,'string') ? value.string : Object.hasOwn(value,'number') ? value.number :
      value.id === 'true' ? true : value.id === 'false' ? false : value.id === 'null' ? null : undefined;
    if (literal === undefined) return;
    return {column, op, value:literal};
  } catch {}
}

// Keep arbitrary existing expressions and nested groups editable without flattening
// or discarding filters authored in Obsidian.
export function filterEditor(rule, columns, displayName) {
  const wrapper = el('div', null, 'filter-editor');
  function build(value, parent, remove) {
    const row = el('div', null, 'filter-rule'); parent.append(row);
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      row.classList.add('filter-group');
      const key = Object.keys(value)[0], mode = select([['and','All of these'],['or','Any of these'],['not','None of these']], key);
      mode.setAttribute('aria-label','Match conditions');
      const bar = el('div', null, 'filter-group-heading'), children = el('div', null, 'filter-children'), getters = [];
      bar.append(mode); if (remove) bar.append(iconButton('close','Remove group',remove));
      row.append(bar, children);
      const add = v => { let get; get = build(v, children, () => { get.node.remove(); getters.splice(getters.indexOf(get),1); }); getters.push(get); };
      (value[key] ?? []).forEach(add);
      const controls = el('div', null, 'filter-add');
      controls.append(button('+ Condition', () => add('')), button('+ Group', () => add({and:['']})));
      row.append(controls);
      return {node:row, read:() => ({[mode.value]:getters.map(get => get.read()).filter(v => v != null)})};
    }
    let parsed = value ? simpleRule(value) : {column:columns[0] ?? 'file.name',op:'==',value:''};
    const mode = select([['condition','Condition'],['expression','Expression']], parsed ? 'condition' : 'expression');
    mode.setAttribute('aria-label','Filter type');
    const content = el('div', null, 'filter-condition'), bar = el('div', null, 'filter-rule-heading');
    bar.append(mode); if (remove) bar.append(iconButton('close','Remove condition',remove)); row.append(bar,content);
    let read;
    function mount() {
      content.replaceChildren();
      if (mode.value === 'expression') {
        const source = input(value || ''); source.placeholder = 'status == "reading"'; source.setAttribute('aria-label','Filter expression');
        content.append(source); read = () => { const v = source.value.trim(); if (v) expression(v); return v || null; }; return;
      }
      const property = select([...new Set([...(parsed ? [parsed.column] : []), ...columns])].map(c=>[c,displayName(c)]), parsed?.column ?? columns[0]);
      const operator = select(operators, parsed?.op ?? '==');
      const kind = select([['text','Text'],['number','Number'],['boolean','Checkbox'],['null','No value']], parsed?.value === null ? 'null' : typeof parsed?.value === 'number' ? 'number' : typeof parsed?.value === 'boolean' ? 'boolean' : 'text');
      const text = input(parsed?.value ?? ''), boolean = select([['true','Checked'],['false','Unchecked']], String(parsed?.value ?? true));
      property.setAttribute('aria-label','Filter property'); operator.setAttribute('aria-label','Filter operator');
      kind.setAttribute('aria-label','Value type'); text.setAttribute('aria-label','Filter value'); boolean.setAttribute('aria-label','Checkbox value');
      const typed = el('div', null, 'filter-value'); typed.append(kind,text,boolean); content.append(property,operator,typed);
      const sync = () => { typed.hidden = operator.value.endsWith('isEmpty'); text.hidden = kind.value === 'boolean' || kind.value === 'null'; boolean.hidden = kind.value !== 'boolean'; text.type = kind.value === 'number' ? 'number' : 'text'; };
      operator.onchange = kind.onchange = sync; sync();
      read = () => {
        const ref = reference(property.value), op = operator.value;
        if (op.endsWith('isEmpty')) return (op[0] === '!' ? '!' : '') + ref + '.isEmpty()';
        let literal = text.value;
        if (kind.value === 'number') { if (!text.value.trim() || !Number.isFinite(Number(text.value))) throw Error('Enter a valid filter number.'); literal = Number(text.value); }
        if (kind.value === 'boolean') literal = boolean.value === 'true';
        if (kind.value === 'null') literal = null;
        return ['contains','!contains','startsWith'].includes(op) ? (op[0] === '!' ? '!' : '') + ref + '.' + op.replace('!','') + '(' + JSON.stringify(literal) + ')' : ref + ' ' + op + ' ' + JSON.stringify(literal);
      };
    }
    mode.onchange = () => {
      try {
        const draft = read() ?? '', next = simpleRule(draft);
        if (mode.value === 'condition' && draft && !next) throw Error('Keep Expression mode for this condition.');
        value = draft; parsed = next; mount();
      } catch(e) { mode.value = mode.value === 'condition' ? 'expression' : 'condition'; mode.setCustomValidity(e.message); mode.reportValidity(); }
    };
    mode.oninput = () => mode.setCustomValidity('');
    mount(); return {node:row, read:() => read()};
  }
  const root = build(rule == null ? {and:[]} : typeof rule === 'string' ? {and:[rule]} : rule, wrapper);
  return {node:wrapper, read:() => { const value = root.read(); return Object.keys(value)[0] === 'and' && !value.and.length ? null : value; }};
}
