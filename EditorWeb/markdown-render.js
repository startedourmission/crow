// Obsidian-flavoured Markdown for canvas cards and embeds: wikilinks, embeds,
// highlights, tags, callouts, comments and task checkboxes. Output is sanitized.
import {Marked} from 'marked';

const escape = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'})[c]);
const imageExt = /\.(png|jpe?g|gif|webp|bmp|svg|heic|tiff?|avif)$/i;
function wikiParts(inner) {
  const bar = inner.indexOf('|');
  return {target:(bar >= 0 ? inner.slice(0, bar) : inner).trim(), alias:bar >= 0 ? inner.slice(bar + 1).trim() : null};
}
const extensions = [
  {name:'embed', level:'inline', start:src => src.indexOf('![['),
    tokenizer(src) { const m = /^!\[\[([^\]\n]+)\]\]/.exec(src); if (m) return {type:'embed', raw:m[0], ...wikiParts(m[1])}; },
    renderer(t) {
      const path = t.target.split('#')[0];
      if (imageExt.test(path)) {
        const size = /^\d+(x\d+)?$/.test(t.alias ?? '') ? t.alias : '';
        return '<span class="md-embed-image" data-src="' + escape(t.target) + '" data-size="' + escape(size) + '" title="' + escape(t.target) + '"></span>';
      }
      return '<span class="md-embed" data-href="' + escape(t.target) + '">' + escape(t.alias || t.target) + '</span>';
    }},
  {name:'wikilink', level:'inline', start:src => src.indexOf('[['),
    tokenizer(src) { const m = /^\[\[([^\]\n]+)\]\]/.exec(src); if (m) return {type:'wikilink', raw:m[0], ...wikiParts(m[1])}; },
    renderer(t) {
      const label = t.alias || t.target.replace(/#\^?/, ' › ').replace(/^ › /, '');
      return '<a class="internal-link" data-href="' + escape(t.target) + '" href="#">' + escape(label) + '</a>';
    }},
  {name:'highlight', level:'inline', start:src => src.indexOf('=='),
    tokenizer(src) { const m = /^==(?=\S)([\s\S]*?\S)==/.exec(src); if (m) return {type:'highlight', raw:m[0], tokens:this.lexer.inlineTokens(m[1])}; },
    renderer(t) { return '<mark>' + this.parser.parseInline(t.tokens) + '</mark>'; }},
  {name:'tag', level:'inline', start:src => { const m = /(^|\s)#[^\s#]/.exec(src); return m ? m.index + m[1].length : undefined; },
    tokenizer(src) { const m = /^#([\p{L}\p{N}_\/-]*[\p{L}_\/-][\p{L}\p{N}_\/-]*)/u.exec(src); if (m) return {type:'tag', raw:m[0], tag:m[1]}; },
    renderer(t) { return '<a class="tag" href="#" data-tag="' + escape(t.tag) + '">#' + escape(t.tag) + '</a>'; }},
  {name:'math', level:'inline', start:src => src.indexOf('$'),
    tokenizer(src) { const m = /^\$(?!\s)([^$\n]+?)\$(?!\d)/.exec(src); if (m) return {type:'math', raw:m[0], text:m[1]}; },
    renderer(t) { return '<code class="math">' + escape(t.text) + '</code>'; }}
];
const marked = new Marked({gfm:true, breaks:true, extensions});
marked.use({renderer:{
  // Obsidian callouts: > [!type]+ Title
  blockquote({tokens}) {
    const first = tokens[0];
    const m = first?.type === 'paragraph' ? /^\[!([\w-]+)\]([+-]?)[ \t]*(.*)/.exec(first.raw ?? first.text ?? '') : null;
    if (!m) return '<blockquote>' + this.parser.parse(tokens) + '</blockquote>';
    const [line, type, fold, title] = m, rest = (first.raw ?? '').slice(line.length).replace(/^\n/, '');
    const bodyTokens = [...(rest.trim() ? marked.lexer(rest) : []), ...tokens.slice(1)];
    const heading = title ? marked.parseInline(title) : type[0].toUpperCase() + type.slice(1).toLowerCase();
    const tag = fold ? 'details' : 'div', open = fold === '+' ? ' open' : '';
    return '<' + tag + ' class="callout" data-callout="' + escape(type.toLowerCase()) + '"' + open + '>' + (fold ? '<summary' : '<div') + ' class="callout-title">' + heading + (fold ? '</summary>' : '</div>') +
      '<div class="callout-content">' + this.parser.parse(bodyTokens) + '</div></' + tag + '>';
  },
  checkbox({checked}) { return '<input type="checkbox" class="task"' + (checked ? ' checked' : '') + '> '; },
  image({href, text, title}) {
    if (/^https?:/i.test(href ?? '')) return '<span class="md-embed-image" data-src="' + escape(href) + '" title="' + escape(title ?? text ?? '') + '"></span>';
    let path = href ?? ''; try { path = decodeURI(path); } catch {}
    return '<span class="md-embed-image" data-src="' + escape(path) + '" title="' + escape(text ?? '') + '"></span>';
  },
  link({href, title, tokens}) {
    const text = this.parser.parseInline(tokens);
    if (/^[a-z][a-z0-9+.-]*:/i.test(href ?? '')) return '<a class="external-link" href="' + escape(href) + '"' + (title ? ' title="' + escape(title) + '"' : '') + '>' + text + '</a>';
    let path = href ?? ''; try { path = decodeURI(path); } catch {}
    return '<a class="internal-link" href="#" data-href="' + escape(path) + '">' + text + '</a>';
  },
  html({text}) { return sanitizeHTML(text); }
}});

const allowed = new Set(['A','ABBR','B','BLOCKQUOTE','BR','CODE','DD','DEL','DETAILS','DIV','DL','DT','EM','H1','H2','H3','H4','H5','H6','HR','I','IMG','INPUT','INS','KBD','LI','MARK','OL','P','PRE','S','SMALL','SPAN','STRONG','SUB','SUMMARY','SUP','TABLE','TBODY','TD','TFOOT','TH','THEAD','TR','U','UL','FONT','CENTER','FIGURE','FIGCAPTION']);
const attributes = new Set(['href','title','alt','class','colspan','rowspan','align','type','checked','disabled','open','data-href','data-src','data-size','data-tag','data-callout','data-line','start','color','width','height','src']);
export function sanitizeHTML(html) {
  const doc = new DOMParser().parseFromString('<body>' + html + '</body>', 'text/html');
  const walk = node => {
    for (const child of [...node.children]) {
      if (!allowed.has(child.tagName)) { if (['SCRIPT','STYLE','IFRAME','OBJECT','EMBED','TEMPLATE','LINK','META','FORM'].includes(child.tagName)) child.remove(); else child.replaceWith(...child.childNodes); continue; }
      for (const attr of [...child.attributes]) {
        const name = attr.name.toLowerCase();
        if (!attributes.has(name) || /^\s*(javascript|vbscript|data(?!:image\/(png|jpe?g|gif|webp)))/i.test(attr.value)) child.removeAttribute(attr.name);
      }
      if (child.tagName === 'INPUT' && child.getAttribute('type') !== 'checkbox') { child.remove(); continue; }
      if (child.tagName === 'IMG') {
        const src = child.getAttribute('src') ?? '';
        if (!src.startsWith('data:image/')) { const span = doc.createElement('span'); span.className = 'md-embed-image'; span.dataset.src = src; child.replaceWith(span); continue; }
      }
      walk(child);
    }
  };
  walk(doc.body); return doc.body.innerHTML;
}
export function stripFrontmatter(text) { return text.replace(/^﻿?---\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/, ''); }
// Extract a heading section (#Heading) or block (#^id) like Obsidian embeds.
export function subpathText(text, subpath) {
  if (!subpath) return text;
  const target = subpath.replace(/^#/, '');
  if (target.startsWith('^')) {
    const id = target.slice(1), lines = text.split('\n'), index = lines.findIndex(l => new RegExp('\\s\\^' + id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*$').test(l));
    if (index < 0) return text;
    let start = index; while (start > 0 && lines[start - 1].trim() && !/^\s*[-*+]\s|^\s*\d+\.\s|^#/.test(lines[start])) start--;
    return lines.slice(start, index + 1).join('\n').replace(/\s\^[\w-]+\s*$/, '');
  }
  const parts = target.split('#').map(p => p.trim().toLowerCase()), lines = text.split('\n');
  let from = -1, level = 0, depth = 0;
  for (let i = 0; i < lines.length; i++) {
    const m = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(lines[i]); if (!m) continue;
    if (m[2].trim().toLowerCase() === parts[depth]) { if (++depth === parts.length) { from = i; level = m[1].length; break; } }
  }
  if (from < 0) return text;
  let to = lines.length;
  for (let i = from + 1; i < lines.length; i++) { const m = /^(#{1,6})\s/.exec(lines[i]); if (m && m[1].length <= level) { to = i; break; } }
  return lines.slice(from, to).join('\n');
}
export function renderMarkdown(text) {
  const clean = String(text ?? '').replace(/%%[\s\S]*?%%/g, '');
  // Mark task lines so a checkbox click can toggle the right source line.
  let html;
  try { html = marked.parse(clean); } catch { html = '<p>' + escape(clean) + '</p>'; }
  return sanitizeHTML(html);
}
// Toggle the n-th task checkbox in the source.
export function toggleTask(text, index, checked) {
  let n = -1;
  return text.replace(/^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\])/gm, (m, a, mark, b) => ++n === index ? a + (checked ? 'x' : ' ') + b : m);
}
// Wire rendered markdown: links, embeds, images and checkboxes.
export function hydrate(root, {open, openWiki, asset, embed, onTask}) {
  root.querySelectorAll('a.internal-link').forEach(a => a.onclick = e => { e.preventDefault(); e.stopPropagation(); openWiki(a.dataset.href); });
  root.querySelectorAll('a.external-link').forEach(a => a.onclick = e => { e.preventDefault(); e.stopPropagation(); open(a.getAttribute('href')); });
  root.querySelectorAll('a.tag').forEach(a => a.onclick = e => e.preventDefault());
  root.querySelectorAll('.md-embed-image').forEach(span => {
    const [w, h] = (span.dataset.size || '').split('x').map(Number);
    if (w) span.style.width = w + 'px'; if (h) span.style.height = h + 'px';
    asset(span.dataset.src, span);
  });
  root.querySelectorAll('.md-embed').forEach(span => { if (embed) embed(span.dataset.href, span); else span.onclick = e => { e.stopPropagation(); openWiki(span.dataset.href); }; });
  root.querySelectorAll('input.task').forEach((box, index) => {
    if (!onTask) { box.disabled = true; return; }
    box.onpointerdown = e => e.stopPropagation();
    box.onclick = e => { e.stopPropagation(); onTask(index, box.checked); };
  });
}
