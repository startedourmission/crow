import {Node} from '@tiptap/core';
export const WikiLink = Node.create({
  name: 'wikiLink', group: 'inline', inline: true, atom: true,
  addAttributes() { return {source: {default: ''}, target: {default: ''}, label: {default: ''}}; },
  parseHTML() { return [{tag: 'a[data-wikilink]'}]; },
  renderHTML({node}) { return ['a', {'data-wikilink': '', href: node.attrs.target, contenteditable: 'false'}, node.attrs.label]; },
  renderMarkdown(node) { return node.attrs.source; }
});
export function wikiNodes(nodes, enabled = true, insideCode = false) {
  return nodes.flatMap(node => {
    if (node.content) return [{...node, content: wikiNodes(node.content, enabled, insideCode || node.type === 'codeBlock' || node.type === 'frontmatter')}];
    if (!enabled || insideCode || node.type !== 'text' || node.marks?.some(mark => ['code','link'].includes(mark.type))) return [node];
    const output = []; let cursor = 0;
    for (const match of node.text.matchAll(/!?\[\[([^\n]+?)\]\]/g)) {
      if (match.index > cursor) output.push({...node, text: node.text.slice(cursor, match.index)});
      const [target, alias] = match[1].split('|');
      output.push({type: 'wikiLink', attrs: {source: match[0], target, label: alias || target}});
      cursor = match.index + match[0].length;
    }
    if (!output.length) return [node];
    if (cursor < node.text.length) output.push({...node, text: node.text.slice(cursor)});
    return output;
  });
}
