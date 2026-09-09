/** Read-only Firstmate delivery intake. CLI contract: bin/fm-nm-pr-preflight.sh. */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fromMarkdown, gfm, gfmFromMarkdown } from './markdown/parser.mjs';
import { deliveryNarrative } from './pr-delivery-narrative.ts';
import { runPrCommunicationCheck } from './check-pr-communication.ts';
import { runFirstmateCeoOverviewCheck } from './check-firstmate-ceo-overview.ts';

function refuse(message: string): never {
  throw new Error(message);
}

function blank(text: string): string {
  return text.replace(/[^\r\n]/g, ' ');
}

type MarkdownNode = {
  type: string;
  depth?: number;
  fences?: number;
  position: { start: { offset: number }; end: { offset: number } };
  children?: MarkdownNode[];
};

function parseMarkdown(body: string, inlineContext = false): MarkdownNode {
  return fromMarkdown(body, {
    extensions: [gfm(), ...(inlineContext ? [{ disable: { null: ['htmlFlow'] } }] : [])],
    mdastExtensions: [gfmFromMarkdown(), {
      enter: {
        codeFencedFence(this: { stack: MarkdownNode[] }): void {
          const block = this.stack.findLast(node => node.type === 'code');
          if (block) block.fences = (block.fences || 0) + 1;
        },
      },
    }],
  });
}

function hasUnclosedFence(node: MarkdownNode, offset: number): boolean {
  return (node.type === 'code' && node.fences === 1 && node.position.start.offset < offset) ||
    Boolean(node.children?.some(child => hasUnclosedFence(child, offset)));
}

function contains(node: MarkdownNode, start: number, end: number): boolean {
  return node.position.start.offset <= start && node.position.end.offset >= end;
}

function unquoted(body: string): string {
  const tree = parseMarkdown(body);
  const ranges: { start: number; end: number }[] = [];
  const visit = (node: MarkdownNode): void => {
    if (['blockquote', 'code', 'html', 'inlineCode', 'thematicBreak', 'definition'].includes(node.type)) return;
    if (node.children) node.children.forEach(visit);
    else ranges.push({ start: node.position.start.offset, end: node.position.end.offset });
  };
  visit(tree);
  let visible = '';
  let cursor = 0;
  for (const range of ranges) {
    visible += blank(body.slice(cursor, range.start)) + body.slice(range.start, range.end);
    cursor = range.end;
  }
  return visible + blank(body.slice(cursor));
}

function pipelineEvidence(body: string): (offset: number, evidence: string, html?: boolean) => boolean {
  const tree = parseMarkdown(body);
  const context = parseMarkdown(body, true);
  const headings = (tree.children || []).filter(node => node.type === 'heading' && node.depth === 2 &&
    /^ {0,3}##[ \t]+/.test(body.slice(node.position.start.offset, node.position.end.offset)));
  const headingIndex = headings.findIndex(node =>
    /^ {0,3}##[ \t]+Pipeline[ \t]*\r?$/i.test(body.slice(node.position.start.offset, node.position.end.offset)));
  const pipeline = headings[headingIndex];
  const end = headings[headingIndex + 1]?.position.start.offset ?? body.length;
  return (offset, evidence, html = false) => {
    const evidenceEnd = offset + evidence.length;
    const lineStart = body.lastIndexOf('\n', offset - 1) + 1;
    const nextLine = body.indexOf('\n', offset);
    if (!pipeline || hasUnclosedFence(tree, offset) || offset < pipeline.position.end.offset || evidenceEnd > end ||
        body.slice(lineStart, nextLine < 0 ? body.length : nextLine).trim() !== evidence) return false;
    const block = tree.children?.find(node => contains(node, offset, evidenceEnd));
    const paragraph = context.children?.find(node => contains(node, offset, evidenceEnd));
    if (!block || block.type !== (html ? 'html' : 'paragraph') || paragraph?.type !== 'paragraph') return false;
    if (html) {
      return block.position.start.offset === offset && block.position.end.offset === evidenceEnd &&
        Boolean(paragraph.children?.some(node => node.type === 'html' &&
          node.position.start.offset === offset && node.position.end.offset === evidenceEnd));
    }
    return !paragraph.children?.some(node =>
      !['text', 'link', 'break'].includes(node.type) &&
      node.position.start.offset < evidenceEnd && node.position.end.offset > offset);
  };
}

function sectionBounds(body: string, heading: string): { start: number; end: number } | undefined {
  const headings = (parseMarkdown(body).children || []).filter(node => node.type === 'heading' && node.depth === 2 &&
    /^ {0,3}##[ \t]+/.test(body.slice(node.position.start.offset, node.position.end.offset)));
  const index = headings.findIndex(node => body.slice(node.position.start.offset, node.position.end.offset)
    .replace(/^ {0,3}##[ \t]+/, '').trim().toLowerCase() === heading);
  if (index < 0) return undefined;
  return { start: headings[index].position.end.offset, end: headings[index + 1]?.position.start.offset ?? body.length };
}

function section(body: string, heading: string): string {
  const bounds = sectionBounds(body, heading);
  return bounds ? unquoted(body).slice(bounds.start, bounds.end) : '';
}

function assess(title: string, body: string, source: string): void {
  const narrative = deliveryNarrative(body, source);
  for (const check of [runPrCommunicationCheck, runFirstmateCeoOverviewCheck]) {
    for (const assessmentBody of [body, narrative]) {
      const result = check({ title, body: assessmentBody });
      if (result.exitCode !== 0) refuse(`${source}: ${result.lines.join('\n')}`);
    }
  }
  // Intake additionally requires the technical section from the shared template.
  // Quoted template text cannot stand in for authored prose; shared rules stay pinned.
  const content = section(narrative, 'what changed technically');
  if (!content.trim() || /^(?:todo|tbd|pending|none|n\/a)[.!]?$/i.test(content.trim())) {
    refuse(`${source}: complete the What changed technically section outside quoted evidence`);
  }
}

function main(): void {
  const args = new Map<string, string>();
  for (let i = 2; i < process.argv.length; i += 2) {
    const key = process.argv[i];
    const value = process.argv[i + 1];
    if (!['--intent-file', '--repo', '--head'].includes(key) || !value || args.has(key)) {
      refuse('usage: fm-nm-pr-preflight.sh --intent-file <file> --repo <owner/repo> --head <owner:branch>');
    }
    args.set(key, value);
  }
  const file = args.get('--intent-file');
  const repo = args.get('--repo') || '';
  const head = args.get('--head') || '';
  const headMatch = head.match(/^([A-Za-z0-9-]+):(.+)$/);
  if (!file || !/^[A-Za-z0-9-]+\/[A-Za-z0-9_.-]+$/.test(repo) || !headMatch) {
    refuse('provide --intent-file, explicit --repo owner/repo, and --head owner:branch');
  }
  const branch = execFileSync('git', ['symbolic-ref', '--quiet', '--short', 'HEAD'], { encoding: 'utf8' }).trim();
  if (branch !== headMatch[2] || branch === 'main' || branch === 'master') {
    refuse('the explicit head must name the checked-out feature branch');
  }
  const intent = readFileSync(file, 'utf8');
  if (Buffer.byteLength(intent) > 16000) refuse('intent exceeds 16000 bytes; shorten prose while retaining every task requirement');
  if (/no-mistakes-pipeline-attestation:|Updates from \[git push no-mistakes\]|^\s*##\s+Pipeline\s*$/im.test(intent)) {
    refuse('authored intent must not contain reserved pipeline sections, signatures, or attestations');
  }
  assess('Firstmate delivery intent', intent, 'authored intent');

  // A base64 scalar avoids interpreting remote prose as TOON, shell code, or
  // terminal instructions. Accept only the complete successful gh-axi envelope.
  const output = execFileSync('gh-axi', [
    'api', 'GET', `/repos/${repo}/pulls`,
    '--hostname', 'github.com',
    '--field', 'state=open', '--field', `head=${head}`, '--field', 'per_page=2',
    '--jq', '@base64', '--full',
  ], { encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024 });
  const match = output.match(/^api_response:\r?\n  body: ([A-Za-z0-9+/]+={0,2})\r?\n  truncated: false\s*$/);
  if (!match) refuse('cannot confirm complete gh-axi PR data; inspect the read-only forge query and retry');
  const pulls = JSON.parse(Buffer.from(match[1], 'base64').toString('utf8'));
  if (!Array.isArray(pulls) || pulls.length > 1) refuse('open PR lookup is ambiguous; reconcile the explicit delivery target');
  for (const pr of pulls) {
    if (pr?.state !== 'open' || pr?.base?.repo?.full_name?.toLowerCase() !== repo.toLowerCase() ||
        pr?.head?.repo?.owner?.login?.toLowerCase() !== headMatch[1].toLowerCase() ||
        pr?.head?.ref !== branch || !/^[a-f0-9]{40}$/.test(pr?.head?.sha || '') ||
        typeof pr?.body !== 'string' || typeof pr?.title !== 'string') {
      refuse('forge response does not identify the requested open PR; no delivery authorized');
    }
    assess(pr.title, pr.body, 'existing live PR body');
    if ((pr.body.match(/<!-- no-mistakes-pipeline-attestation:/g) || []).length !== 1) {
      refuse('existing live PR body has missing or ambiguous pipeline attestations; ask its owner to reconcile it');
    }
    const isEvidence = pipelineEvidence(pr.body);
    const signature = 'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)';
    const signatureLines = [...pr.body.matchAll(/^[^\n]+/gm)];
    if (!signatureLines.some(line => line[0].trim() === signature && isEvidence(line.index + line[0].indexOf(signature), signature))) {
      refuse('existing live PR body has no pipeline signature outside quoted evidence; ask its owner to reconcile it');
    }
    const originalAttestation = pr.body.match(/<!-- no-mistakes-pipeline-attestation:v1 ([\s\S]*?) -->/);
    if (!originalAttestation || !isEvidence(originalAttestation.index, originalAttestation[0], true)) {
      refuse('existing live PR body needs exactly one unquoted pipeline attestation; ask its owner to reconcile it');
    }
    const attestation = JSON.parse(originalAttestation[1]);
    if (attestation?.head_sha !== pr.head.sha) {
      refuse('existing live PR body has a stale pipeline head; ask its owner to reconcile it before another push');
    }
    if (!Array.isArray(attestation.steps) ||
        attestation.steps.some((entry: unknown) => entry === null || typeof entry !== 'object' || Array.isArray(entry))) {
      refuse('existing live PR body has invalid pipeline step entries; return to its pipeline owner');
    }
    if (['review', 'test', 'document'].some(step => {
      const entries = attestation.steps.filter((entry: { step?: string; status?: string }) => entry?.step === step);
      return entries.length !== 1 || entries[0].status !== 'completed';
    })) refuse('existing live PR body lacks completed required pipeline steps; return to its pipeline owner');
  }
  console.error(`PR communication preflight passed: authored intent and ${pulls.length} existing live PR body checked. Recheck after any input or head change.`);
  process.stdout.write(intent);
}

try {
  main();
} catch (error) {
  console.error(`REFUSED: ${error instanceof Error ? error.message : 'preflight failed'}`);
  console.error('No PR or pipeline was changed. Correct the authored intent or have the existing PR owner reconcile its live body, then repeat the preflight.');
  process.exitCode = 2;
}
