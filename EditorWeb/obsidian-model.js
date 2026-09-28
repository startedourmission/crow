import { parse, parseDocument } from 'yaml';
import {expression, evaluate, display, compare, isEmptyValue, parseDate, markDateOnly, Link, CellError, summarize, truthy} from './bases-engine.js';
export {expression, evaluate, display, compare, Link, CellError} from './bases-engine.js';
export const emptyValue = isEmptyValue;
const own = (o, k) => o != null && Object.hasOwn(o, k) ? o[k] : null;
const unsafeKey = key => ['__proto__', 'constructor', 'prototype'].includes(key);
export function yaml(source) { return parse(source, { maxAliasCount: 30, uniqueKeys: true }) ?? {}; }

// ---------------------------------------------------------------- JSON Canvas
const nodeTypes = ['text', 'file', 'link', 'group'];
// Keep every node and edge exactly as authored. Entries this editor cannot draw are
// reported and preserved on save instead of making the whole canvas unreadable.
export function canvas(source) {
  const doc = source.trim() ? JSON.parse(source) : {};
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) throw Error('Invalid Canvas document.');
  if (doc.nodes != null && !Array.isArray(doc.nodes) || doc.edges != null && !Array.isArray(doc.edges)) throw Error('Invalid Canvas document.');
  const nodes = doc.nodes ?? [], edges = doc.edges ?? [], ids = new Set(), issues = [];
  for (const n of nodes) {
    if (!n || typeof n !== 'object' || typeof n.id !== 'string') { issues.push('A card without an id was skipped.'); continue; }
    if (ids.has(n.id)) issues.push('Duplicate card id ' + n.id + ' was skipped.');
    else if (!['x', 'y', 'width', 'height'].every(k => Number.isFinite(n[k]))) issues.push('Card ' + n.id + ' has no position and was skipped.');
    ids.add(n.id);
  }
  for (const e of edges) if (!e || !ids.has(e.fromNode) || !ids.has(e.toNode)) issues.push('A connection to a missing card was skipped.');
  return {...doc, nodes, edges, issues:[...new Set(issues)]};
}
export function drawableNodes(doc) {
  const seen = new Set();
  return doc.nodes.filter(n => n && typeof n === 'object' && typeof n.id === 'string' && !seen.has(n.id) && seen.add(n.id) &&
    ['x', 'y', 'width', 'height'].every(k => Number.isFinite(n[k])));
}
export const knownNodeType = type => nodeTypes.includes(type);
export function serializeCanvas(doc) {
  const {issues, ...rest} = doc;
  // Obsidian writes tab-indented JSON; keep the same shape for clean diffs.
  return JSON.stringify(rest, null, '\t') + '\n';
}

// ---------------------------------------------------------------- .base editing
// Edit the YAML syntax tree so comments and unrecognized plugin settings survive.
const viewKeys = new Set(['name', 'type', 'order', 'filters', 'sort', 'groupBy', 'columnSize', 'limit', 'summaries', 'rowHeight',
  'image', 'imageFit', 'imageAspectRatio', 'cardSize', 'markers', 'indentProperties', 'separator', 'hideEmptyColumns', 'columnWidth', 'groupOrder']);
export function updateBaseView(source, index, changes) {
  const value = yaml(source), doc = parseDocument(source);
  const views = Array.isArray(value.views) ? value.views : [];
  if (!Number.isInteger(index) || index < 0 || index > views.length) throw Error('Missing Base view.');
  if (!Array.isArray(value.views)) doc.set('views', doc.createNode([]));
  if (index === views.length) doc.addIn(['views'], doc.createNode({type: 'table', name: 'Table', order: ['file.name']}));
  for (const [key, value] of Object.entries(changes)) {
    if (!viewKeys.has(key)) throw Error('Unsupported view setting: ' + key);
    if (key === 'type' && (typeof value !== 'string' || !value.trim())) throw Error('Unsupported view type.');
    if (value == null) doc.deleteIn(['views', index, key]);
    else doc.setIn(['views', index, key], value);
  }
  return doc.toString();
}
export function removeBaseView(source, index) {
  const doc = parseDocument(source), views = yaml(source).views ?? [];
  if (views.length <= 1) throw Error('A Base needs at least one view.');
  doc.deleteIn(['views', index]); return doc.toString();
}
export function moveBaseView(source, from, to) {
  const doc = parseDocument(source), seq = doc.get('views');
  if (!seq?.items || from === to || to < 0 || to >= seq.items.length) return source;
  const [item] = seq.items.splice(from, 1); seq.items.splice(to, 0, item); return doc.toString();
}
export function duplicateBaseView(source, index) {
  const doc = parseDocument(source), view = yaml(source).views?.[index];
  if (!view) throw Error('Missing Base view.');
  const names = new Set(yaml(source).views.map(v => v.name));
  let name = (view.name || 'View') + ' copy', n = 2; while (names.has(name)) name = (view.name || 'View') + ' copy ' + n++;
  doc.get('views').items.splice(index + 1, 0, doc.createNode({...structuredClone(view), name}));
  return doc.toString();
}
export function updateBaseFilters(source, index, scope, rule) {
  const parsed = yaml(source), before = scope === 'view' ? parsed.views[index].filters : parsed.filters;
  if (JSON.stringify(before ?? null) === JSON.stringify(rule ?? null)) return source;
  if (scope === 'view') return updateBaseView(source, index, {filters:rule});
  if (scope !== 'all') throw Error('Invalid filter scope.');
  const doc = parseDocument(source);
  if (rule == null) doc.delete('filters'); else doc.set('filters', rule);
  return doc.toString();
}
export function updateBaseFormula(source, index, name, value, previous = null) {
  name = name.trim();
  if (!name || unsafeKey(name) || /[.\[\]"]/.test(name)) throw Error('Enter a formula name without dots or brackets.');
  expression(value);
  const doc = parseDocument(source), parsed = yaml(source), column = 'formula.' + name;
  if (previous && previous !== name) {
    if (own(parsed.formulas, name) != null) throw Error('A formula named “' + name + '” already exists.');
    doc.deleteIn(['formulas', previous]);
    (parsed.views ?? []).forEach((view, i) => {
      if (Array.isArray(view.order)) doc.setIn(['views', i, 'order'], view.order.map(c => c === 'formula.' + previous ? column : c));
      if (view.sort) doc.setIn(['views', i, 'sort'], view.sort.map(s => s.property === 'formula.' + previous ? {...s, property:column} : s));
      if (view.groupBy?.property === 'formula.' + previous) doc.setIn(['views', i, 'groupBy', 'property'], column);
    });
    if (own(parsed.properties, 'formula.' + previous)) { doc.setIn(['properties', column], parsed.properties['formula.' + previous]); doc.deleteIn(['properties', 'formula.' + previous]); }
  }
  doc.setIn(['formulas', name], value);
  if (index != null && parsed.views?.[index]) {
    const order = parsed.views[index].order ?? ['file.name'];
    if (!order.includes(column) && !(previous && order.includes('formula.' + previous))) doc.setIn(['views', index, 'order'], [...order, column]);
  }
  return doc.toString();
}
export function removeBaseFormula(source, name) {
  const doc = parseDocument(source), parsed = yaml(source), column = 'formula.' + name;
  doc.deleteIn(['formulas', name]);
  (parsed.views ?? []).forEach((view, i) => {
    if (Array.isArray(view.order) && view.order.includes(column)) doc.setIn(['views', i, 'order'], view.order.filter(c => c !== column));
  });
  if (parsed.formulas && Object.keys(parsed.formulas).length === 1 && own(parsed.formulas, name) != null) doc.delete('formulas');
  return doc.toString();
}
export function propertyConfig(doc, column) {
  const props = doc?.properties;
  if (!props || typeof props !== 'object') return null;
  const bare = column.replace(/^note\./, '');
  return own(props, column) ?? own(props, bare) ?? own(props, 'note.' + bare);
}
export function updateBaseProperty(source, column, patch) {
  const doc = parseDocument(source), parsed = yaml(source), props = parsed.properties ?? {};
  const bare = column.replace(/^note\./, '');
  const key = Object.hasOwn(props, column) ? column : Object.hasOwn(props, bare) ? bare : Object.hasOwn(props, 'note.' + bare) ? 'note.' + bare : column;
  for (const [name, value] of Object.entries(patch)) {
    if (value == null || value === '') doc.deleteIn(['properties', key, name]); else doc.setIn(['properties', key, name], value);
  }
  const after = yaml(doc.toString()).properties;
  if (after && after[key] && !Object.keys(after[key]).length) doc.deleteIn(['properties', key]);
  if (after && !Object.keys(yaml(doc.toString()).properties ?? {}).length) doc.delete('properties');
  return doc.toString();
}
export function updateBaseSummaryFormula(source, name, formula) {
  if (!name.trim() || unsafeKey(name)) throw Error('Enter a summary name.');
  expression(formula);
  const doc = parseDocument(source); doc.setIn(['summaries', name.trim()], formula); return doc.toString();
}

export function noteProperty(column) {
  if (typeof column !== 'string' || column.startsWith('file.') || column.startsWith('formula.')) return null;
  const name = column.startsWith('note.') ? column.slice(5) : column;
  return name && !unsafeKey(name) ? name : null;
}
export function propertyExpression(column) {
  const match = /^(file|formula|note)\.(.*)$/s.exec(column);
  return (match ? match[1] : 'note') + '[' + JSON.stringify(match ? match[2] : column) + ']';
}

const scalar = value => value == null || typeof value === 'string' || typeof value === 'boolean' || typeof value === 'number' && Number.isFinite(value);
export function updateNoteProperty(source, column, value) {
  const name = noteProperty(column);
  if (!name) throw Error('Only note properties can be edited.');
  if (typeof source !== 'string') throw Error('This note has not been loaded.');
  if (!(scalar(value) || Array.isArray(value) && value.every(v => scalar(v) && v != null))) throw Error('Unsupported property value.');
  const start = source.match(/^﻿?---\r?\n/), bom = source.startsWith('﻿') ? '﻿' : '';
  const newline = source.includes('\r\n') ? '\r\n' : '\n';
  let body = source.slice(bom.length), frontmatter = '';
  if (start) {
    const rest = source.slice(start[0].length), end = /^---[ \t]*(?:\r?\n|$)/m.exec(rest);
    if (!end) throw Error('The note has unclosed frontmatter.');
    frontmatter = rest.slice(0, end.index); body = rest.slice(end.index + end[0].length);
  }
  const parsed = yaml(frontmatter);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw Error('Invalid note properties.');
  const doc = parseDocument(frontmatter);
  if (value == null) doc.delete(name); else doc.set(name, value);
  const properties = doc.toString().replace(/\r?\n/g, newline);
  if (!start && value == null) return source;
  return bom + '---' + newline + (properties.trim() ? properties : '') + '---' + newline + body;
}

// ---------------------------------------------------------------- notes
const recordsCache = new WeakMap();
const withoutCode = text => text.replace(/^(```|~~~)[^\n]*\n[\s\S]*?(?:\n\1[^\n]*|$)/gm, '').replace(/`[^`\n]*`/g, '').replace(/<!--[\s\S]*?-->|%%[\s\S]*?%%/g, '');
function frontmatterLinks(value, out) {
  if (typeof value === 'string') { for (const m of value.matchAll(/\[\[([^\]\n]+)\]\]/g)) out.push(new Link('[[' + m[1] + ']]')); }
  else if (Array.isArray(value)) value.forEach(v => frontmatterLinks(v, out));
  else if (value && typeof value === 'object') Object.values(value).forEach(v => frontmatterLinks(v, out));
}
function typed(value, type) {
  if (value == null) return value;
  if (typeof value === 'string') {
    const wiki = value.trim().match(/^!?\[\[[^\]\n]+\]\]$/);
    if (wiki) return new Link(value.trim());
    if (type === 'date' || type === 'datetime') {
      const d = parseDate(value); if (d) return type === 'date' ? markDateOnly(new Date(d.getFullYear(), d.getMonth(), d.getDate())) : d;
    }
    if (type === 'number' && value.trim() && Number.isFinite(Number(value))) return Number(value);
    if (type === 'checkbox' && /^(true|false)$/i.test(value)) return value.toLowerCase() === 'true';
    if (type === 'multitext' || type === 'tags' || type === 'aliases') return [value];
    return value;
  }
  if (Array.isArray(value)) return value.map(v => typed(v, type === 'multitext' || type === 'tags' || type === 'aliases' ? 'text' : type));
  return value;
}
const internal = target => target && !/^[a-z][a-z0-9+.-]*:/i.test(target) && !target.startsWith('#');
export function record(file, types = null) {
  const cached = recordsCache.get(file);
  if (cached && cached.text === file.text && cached.modified === file.modified && cached.created === file.created && cached.size === file.size &&
      cached.path === file.path && cached.types === types) return cached.value;
  const match = file.text?.match(/^﻿?---\r?\n([\s\S]*?)\r?\n?---[ \t]*(?:\r?\n|$)/);
  const raw = match ? yaml(match[1]) : {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw Error('Invalid frontmatter in ' + file.path);
  const note = {};
  for (const [key, value] of Object.entries(raw)) if (!unsafeKey(key)) note[key] = typed(value, types?.[key] ?? (key === 'tags' ? 'tags' : key === 'aliases' ? 'aliases' : null));
  const name = file.path.split('/').pop(), dot = name.lastIndexOf('.');
  const body = typeof file.text === 'string' ? withoutCode(match ? file.text.slice(match[0].length) : file.text) : '';
  const tags = new Set();
  for (const key of ['tags', 'tag']) for (const tag of [raw[key]].flat(Infinity)) {
    if (tag == null) continue;
    for (const t of String(tag).split(/[,\s]+/)) { const clean = t.replace(/^#/, '').trim(); if (clean) tags.add('#' + clean); }
  }
  for (const m of body.matchAll(/(?:^|[\s(\[{,;])#([\p{L}\p{N}_\/-]*[\p{L}_\/-][\p{L}\p{N}_\/-]*)/gu)) tags.add('#' + m[1]);
  const links = [], embeds = [];
  frontmatterLinks(raw, links);
  for (const m of body.matchAll(/(!?)\[\[([^\]\n]+)\]\]/g)) (m[1] ? embeds : links).push(new Link('[[' + m[2] + ']]', null, !!m[1]));
  for (const m of body.matchAll(/(!?)\[([^\]\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g)) {
    let target = m[3]; if (!internal(target)) continue;
    try { target = decodeURI(target); } catch {}
    (m[1] ? embeds : links).push(new Link(target, m[1] ? null : m[2] || null, !!m[1]));
  }
  const fields = {
    name, basename:dot > 0 ? name.slice(0, dot) : name, path:file.path, ext:dot > 0 ? name.slice(dot + 1) : '',
    folder:file.path.includes('/') ? file.path.slice(0, file.path.lastIndexOf('/')) : '', size:file.size ?? (typeof file.text === 'string' ? new TextEncoder().encode(file.text).length : null),
    ctime:file.created ? new Date(file.created * 1000) : null, mtime:file.modified ? new Date(file.modified * 1000) : null,
    properties:note, tags:[...tags], links, embeds
  };
  const value = {note, raw, file:{__file:true, path:file.path, name, basename:fields.basename, fields}, source:file};
  recordsCache.set(file, {text:file.text, modified:file.modified, created:file.created, size:file.size, path:file.path, types, value});
  return value;
}

// Obsidian resolves a link by exact path first, then by file name, preferring the
// closest match to the linking note.
const indexes = new WeakMap();
function linkIndex(files) {
  let index = indexes.get(files);
  if (index) return index;
  const byPath = new Map(), byName = new Map();
  const add = (map, key, path) => { key = key.toLowerCase(); const list = map.get(key); if (list) list.push(path); else map.set(key, [path]); };
  for (const file of files) {
    const path = file.path; byPath.set(path.toLowerCase(), path);
    const name = path.split('/').pop();
    add(byName, name, path);
    if (/\.md$/i.test(name)) { add(byName, name.slice(0, -3), path); byPath.set(path.slice(0, -3).toLowerCase(), byPath.get(path.slice(0, -3).toLowerCase()) ?? path); }
  }
  index = {byPath, byName, cache:new Map()}; indexes.set(files, index); return index;
}
export function resolver(files) {
  const index = linkIndex(files);
  return (target, from = '') => {
    if (target == null) return null;
    let clean = String(target).trim().replace(/^\/+/, '');
    const key = from + '\0' + clean, hit = index.cache.get(key);
    if (hit !== undefined) return hit;
    let result = null;
    if (!clean) result = from || null;
    else {
      const folder = from.includes('/') ? from.slice(0, from.lastIndexOf('/')) : '';
      const relative = (folder ? folder + '/' : '') + clean, normalized = [];
      for (const part of relative.split('/')) { if (part === '..') normalized.pop(); else if (part !== '.' && part) normalized.push(part); }
      result = index.byPath.get(clean.toLowerCase()) ?? index.byPath.get(normalized.join('/').toLowerCase()) ?? null;
      if (!result) {
        const name = clean.split('/').pop(), suffix = clean.includes('/') ? '/' + clean.toLowerCase() : null;
        let candidates = index.byName.get(name.toLowerCase()) ?? [];
        if (suffix) candidates = candidates.filter(p => ('/' + p.toLowerCase()).endsWith(suffix) || ('/' + p.toLowerCase()).endsWith(suffix + '.md'));
        if (candidates.length) {
          result = candidates.find(p => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '') === folder) ??
            [...candidates].sort((a, b) => a.split('/').length - b.split('/').length || a.length - b.length)[0];
        }
      }
    }
    if (index.cache.size > 20000) index.cache.clear();
    index.cache.set(key, result); return result;
  };
}

// ---------------------------------------------------------------- evaluation
export function filter(rule, ctx) {
  if (rule == null) return true;
  if (typeof rule === 'string') return rule.trim() ? truthy(evaluate(expression(rule), ctx)) : true;
  if (typeof rule !== 'object' || Array.isArray(rule)) throw Error('Invalid Base filter.');
  const keys = Object.keys(rule);
  if (keys.length !== 1 || !['and', 'or', 'not'].includes(keys[0]) || !Array.isArray(rule[keys[0]] ?? [])) throw Error('Invalid Base filter group.');
  const values = rule[keys[0]] ?? [];
  return keys[0] === 'and' ? values.every(r => filter(r, ctx)) : keys[0] === 'or' ? values.some(r => filter(r, ctx)) : !values.some(r => filter(r, ctx));
}
export const builtInLayouts = ['table', 'cards', 'list', 'kanban'];
export function columnValue(ctx, column) {
  try { return evaluate(expression(propertyExpression(column)), ctx); }
  catch (e) { return new CellError(e.message); }
}
// Shared evaluation context for one Base render: link index, backlinks and records.
export function baseContext(source, files, path, options = {}) {
  const doc = typeof source === 'string' ? yaml(source) : source;
  const records = [], byPath = new Map(), warnings = [];
  let unreadable = 0;
  for (const file of files) {
    try { const r = record(file, options.types ?? null); records.push(r); byPath.set(file.path, r); }
    catch { unreadable++; if (unreadable <= 3) warnings.push('Could not read properties in ' + file.path + '. Fix its frontmatter to include it.'); }
  }
  if (unreadable > 3) warnings.push((unreadable - 3) + ' more notes have invalid properties.');
  const resolve = resolver(files);
  let backlinks = null;
  const shared = {
    resolve, formulas:doc.formulas ?? {},
    fileAt: p => p ? byPath.get(p)?.file ?? null : null,
    backlinks: target => {
      if (!backlinks) {
        backlinks = new Map();
        for (const r of records) for (const link of r.file.fields.links) {
          const to = resolve(link.path, r.file.path); if (!to) continue;
          const list = backlinks.get(to); const entry = new Link(r.file.path);
          if (!list) backlinks.set(to, [entry]); else if (!list.some(l => l.path === r.file.path)) list.push(entry);
        }
      }
      return backlinks.get(target) ?? [];
    }
  };
  const embedding = options.thisPath ?? path;
  const current = byPath.get(embedding) ?? record({path:embedding ?? 'Untitled.base'}, options.types ?? null);
  shared.this = {__this:true, ...current.note, file:current.file};
  const contextFor = r => ({...shared, file:r.file, note:r.note, memo:new Map(), property:id => Object.hasOwn(r.note, id) ? r.note[id] : null});
  return {doc, records, warnings, shared, contextFor};
}
export function base(source, files, path, viewIndex = 0, options = {}) {
  const doc = yaml(source);
  if (!Array.isArray(doc.views) || !doc.views.length) throw Error('This Base has no views.');
  const view = doc.views[viewIndex]; if (!view || typeof view !== 'object') throw Error('Missing Base view.');
  const context = baseContext(doc, files, path, options), warnings = [...context.warnings];
  if (view.type != null && !builtInLayouts.includes(view.type)) warnings.push('The “' + view.type + '” layout is provided by a plugin. Showing it as a table; its settings are preserved.');
  const columns = view.order ?? ['file.name'];
  if (!Array.isArray(columns) || columns.some(c => typeof c !== 'string')) throw Error('Invalid Base columns.');
  if (view.sort != null && !Array.isArray(view.sort)) throw Error('Invalid Base sort.');
  for (const rule of [doc.filters, view.filters]) validateFilter(rule);
  let failed = 0, failure = '';
  const rows = [];
  for (const r of context.records) {
    const ctx = context.contextFor(r);
    try { if (filter(doc.filters, ctx) && filter(view.filters, ctx)) rows.push({record:r, ctx}); }
    catch (e) { failed++; failure ||= e.message; }
  }
  if (failed) warnings.push('Filter error in ' + failed + (failed === 1 ? ' file' : ' files') + ': ' + failure);
  const sort = [...(view.groupBy?.property ? [view.groupBy] : []), ...(view.sort ?? []).filter(s => s?.property)];
  const keyed = rows.map(row => ({...row, keys:sort.map(s => columnValue(row.ctx, s.property))}));
  keyed.sort((a, b) => {
    for (let i = 0; i < sort.length; i++) {
      const av = a.keys[i], bv = b.keys[i], ae = isEmptyValue(av), be = isEmptyValue(bv);
      if (ae !== be) return ae ? 1 : -1;
      const v = ae ? 0 : compare(av, bv) * (String(sort[i].direction).toUpperCase() === 'DESC' ? -1 : 1);
      if (v) return v;
    }
    return compare(a.record.file.path, b.record.file.path);
  });
  const limited = Number.isInteger(view.limit) && view.limit > 0 ? keyed.slice(0, view.limit) : keyed;
  const result = limited.map(row => ({
    path:row.record.file.path, file:row.record.file, record:row.record, ctx:row.ctx,
    group:view.groupBy?.property ? row.keys[0] : null, cells:columns.map(c => columnValue(row.ctx, c))
  }));
  return {doc, view, columns, warnings, rows:result, total:keyed.length, context};
}
function validateFilter(rule) {
  if (rule == null) return;
  if (typeof rule === 'string') { if (rule.trim()) expression(rule); return; }
  if (typeof rule !== 'object' || Array.isArray(rule)) throw Error('Invalid Base filter.');
  const keys = Object.keys(rule);
  if (keys.length !== 1 || !['and', 'or', 'not'].includes(keys[0]) || !Array.isArray(rule[keys[0]] ?? [])) throw Error('Invalid Base filter group.');
  (rule[keys[0]] ?? []).forEach(validateFilter);
}
export function groupRows(rows) {
  const groups = [];
  for (const row of rows) {
    const last = groups.at(-1);
    if (last && (last.key === row.group || isEmptyValue(last.key) && isEmptyValue(row.group) || display(last.key) === display(row.group) && !isEmptyValue(row.group))) last.rows.push(row);
    else groups.push({key:row.group, rows:[row]});
  }
  return groups;
}
export function summaryValue(result, rows, column, name) {
  const index = result.columns.indexOf(column);
  const values = rows.map(row => index >= 0 ? row.cells[index] : columnValue(row.ctx, column));
  try { return summarize(name, values, result.doc.summaries ?? {}, result.context?.shared ?? {}); }
  catch (e) { return new CellError(e.message); }
}

// Property types: .obsidian/types.json wins, otherwise infer from the vault's values
// the same way Obsidian assigns a type when a property is first used.
const typeAliases = {text:'text', multitext:'multitext', number:'number', checkbox:'checkbox', date:'date', datetime:'datetime', tags:'tags', aliases:'aliases'};
export function propertyTypes(records, declared = null) {
  const types = {}, seen = {};
  for (const [key, value] of Object.entries(declared ?? {})) if (typeAliases[value]) types[key] = typeAliases[value];
  for (const r of records) for (const [key, value] of Object.entries(r.raw)) {
    if (types[key] || value == null) continue;
    const kind = Array.isArray(value) ? 'multitext' : typeof value === 'boolean' ? 'checkbox' : typeof value === 'number' ? 'number' :
      typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value.trim()) ? 'date' :
      typeof value === 'string' && /^\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}/.test(value.trim()) ? 'datetime' : 'text';
    (seen[key] ??= new Set()).add(kind);
  }
  for (const [key, kinds] of Object.entries(seen)) {
    if (types[key]) continue;
    types[key] = key === 'tags' ? 'tags' : key === 'aliases' ? 'aliases' : kinds.size === 1 ? [...kinds][0] :
      [...kinds].every(k => k === 'date' || k === 'datetime') ? 'datetime' : kinds.has('multitext') ? 'multitext' : 'text';
  }
  types.tags ??= 'tags'; types.aliases ??= 'aliases';
  return types;
}
const fileTypes = {'file.name':'text', 'file.basename':'text', 'file.path':'text', 'file.folder':'text', 'file.ext':'text', 'file.size':'number',
  'file.ctime':'datetime', 'file.mtime':'datetime', 'file.tags':'tags', 'file.links':'multitext', 'file.embeds':'multitext', 'file.backlinks':'multitext'};
export function columnType(column, types) {
  if (fileTypes[column]) return fileTypes[column];
  if (column.startsWith('formula.')) return 'formula';
  const key = noteProperty(column);
  return key ? types?.[key] ?? 'text' : 'text';
}
