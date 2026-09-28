import test from 'node:test';
import assert from 'node:assert/strict';
import {base, record, baseContext, groupRows, summaryValue, updateBaseFormula, removeBaseFormula, updateBaseProperty, propertyConfig,
  removeBaseView, moveBaseView, duplicateBaseView, yaml, resolver, canvas, serializeCanvas, drawableNodes} from './obsidian-model.js';
import {expression, evaluate, display, formatDate, relativeDate, parseDate, Link, Duration, CellError, summarize, isDateOnly} from './bases-engine.js';

const vault = [
  {path:'Books/Dune.md', size:120, modified:1700000000, created:1690000000, text:'---\nauthor: "[[Frank Herbert]]"\nprice: 12.5\npages: 400\nread: true\ndue: 2025-01-10\ntags: [book, scifi/classic]\ncover: "[[covers/dune.png]]"\n---\n# Dune\nA #desert planet. See [[Children of Dune|sequel]] and [notes](../Notes/Reading%20log.md).\n![[covers/dune.png]]\n```\n#notatag [[NotALink]]\n```\n'},
  {path:'Books/Children of Dune.md', text:'---\nauthor: "[[Frank Herbert]]"\nprice: 8\npages: 350\nread: false\ntags: book\n---\nBack to [[Dune]].'},
  {path:'People/Frank Herbert.md', text:'---\nborn: 1920-10-08\n---\n'},
  {path:'Notes/Reading log.md', text:'Links [[Dune]] #log #2024'},
  {path:'covers/dune.png', size:2048},
  {path:'Books/Index.base', text:null}
];
const types = {due:'date', born:'date', price:'number'};
function run(expr, path = 'Books/Dune.md', extra = {}) {
  const ctx = baseContext('views: [{type: table}]', vault, 'Books/Index.base', {types});
  const r = ctx.records.find(r => r.file.path === path);
  return evaluate(expression(expr), {...ctx.contextFor(r), ...extra});
}

test('File fields follow Obsidian: name keeps the extension, basename drops it', () => {
  assert.equal(run('file.name'), 'Dune.md');
  assert.equal(run('file.basename'), 'Dune');
  assert.equal(run('file.path'), 'Books/Dune.md');
  assert.equal(run('file.folder'), 'Books');
  assert.equal(run('file.ext'), 'md');
  assert.equal(run('file.size'), 120);
  assert.equal(run('file.mtime').getTime(), 1700000000000);
  assert.equal(run('file.properties.pages'), 400);
  assert.equal(run('file.file.basename'), 'Dune');
  assert.equal(run('file.name', 'covers/dune.png'), 'dune.png');
});
test('Tags, links, embeds and backlinks come from the note, ignoring code', () => {
  assert.deepEqual(run('file.tags'), ['#book', '#scifi/classic', '#desert']);
  assert.deepEqual(run('file.tags', 'Notes/Reading log.md'), ['#log']);
  assert.equal(run('file.hasTag("scifi")'), true);
  assert.equal(run('file.hasTag("#desert", "nope")'), true);
  assert.equal(run('file.hasTag("sci")'), false);
  const links = run('file.links').map(l => l.path);
  assert.deepEqual(links, ['Frank Herbert', 'covers/dune.png', 'Children of Dune', '../Notes/Reading log.md']);
  assert.deepEqual(run('file.embeds').map(l => l.path), ['covers/dune.png']);
  assert.equal(run('file.hasLink("Children of Dune")'), true);
  assert.equal(run('file.hasLink(link("Notes/Reading log"))'), true);
  assert.equal(run('file.hasLink("NotALink")'), false);
  assert.deepEqual(run('file.backlinks').map(l => l.path).sort(), ['Books/Children of Dune.md', 'Notes/Reading log.md']);
  assert.equal(run('file.inFolder("Books")'), true);
  assert.equal(run('file.inFolder("Boo")'), false);
  assert.equal(run('file.hasProperty("pages")'), true);
});
test('Links compare to files, strings and this; frontmatter wikilinks become links', () => {
  assert.ok(run('author') instanceof Link);
  assert.equal(display(run('author')), 'Frank Herbert');
  assert.equal(run('author == link("Frank Herbert")'), true);
  assert.equal(run('author == "Frank Herbert"'), true);
  assert.equal(run('author == file("People/Frank Herbert.md")'), true);
  assert.equal(run('author.asFile().basename'), 'Frank Herbert');
  assert.equal(display(run('author.born')), '1920-10-08');
  assert.equal(run('link("Children of Dune").linksTo(file)'), true);
  assert.equal(run('this.file.name'), 'Index.base');
  assert.equal(run('file.folder == this.file.folder'), true);
  assert.equal(display(run('file.asLink("Read")')), 'Read');
  assert.equal(run('list(author).contains(link("Frank Herbert"))'), true);
});
test('Dates: parsing, typed properties, fields, arithmetic, format and relative', () => {
  const due = run('due');
  assert.ok(due instanceof Date && isDateOnly(due));
  assert.equal(run('due.year'), 2025); assert.equal(run('due.month'), 1); assert.equal(run('due.day'), 10);
  assert.equal(run('due < date("2025-02-01")'), true);
  assert.equal(run('due < "2025-02-01"'), true);
  assert.equal(display(run('date("2024-12-01") + "1M" + "4h" + "3m"')), '2025-01-01 04:03');
  assert.equal(display(run('date("2024-01-31") + "1 month"')), '2024-02-29');
  assert.equal(run('(date("2024-01-02") - date("2024-01-01"))'), 86400000);
  assert.equal(run('(now() + "1d") - now() >= 86399000'), true);
  assert.equal(run('date("2025-05-27 13:05:09").format("YYYY-MM-DD HH:mm:ss")'), '2025-05-27 13:05:09');
  assert.equal(run('date("2025-05-27 13:05:09").time()'), '13:05:09');
  assert.equal(run('date("2025-05-27 13:05:09").date().format("HH:mm")'), '00:00');
  assert.equal(formatDate(new Date(2025, 0, 5, 15, 4), 'dddd, MMMM Do YYYY h:mm A [at] Q'), 'Sunday, January 5th 2025 3:04 PM at 1');
  assert.equal(relativeDate(new Date(Date.now() - 3 * 86400000)), '3 days ago');
  assert.equal(relativeDate(new Date(Date.now() + 2 * 3600000)), 'in 2 hours');
  assert.equal(run('due.isEmpty()'), false);
  assert.equal(run('today().format("HH:mm")'), '00:00');
  assert.equal(run('file.mtime > now() - "1 week"'), false);
  assert.equal(run('number(date("1970-01-02 00:00:00Z"))'), 86400000);
});
test('Durations need the duration on the left for scalar arithmetic', () => {
  assert.ok(run('duration("5h") * 2') instanceof Duration);
  assert.equal(run('(duration("1d") * 2).hours'), 48);
  assert.equal(display(run('date("2025-01-01") + duration("1d") * 2')), '2025-01-03');
  assert.throws(() => run('2 * duration("5h")'), /left/);
});
test('Strings: every documented function', () => {
  assert.equal(run('"hello".contains("ell")'), true);
  assert.equal(run('"hello".containsAll("h", "e")'), true);
  assert.equal(run('"hello".containsAny("x", "y", "e")'), true);
  assert.equal(run('"hello".endsWith("lo")'), true);
  assert.equal(run('"hello".startsWith("he")'), true);
  assert.equal(run('"".isEmpty()'), true);
  assert.equal(run('"Hello world".isEmpty()'), false);
  assert.equal(run('"ABC".lower()'), 'abc');
  assert.equal(run('"a:b:c:d".replace(/:/, "-")'), 'a-b:c:d');
  assert.equal(run('"a:b:c:d".replace(/:/g, "-")'), 'a-b-c-d');
  assert.equal(run('"a:b:c:d".replace(":", "-")'), 'a-b-c-d');
  assert.equal(run('"John Smith".replace(/(\\w+) (\\w+)/, "$2, $1")'), 'Smith, John');
  assert.equal(run('"123".repeat(2)'), '123123');
  assert.equal(run('"hello".reverse()'), 'olleh');
  assert.equal(run('"hello".slice(1, 4)'), 'ell');
  assert.deepEqual(run('"a,b,c,d".split(",", 3)'), ['a', 'b', 'c']);
  assert.deepEqual(run('"a,b,c,d".split(/,/, 3)'), ['a', 'b', 'c']);
  assert.equal(run('"hello world".title()'), 'Hello World');
  assert.equal(run('"  hi  ".trim()'), 'hi');
  assert.equal(run('"hello".length'), 5);
  assert.equal(run('/abc/.matches("abcde")'), true);
  assert.equal(run('escapeHTML("<b>")'), '&lt;b&gt;');
  assert.equal(run('"a" + 1 + true'), 'a1true');
});
test('Numbers, any-type helpers and globals', () => {
  assert.equal(run('(-5).abs()'), 5);
  assert.equal(run('(2.1).ceil()'), 3);
  assert.equal(run('(2.9).floor()'), 2);
  assert.equal(run('(2.5).round()'), 3);
  assert.equal(run('(2.3333).round(2)'), 2.33);
  assert.equal(run('(3.14159).toFixed(2)'), '3.14');
  assert.equal(run('5.isEmpty()'), false);
  assert.equal(run('missing.isEmpty()'), true);
  assert.equal(run('1.isTruthy()'), true);
  assert.equal(run('"example".isType("string") && true.isType("boolean") && [1].isType("list")'), true);
  assert.equal(run('123.toString()'), '123');
  assert.equal(run('number("3.4")'), 3.4);
  assert.equal(run('number(true)'), 1);
  assert.throws(() => run('number("x")'), /number/);
  assert.equal(run('max(1, 5, 3)'), 5);
  assert.equal(run('min(4, 2)'), 2);
  assert.equal(run('if(read, "Read", "Unread")'), 'Read');
  assert.equal(run('if(false, 1)'), null);
  assert.equal(run('price * 2 + pages % 7'), 25 + 400 % 7);
  assert.deepEqual(run('list("value")'), ['value']);
  const r = run('random()'); assert.ok(r >= 0 && r < 1);
  assert.equal(display(run('image("https://obsidian.md/logo.svg")')), 'https://obsidian.md/logo.svg');
  assert.equal(run('icon("arrow-right")').name, 'arrow-right');
  assert.equal(run('html("<b>x</b>")').html, '<b>x</b>');
});
test('Lists: filter, map, reduce with value, index and acc', () => {
  assert.deepEqual(run('[1,2,3,4].filter(value > 2)'), [3, 4]);
  assert.deepEqual(run('[1,2,3,4].map(value + 1)'), [2, 3, 4, 5]);
  assert.deepEqual(run('[1,2,3].map(value * index)'), [0, 2, 6]);
  assert.equal(run('[1,2,3].reduce(acc + value, 0)'), 6);
  assert.equal(run('[3,"x",9,1].filter(value.isType("number")).reduce(if(acc == null || value > acc, value, acc), null)'), 9);
  assert.equal(run('[1,2,3].contains(2)'), true);
  assert.equal(run('[1,2,3].containsAll(2,3)'), true);
  assert.equal(run('[1,2,3].containsAny(3,4)'), true);
  assert.deepEqual(run('[1,[2,3]].flat()'), [1, 2, 3]);
  assert.equal(run('[1,2,3].isEmpty()'), false);
  assert.equal(run('[1,2,3].join(",")'), '1,2,3');
  assert.deepEqual(run('[1,2,3].reverse()'), [3, 2, 1]);
  assert.deepEqual(run('[1,2,3,4].slice(1,3)'), [2, 3]);
  assert.deepEqual(run('[3, 1, 2].sort()'), [1, 2, 3]);
  assert.deepEqual(run('["c", "a", "b"].sort()'), ['a', 'b', 'c']);
  assert.deepEqual(run('[1,2,2,3].unique()'), [1, 2, 3]);
  assert.equal(run('[1,2,3].length'), 3);
  assert.equal(run('tags[0]'), 'book');
  assert.equal(run('[1,2,3].map(value * 2).filter(value > 2).length'), 2);
  assert.deepEqual(run('{"a": 1, "b": 2}.keys()'), ['a', 'b']);
  assert.deepEqual(run('{"a": 1, "b": 2}.values()'), [1, 2]);
  assert.equal(run('{}.isEmpty()'), true);
});
test('Formulas reference each other, errors stay in their cell, cycles are reported', () => {
  const source = `formulas:\n  ppu: "(price / pages).toFixed(3)"\n  label: 'if(price, price.toFixed(2) + " dollars")'\n  broken: 'price.nope()'\n  loop: formula.loop\nviews:\n  - type: table\n    filters: 'file.ext == "md" && file.inFolder("Books")'\n    order: [file.name, formula.ppu, formula.label, formula.broken, formula.loop]\n    sort: [{property: price, direction: ASC}]`;
  const result = base(source, vault, 'Books/Index.base', 0, {types});
  assert.equal(result.rows.length, 2);
  assert.deepEqual(result.rows.map(r => r.cells[0]), ['Children of Dune.md', 'Dune.md']);
  assert.equal(result.rows[1].cells[1], '0.031');
  assert.equal(result.rows[1].cells[2], '12.50 dollars');
  assert.ok(result.rows[1].cells[3] instanceof CellError);
  assert.match(result.rows[1].cells[4].error, /Circular/);
});
test('Filters that fail on some notes exclude them and warn instead of failing the view', () => {
  const result = base(`views: [{type: table, filters: 'pages.nope()'}]`, vault, 'x.base');
  assert.equal(result.rows.length, 0); assert.match(result.warnings.join(' '), /Filter error/);
  assert.throws(() => base(`views: [{type: table, filters: 'price >'}]`, vault, 'x.base'));
});
test('Groups and summaries match the table view defaults', () => {
  const source = `summaries:\n  total3: 'values.sum() * 3'\nviews:\n  - type: table\n    filters: file.inFolder("Books")\n    groupBy: {property: read, direction: DESC}\n    order: [file.name, price, due, read]\n    summaries: {price: Sum}`;
  const result = base(source, vault, 'x.base', 0, {types});
  const groups = groupRows(result.rows);
  assert.deepEqual(groups.map(g => g.key), [true, false, null]); // Index.base has no value
  assert.equal(summaryValue(result, result.rows, 'price', 'Sum'), 20.5);
  assert.equal(summaryValue(result, result.rows, 'price', 'Average'), 10.25);
  assert.equal(summaryValue(result, result.rows, 'price', 'Median'), 10.25);
  assert.equal(summaryValue(result, result.rows, 'price', 'Range'), 4.5);
  assert.equal(summaryValue(result, result.rows, 'price', 'total3'), 61.5);
  assert.equal(summaryValue(result, result.rows, 'read', 'Checked'), 1);
  assert.equal(summaryValue(result, result.rows, 'read', 'Unchecked'), 2);
  assert.equal(summaryValue(result, result.rows, 'due', 'Empty'), 2);
  assert.equal(summaryValue(result, result.rows, 'due', 'Filled'), 1);
  assert.equal(summaryValue(result, result.rows, 'price', 'Unique'), 2);
  assert.equal(display(summaryValue(result, result.rows, 'due', 'Earliest')), '2025-01-10');
  assert.equal(summarize('Stddev', [2, 4, 4, 4, 5, 5, 7, 9]), 2);
});
test('Limit, list/object values and unknown layouts', () => {
  const result = base('views: [{type: cards, limit: 1, order: [tags]}]', vault, 'x.base');
  assert.equal(result.rows.length, 1); assert.equal(result.total, vault.length);
  assert.equal(base('views: [{type: kanban}]', vault, 'x.base').warnings.length, 0);
});
test('Link resolution prefers exact paths, then the closest file of that name', () => {
  const files = [{path:'a/Note.md'}, {path:'b/Note.md'}, {path:'b/c/Other.md'}, {path:'img.png'}];
  const resolve = resolver(files);
  assert.equal(resolve('Note', 'b/x.md'), 'b/Note.md');
  assert.equal(resolve('Note', 'z.md'), 'a/Note.md');
  assert.equal(resolve('a/Note', 'b/x.md'), 'a/Note.md');
  assert.equal(resolve('c/Other', ''), 'b/c/Other.md');
  assert.equal(resolve('../img.png', 'b/x.md'), 'img.png');
  assert.equal(resolve('Missing', ''), null);
});
test('Base editing helpers keep YAML comments and rename formulas everywhere', () => {
  const source = '# keep\nformulas:\n  old: price * 2\nproperties:\n  formula.old: {displayName: Double}\nviews:\n  - name: A\n    type: table\n    order: [file.name, formula.old]\n    sort: [{property: formula.old, direction: ASC}]\n  - name: B\n    type: cards\n';
  const renamed = updateBaseFormula(source, 0, 'new', 'price * 3', 'old');
  const doc = yaml(renamed);
  assert.equal(doc.formulas.new, 'price * 3'); assert.equal(doc.formulas.old, undefined);
  assert.deepEqual(doc.views[0].order, ['file.name', 'formula.new']);
  assert.equal(doc.views[0].sort[0].property, 'formula.new');
  assert.equal(doc.properties['formula.new'].displayName, 'Double');
  assert.ok(renamed.startsWith('# keep'));
  assert.deepEqual(yaml(removeBaseFormula(renamed, 'new')).views[0].order, ['file.name']);
  const labeled = updateBaseProperty(source, 'note.status', {displayName:'State'});
  assert.equal(propertyConfig(yaml(labeled), 'status').displayName, 'State');
  assert.equal(yaml(updateBaseProperty(labeled, 'status', {displayName:null})).properties['note.status'], undefined);
  assert.deepEqual(yaml(moveBaseView(source, 1, 0)).views.map(v => v.name), ['B', 'A']);
  assert.deepEqual(yaml(duplicateBaseView(source, 0)).views.map(v => v.name), ['A', 'A copy', 'B']);
  assert.deepEqual(yaml(removeBaseView(source, 0)).views.map(v => v.name), ['B']);
  assert.throws(() => removeBaseView('views: [{type: table}]', 0), /at least one/);
});
test('Canvas round-trips unknown node types, stray edges and extra fields', () => {
  const source = JSON.stringify({nodes:[{id:'a', type:'text', x:0, y:0, width:10, height:10, text:'x'}, {id:'p', type:'portal', x:1, y:1, width:5, height:5, custom:1}, {id:'bad', type:'text'}],
    edges:[{id:'e', fromNode:'a', toNode:'gone'}], metadata:{version:'1.0'}});
  const doc = canvas(source);
  assert.equal(drawableNodes(doc).length, 2);
  const saved = JSON.parse(serializeCanvas(doc));
  assert.deepEqual(saved, JSON.parse(source));
  assert.ok(serializeCanvas(doc).includes('\n\t"nodes"'));
});
test('Records survive odd frontmatter and numeric-only tags are ignored', () => {
  const r = record({path:'x.md', text:'---\ntags: "#a, b"\n---\n#123 #ok/child'});
  assert.deepEqual(r.file.fields.tags, ['#a', '#b', '#ok/child']);
  assert.equal(record({path:'y.md', text:'no frontmatter'}).file.fields.properties.constructor, Object);
  assert.equal(parseDate('2025-01-02T03:04:05Z').getUTCHours(), 3);
});
