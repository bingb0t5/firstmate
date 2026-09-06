/**
 * Firstmate-specific CEO overview quality gate.
 *
 * The shared Lalo assessor in prCommunication.ts remains the owner of template
 * completeness (labelled CEO fields, Validation, Module-boundary decision, and
 * Decision needed). This module fails a missing CEO overview or one that is
 * only implementation intent, which that shared assessor treats as optional
 * once the labels are filled.
 *
 * Do not copy these rules into the vendored SoT file.
 */
import { assessPullRequestCommunication } from './prCommunication.ts';

export const MISSING_CEO_OVERVIEW_MESSAGE =
  'CEO overview is missing or incomplete; implementation intent is not an acceptable substitute';

export const IMPLEMENTATION_ONLY_CEO_OVERVIEW_MESSAGE =
  'CEO overview is only implementation intent; tell the captain what is changing, why it matters, impact, risk, and any decision needed';

const IMPLEMENTATION_BRIEF_MARKERS = [
  /\bdo not invent\b/i,
  /\bdo not implement\b/i,
  /\bdo not merge\b/i,
  /\bdo not hand-edit\b/i,
  /\bdo not resume\b/i,
  /\bnever assert implementation-source\b/i,
  /\bkeep one owner\b/i,
  /\bacceptance scenarios\b/i,
  /\bdrive all gates through no-mistakes\b/i,
  /\bnever add an agent name\b/i,
  /\bstop if the pipeline\b/i,
  /\bpreserve the target captain fork\b/i,
  /\bpreserve the existing pr\b/i,
  /\bnever merge, force, reset\b/i,
  /\bconstraints are withheld capabilities\b/i,
];

const IMPLEMENTATION_PATHS = /\b(?:bin|tests|scripts)\/[\w./-]+\.(?:sh|ts|mjs|js|py)\b/g;

export type FirstmateCeoOverviewAssessment = {
  eligible: boolean;
  missing: string[];
};

function overviewBlob(values: Array<string | null>): string {
  return values.filter((value): value is string => Boolean(value)).join('\n');
}

function isImplementationOnlyOverview(values: Array<string | null>): boolean {
  const blob = overviewBlob(values);
  if (!blob) return false;
  if (IMPLEMENTATION_BRIEF_MARKERS.some((marker) => marker.test(blob))) return true;
  const paths = blob.match(IMPLEMENTATION_PATHS) || [];
  return paths.length >= 2;
}

export function assessFirstmateCeoOverview(input: {
  title: string;
  body: string | null | undefined;
}): FirstmateCeoOverviewAssessment {
  const result = assessPullRequestCommunication(input);
  const overviewValues = [
    result.ceoOverview.what,
    result.ceoOverview.why,
    result.ceoOverview.impact,
    result.ceoOverview.riskAndRollout,
  ];
  const fieldGaps = result.missing.filter((item) => item.startsWith('CEO overview:'));
  const missing: string[] = [];

  if (fieldGaps.length > 0) {
    missing.push(MISSING_CEO_OVERVIEW_MESSAGE);
    missing.push(...fieldGaps);
  } else if (isImplementationOnlyOverview(overviewValues)) {
    missing.push(IMPLEMENTATION_ONLY_CEO_OVERVIEW_MESSAGE);
  }

  return {
    eligible: missing.length === 0,
    missing,
  };
}
