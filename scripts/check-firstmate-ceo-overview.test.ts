import assert from 'node:assert/strict';
import test from 'node:test';

import { runFirstmateCeoOverviewCheck } from './check-firstmate-ceo-overview.ts';
import {
  IMPLEMENTATION_ONLY_CEO_OVERVIEW_MESSAGE,
  MISSING_CEO_OVERVIEW_MESSAGE,
} from './pr-communication/firstmateCeoOverview.ts';

const completeOverview = `## CEO overview

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

const implementationOnlyOverview = `## CEO overview

- **What is changing:** Extract the duplicated process-event arm into one owner after reading bin/fm-procevent.sh and bin/fm-watch.sh; do not invent a second control plane.
- **Why it matters:** Keep one owner for the arm-and-shim contract and never assert implementation-source bytes.
- **Customer or business impact:** Preserve the target captain fork, do not merge, and stop if the pipeline opens a PR against the wrong remote.
- **Risk and rollout:** Add portable executable behavior tests under tests/named-subject.test.sh.

## Validation

- **Checks passed:** Unit tests and type check.
- **Checks not run:** End-to-end test was not run locally.
- **Evidence and limitations:** Tested with a representative request.

## Module-boundary decision

Current module retained: process-event registration stays with the existing owner.

## Decision needed

No decision required.`;

test('Firstmate CEO overview check passes a captain-facing overview', () => {
  const result = runFirstmateCeoOverviewCheck({
    title: 'Show members the status of their requests',
    body: completeOverview,
  });
  assert.equal(result.exitCode, 0);
  assert.ok(result.lines.some((line) => line.includes('Firstmate CEO overview is complete.')));
});

test('Firstmate CEO overview check fails a missing overview', () => {
  const result = runFirstmateCeoOverviewCheck({
    title: 'Harden wake routing',
    body: '## Intent\n\nExtract the duplicated process-event arm.\n',
  });
  assert.equal(result.exitCode, 1);
  const failure = result.lines.find((line) =>
    line.startsWith('Cannot enter staging until completed:'),
  );
  assert.ok(failure);
  assert.ok(failure.includes(MISSING_CEO_OVERVIEW_MESSAGE));
  assert.match(failure, /CEO overview: What is changing/);
});

test('Firstmate CEO overview check fails implementation-only filled fields', () => {
  const result = runFirstmateCeoOverviewCheck({
    title: 'Harden wake routing and process-event delivery',
    body: implementationOnlyOverview,
  });
  assert.equal(result.exitCode, 1);
  const failure = result.lines.find((line) =>
    line.startsWith('Cannot enter staging until completed:'),
  );
  assert.ok(failure);
  assert.ok(failure.includes(IMPLEMENTATION_ONLY_CEO_OVERVIEW_MESSAGE));
  assert.doesNotMatch(failure, /CEO overview: What is changing/);
});

test('Firstmate CEO overview check ignores leftover Intent when the overview is real', () => {
  const result = runFirstmateCeoOverviewCheck({
    title: 'Show members the status of their requests',
    body: `## Intent\n\nExtract the duplicated process-event arm into one owner.\n\n${completeOverview}`,
  });
  assert.equal(result.exitCode, 0);
});
