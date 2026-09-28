// Obsidian Bases expression language: a sandboxed interpreter that never executes
// document text as JavaScript. Semantics follow https://obsidian.md/help/bases/functions.

export class Link {
  constructor(path, display = null, embed = false) {
    const raw = String(path ?? '').trim(), wiki = raw.match(/^(!?)\[\[([^\]]*?)\]\]$/);
    let target = wiki ? wiki[2] : raw, label = display;
    if (wiki) {
      const bar = target.indexOf('|');
      if (bar >= 0) { if (label == null) label = target.slice(bar + 1); target = target.slice(0, bar); }
      embed = embed || wiki[1] === '!';
    }
    const hash = target.indexOf('#');
    this.path = (hash >= 0 ? target.slice(0, hash) : target).trim();
    this.subpath = hash >= 0 ? target.slice(hash) : '';
    this.display = label == null || label === '' ? null : label;
    this.embed = embed;
  }
  get external() { return /^[a-z][a-z0-9+.-]*:/i.test(this.path); }
  toString() { return this.display != null ? display(this.display) : this.path.split('/').pop().replace(/\.md$/i, '') + (this.subpath && !this.path ? this.subpath : ''); }
}
export class Duration {
  constructor(ms = 0, months = 0) { this.ms = ms; this.months = months; }
  toString() { return humanDuration(this); }
}
export class BaseImage { constructor(src) { this.src = src; } toString() { return display(this.src); } }
export class BaseIcon { constructor(name) { this.name = String(name ?? ''); } toString() { return ''; } }
export class BaseHTML { constructor(html) { this.html = String(html ?? ''); } toString() { return this.html.replace(/<[^>]*>/g, ''); } }
export class CellError { constructor(message) { this.error = message; } toString() { return 'Error: ' + this.error; } }

const dateOnly = new WeakSet();
export const markDateOnly = date => { dateOnly.add(date); return date; };
export const isDateOnly = date => dateOnly.has(date);
const isDate = v => v instanceof Date;
const validDate = v => isDate(v) && Number.isFinite(+v);
export const isFile = v => v != null && typeof v === 'object' && v.__file === true;

// ---------------------------------------------------------------- parsing
const cache = new Map();
const precedence = {'||':1,'&&':2,'==':3,'!=':3,'>':4,'<':4,'>=':4,'<=':4,'+':5,'-':5,'*':6,'/':6,'%':6};
function tokenize(source) {
  const tokens = []; let pos = 0;
  const pattern = /\s*(?:(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|([\p{L}_$](?:[\p{L}\p{N}_$]|-(?=\p{L}))*)|(==|!=|>=|<=|&&|\|\||[+\-*/%<>!().,\[\]{}:]))/uy;
  const regex = /\s*\/((?:[^/\\\n[]|\\.|\[(?:[^\]\\\n]|\\.)*\])+)\/([dgimsuy]*)/y;
  while (pos < source.length && source.slice(pos).trim()) {
    const previous = tokens.at(-1);
    const expectsValue = previous == null || (typeof previous === 'string' && !')]}'.includes(previous));
    if (expectsValue) {
      regex.lastIndex = pos; const match = regex.exec(source);
      if (match) { tokens.push({regex:match[1], flags:match[2]}); pos = regex.lastIndex; continue; }
    }
    pattern.lastIndex = pos; const m = pattern.exec(source);
    if (!m) throw Error('Unsupported syntax near: ' + source.slice(pos, pos + 35).trim());
    // Identifiers may contain hyphens (Obsidian property names such as image-property),
    // but "a-b" between two plain names in arithmetic stays subtraction when spaced.
    if (m[1]) tokens.push({number:Number(m[1])});
    else if (m[2]) tokens.push({string:m[2][0] === '"' ? JSON.parse(m[2].replace(/\\'/g, "'")) : m[2].slice(1, -1).replace(/\\(['"\\nt])/g, (_, c) => ({n:'\n', t:'\t'})[c] ?? c)});
    else if (m[3]) tokens.push({id:m[3]});
    else tokens.push(m[4]);
    pos = pattern.lastIndex;
    if (tokens.length > 4000) throw Error('Expression is too complex.');
  }
  return tokens;
}
export function expression(source) {
  if (cache.has(source)) return cache.get(source);
  if (typeof source !== 'string' || source.length > 20000) throw Error('Invalid expression.');
  const tokens = tokenize(source); let i = 0, depth = 0;
  const expect = t => { if (tokens[i++] !== t) throw Error('Expected “' + t + '”.'); };
  const list = close => {
    const items = [];
    if (tokens[i] !== close) { do { items.push(read()); if (tokens[i] !== ',') break; i++; } while (tokens[i] !== close); }
    expect(close); return items;
  };
  function primary() {
    const t = tokens[i++];
    if (t === '!' || t === '-') return {unary:t, value:read(7)};
    if (t === '(') { const node = read(); expect(')'); return node; }
    if (t === '[') return {list:list(']')};
    if (t === '{') {
      const entries = [];
      if (tokens[i] !== '}') do {
        const key = tokens[i++]; const name = key?.string ?? key?.id ?? (key?.number != null ? String(key.number) : null);
        if (name == null) throw Error('Expected an object key.');
        expect(':'); entries.push([name, read()]);
        if (tokens[i] !== ',') break; i++;
      } while (tokens[i] !== '}');
      expect('}'); return {object:entries};
    }
    if (t && typeof t === 'object') return t;
    throw Error(t == null ? 'The expression ended unexpectedly.' : 'Unexpected “' + t + '”.');
  }
  function read(min = 0) {
    if (++depth > 120) throw Error('Expression is too deeply nested.');
    let node = primary();
    while (i < tokens.length) {
      const t = tokens[i];
      if (t === '.') {
        i++; const name = tokens[i++];
        if (!name?.id) throw Error('Expected a property name after “.”.');
        node = {member:node, key:{string:name.id}};
      } else if (t === '[') { i++; const key = read(); expect(']'); node = {member:node, key}; }
      else if (t === '(') { i++; node = {call:node, args:list(')')}; }
      else if (precedence[t] && precedence[t] >= min) { i++; node = {op:t, left:node, right:read(precedence[t] + 1)}; }
      else break;
    }
    depth--; return node;
  }
  const tree = read();
  if (i !== tokens.length) throw Error('Unexpected “' + (tokens[i]?.id ?? tokens[i]?.string ?? tokens[i]) + '”.');
  if (cache.size >= 512) cache.delete(cache.keys().next().value);
  cache.set(source, tree); return tree;
}

// ---------------------------------------------------------------- values
export function display(v) {
  if (v == null) return '';
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return Number.isFinite(v) ? String(Math.round(v * 1e12) / 1e12) : String(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (isDate(v)) return validDate(v) ? formatDate(v, isDateOnly(v) ? 'YYYY-MM-DD' : 'YYYY-MM-DD HH:mm') : '';
  if (Array.isArray(v)) return v.map(display).join(', ');
  if (isFile(v)) return v.basename;
  if (v instanceof Link || v instanceof Duration || v instanceof BaseImage || v instanceof BaseHTML || v instanceof BaseIcon || v instanceof CellError) return v.toString();
  if (v instanceof RegExp) return String(v);
  try { return JSON.stringify(v); } catch { return String(v); }
}
export function truthy(v) {
  if (Array.isArray(v)) return v.length > 0;
  if (isDate(v)) return validDate(v);
  if (v instanceof Duration) return v.ms !== 0 || v.months !== 0;
  if (v instanceof CellError) return false;
  if (v && typeof v === 'object' && !(v instanceof Link) && !isFile(v) && Object.getPrototypeOf(v) === Object.prototype) return Object.keys(v).length > 0;
  return !!v;
}
export function typeOf(v) {
  if (v == null) return 'null';
  if (Array.isArray(v)) return 'list';
  if (isDate(v)) return 'date';
  if (v instanceof Link) return 'link';
  if (isFile(v)) return 'file';
  if (v instanceof Duration) return 'duration';
  if (v instanceof RegExp) return 'regexp';
  if (v instanceof BaseImage) return 'image';
  if (v instanceof BaseIcon) return 'icon';
  if (v instanceof BaseHTML) return 'html';
  return typeof v === 'object' ? 'object' : typeof v;
}
export function isEmptyValue(v) {
  if (v == null) return true;
  if (typeof v === 'string') return !v.trim();
  if (Array.isArray(v)) return v.length === 0 || v.every(isEmptyValue);
  if (isDate(v)) return !validDate(v);
  if (typeof v === 'number') return Number.isNaN(v);
  if (v instanceof Link) return !v.path && !v.subpath;
  if (v instanceof CellError) return false;
  if (typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype) return Object.keys(v).length === 0;
  return false;
}
const list = v => v == null ? [] : Array.isArray(v) ? v : [v];
const text = v => display(v);

const isoDate = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3})\d*)?)?\s*(Z|[+-]\d{2}:?\d{2})?)?$/;
export function parseDate(value) {
  if (isDate(value)) return value;
  if (typeof value === 'number') return new Date(value);
  if (value instanceof Link) value = value.path;
  if (typeof value !== 'string') return null;
  const s = value.trim(), m = s.match(isoDate);
  if (m) {
    if (!m[4]) { const d = new Date(+m[1], +m[2] - 1, +m[3]); return Number.isFinite(+d) ? markDateOnly(d) : null; }
    if (m[8]) { const d = new Date(s.replace(' ', 'T')); return Number.isFinite(+d) ? d : null; }
    const d = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0), +((m[7] ?? '0').padEnd(3, '0')));
    return Number.isFinite(+d) ? d : null;
  }
  if (!s || /^\d+(\.\d+)?$/.test(s)) return null;
  const d = new Date(s); return Number.isFinite(+d) ? d : null;
}
const units = [
  [/^(y|yr|yrs|year|years)$/, 0, 12], [/^(M|month|months|mo)$/, 0, 1], [/^(w|wk|wks|week|weeks)$/, 604800000], [/^(d|day|days)$/, 86400000],
  [/^(h|hr|hrs|hour|hours)$/, 3600000], [/^(m|min|mins|minute|minutes)$/, 60000], [/^(s|sec|secs|second|seconds)$/, 1000], [/^(ms|millisecond|milliseconds)$/, 1]
];
export function parseDuration(value) {
  if (value instanceof Duration) return value;
  if (typeof value === 'number') return new Duration(value);
  if (typeof value !== 'string') throw Error('Invalid duration.');
  let ms = 0, months = 0, matched = false;
  const source = value.trim(), pattern = /([+-]?\d+(?:\.\d+)?)\s*([a-zA-Z]+)\s*,?\s*/y;
  let pos = 0;
  while (pos < source.length) {
    pattern.lastIndex = pos; const m = pattern.exec(source);
    if (!m) throw Error('Invalid duration: ' + value);
    const unit = units.find(([test]) => test.test(m[2]) || (m[2].length > 1 && test.test(m[2].toLowerCase())));
    if (!unit) throw Error('Invalid duration unit: ' + m[2]);
    const n = Number(m[1]);
    if (unit[2]) months += n * unit[2]; else ms += n * unit[1];
    matched = true; pos = pattern.lastIndex;
  }
  if (!matched) throw Error('Invalid duration: ' + value);
  return new Duration(ms, months);
}
function shift(date, duration, sign) {
  const result = new Date(date);
  if (duration.months) {
    const whole = Math.trunc(duration.months) * sign, day = result.getDate();
    result.setDate(1); result.setMonth(result.getMonth() + whole);
    result.setDate(Math.min(day, new Date(result.getFullYear(), result.getMonth() + 1, 0).getDate()));
    const rest = duration.months - Math.trunc(duration.months);
    if (rest) result.setTime(+result + sign * rest * 30 * 86400000);
  }
  result.setTime(+result + sign * duration.ms);
  if (isDateOnly(date) && duration.ms % 86400000 === 0) markDateOnly(result);
  return result;
}
function humanDuration(d) {
  const parts = [];
  if (d.months) { const y = Math.trunc(d.months / 12), m = d.months % 12; if (y) parts.push(y + (Math.abs(y) === 1 ? ' year' : ' years')); if (m) parts.push(m + (Math.abs(m) === 1 ? ' month' : ' months')); }
  let ms = d.ms;
  for (const [unit, size] of [['day', 86400000], ['hour', 3600000], ['minute', 60000], ['second', 1000]]) {
    const n = Math.trunc(ms / size); if (n) { parts.push(n + ' ' + unit + (Math.abs(n) === 1 ? '' : 's')); ms -= n * size; }
  }
  return parts.join(' ') || '0 seconds';
}
const monthNames = ['January','February','March','April','May','June','July','August','September','October','November','December'];
const dayNames = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
const pad = (n, w = 2) => String(Math.abs(n)).padStart(w, '0');
function isoWeek(d) {
  const t = new Date(d.getFullYear(), d.getMonth(), d.getDate()); const day = (t.getDay() + 6) % 7;
  t.setDate(t.getDate() - day + 3); const first = new Date(t.getFullYear(), 0, 4);
  return {week:1 + Math.round(((t - first) / 86400000 - 3 + ((first.getDay() + 6) % 7)) / 7), year:t.getFullYear()};
}
const ordinal = n => n + (n % 100 >= 11 && n % 100 <= 13 ? 'th' : ['th','st','nd','rd'][n % 10] ?? 'th');
// Moment.js format tokens used by Obsidian.
export function formatDate(d, format = 'YYYY-MM-DD') {
  if (!validDate(d)) return '';
  const offset = -d.getTimezoneOffset(), tz = (offset >= 0 ? '+' : '-') + pad(Math.floor(Math.abs(offset) / 60)) + ':' + pad(Math.abs(offset) % 60);
  const dayOfYear = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - new Date(d.getFullYear(), 0, 1)) / 86400000) + 1;
  const tokens = {
    YYYY:() => String(d.getFullYear()), YY:() => pad(d.getFullYear() % 100), Y:() => String(d.getFullYear()),
    Q:() => String(Math.floor(d.getMonth() / 3) + 1), Qo:() => ordinal(Math.floor(d.getMonth() / 3) + 1),
    MMMM:() => monthNames[d.getMonth()], MMM:() => monthNames[d.getMonth()].slice(0, 3), MM:() => pad(d.getMonth() + 1), Mo:() => ordinal(d.getMonth() + 1), M:() => String(d.getMonth() + 1),
    DDDD:() => pad(dayOfYear, 3), DDDo:() => ordinal(dayOfYear), DDD:() => String(dayOfYear),
    DD:() => pad(d.getDate()), Do:() => ordinal(d.getDate()), D:() => String(d.getDate()),
    dddd:() => dayNames[d.getDay()], ddd:() => dayNames[d.getDay()].slice(0, 3), dd:() => dayNames[d.getDay()].slice(0, 2), do:() => ordinal(d.getDay()), d:() => String(d.getDay()),
    E:() => String((d.getDay() + 6) % 7 + 1), e:() => String(d.getDay()),
    WW:() => pad(isoWeek(d).week), Wo:() => ordinal(isoWeek(d).week), W:() => String(isoWeek(d).week), GGGG:() => String(isoWeek(d).year),
    ww:() => pad(isoWeek(d).week), w:() => String(isoWeek(d).week), gggg:() => String(isoWeek(d).year),
    HH:() => pad(d.getHours()), H:() => String(d.getHours()), hh:() => pad(d.getHours() % 12 || 12), h:() => String(d.getHours() % 12 || 12),
    kk:() => pad(d.getHours() || 24), k:() => String(d.getHours() || 24),
    mm:() => pad(d.getMinutes()), m:() => String(d.getMinutes()), ss:() => pad(d.getSeconds()), s:() => String(d.getSeconds()),
    SSS:() => pad(d.getMilliseconds(), 3), SS:() => pad(Math.floor(d.getMilliseconds() / 10)), S:() => String(Math.floor(d.getMilliseconds() / 100)),
    A:() => d.getHours() < 12 ? 'AM' : 'PM', a:() => d.getHours() < 12 ? 'am' : 'pm',
    ZZ:() => tz.replace(':', ''), Z:() => tz, X:() => String(Math.floor(+d / 1000)), x:() => String(+d)
  };
  const keys = Object.keys(tokens).sort((a, b) => b.length - a.length).join('|');
  return String(format).replace(new RegExp('\\[([^\\]]*)\\]|' + keys, 'g'), (m, literal) => literal ?? tokens[m]());
}
export function relativeDate(d, now = new Date()) {
  const seconds = (d - now) / 1000, abs = Math.abs(seconds), future = seconds > 0;
  const say = s => future ? 'in ' + s : s + ' ago', round = n => Math.round(n);
  if (abs < 45) return say('a few seconds');
  if (abs < 90) return say('a minute');
  if (abs < 2700) return say(round(abs / 60) + ' minutes');
  if (abs < 5400) return say('an hour');
  if (abs < 79200) return say(round(abs / 3600) + ' hours');
  if (abs < 129600) return say('a day');
  if (abs < 2246400) return say(round(abs / 86400) + ' days');
  if (abs < 3888000) return say('a month');
  if (abs < 27648000) return say(round(abs / 2592000) + ' months');
  if (abs < 47347200) return say('a year');
  return say(round(abs / 31536000) + ' years');
}

// ---------------------------------------------------------------- comparison
export function resolvePath(value, ctx) {
  if (value == null) return null;
  if (isFile(value)) return value.path;
  if (value?.file && isFile(value.file) && value.__this) return value.file.path;
  if (value instanceof Link) return value.external ? value.path : (ctx?.resolve?.(value.path, ctx?.file?.path) ?? null);
  return null;
}
function linkKey(value, ctx) {
  if (isFile(value) || value instanceof Link || value?.__this) {
    const path = resolvePath(value, ctx);
    if (path) return 'path:' + path.toLowerCase();
    if (value instanceof Link) return 'link:' + value.path.toLowerCase().replace(/\.md$/, '');
  }
  return null;
}
export function equals(a, b, ctx) {
  if (a == null || b == null) return a == null && b == null;
  const la = linkKey(a, ctx), lb = linkKey(b, ctx);
  if (la || lb) {
    if (la && lb) return la === lb;
    const other = la ? b : a, key = la ?? lb;
    if (typeof other === 'string') {
      const link = linkKey(new Link(other), ctx);
      return link === key || key === 'link:' + other.toLowerCase().replace(/\.md$/, '');
    }
    return false;
  }
  if (isDate(a) || isDate(b)) { const x = parseDate(a), y = parseDate(b); return !!x && !!y && +x === +y; }
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((v, i) => equals(v, b[i], ctx));
  if (a instanceof Duration && b instanceof Duration) return a.ms === b.ms && a.months === b.months;
  if (typeof a === 'number' && typeof b === 'string' && b.trim() && Number.isFinite(Number(b))) return a === Number(b);
  if (typeof b === 'number' && typeof a === 'string' && a.trim() && Number.isFinite(Number(a))) return b === Number(a);
  if (typeof a === 'object' && typeof b === 'object') return JSON.stringify(a) === JSON.stringify(b);
  return a === b;
}
const collator = new Intl.Collator(undefined, {numeric:true, sensitivity:'base'});
function comparable(v) {
  if (isDate(v)) return +v;
  if (v instanceof Duration) return v.ms + v.months * 2592000000;
  if (typeof v === 'boolean') return v ? 1 : 0;
  return v;
}
function relational(a, b) {
  if (isDate(a) && !isDate(b)) b = parseDate(b) ?? b;
  if (isDate(b) && !isDate(a)) a = parseDate(a) ?? a;
  a = comparable(a); b = comparable(b);
  if (typeof a === 'number' && typeof b === 'string' && b.trim() && Number.isFinite(Number(b))) b = Number(b);
  if (typeof b === 'number' && typeof a === 'string' && a.trim() && Number.isFinite(Number(a))) a = Number(a);
  if (typeof a === 'number' && typeof b === 'number') return a < b ? -1 : a > b ? 1 : 0;
  if (a == null || b == null) return null;
  return collator.compare(display(a), display(b));
}
// Sort order used by views: empties last, numbers and dates by value, text naturally.
export function compare(a, b) {
  const ae = isEmptyValue(a), be = isEmptyValue(b);
  if (ae || be) return ae === be ? 0 : ae ? 1 : -1;
  if (Array.isArray(a) || Array.isArray(b)) return collator.compare(display(a), display(b));
  return relational(a, b) ?? 0;
}

// ---------------------------------------------------------------- evaluation
const forbidden = new Set(['__proto__', 'constructor', 'prototype', '__defineGetter__', '__lookupGetter__']);
const own = (o, k) => o != null && typeof o === 'object' && Object.hasOwn(o, k) ? o[k] : null;
function member(obj, key, ctx, stack = []) {
  key = String(key);
  if (forbidden.has(key)) throw Error('Unsupported property: ' + key);
  if (obj == null) return null;
  if (obj.__formula) return formulaValue(ctx, key, stack);
  if (typeof obj === 'string' || Array.isArray(obj)) {
    if (key === 'length') return obj.length;
    if (Array.isArray(obj) && /^-?\d+$/.test(key)) return obj.at(Number(key)) ?? null;
    return null;
  }
  if (isDate(obj)) {
    const fields = {year:() => obj.getFullYear(), month:() => obj.getMonth() + 1, day:() => obj.getDate(), hour:() => obj.getHours(),
      minute:() => obj.getMinutes(), second:() => obj.getSeconds(), millisecond:() => obj.getMilliseconds()};
    return fields[key]?.() ?? null;
  }
  if (obj instanceof Duration) {
    const fields = {days:obj.ms / 86400000, hours:obj.ms / 3600000, minutes:obj.ms / 60000, seconds:obj.ms / 1000, milliseconds:obj.ms, months:obj.months, years:obj.months / 12};
    return fields[key] ?? null;
  }
  if (obj instanceof Link) {
    if (key === 'path') return obj.path; if (key === 'display') return obj.display;
    const file = ctx.fileAt?.(resolvePath(obj, ctx));
    if (!file) return null;
    return Object.hasOwn(file.fields, key) ? member(file, key, ctx, stack) : own(file.fields.properties, key);
  }
  if (isFile(obj)) {
    if (key === 'backlinks') return ctx.backlinks?.(obj.path) ?? [];
    if (key === 'file') return obj;
    return Object.hasOwn(obj.fields, key) ? obj.fields[key] : null;
  }
  return own(obj, key);
}
export function evaluate(tree, ctx, locals = null, stack = []) {
  const run = node => evaluate(node, ctx, locals, stack);
  if (Object.hasOwn(tree, 'number')) return tree.number;
  if (Object.hasOwn(tree, 'string')) return tree.string;
  if (Object.hasOwn(tree, 'regex')) {
    try { return new RegExp(tree.regex, tree.flags); } catch (e) { throw Error('Invalid regular expression: ' + e.message); }
  }
  if (tree.list) return tree.list.map(run);
  if (tree.object) return Object.fromEntries(tree.object.filter(([k]) => !forbidden.has(k)).map(([k, v]) => [k, run(v)]));
  if (tree.id) {
    const id = tree.id;
    if (locals && Object.hasOwn(locals, id)) return locals[id];
    if (id === 'true') return true; if (id === 'false') return false; if (id === 'null') return null;
    if (id === 'file') return ctx.file;
    if (id === 'note') return ctx.note;
    if (id === 'this') return ctx.this;
    if (id === 'formula') return {__formula:true};
    if (id === 'values' && ctx.values) return ctx.values;
    return ctx.property ? ctx.property(id) : own(ctx.note, id);
  }
  if (tree.member) return member(run(tree.member), run(tree.key), ctx, stack);
  if (tree.call) return call(tree, ctx, locals, stack);
  if (tree.unary) { const v = run(tree.value); return tree.unary === '!' ? !truthy(v) : v instanceof Duration ? new Duration(-v.ms, -v.months) : -number(v); }
  const a = run(tree.left);
  if (tree.op === '&&') return truthy(a) ? run(tree.right) : a;
  if (tree.op === '||') return truthy(a) ? a : run(tree.right);
  return operate(tree.op, a, run(tree.right), ctx);
}
function formulaValue(ctx, key, stack) {
  if (stack.includes(key)) throw Error('Circular formula: ' + [...stack, key].join(' → '));
  if (stack.length > 64) throw Error('Formulas are too deeply nested.');
  const source = own(ctx.formulas, key); if (source == null) return null;
  const cacheKey = 'formula:' + key;
  if (ctx.memo && ctx.memo.has(cacheKey)) return ctx.memo.get(cacheKey);
  const value = evaluate(expression(String(source)), ctx, null, [...stack, key]);
  ctx.memo?.set(cacheKey, value); return value;
}
function number(v) {
  if (typeof v === 'number') return v;
  if (isDate(v)) return +v;
  if (typeof v === 'boolean') return v ? 1 : 0;
  if (v instanceof Duration) return v.ms + v.months * 2592000000;
  if (v == null || v === '') return 0;
  const n = Number(typeof v === 'string' ? v.trim() : v);
  return n;
}
function operate(op, a, b, ctx) {
  switch (op) {
    case '==': return equals(a, b, ctx);
    case '!=': return !equals(a, b, ctx);
    case '>': case '<': case '>=': case '<=': {
      const c = relational(a, b); if (c == null) return false;
      return op === '>' ? c > 0 : op === '<' ? c < 0 : op === '>=' ? c >= 0 : c <= 0;
    }
  }
  if (isDate(a) && (op === '+' || op === '-') && (typeof b === 'string' || b instanceof Duration || typeof b === 'number')) {
    let duration = null;
    try { duration = parseDuration(b); } catch (e) {
      const other = op === '-' && parseDate(b); if (other) return +a - +other; throw e;
    }
    return shift(a, duration, op === '+' ? 1 : -1);
  }
  if (isDate(a) && isDate(b) && op === '-') return +a - +b;
  if (a instanceof Duration || b instanceof Duration) {
    const d = a instanceof Duration ? a : b, other = a instanceof Duration ? b : a;
    if (op === '+' || op === '-') { const o = parseDuration(other), s = op === '+' ? 1 : -1; return new Duration(d.ms + s * o.ms, d.months + s * o.months); }
    if (op === '*' && a instanceof Duration) return new Duration(d.ms * number(other), d.months * number(other));
    if (op === '/' && a instanceof Duration) return b instanceof Duration ? number(a) / number(b) : new Duration(d.ms / number(other), d.months / number(other));
    throw Error('Put the duration on the left when multiplying or dividing.');
  }
  if (op === '+') {
    if (Array.isArray(a) && Array.isArray(b)) return [...a, ...b];
    if (typeof a === 'string' || typeof b === 'string' || a instanceof Link || b instanceof Link || Array.isArray(a) || Array.isArray(b)) return display(a) + display(b);
    return number(a) + number(b);
  }
  const x = number(a), y = number(b);
  switch (op) { case '-': return x - y; case '*': return x * y; case '/': return x / y; case '%': return x % y; }
  throw Error('Unsupported operator: ' + op);
}
function call(tree, ctx, locals, stack) {
  const run = node => evaluate(node, ctx, locals, stack), fn = tree.call;
  if (fn.member) {
    const name = String(evaluate(fn.key, ctx, locals, stack));
    if (forbidden.has(name)) throw Error('Unsupported function: ' + name);
    const target = run(fn.member);
    if (['filter', 'map', 'reduce'].includes(name)) return iterate(name, target, tree.args, ctx, locals, stack);
    return method(name, target, tree.args.map(run), ctx);
  }
  if (!fn.id) throw Error('This value is not a function.');
  if (fn.id === 'if') return truthy(run(tree.args[0])) ? (tree.args[1] ? run(tree.args[1]) : null) : tree.args[2] ? run(tree.args[2]) : null;
  const args = tree.args.map(run);
  return global(fn.id, args, ctx);
}
function iterate(name, target, argTrees, ctx, locals, stack) {
  const items = list(target), scope = value => ({...(locals ?? {}), ...value});
  if (!argTrees[0]) throw Error(name + '() needs an expression.');
  if (name === 'filter') return items.filter((value, index) => truthy(evaluate(argTrees[0], ctx, scope({value, index}), stack)));
  if (name === 'map') return items.map((value, index) => evaluate(argTrees[0], ctx, scope({value, index}), stack));
  let acc = argTrees[1] ? evaluate(argTrees[1], ctx, locals, stack) : null;
  items.forEach((value, index) => { acc = evaluate(argTrees[0], ctx, scope({value, index, acc}), stack); });
  return acc;
}
function toLink(value, display, ctx) {
  if (value instanceof Link) return display === undefined ? value : new Link(value.path + value.subpath, display);
  if (isFile(value)) return new Link(value.path, display ?? null);
  if (value?.__this) return new Link(value.file.path, display ?? null);
  return new Link(text(value), display ?? null);
}
function global(name, args, ctx) {
  switch (name) {
    case 'date': { if (args[0] == null) return null; const d = parseDate(args[0]); if (!d) throw Error('Invalid date: ' + text(args[0])); return d; }
    case 'duration': return parseDuration(args[0]);
    case 'now': return new Date();
    case 'today': { const d = new Date(); d.setHours(0, 0, 0, 0); return markDateOnly(d); }
    case 'number': {
      const v = args[0];
      if (v == null || v === '') return null;
      const n = number(v); if (Number.isNaN(n)) throw Error('Cannot convert “' + text(v) + '” to a number.'); return n;
    }
    case 'string': return text(args[0]);
    case 'list': return Array.isArray(args[0]) ? args[0] : args[0] == null ? [] : [args[0]];
    case 'link': return toLink(args[0], args[1], ctx);
    case 'file': {
      const v = args[0], path = isFile(v) ? v.path : resolvePath(v instanceof Link ? v : new Link(text(v)), ctx) ?? text(v);
      return ctx.fileAt?.(path) ?? null;
    }
    case 'image': return args[0] == null || args[0] === '' ? null : new BaseImage(isFile(args[0]) ? new Link(args[0].path) : args[0]);
    case 'icon': return new BaseIcon(args[0]);
    case 'html': return new BaseHTML(text(args[0]));
    case 'escapeHTML': return text(args[0]).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c]);
    case 'max': { const n = args.flatMap(list).filter(v => v != null).map(v => isDate(v) ? v : number(v)); if (!n.length) return null; return n.reduce((a, b) => relational(a, b) >= 0 ? a : b); }
    case 'min': { const n = args.flatMap(list).filter(v => v != null).map(v => isDate(v) ? v : number(v)); if (!n.length) return null; return n.reduce((a, b) => relational(a, b) <= 0 ? a : b); }
    case 'random': return Math.random();
    case 'choice': return args[0] ? args[1] : args[2];
    default: throw Error('Unknown function: ' + name + '()');
  }
}
function numbers(v) { return list(v).filter(x => !isEmptyValue(x)).map(number).filter(Number.isFinite); }
function median(values) {
  const n = [...values].sort((a, b) => a - b); if (!n.length) return null;
  const mid = Math.floor(n.length / 2); return n.length % 2 ? n[mid] : (n[mid - 1] + n[mid]) / 2;
}
function method(name, value, args, ctx) {
  // Methods available on every type.
  switch (name) {
    case 'isTruthy': return truthy(value);
    case 'isType': {
      const wanted = String(args[0] ?? '').toLowerCase(), actual = typeOf(value);
      return wanted === actual || (wanted === 'array' && actual === 'list') || (wanted === 'text' && actual === 'string') || (wanted === 'datetime' && actual === 'date');
    }
    case 'toString': return text(value);
    case 'isEmpty': return isDate(value) ? false : isEmptyValue(value);
  }
  if (value instanceof CellError) throw Error(value.error);
  if (isFile(value) || value?.__this) {
    const file = isFile(value) ? value : value.file;
    switch (name) {
      case 'asLink': return new Link(file.path, args[0] ?? null);
      case 'hasTag': {
        const tags = file.fields.tags.map(t => t.replace(/^#/, '').toLowerCase());
        return args.flatMap(list).some(tag => { const t = text(tag).replace(/^#/, '').toLowerCase(); return tags.some(x => x === t || x.startsWith(t + '/')); });
      }
      case 'hasLink': {
        const target = args[0], path = isFile(target) ? target.path : target?.__this ? target.file.path : resolvePath(target instanceof Link ? target : new Link(text(target)), ctx);
        const name = !path && target != null ? text(target instanceof Link ? target.path : target).toLowerCase().replace(/\.md$/, '') : null;
        return file.fields.links.some(link => {
          const resolved = resolvePath(link, {...ctx, file});
          return path ? resolved === path : link.path.toLowerCase().replace(/\.md$/, '') === name;
        });
      }
      case 'inFolder': {
        const folder = text(args[0] instanceof Link ? args[0].path : args[0]).replace(/^\/+|\/+$/g, '');
        if (!folder) return true;
        const f = file.fields.folder.toLowerCase(), g = folder.toLowerCase();
        return f === g || f.startsWith(g + '/');
      }
      case 'hasProperty': return Object.hasOwn(file.fields.properties ?? {}, text(args[0]));
      case 'linksTo': return method('hasLink', file, args, ctx);
    }
  }
  if (value instanceof Link) {
    switch (name) {
      case 'asFile': return ctx.fileAt?.(resolvePath(value, ctx)) ?? null;
      case 'linksTo': { const file = ctx.fileAt?.(resolvePath(value, ctx)); return file ? method('hasLink', file, args, ctx) : false; }
      case 'asLink': return value;
    }
    const file = ctx.fileAt?.(resolvePath(value, ctx));
    if (file && ['hasTag','hasLink','inFolder','hasProperty'].includes(name)) return method(name, file, args, ctx);
    value = value.toString();
  }
  if (value instanceof RegExp) {
    if (name === 'matches') { value.lastIndex = 0; return value.test(text(args[0])); }
    throw Error('Unknown function on regular expression: ' + name + '()');
  }
  if (isDate(value)) {
    switch (name) {
      case 'date': { const d = new Date(value); d.setHours(0, 0, 0, 0); return markDateOnly(d); }
      case 'format': return formatDate(value, args[0] == null ? 'YYYY-MM-DD' : text(args[0]));
      case 'time': return formatDate(value, 'HH:mm:ss');
      case 'relative': return relativeDate(value);
    }
  }
  if (value instanceof Duration) {
    if (name === 'toString') return humanDuration(value);
    value = number(value);
  }
  if (Array.isArray(value)) {
    switch (name) {
      case 'contains': return value.some(v => equals(v, args[0], ctx));
      case 'containsAll': return args.every(a => value.some(v => equals(v, a, ctx)));
      case 'containsAny': return args.some(a => value.some(v => equals(v, a, ctx)));
      case 'flat': return value.flat(Infinity);
      case 'join': return value.map(text).join(args[0] == null ? ',' : text(args[0]));
      case 'reverse': return [...value].reverse();
      case 'slice': return value.slice(args[0] == null ? undefined : number(args[0]), args[1] == null ? undefined : number(args[1]));
      case 'sort': return [...value].sort(compare);
      case 'unique': return value.filter((v, i) => value.findIndex(x => equals(x, v, ctx)) === i);
      case 'first': return value[0] ?? null;
      case 'last': return value.at(-1) ?? null;
      case 'sum': return numbers(value).reduce((a, b) => a + b, 0);
      case 'mean': case 'average': { const n = numbers(value); return n.length ? n.reduce((a, b) => a + b, 0) / n.length : null; }
      case 'median': return median(numbers(value));
      case 'stddev': { const n = numbers(value); if (!n.length) return null; const m = n.reduce((a, b) => a + b, 0) / n.length; return Math.sqrt(n.reduce((a, b) => a + (b - m) ** 2, 0) / n.length); }
      case 'min': { const n = value.filter(v => !isEmptyValue(v)); return n.length ? n.reduce((a, b) => compare(a, b) <= 0 ? a : b) : null; }
      case 'max': { const n = value.filter(v => !isEmptyValue(v)); return n.length ? n.reduce((a, b) => compare(a, b) >= 0 ? a : b) : null; }
      case 'length': return value.length;
    }
    throw Error('Unknown function on list: ' + name + '()');
  }
  if (typeof value === 'number') {
    switch (name) {
      case 'abs': return Math.abs(value); case 'ceil': return Math.ceil(value); case 'floor': return Math.floor(value);
      case 'round': { const digits = args[0] == null ? 0 : Math.max(0, Math.min(15, number(args[0]))); const f = 10 ** digits; return Math.round((value + Number.EPSILON) * f) / f; }
      case 'toFixed': return value.toFixed(Math.max(0, Math.min(20, number(args[0] ?? 0))));
    }
  }
  if (value && typeof value === 'object' && !(value instanceof BaseImage) && !(value instanceof BaseHTML) && !(value instanceof BaseIcon)) {
    switch (name) {
      case 'keys': return Object.keys(value);
      case 'values': return Object.values(value);
    }
    throw Error('Unknown function on object: ' + name + '()');
  }
  if (typeof value === 'boolean' || typeof value === 'number' || value == null || typeof value === 'string' || typeof value === 'object') {
    const s = text(value);
    switch (name) {
      case 'contains': return s.includes(text(args[0]));
      case 'containsAll': return args.every(a => s.includes(text(a)));
      case 'containsAny': return args.some(a => s.includes(text(a)));
      case 'startsWith': return s.startsWith(text(args[0]));
      case 'endsWith': return s.endsWith(text(args[0]));
      case 'lower': return s.toLowerCase();
      case 'upper': return s.toUpperCase();
      case 'title': return s.replace(/(^|[\s\-_/])(\p{L})/gu, (_, p, c) => p + c.toUpperCase());
      case 'trim': return s.trim();
      case 'repeat': return s.repeat(Math.max(0, Math.min(10000, number(args[0]))));
      case 'reverse': return [...s].reverse().join('');
      case 'slice': return s.slice(args[0] == null ? undefined : number(args[0]), args[1] == null ? undefined : number(args[1]));
      case 'replace': return args[0] instanceof RegExp ? s.replace(args[0], text(args[1])) : s.replaceAll(text(args[0]), text(args[1]));
      case 'replaceAll': return args[0] instanceof RegExp ? s.replace(new RegExp(args[0].source, args[0].flags.includes('g') ? args[0].flags : args[0].flags + 'g'), text(args[1])) : s.replaceAll(text(args[0]), text(args[1]));
      case 'split': { const parts = s.split(args[0] instanceof RegExp ? args[0] : text(args[0])); return args[1] == null ? parts : parts.slice(0, number(args[1])); }
      case 'matches': { const r = args[0] instanceof RegExp ? args[0] : new RegExp(text(args[0])); r.lastIndex = 0; return r.test(s); }
      case 'length': return s.length;
      case 'date': { const d = parseDate(s); if (!d) throw Error('Invalid date: ' + s); return method('date', d, args, ctx); }
      case 'format': { const d = parseDate(s); if (!d) throw Error('Invalid date: ' + s); return formatDate(d, args[0] == null ? 'YYYY-MM-DD' : text(args[0])); }
      case 'relative': { const d = parseDate(s); if (!d) throw Error('Invalid date: ' + s); return relativeDate(d); }
      case 'toFixed': case 'round': case 'abs': case 'ceil': case 'floor': {
        const n = Number(s); if (!s.trim() || Number.isNaN(n)) throw Error(name + '() needs a number.'); return method(name, n, args, ctx);
      }
      case 'asLink': return new Link(s, args[0] ?? null);
    }
  }
  throw Error('Unknown function: ' + name + '()');
}

// ---------------------------------------------------------------- summaries
export const defaultSummaries = ['Average','Min','Max','Sum','Range','Median','Stddev','Earliest','Latest','Checked','Unchecked','Empty','Filled','Unique'];
export function summaryOptions(values) {
  const present = values.filter(v => !isEmptyValue(v));
  const kind = present.length && present.every(v => typeof v === 'number') ? 'number' : present.length && present.every(isDate) ? 'date' :
    present.length && values.every(v => v == null || typeof v === 'boolean') ? 'boolean' : 'any';
  const common = ['Empty','Filled','Unique'];
  return kind === 'number' ? ['Average','Min','Max','Sum','Range','Median','Stddev', ...common] : kind === 'date' ? ['Earliest','Latest','Range', ...common] :
    kind === 'boolean' ? ['Checked','Unchecked', ...common] : common;
}
export function summarize(name, values, custom = {}, ctx = {}) {
  const present = values.filter(v => !isEmptyValue(v) && !(v instanceof CellError));
  const nums = present.map(v => isDate(v) ? NaN : typeof v === 'number' ? v : typeof v === 'string' && v.trim() && Number.isFinite(Number(v)) ? Number(v) : NaN).filter(Number.isFinite);
  const dates = present.map(v => isDate(v) ? v : parseDate(v)).filter(validDate);
  switch (name) {
    case 'Average': return nums.length ? nums.reduce((a, b) => a + b, 0) / nums.length : null;
    case 'Min': return nums.length ? Math.min(...nums) : null;
    case 'Max': return nums.length ? Math.max(...nums) : null;
    case 'Sum': return nums.reduce((a, b) => a + b, 0);
    case 'Median': return median(nums);
    case 'Stddev': { if (!nums.length) return null; const m = nums.reduce((a, b) => a + b, 0) / nums.length; return Math.sqrt(nums.reduce((a, b) => a + (b - m) ** 2, 0) / nums.length); }
    case 'Range':
      if (present.length && present.every(isDate)) { if (!dates.length) return null; return new Duration(Math.max(...dates) - Math.min(...dates)); }
      return nums.length ? Math.max(...nums) - Math.min(...nums) : null;
    case 'Earliest': return dates.length ? dates.reduce((a, b) => a <= b ? a : b) : null;
    case 'Latest': return dates.length ? dates.reduce((a, b) => a >= b ? a : b) : null;
    case 'Checked': return values.filter(v => v === true).length;
    case 'Unchecked': return values.filter(v => v === false || v == null).length;
    case 'Empty': return values.filter(isEmptyValue).length;
    case 'Filled': return values.filter(v => !isEmptyValue(v)).length;
    case 'Unique': return present.filter((v, i) => present.findIndex(x => equals(x, v, ctx)) === i).length;
  }
  const formula = own(custom, name);
  if (formula == null) throw Error('Unknown summary: ' + name);
  return evaluate(expression(String(formula)), {...ctx, values, note:{}, property:() => null});
}
