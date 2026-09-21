export function wikiTarget(value) {
  if(typeof value!=='string')return null;
  const match=value.trim().match(/^!?\[\[([^\n]+?)\]\]$/);if(!match)return null;
  const [target,alias]=match[1].split('|');
  if(!target || /^[a-z][a-z0-9+.-]*:/i.test(target))return null;
  return {target,label:alias && !(value.trim().startsWith('!') && /^\d+(x\d+)?$/.test(alias)) ? alias : target};
}
// Keep the value directly editable; an adjacent link opens its attachment without
// stealing text selection or changing the stored wiki-link syntax.
let textMeasure;
export function attachPropertyLink(parent,field,enabled,open) {
  const link=document.createElement('a');link.className='property-link';link.textContent='↗';
  const resize=()=>{if(!field.isConnected||link.hidden)return;textMeasure??=document.createElement('canvas').getContext('2d');const style=getComputedStyle(field);textMeasure.font=style.font;field.style.setProperty('--property-link-width',Math.ceil(textMeasure.measureText(field.value).width+(parseFloat(style.paddingLeft)||0)+(parseFloat(style.paddingRight)||0)+4)+'px');};
  const refresh=()=>{const value=enabled()&&wikiTarget(field.value);link.hidden=!value;field.classList.toggle('has-property-link',!!value);if(value){resize();queueMicrotask(resize);}if(value){link.href=value.target;link.title='Open '+value.label;link.setAttribute('aria-label',link.title);}else link.removeAttribute('href');};
  link.onclick=event=>{event.preventDefault();event.stopPropagation();const value=enabled()&&wikiTarget(field.value);if(value)open(value.target);};
  field.refreshPropertyLink=refresh;field.addEventListener('input',refresh);field.addEventListener('change',refresh);parent.append(link);refresh();return refresh;
}
