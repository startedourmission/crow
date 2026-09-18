import {WikiLink,wikiNodes} from './note-wikilinks.js';
import {Editor,Node,Extension} from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import {Markdown} from '@tiptap/markdown';
import {TableKit} from '@tiptap/extension-table';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import {frontmatterView} from './frontmatter-editor.js';
import {NoteCompletions,setCatalog} from './note-completions.js';
import {markdownEditorCSS} from './editor-styles.js';

export function embeddedNoteEditor(element,source,{onChange,onSave,onOpenLink,paths,editable=true}) {
  if(!document.querySelector('[data-note-editor-style]')){const style=document.createElement('style');style.dataset.noteEditorStyle='';style.textContent=markdownEditorCSS;document.head.append(style);}
  document.documentElement.dataset.noteLinks='true';setCatalog({paths,tags:[]});
  const Frontmatter=Node.create({name:'frontmatter',group:'block',atom:true,selectable:false,
    addAttributes(){return {source:{default:''}};},parseHTML(){return [{tag:'section[data-frontmatter]'}];},renderHTML(){return ['section',{'data-frontmatter':'',class:'frontmatter',contenteditable:'false'}];},
    addNodeView(){return args=>frontmatterView({...args,onOpenLink,onSave});},renderMarkdown(node){return node.attrs.source;}});
  const shortcuts=Extension.create({name:'crowPopupShortcuts',addKeyboardShortcuts(){return {'Mod-s':()=>{onSave();return true;}};}});
  let initialBody,bodySource;
  const editor=new Editor({element,editable,injectCSS:false,extensions:[Frontmatter,WikiLink,NoteCompletions,StarterKit.configure({link:{openOnClick:false},trailingNode:false}),Markdown,TableKit.configure({table:{resizable:false}}),TaskList,TaskItem.configure({nested:true}),shortcuts],
    editorProps:{attributes:{'aria-label':'Markdown editor',spellcheck:'false'},handlePaste(_view,event){const text=event.clipboardData?.getData('text/plain');if(text==null)return false;event.preventDefault();editor.commands.insertContent(text,{contentType:'markdown'});return true;},handleClick(_view,_pos,event){const a=event.target.closest('a');if(a&&(event.metaKey||event.ctrlKey||!editable)){event.preventDefault();onOpenLink(a.getAttribute('href'));return true;}return false;}},
    onUpdate(){onChange(read());}});
  const match=source.match(/^\uFEFF?---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/),front=match?.[0];bodySource=front?source.slice(front.length):source;
  const body=editor.markdown.parse(bodySource);body.content=wikiNodes(body.content?.length?body.content:[{type:'paragraph'}]);initialBody=JSON.stringify(body.content);
  editor.commands.setContent({type:'doc',content:[...(front?[{type:'frontmatter',attrs:{source:front}}]:[]),...(body.content??[])]},{emitUpdate:false});
  function read(){const content=editor.getJSON().content??[],front=content.find(n=>n.type==='frontmatter')?.attrs.source??'',body=content.filter(n=>n.type!=='frontmatter');return front+(JSON.stringify(body)===initialBody?bodySource:'\n'+editor.markdown.serialize({type:'doc',content:wikiNodes(body)})+'\n');}
  return {editor,read,destroy:()=>editor.destroy()};
}
