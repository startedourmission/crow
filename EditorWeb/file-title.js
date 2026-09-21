import {editFrontmatter,frontmatter} from './frontmatter-model.js';
// The filename is UI, never a heading inserted into the Markdown source.
export function fileTitle(onRename) {
  const dom=document.createElement('div');dom.className='note-file-heading';dom.setAttribute('role','heading');dom.setAttribute('aria-level','1');
  const input=document.createElement('textarea');input.rows=1;input.className='note-file-title';input.setAttribute('aria-label','Note filename');input.spellcheck=false;
  const error=document.createElement('div');error.className='note-title-error';error.setAttribute('role','alert');dom.append(input,error);
  let name='',busy=false,width=0;
  function resize(){if(!input.isConnected||dom.hidden)return;input.style.height='auto';input.style.height=input.scrollHeight+'px';}
  const observer=new ResizeObserver(entries=>{const next=entries[0].contentRect.width;if(next!==width){width=next;resize();}});observer.observe(dom);
  input.oninput=resize;

  function set(value){name=value??'';dom.hidden=!name;if(document.activeElement!==input&&!busy)input.value=name.replace(/\.md$/i,'');requestAnimationFrame(resize);}
  async function commit(){
    if(busy)return;const title=input.value.trim(),before=name.replace(/\.md$/i,'');if(title===before)return;
    if(!title||/[\/\\\0\r\n]/.test(title)||title==='.'||title==='..'){error.textContent='Enter a valid filename.';return;}
    busy=true;input.readOnly=true;error.textContent='';
    try{const renamed=await onRename(title);name=renamed??title+'.md';input.value=name.replace(/\.md$/i,'');}
    catch(e){error.textContent=e.message??String(e);}
    finally{busy=false;input.readOnly=false;resize();}
  }
  input.onblur=commit;
  input.onkeydown=e=>{if(e.isComposing)return;if(e.key==='Enter'){e.preventDefault();e.stopPropagation();input.blur();}else if(e.key==='Escape'){e.preventDefault();e.stopPropagation();input.value=name.replace(/\.md$/i,'');error.textContent='';input.blur();resize();}};
  return {dom,input,set,destroy:()=>observer.disconnect()};
}

export function renamedNoteSource(source,filename) {
  const rows=frontmatter(source).rows,meta=Object.fromEntries(rows.map(r=>[r.name,r.value]));
  let title=filename.replace(/\.md$/i,'');
  if(['milestone','revision'].includes(meta.kind)){const project=typeof meta.project==='string'?meta.project.replace(/^\[\[|\]\]$/g,''):'';if(project&&title.startsWith(project+'-'))title=title.slice(project.length+1);}
  let updated=editFrontmatter(source,'title',{value:title,type:'text',add:!Object.hasOwn(meta,'title')});
  // Short title links and legacy UUID-note links remain resolvable after a rename.
  if(typeof meta.title==='string'&&meta.title!==title&&meta.title.trim()){
    const aliases=Array.isArray(meta.aliases)?meta.aliases:typeof meta.aliases==='string'?[meta.aliases]:[];
    if(!aliases.includes(meta.title))updated=editFrontmatter(updated,'aliases',{value:[...aliases,meta.title],type:'list',add:!Object.hasOwn(meta,'aliases')});
  }
  return updated;
}
