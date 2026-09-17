import {parseDocument, isMap, isScalar} from 'yaml';

export const propertyTypes = [['text','Text'],['number','Number'],['boolean','Checkbox'],['list','List'],['date','Date'],['datetime','Date & time'],['yaml','YAML']];
export function frontmatter(source) {
  const match = /^(\uFEFF?---\r?\n)([\s\S]*?)(^---[ \t]*(?:\r?\n|$))/m.exec(source);
  if (!match || match.index !== 0) throw Error('Invalid frontmatter.');
  const doc = parseDocument(match[2], {uniqueKeys:true});
  if (doc.errors.length) throw doc.errors[0];
  if (doc.contents && !isMap(doc.contents)) throw Error('Properties must be a YAML map.');
  const values = doc.toJS({maxAliasCount:30}) ?? {};
  const rows = Object.entries(values).map(([name,value]) => {
    const node = doc.get(name, true);
    const plain = isScalar(node) && (!node.type || node.type === 'PLAIN');
    const type = typeof value === 'boolean' ? 'boolean' : typeof value === 'number' ? 'number' :
      Array.isArray(value) && value.every(v=>typeof v==='string') ? 'list' : value && typeof value === 'object' ? 'yaml' :
      plain && /^\d{4}-\d{2}-\d{2}$/.test(value ?? '') ? 'date' : plain && /^\d{4}-\d{2}-\d{2}T/.test(value ?? '') ? 'datetime' : 'text';
    return {name,value,type};
  });
  return {doc,rows,prefix:match[1],suffix:source.slice(match[1].length + match[2].length)};
}
export function propertyValue(value, type) {
  if (type === 'text') return Array.isArray(value) ? value.join('\n') : value != null && typeof value === 'object' ? JSON.stringify(value) : String(value ?? '');
  if (type === 'number') {
    if (typeof value === 'boolean' || value == null || String(value).trim() === '') throw Error('Enter a number before choosing Number.');
    const number = Number(value); if (!Number.isFinite(number)) throw Error('Enter a valid number.'); return number;
  }
  if (type === 'boolean') {
    if ([true,1,'true','1'].includes(value)) return true;
    if ([false,0,'false','0','',null,undefined].includes(value)) return false;
    throw Error('Use true or false for a checkbox.');
  }
  if (type === 'list') return Array.isArray(value) ? value.map(String) : String(value ?? '').split(/\r?\n/).filter(v=>v.trim());
  if (type === 'date' || type === 'datetime') {
    const text = String(value ?? '');
    const pattern = type === 'date' ? /^\d{4}-\d{2}-\d{2}$/ : /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})?$/;
    if (text && (!pattern.test(text) || !Number.isFinite(Date.parse(text)))) throw Error('Enter a valid ' + (type === 'date' ? 'date (YYYY-MM-DD).' : 'date and time.'));
    return text;
  }
  if (type === 'yaml') {
    const doc = parseDocument(String(value)); if (doc.errors.length) throw doc.errors[0]; return doc.toJS({maxAliasCount:30});
  }
  throw Error('Unsupported property type.');
}
export function editFrontmatter(source, name, {value, type, rename, remove = false, add = false}) {
  const {doc,prefix,suffix} = frontmatter(source);
  if (!name.trim()) throw Error('Enter a property name.');
  if (add && doc.has(name)) throw Error('This property already exists.');
  if (remove) doc.delete(name);
  else if (rename != null) {
    if (!rename.trim()) throw Error('Enter a property name.');
    if (rename !== name && doc.has(rename)) throw Error('This property already exists.');
    const pair = doc.contents.items.find(p=>String(p.key.value)===name);
    if (!pair) throw Error('Property no longer exists.');
    pair.key = doc.createNode(rename);
  } else {
    doc.set(name, propertyValue(value, type));
    const node = doc.get(name, true);
    // YAML 1.2 dates are plain strings; preserve an explicitly chosen Text type.
    if (isScalar(node) && typeof node.value === 'string') node.type = type === 'text' && /^\d{4}-\d{2}-\d{2}(T|$)/.test(node.value) ? 'QUOTE_DOUBLE' : undefined;
  }
  const newline = prefix.includes('\r\n') ? '\r\n' : '\n';
  return prefix + doc.toString().replace(/\r?\n/g,newline) + suffix;
}
