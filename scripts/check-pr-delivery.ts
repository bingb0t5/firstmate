/** Read-only Firstmate delivery intake. CLI contract: bin/fm-nm-pr-preflight.sh. */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { runPrCommunicationCheck } from './check-pr-communication.ts';
import { runFirstmateCeoOverviewCheck } from './check-firstmate-ceo-overview.ts';

function refuse(message: string): never {
  throw new Error(message);
}

function unquoted(body: string): string {
  const lines: string[] = [];
  let fence: { marker: string; length: number } | undefined;
  for (const line of body.split(/\r?\n/)) {
    if (/^(?: {0,3}>| {4}| {0,3}\t)/.test(line)) continue;
    const match = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (fence) {
      if (match && match[1][0] === fence.marker && match[1].length >= fence.length && !match[2].trim()) fence = undefined;
      continue;
    }
    if (match && !(match[1][0] === '`' && match[2].includes('`'))) {
      fence = { marker: match[1][0], length: match[1].length };
      continue;
    }
    lines.push(line);
  }
  return lines.join('\n');
}

function section(body: string, heading: string): string {
  const lines = body.split('\n');
  const start = lines.findIndex(line => line.trim().toLowerCase() === `## ${heading}`);
  if (start < 0) return '';
  const rest = lines.slice(start + 1);
  const end = rest.findIndex(line => /^##\s+/.test(line));
  return (end < 0 ? rest : rest.slice(0, end)).join('\n');
}

function assess(title: string, body: string, source: string): void {
  for (const check of [runPrCommunicationCheck, runFirstmateCeoOverviewCheck]) {
    const result = check({ title, body });
    if (result.exitCode !== 0) refuse(`${source}: ${result.lines.join('\n')}`);
  }
  // Intake additionally requires the technical section from the shared template.
  // Quoted template text cannot stand in for authored prose; shared rules stay pinned.
  const visible = unquoted(body.replace(/<!--[\s\S]*?(?:-->|$)/g, ''));
  const content = section(visible, 'what changed technically');
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
    const visible = unquoted(pr.body).replace(/<!--[\s\S]*?(?:-->|$)/g, (comment: string) =>
      comment.startsWith('<!-- no-mistakes-pipeline-attestation:v1 ') ? comment : '');
    const pipeline = section(visible, 'pipeline');
    if (!pipeline.includes('Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)')) {
      refuse('existing live PR body has no pipeline signature outside quoted evidence; ask its owner to reconcile it');
    }
    const attestations = [...pipeline.matchAll(/<!-- no-mistakes-pipeline-attestation:v1 (.*?) -->/g)];
    if (attestations.length !== 1) refuse('existing live PR body needs exactly one pipeline attestation; ask its owner to reconcile it');
    const attestation = JSON.parse(attestations[0][1]);
    if (attestation?.head_sha !== pr.head.sha) {
      refuse('existing live PR body has a stale pipeline head; ask its owner to reconcile it before another push');
    }
    if (!Array.isArray(attestation.steps) || ['review', 'test', 'document'].some(step => {
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
