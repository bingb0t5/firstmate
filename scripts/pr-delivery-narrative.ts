import { fromMarkdown, gfm, gfmFromMarkdown } from './markdown/parser.mjs';

type Node = {
  type: string;
  depth?: number;
  position: { start: { offset: number; line: number }; end: { offset: number } };
  children?: Node[];
};
type Range = { start: number; end: number };

const fields = new Map([
  ['CEO overview', ['What is changing', 'Why it matters', 'Customer or business impact', 'Risk and rollout']],
  ['Validation', ['Checks passed', 'Checks not run', 'Evidence and limitations']],
]);

function parse(body: string): Node {
  return fromMarkdown(body, { extensions: [gfm()], mdastExtensions: [gfmFromMarkdown()] });
}

function headings(tree: Node, body: string): Array<Range & { name: string; line: number; content: number }> {
  const nodes = (tree.children || []).filter(node => node.type === 'heading' && node.depth === 2 &&
    /^ {0,3}##[ \t]+/.test(body.slice(node.position.start.offset, node.position.end.offset)));
  return nodes.map((node, index) => ({
    start: node.position.start.offset,
    end: nodes[index + 1]?.position.start.offset ?? body.length,
    content: node.position.end.offset,
    line: node.position.start.line,
    name: body.slice(node.position.start.offset, node.position.end.offset).replace(/^ {0,3}##[ \t]+/, '').trim().toLowerCase(),
  }));
}

function mask(body: string, ranges: Range[]): string {
  for (const { start, end } of ranges) {
    body = body.slice(0, start) + body.slice(start, end).replace(/[^\r\n]/g, ' ') + body.slice(end);
  }
  return body;
}

function forbiddenBullet(node: Node): boolean {
  return ['html', 'blockquote', 'code', 'inlineCode'].includes(node.type) ||
    Boolean(node.children?.some(forbiddenBullet));
}

export function deliveryNarrative(body: string, source: string): string {
  const pipeline = headings(parse(body), body).filter(heading => heading.name === 'pipeline');
  const narrative = mask(body, pipeline);
  const tree = parse(narrative);
  const comments: Range[] = [];
  const inspectHtml = (node: Node): void => {
    if (node.type === 'html') {
      const start = node.position.start.offset;
      const html = narrative.slice(start, node.position.end.offset);
      const nonComment = html.replace(/<!--[\s\S]*?(?:-->|$)/g, comment => comment.replace(/[^\r\n]/g, ' '));
      const index = nonComment.search(/\S/);
      if (index >= 0) {
        const line = node.position.start.line + (html.slice(0, index).match(/\n/g) || []).length;
        throw new Error(`${source}: raw HTML on line ${line}; remove it or use plain Markdown outside ## Pipeline`);
      }
      comments.push({ start, end: node.position.end.offset });
    }
    node.children?.forEach(inspectHtml);
  };
  inspectHtml(tree);
  let projected = mask(narrative, comments);
  const sections = headings(tree, narrative);
  for (const [name, labels] of fields) {
    const section = sections.find(heading => heading.name === name.toLowerCase());
    if (!section) throw new Error(`${source}: add ## ${name} with its exact template bullets`);
    const accepted: Range[] = [];
    const found = new Set<string>();
    for (const list of tree.children || []) {
      if (list.type !== 'list' || list.position.start.offset < section.content || list.position.end.offset > section.end) continue;
      for (const item of list.children || []) {
        const start = item.position.start.offset;
        const lineStart = narrative.lastIndexOf('\n', start - 1) + 1;
        const newline = narrative.indexOf('\n', start);
        const end = newline < 0 ? narrative.length : newline;
        const line = narrative.slice(start, end).replace(/\r$/, '');
        const label = labels.find(label => {
          const prefix = `- **${label}:**`;
          return line.startsWith(prefix) && (line.length === prefix.length || /^[ \t]/.test(line.slice(prefix.length)));
        });
        if (start !== lineStart || item.children?.[0]?.type !== 'paragraph' || !label) continue;
        const bullet = narrative.slice(start, item.position.end.offset);
        if (forbiddenBullet(item) || /(?:^|[ \t])>|`{3,}|~{3,}/m.test(bullet)) {
          throw new Error(`${source}: ${name} bullet on line ${item.position.start.line} contains quoted or coded content; use plain prose after - **${label}:**`);
        }
        accepted.push({ start, end });
        found.add(label);
      }
    }
    for (const label of labels) {
      if (!found.has(label)) {
        throw new Error(`${source}: ${name} at line ${section.line} requires - **${label}:** at the start of an unquoted template bullet`);
      }
    }
    projected = mask(projected, [{ start: section.content, end: section.end }]);
    for (const { start, end } of accepted) projected = projected.slice(0, start) + narrative.slice(start, end) + projected.slice(end);
  }
  return projected;
}
