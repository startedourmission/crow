import {Extension} from '@tiptap/core';
import {Plugin} from '@tiptap/pm/state';
import {el} from './obsidian-ui.js';
let catalog = {paths:[],tags:[]};
export function setCatalog(value) {
  catalog = {paths:Array.isArray(value.paths)?value.paths:[],tags:Array.isArray(value.tags)?value.tags:[]};
  document.dispatchEvent(new Event('crow-catalog'));
}
const normalize = value => value.normalize('NFC').toLocaleLowerCase();
export function suggestions(kind, query, {embed = false, exclude = []} = {}) {
  const term=normalize(query), hidden=new Set(exclude.map(normalize));
  const items = (kind==='tag'?catalog.tags:catalog.paths.filter(path=>embed || /\.(md|markdown)$/i.test(path)))
    .filter(value=>!hidden.has(normalize(value)) && normalize(value).includes(term));
  return items.sort((a,b)=>{
    const rank=value=>normalize(value.split('/').at(-1)).startsWith(term)?0:1;
    return rank(a)-rank(b)||a.localeCompare(b);
  }).slice(0,12);
}
export function completionMenu(anchor, values, choose, label) {
  const menu=el('div',null,'note-completions'); menu.setAttribute('role','listbox'); menu.setAttribute('aria-label',label);
  let selected=0;
  const buttons=values.map((value,i)=>{
    const row=el('div',value,'note-completion'); row.setAttribute('role','option'); row.id='note-completion-'+i;
    row.onpointerdown=e=>{e.preventDefault();choose(value);}; menu.append(row); return row;
  });
  function select(index) { selected=(index+values.length)%values.length; buttons.forEach((row,i)=>row.setAttribute('aria-selected',String(i===selected))); }
  const bounds=anchor(); menu.style.left=Math.max(8,Math.min(bounds.left,innerWidth-360))+'px';
  menu.style.top=Math.min(bounds.bottom+4,Math.max(8,innerHeight-Math.min(values.length*32+8,250)))+'px';
  document.body.append(menu); select(0);
  return {node:menu, close:()=>menu.remove(), key(event) {
    if(event.isComposing)return false;
    if(event.key==='ArrowDown'||event.key==='ArrowUp'){event.preventDefault();select(selected+(event.key==='ArrowDown'?1:-1));buttons[selected].scrollIntoView({block:'nearest'});return true;}
    if(event.key==='Enter'||event.key==='Tab'){event.preventDefault();choose(values[selected]);return true;}
    return false;
  }};
}

export function attachTagSuggestions(field, choose, existing=()=>[]) {
  let menu;
  const close=()=>{menu?.close();menu=null;field.setAttribute('aria-expanded','false');};
  const refresh=()=>{
    close(); if(field!==document.activeElement || field.dataset.composing==='true')return;
    const wiki=field.value.match(/^(!?)\[\[(.*)$/);
    const values=suggestions(wiki?'note':'tag',wiki?wiki[2]:field.value.replace(/^#/,''),{embed:!!wiki?.[1],exclude:existing()}); if(!values.length)return;
    menu=completionMenu(()=>field.getBoundingClientRect(),values,value=>{close();choose(wiki?wiki[1]+'[['+value.replace(/\.md$/i,'')+']]':value);},wiki?'Notes':'Tags');
    field.setAttribute('aria-expanded','true');
  };
  field.setAttribute('role','combobox');field.setAttribute('aria-autocomplete','list');field.setAttribute('aria-expanded','false');
  field.addEventListener('input',refresh);field.addEventListener('focus',refresh);field.addEventListener('blur',close);
  field.addEventListener('compositionstart',()=>{field.dataset.composing='true';close();});
  field.addEventListener('compositionend',()=>{field.dataset.composing='false';refresh();});
  field.addEventListener('keydown',event=>{
    if(event.isComposing)return;
    if(event.key==='Escape'){close();event.stopPropagation();event.preventDefault();}
    else if(menu?.key(event))event.stopImmediatePropagation();
  },true);
  return close;
}

export const NoteCompletions = Extension.create({
  name:'noteCompletions',
  addProseMirrorPlugins() {
    let menu, active, dismissed;
    const close=()=>{menu?.close();menu=null;};
    const enabled=()=>document.documentElement.dataset.noteLinks==='true';
    const refresh=view=>{
      close();active=null;
      const {selection}=view.state;
      if(!enabled()||!selection.empty||view.composing||!view.hasFocus()||selection.$from.parent.type.spec.code||selection.$from.marks().some(m=>m.type.name==='code'))return;
      const before=selection.$from.parent.textBetween(0,selection.$from.parentOffset,'','\ufffc');
      const match=before.match(/(!?)\[\[((?:(?!\]\])[^\n])*)$/);if(!match||match[2].includes('|')||match[2].includes('#'))return;
      const key=selection.from+':'+match[0]; if(dismissed===key)return;
      const from=selection.from-match[0].length, values=suggestions('document',match[2],{embed:!!match[1]});
      if(!values.length)return;
      active={from,to:selection.from,key};
      menu=completionMenu(()=>view.coordsAtPos(selection.from),values,path=>{
        const target=/\.(md|markdown)$/i.test(path)?path.replace(/\.(md|markdown)$/i,''):path;
        const source=match[1]+'[['+target+']]';
        const {from,to}=active;close();active=null;
        const node=view.state.schema.nodes.wikiLink.create({source,target,label:target});
        view.dispatch(view.state.tr.replaceWith(from,to,node).scrollIntoView());view.focus();
      },'Link to note');
    };
    return [new Plugin({
      props:{handleKeyDown(view,event){
        if(event.isComposing||view.composing)return false;
        if(menu&&event.key==='Escape'){dismissed=active.key;close();event.preventDefault();return true;}
        return menu?.key(event)??false;
      }},
      view(view){
        const update=()=>refresh(view), scroll=()=>close();
        document.addEventListener('crow-catalog',update);view.dom.addEventListener('compositionend',update);
        document.addEventListener('scroll',scroll,true);view.dom.addEventListener('blur',scroll);
        return {update,destroy(){close();document.removeEventListener('crow-catalog',update);view.dom.removeEventListener('compositionend',update);document.removeEventListener('scroll',scroll,true);view.dom.removeEventListener('blur',scroll);}};
      }
    })];
  }
});
