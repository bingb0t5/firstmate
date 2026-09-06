/**
 * GitHub Actions entrypoint for Firstmate's CEO overview quality check.
 * Shared template completeness stays in the vendored Lalo assessor.
 */
import { pathToFileURL } from 'node:url';

import {
  emitPrCommunicationCheckOutput,
} from './check-pr-communication.ts';
import { assessFirstmateCeoOverview } from './pr-communication/firstmateCeoOverview.ts';

export function runFirstmateCeoOverviewCheck(input: {
  title: string;
  body: string | null | undefined;
}): { exitCode: number; lines: string[] } {
  const result = assessFirstmateCeoOverview(input);
  const lines: string[] = [];

  if (!result.eligible) {
    lines.push(`Cannot enter staging until completed: ${result.missing.join('; ')}`);
    return { exitCode: 1, lines };
  }

  lines.push('Firstmate CEO overview is complete.');
  return { exitCode: 0, lines };
}

function main(): void {
  const title = process.env.PR_TITLE ?? '';
  const body = process.env.PR_BODY ?? '';
  const { exitCode, lines } = runFirstmateCeoOverviewCheck({ title, body });
  emitPrCommunicationCheckOutput({ exitCode, lines });
  process.exit(exitCode);
}

const entry = process.argv[1] ? pathToFileURL(process.argv[1]).href : '';
if (entry && import.meta.url === entry) {
  main();
}
