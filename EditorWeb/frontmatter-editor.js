import {attachPropertyLink} from './property-links.js';
import {frontmatter, editFrontmatter, propertyTypes} from './frontmatter-model.js';
import {attachTagSuggestions} from './note-completions.js';
import {el, icon, button, input, select} from './obsidian-ui.js';

export function frontmatterView({node, editor, getPos, onOpenLink = url=>window.webkit.messageHandlers.markdown.postMessage({action:'openLink',url}), onSave = ()=>window.webkit.messageHandlers.markdown.postMessage({action:'save'})}) {
  let current = node, renderedShape = '';
  let cleanup=[];
  const emptyTypes = new Map();
  const linkField=(parent,field)=>attachPropertyLink(parent,field,()=>document.documentElement.dataset.noteLinks==='true',onOpenLink);
  const readRows = () => frontmatter(current.attrs.source).rows.map(row => row.value === '' && emptyTypes.has(row.name) ? {...row,type:emptyTypes.get(row.name)} : row);
  const shape = rows => JSON.stringify(rows.map(({name,type,value})=>[name,type,type==='list'?value:typeof value==='string' && value.includes('\n')]));
  const displayValue = ({type,value}) => type==='list' ? value.join('\n') : type==='yaml' ? JSON.stringify(value,null,2) : value ?? '';
  const dom = el('section', null, 'frontmatter'); dom.dataset.frontmatter = ''; dom.contentEditable = 'false';
  const error = el('div', '', 'frontmatter-error'); error.setAttribute('role','alert');
  function commit(name, patch) {
    try {
      const source = editFrontmatter(current.attrs.source,name,patch);
      if (patch.type && ['date','datetime'].includes(patch.type) && patch.value==='') emptyTypes.set(name,patch.type);
      else if (patch.type || patch.remove) emptyTypes.delete(name);
      if (patch.rename != null && emptyTypes.has(name)) { emptyTypes.set(patch.rename,emptyTypes.get(name)); emptyTypes.delete(name); }
      const pos = getPos(); if (typeof pos !== 'number') return false;
      editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, {...current.attrs,source}));
      if (shape(readRows())!==renderedShape) render();
      error.textContent = ''; return true;
    } catch(e) { error.textContent = e.message; return false; }
  }
  function render() {
    cleanup.forEach(close=>close());cleanup=[];
    dom.replaceChildren(el('div','Properties','frontmatter-heading'),error);
    let rows;
    try { rows = readRows(); renderedShape=shape(rows); }
    catch(e) { error.textContent = e.message; dom.append(el('pre',current.attrs.source)); return; }
    const list = el('div',null,'frontmatter-properties'); dom.append(list);
    for (const {name,value,type} of rows) {
      const row = el('div',null,'frontmatter-row'); row.dataset.property = name;
      const picker = el('label',null,'frontmatter-type');
      picker.append(icon(({text:'text',number:'number',boolean:'checkbox',list:'properties',date:'calendar',datetime:'calendar',yaml:'settings'})[type]));
      const kind = select(propertyTypes,type); kind.setAttribute('aria-label','Type of '+name); kind.title = 'Property type: ' + propertyTypes.find(([key])=>key===type)[1];
      picker.append(kind);
      const key = input(name); key.className = 'frontmatter-name'; key.setAttribute('aria-label','Property name');
      key.onchange = () => { if (!commit(name,{rename:key.value})) key.value=name; };
      const field = type==='list' ? el('div') : type==='yaml' || typeof value==='string' && value.includes('\n') ? el('textarea') : input('',type==='boolean'?'checkbox':type==='number'?'number':type==='date'?'date':'text');
      field.className = 'frontmatter-value'; field.setAttribute('aria-label',name); field.dataset.propertyValue = name;
      if (type==='list') {
        field.classList.add('frontmatter-list');
        const save=values=>commit(name,{value:values,type:'list'});
        value.forEach((item,index)=>{
          const part=el('span',null,'frontmatter-list-item'),edit=input(item);edit.size=Math.max(2,[...item].length);edit.setAttribute('aria-label',name+' item '+(index+1));
          const replace=text=>{const next=[...value];next[index]=text;save(next);};
          edit.onchange=()=>replace(edit.value);edit.onkeydown=e=>{if(!e.isComposing&&e.key==='Enter'){e.preventDefault();edit.blur();}};
          cleanup.push(attachTagSuggestions(edit,replace,()=>value.filter((_,i)=>i!==index)));
          const remove=button('×',()=>save(value.filter((_,i)=>i!==index)));remove.setAttribute('aria-label','Remove '+item);
          part.append(edit);linkField(part,edit);part.append(remove);field.append(part);
        });
        const add=input();add.className='frontmatter-list-add';add.placeholder=name==='tags'?'Add tag…':'Add item…';add.setAttribute('aria-label',name==='tags'?'Add tag':'Add list item');
        const append=text=>{text=text.trim();if(!text)return;save([...value,text]);dom.querySelector('[data-property='+CSS.escape(name)+'] .frontmatter-list-add')?.focus();};
        add.onkeydown=e=>{if(!e.isComposing&&e.key==='Enter'){e.preventDefault();e.stopPropagation();append(add.value);}};
        add.onchange=()=>append(add.value);
        cleanup.push(attachTagSuggestions(add,append,()=>value));
        field.append(add);
      } else if (type==='boolean') field.checked = value;
      else field.value = type==='list' ? value.join('\n') : type==='yaml' ? JSON.stringify(value,null,2) : value ?? '';
      if (type==='number') field.step='any';
      if (type==='date') { field.min='1970-01-01'; field.max='2100-12-31'; }
      if (type==='datetime') field.placeholder='YYYY-MM-DDTHH:mm';
      if (field.tagName==='TEXTAREA') field.rows=Math.min(6,Math.max(1,field.value.split('\n').length));
      const read = () => type==='list' ? value : type==='boolean' ? field.checked : field.value;
      const commitValue = () => {
        const next=read();
        if(type==='date'&&next&&!/^\d{4}-\d{2}-\d{2}$/.test(next))return;
        if(type==='number'&&String(next).trim()==='')return;
        if(commit(name,{value:next,type}))field.dataset.dirty='false';
      };
      field.oninput = () => { field.dataset.dirty='true'; };
      if(type!=='list') field.onchange = commitValue;
      if(type!=='list') field.onblur = () => { if(field.dataset.dirty==='true')commitValue(); };
      kind.onchange = () => {
        const next = kind.value;
        if (commit(name,{value:read(),type:next})) dom.querySelector('[data-property='+CSS.escape(name)+'] .frontmatter-value')?.focus();
        else kind.value=type;
      };
      for (const control of type==='list'?[key]:[key,field]) control.onkeydown = event => {
        if (event.isComposing) return;
        if (event.key==='Escape') { event.preventDefault(); render(); editor.commands.focus(); }
        else if (event.key==='Enter' && control.tagName!=='TEXTAREA') { event.preventDefault(); control.blur(); }
      };
      const remove = button(null,()=>commit(name,{remove:true}),'frontmatter-remove'); remove.append(icon('close')); remove.setAttribute('aria-label','Remove '+name);
      let container=field;
      if(type==='text'){container=el('div',null,'frontmatter-linked-value');container.append(field);linkField(container,field);}
      row.append(picker,key,container,remove); list.append(row);
    }
    const add = button('+ Add property',()=>{
      if (dom.querySelector('.frontmatter-new')) return;
      const row = el('form',null,'frontmatter-new'), name=input(); name.placeholder='Property name'; name.setAttribute('aria-label','New property name');
      const kind=select(propertyTypes.filter(([type])=>type!=='yaml'),'text'); kind.setAttribute('aria-label','New property type');
      row.append(name,kind,button('Add',()=>row.requestSubmit()),button('Cancel',()=>row.remove()));
      row.onsubmit=e=>{e.preventDefault(); const type=kind.value; const value=type==='number'?0:type==='boolean'?false:type==='list'?[]:''; if(commit(name.value,{value,type,add:true})) dom.querySelector('[data-property='+CSS.escape(name.value)+'] .frontmatter-value')?.focus();};
      dom.insertBefore(row,add); name.focus();
    },'frontmatter-add');
    dom.append(add);
  }
  dom.addEventListener('keydown',event=>{
    if ((event.metaKey||event.ctrlKey) && event.key.toLowerCase()==='s') {
      event.preventDefault(); document.activeElement?.blur(); onSave();
    }
    if ((event.metaKey||event.ctrlKey) && event.key.toLowerCase()==='z' && event.target.dataset.dirty!=='true' && !event.isComposing) {
      event.preventDefault(); event.shiftKey ? editor.commands.redo() : editor.commands.undo();
    }
  });
  render();
  return {dom, destroy(){cleanup.forEach(close=>close());}, stopEvent:()=>true, ignoreMutation:()=>true, update(next) {
    if (next.type!==current.type) return false;
    if (next.attrs.source!==current.attrs.source) {
      current=next;
      let rows;
      try { rows=readRows(); } catch { render(); return true; }
      if (shape(rows)!==renderedShape) render();
      else rows.forEach(row => {
        const field=dom.querySelector('[data-property='+CSS.escape(row.name)+'] .frontmatter-value');
        if(row.type==='list')return;
        if (field.type==='checkbox') field.checked=row.value;
        else if (field!==document.activeElement) field.value=displayValue(row);
        field.refreshPropertyLink?.();
      });
    }
    return true;
  }};
}
