/**
 * GitHub Actions entrypoint for the pr-communication check.
 * Rules are vendored from lalo-admin src/shared/prCommunication.ts. Do not fork them here.
 */
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

import { assessPullRequestCommunication } from './pr-communication/prCommunication.ts';

export function runPrCommunicationCheck(input: {
  title: string;
  body: string | null | undefined;
}): { exitCode: number; lines: string[] } {
  const result = assessPullRequestCommunication(input);
  const lines: string[] = [];

  for (const warning of result.clarityWarnings) {
    lines.push(`Clarity check: ${warning}`);
  }

  if (!result.eligible) {
    lines.push(`Cannot enter staging until completed: ${result.missing.join('; ')}`);
    return { exitCode: 1, lines };
  }

  lines.push('PR communication is complete.');
  return { exitCode: 0, lines };
}

export type PrCommunicationEmission =
  | { kind: 'stdout'; text: string }
  | { kind: 'error_annotation'; text: string }
  | { kind: 'step_summary'; text: string };

/** Pure plan for how check lines are surfaced (stdout + GHA annotations/summary). */
export function planPrCommunicationEmission(
  lines: string[],
  exitCode: number,
): PrCommunicationEmission[] {
  const planned: PrCommunicationEmission[] = [];
  for (const line of lines) {
    // Always stdout so gh --log-failed / job log download see the missing-section list.
    planned.push({ kind: 'stdout', text: line });
    if (exitCode !== 0 && line.startsWith('Cannot enter staging')) {
      planned.push({ kind: 'error_annotation', text: `::error::${line}` });
      planned.push({ kind: 'step_summary', text: line });
    }
  }
  return planned;
}

export function emitPrCommunicationCheckOutput(opts: {
  exitCode: number;
  lines: string[];
  writeStdout?: (text: string) => void;
  appendStepSummary?: (text: string) => void;
  githubStepSummaryPath?: string | undefined;
}): void {
  const writeStdout = opts.writeStdout ?? ((text: string) => console.log(text));
  const summaryPath = opts.githubStepSummaryPath ?? process.env.GITHUB_STEP_SUMMARY;
  const appendStepSummary =
    opts.appendStepSummary ??
    ((text: string) => {
      if (!summaryPath) return;
      appendFileSync(summaryPath, `${text}\n`, 'utf8');
    });

  for (const item of planPrCommunicationEmission(opts.lines, opts.exitCode)) {
    if (item.kind === 'stdout' || item.kind === 'error_annotation') {
      writeStdout(item.text);
      continue;
    }
    appendStepSummary(item.text);
  }
}

function main(): void {
  const title = process.env.PR_TITLE ?? '';
  const body = process.env.PR_BODY ?? '';
  const { exitCode, lines } = runPrCommunicationCheck({ title, body });
  emitPrCommunicationCheckOutput({ exitCode, lines });
  process.exit(exitCode);
}

const entry = process.argv[1] ? pathToFileURL(process.argv[1]).href : '';
if (entry && import.meta.url === entry) {
  main();
}
