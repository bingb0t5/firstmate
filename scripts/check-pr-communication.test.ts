import assert from 'node:assert/strict';
import test from 'node:test';

import {
  emitPrCommunicationCheckOutput,
  planPrCommunicationEmission,
  runPrCommunicationCheck,
} from './check-pr-communication.ts';

const completeBody = `## CEO overview

- **What is changing:** Members can see the status of their submitted requests.
- **Why it matters:** It reduces support messages asking for updates.
- **Customer or business impact:** Members get clearer communication and the team saves time.
- **Risk and rollout:** Low risk. Release through staging and confirm the main request flow.

## Validation

- **Checks passed:** Unit tests and type check.
- **Checks not run:** End-to-end test was not run locally.
- **Evidence and limitations:** Tested with a representative request.

## Module-boundary decision

Current module retained: request status rendering belongs with the existing member request page module.

## Decision needed

No decision required.`;

test('CLI reports complete descriptions as exit 0', () => {
  const result = runPrCommunicationCheck({
    title: 'Show members the status of their requests',
    body: completeBody,
  });
  assert.equal(result.exitCode, 0);
  assert.ok(result.lines.some((line) => line.includes('PR communication is complete')));
});

test('CLI fails incomplete descriptions with staging-matching copy', () => {
  const result = runPrCommunicationCheck({
    title: 'Show members the status of their requests',
    body: '## CEO overview\n\n- **What is changing:** A status is shown.\n',
  });
  assert.equal(result.exitCode, 1);
  const failure = result.lines.find((line) =>
    line.startsWith('Cannot enter staging until completed:'),
  );
  assert.ok(failure);
  assert.match(failure!, /CEO overview: Why it matters/);
  assert.match(failure!, /Decision needed/);
  assert.match(failure!, /Module-boundary decision/);
  assert.match(failure!, /Validation: Checks passed/);
});

test('failure emission uses stdout and ::error:: (not stderr-only)', () => {
  const failure =
    'Cannot enter staging until completed: CEO overview: Why it matters; Decision needed';
  const planned = planPrCommunicationEmission([failure], 1);
  assert.deepEqual(
    planned.map((item) => item.kind),
    ['stdout', 'error_annotation', 'step_summary'],
  );
  assert.equal(planned[0]?.text, failure);
  assert.equal(planned[1]?.text, `::error::${failure}`);
  assert.equal(planned[2]?.text, failure);

  const stdout: string[] = [];
  const summary: string[] = [];
  emitPrCommunicationCheckOutput({
    exitCode: 1,
    lines: [failure],
    writeStdout: (text) => stdout.push(text),
    appendStepSummary: (text) => summary.push(text),
  });
  assert.deepEqual(stdout, [failure, `::error::${failure}`]);
  assert.deepEqual(summary, [failure]);
});

test('success emission is stdout-only', () => {
  const planned = planPrCommunicationEmission(['PR communication is complete.'], 0);
  assert.deepEqual(planned, [{ kind: 'stdout', text: 'PR communication is complete.' }]);
});
