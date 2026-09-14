import { parse } from 'yaml';
const own = (o, k) => o != null && Object.hasOwn(o, k) ? o[k] : null;
export function yaml(source) { return parse(source, { maxAliasCount: 30, uniqueKeys: true }) ?? {}; }
export function canvas(source) {
  const doc = JSON.parse(source);
  if (!doc || typeof doc !== 'object' || !Array.isArray(doc.nodes ?? []) || !Array.isArray(doc.edges ?? [])) throw Error('Invalid Canvas document.');
  const nodes = doc.nodes ?? [], edges = doc.edges ?? [];
  if (nodes.length > 2000 || edges.length > 5000) throw Error('Canvas preview supports up to 2,000 nodes and 5,000 connections.');
  const ids = new Set();
  for (const n of nodes) {
    if (!n || typeof n.id !== 'string' || ids.has(n.id) || !['text','file','link','group'].includes(n.type) ||
        !['x','y','width','height'].every(k => Number.isFinite(n[k]) && Math.abs(n[k]) <= 1e7) || n.width <= 0 || n.height <= 0) throw Error('Invalid or duplicate Canvas node.');
    ids.add(n.id);
  }
  for (const e of edges) if (!e || !ids.has(e.fromNode) || !ids.has(e.toNode)) throw Error('A Canvas connection refers to a missing node.');
  return {nodes, edges};
}

// A small expression interpreter: document expressions never execute as JavaScript.
export function expression(source) {
  if (typeof source !== 'string' || source.length > 10000) throw Error('Invalid Base expression.');
  const tokens = []; let pos = 0;
  const pattern = /\s*(?:(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|([\p{L}_$][\p{L}\p{N}_$]*)|(==|!=|>=|<=|&&|\|\||[+\-*/%<>!().,\[\]]))/uy;
  while (pos < source.length && source.slice(pos).trim()) {
    pattern.lastIndex = pos; const m = pattern.exec(source);
    if (!m) throw Error('Unsupported Base expression near: ' + source.slice(pos, pos + 35));
    tokens.push(m[1] ? {number: Number(m[1])} : m[2] ? {string: m[2][0] === '"' ? JSON.parse(m[2]) : m[2].slice(1,-1).replace(/\\(['\\])/g,'$1')} : m[3] ? {id:m[3]} : m[4]);
    pos = pattern.lastIndex;
    if (tokens.length > 1500) throw Error('Base expression is too complex.');
  }
  let i = 0, depth = 0;
  const prec = {'||':1,'&&':2,'==':3,'!=':3,'>':4,'<':4,'>=':4,'<=':4,'+':5,'-':5,'*':6,'/':6,'%':6};
  const expect = t => { if (tokens[i++] !== t) throw Error('Expected ' + t + ' in Base expression.'); };
  function read(min = 0) {
    if (++depth > 80) throw Error('Base expression is too deeply nested.');
    let t = tokens[i++], node;
    if (t === '!' || t === '-') node = {unary:t, value:read(7)};
    else if (t === '(') { node = read(); expect(')'); }
    else if (t && typeof t === 'object') node = t;
    else throw Error('Expected a value in Base expression.');
    while (i < tokens.length) {
      t = tokens[i];
      if (t === '.') { i++; const name=tokens[i++]; if (!name?.id) throw Error('Expected a property name.'); node={object:node,key:{string:name.id}}; }
      else if (t === '[') { i++; const key=read(); expect(']'); node={object:node,key}; }
      else if (t === '(') {
        i++; const args=[];
        if (tokens[i] !== ')') { do { args.push(read()); if(tokens[i] !== ',') break; i++; } while(true); }
        expect(')'); node={call:node,args};
      } else if (prec[t] && prec[t] >= min) { i++; node={op:t,left:node,right:read(prec[t]+1)}; }
      else break;
    }
    depth--; return node;
  }
  const tree=read(); if(i !== tokens.length) throw Error('Unexpected tokens in Base expression.'); return tree;
}
const truth = v => Array.isArray(v) ? v.length > 0 : !!v;
const linked = v => v && typeof v === 'object' && Object.hasOwn(v,'link') ? v.link : v;
const eq = (a,b) => JSON.stringify(linked(a)) === JSON.stringify(linked(b));
const display = v => v == null ? '' : v instanceof Date ? v.toISOString() : typeof v === 'object' ? JSON.stringify(v) : String(v);
const list = v => v == null ? [] : Array.isArray(v) ? v : [v];
function invoke(name, value, args, ctx) {
  const s=()=>display(value), num=()=>Number(value);
  switch(name) {
    case 'contains': return Array.isArray(value) ? value.some(v=>eq(v,args[0])) : s().includes(display(args[0]));
    case 'containsAny': return args.flatMap(list).some(v=>list(value).some(x=>eq(x,v)));
    case 'containsAll': return args.flatMap(list).every(v=>list(value).some(x=>eq(x,v)));
    case 'startsWith': return s().startsWith(display(args[0]));
    case 'endsWith': return s().endsWith(display(args[0]));
    case 'isEmpty': return value == null || value === '' || Array.isArray(value) && !value.length;
    case 'lower': return s().toLowerCase(); case 'upper': return s().toUpperCase();
    case 'trim': return s().trim(); case 'toString': return display(value);
    case 'toFixed': return num().toFixed(Math.max(0,Math.min(20, Number(args[0]??0))));
    case 'round': { const n=10**Math.max(-20,Math.min(20,Number(args[0]??0))); return Math.round(num()*n)/n; }
    case 'floor': return Math.floor(num()); case 'ceil': return Math.ceil(num()); case 'abs': return Math.abs(num());
    case 'replace': return s().replaceAll(display(args[0]),display(args[1]));
    case 'split': return s().split(display(args[0])); case 'join': return list(value).join(args[0]??', ');
    case 'slice': return (Array.isArray(value)?value:s()).slice(...args);
    case 'unique': return list(value).filter((v,i,a)=>a.findIndex(x=>eq(x,v))===i);
    case 'sort': return [...list(value)].sort(compare); case 'reverse': return [...list(value)].reverse();
    case 'sum': return list(value).reduce((a,b)=>a+Number(b),0);
    case 'mean': { const a=list(value); return a.length?a.reduce((a,b)=>a+Number(b),0)/a.length:null; }
    case 'min': return Math.min(...list(value)); case 'max': return Math.max(...list(value));
    case 'hasTag': return args.flatMap(list).some(t=>list(value.tags).some(tag=>tag===String(t).replace(/^#/,'') || tag.startsWith(String(t).replace(/^#/,'')+'/')));
    case 'hasLink': return list(value.links).some(l=>eq(l,args[0]?.path??args[0]) || l===String(args[0]?.path??args[0]).replace(/\.md$/i,''));
    case 'inFolder': { const p=String(args[0]).replace(/^\/+|\/+$/g,''); return value.folder===p || value.folder.startsWith(p+'/'); }
    case 'hasProperty': return Object.hasOwn(ctx.note,String(args[0]));
    case 'asLink': return {link:value.path, label:args[0]??value.name};
    case 'date': { const d=new Date(value); d.setHours(0,0,0,0); return d; }
    case 'format': { const d=new Date(value); if(!Number.isFinite(+d)) return null; const fields={YYYY:d.getFullYear(),MM:String(d.getMonth()+1).padStart(2,'0'),DD:String(d.getDate()).padStart(2,'0'),HH:String(d.getHours()).padStart(2,'0'),mm:String(d.getMinutes()).padStart(2,'0'),ss:String(d.getSeconds()).padStart(2,'0')}; return String(args[0]??'YYYY-MM-DD').replace(/YYYY|MM|DD|HH|mm|ss/g,m=>fields[m]); }
    default: throw Error('Unsupported Base function: '+name);
  }
}
export function evaluate(tree, ctx, stack=[]) {
  if(stack.length > 64) throw Error("Base formulas are too deeply nested.");
  const run = t=>evaluate(t,ctx,stack);
  if(Object.hasOwn(tree,'number')) return tree.number;
  if(Object.hasOwn(tree,'string')) return tree.string;
  if(tree.id) {
    if(tree.id==='true') return true; if(tree.id==='false') return false; if(tree.id==='null') return null;
    if(['file','note','this','values'].includes(tree.id)) return ctx[tree.id];
    if(tree.id==='formula') return {formula:true};
    return own(ctx.note,tree.id);
  }
  if(tree.object) {
    const obj=run(tree.object), key=run(tree.key);
    if(['__proto__','constructor','prototype'].includes(String(key))) throw Error('Unsupported property.');
    if(obj?.formula === true) {
      if(stack.includes(key)) throw Error('Circular Base formula: '+key);
      const formula=own(ctx.formulas,key); if(formula==null) return null;
      return evaluate(expression(formula),ctx,[...stack,key]);
    }
    if(key==='length' && (typeof obj==='string' || Array.isArray(obj))) return obj.length;
    return own(obj,key);
  }
  if(tree.call) {
    const fn=tree.call;
    if(fn.id==='if') return truth(run(tree.args[0])) ? run(tree.args[1]) : tree.args[2]?run(tree.args[2]):null;
    const args=tree.args.map(run);
    if(fn.object) return invoke(String(run(fn.key)),run(fn.object),args,ctx);
    switch(fn.id) {
      case 'list': return args.flatMap(list); case 'number': return Number(args[0]); case 'string': return display(args[0]);
      case 'date': return new Date(args[0]); case 'now': return new Date(); case 'today': { const d=new Date(); d.setHours(0,0,0,0);return d; }
      case 'link': return {link:args[0],label:args[1]??args[0]};
      case 'min': return Math.min(...args); case 'max': return Math.max(...args);
      default: throw Error('Unsupported Base function: '+fn.id);
    }
  }
  if(tree.unary) return tree.unary==='!' ? !truth(run(tree.value)) : -Number(run(tree.value));
  const a=run(tree.left);
  if(tree.op==='&&') return truth(a) && truth(run(tree.right));
  if(tree.op==='||') return truth(a) || truth(run(tree.right));
  const b=run(tree.right);
  if(a instanceof Date && typeof b==='string' && ['+','-'].includes(tree.op)) {
    const m=b.match(/^([+-]?\d+)\s*(years?|y|months?|M|weeks?|w|days?|d|hours?|h|minutes?|m|seconds?|s)$/);
    if(!m) throw Error('Unsupported date duration: '+b);
    const n=Number(m[1])*(tree.op==='+'?1:-1), d=new Date(a), u=m[2];
    if(u==='M'||u.startsWith('month')) d.setMonth(d.getMonth()+n);
    else if(u==='y'||u.startsWith('year')) d.setFullYear(d.getFullYear()+n);
    else d.setTime(+d+n*(u[0]==='w'?604800000:u[0]==='d'?86400000:u[0]==='h'?3600000:u[0]==='m'?60000:1000));
    return d;
  }
  switch(tree.op) { case '==':return eq(a,b);case '!=':return !eq(a,b);case '>':return a>b;case '<':return a<b;case '>=':return a>=b;case '<=':return a<=b;case '+':return a+b;case '-':return a-b;case '*':return a*b;case '/':return a/b;case '%':return a%b; }
  throw Error('Unsupported Base expression.');
}
export function filter(rule, ctx) {
  if(rule==null) return true;
  if(typeof rule==='string') return truth(evaluate(expression(rule),ctx));
  if(typeof rule!=='object' || Array.isArray(rule)) throw Error('Invalid Base filter.');
  const keys=Object.keys(rule); if(keys.length!==1 || !['and','or','not'].includes(keys[0]) || !Array.isArray(rule[keys[0]])) throw Error('Invalid Base filter group.');
  const values=rule[keys[0]];
  return keys[0]==='and'?values.every(r=>filter(r,ctx)):keys[0]==='or'?values.some(r=>filter(r,ctx)):!values.some(r=>filter(r,ctx));
}
export function record(file) {
  const match=file.text?.match(/^\uFEFF?---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
  const note=match?yaml(match[1]):{};
  if(!note || typeof note!=='object' || Array.isArray(note)) throw Error('Invalid frontmatter in '+file.path);
  const name=file.path.split('/').pop(), dot=name.lastIndexOf('.');
  const tags=[...list(note.tags).flatMap(v=>String(v).split(/[,\s]+/)), ...Array.from((file.text??'').matchAll(/(?:^|\s)#([\p{L}\p{N}_/-]+)/gu),m=>m[1])].map(t=>t.replace(/^#/,''));
  const links=Array.from((file.text??'').matchAll(/\[\[([^\]|#]+)(?:[^\]]*)\]\]/g),m=>m[1]);
  return {note,file:{...file,name:dot>0?name.slice(0,dot):name,ext:dot>0?name.slice(dot+1):'',folder:file.path.includes('/')?file.path.slice(0,file.path.lastIndexOf('/')):'',tags:[...new Set(tags)],links,properties:note,mtime:file.modified?new Date(file.modified*1000):null,ctime:file.created?new Date(file.created*1000):null}};
}
export function compare(a,b) { if(a==null)return b==null?0:1;if(b==null)return -1;return typeof a==='number'&&typeof b==='number'?a-b:display(a).localeCompare(display(b),undefined,{numeric:true}); }
export function base(source, files, path, viewIndex=0) {
  const doc=yaml(source);
  if(!Array.isArray(doc.views)||!doc.views.length) throw Error('This Base has no views.');
  const view=doc.views[viewIndex]; if(!view) throw Error('Missing Base view.');
  if(!['table','cards','list'].includes(view.type)) throw Error('Unsupported Base view: '+view.type+'. Use Source to inspect its configuration.');
  const records=files.map(record), current=records.find(r=>r.file.path===path)??record({path});
  const rows=records.map(r=>({...r,formulas:doc.formulas??{},this:current})).filter(r=>filter(doc.filters,r)&&filter(view.filters,r));
  const columns=view.order??['file.name']; if(!Array.isArray(columns)||columns.some(c=>typeof c!=='string')) throw Error('Invalid Base columns.');
  const read=(r,c)=>evaluate(expression(c.startsWith('file.')||c.startsWith('formula.')||c.startsWith('note.')?c:'note['+JSON.stringify(c)+']'),r);
  if(view.sort && !Array.isArray(view.sort)) throw Error('Invalid Base sort.');
  const sort=[...(view.groupBy?[view.groupBy]:[]),...(view.sort??[])];
  rows.sort((a,b)=>{ for(const s of sort) { const v=compare(read(a,s.property),read(b,s.property))*(String(s.direction).toUpperCase()==='DESC'?-1:1); if(v)return v; } return compare(a.file.path,b.file.path); });
  const limited=Number.isInteger(view.limit)&&view.limit>=0?rows.slice(0,view.limit):rows;
  return {doc,view,columns,rows:limited.map(r=>({path:r.file.path,group:view.groupBy?read(r,view.groupBy.property):null,cells:columns.map(c=>read(r,c))})),total:rows.length};
}
