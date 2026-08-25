// SOURCE: bingb0t5/lalo-admin@main:src/shared/prCommunication.ts
// Re-vendor from that path when the SoT changes. Do not edit assessment rules here.

export type PrCeoOverview = {
  what: string | null;
  why: string | null;
  impact: string | null;
  riskAndRollout: string | null;
};

export type PrCommunicationAssessment = {
  eligible: boolean;
  ceoOverview: PrCeoOverview;
  decisionNeeded: string | null;
  moduleBoundaryDecision: string | null;
  missing: string[];
  clarityWarnings: string[];
};

const REQUIRED_OVERVIEW_FIELDS = [
  ['What is changing', 'what'],
  ['Why it matters', 'why'],
  ['Customer or business impact', 'impact'],
  ['Risk and rollout', 'riskAndRollout'],
] as const;
const REQUIRED_VALIDATION_FIELDS = ['Checks passed', 'Checks not run', 'Evidence and limitations'] as const;

const PLACEHOLDER_PATTERN = /^(?:\(?\s*(?:fill\s*(?:this|in)?|todo|tbd|n\/a|none|pending|not provided)\s*\)?)\.?$/i;
const JARGON_PATTERN = /\b(?:api|orm|typescript|javascript|tsx|jsx|lint|eslint|tsc|refactor|hook|schema|migration|webhook|ci\/cd|regex)\b/i;

function normalize(value: string, options?: { allowNone?: boolean }): string | null {
  const compact = value.replace(/\s+/g, ' ').trim();
  if (!compact) return null;
  if (PLACEHOLDER_PATTERN.test(compact) && !(options?.allowNone && /^none\.?$/i.test(compact))) return null;
  return compact;
}

const FENCE_PATTERN = /^ {0,3}(`{3,}|~{3,})(.*)$/;

/**
 * Marks the lines that sit inside a fenced code block (including the fence
 * lines themselves). Generated PR bodies embed evidence transcripts that quote
 * markdown, so a fenced `## ` line must neither satisfy a required section nor
 * truncate a real one.
 */
function fencedLineFlags(lines: string[]): boolean[] {
  const flags: boolean[] = [];
  let fence: { marker: string; length: number } | null = null;
  for (const line of lines) {
    const fenceMatch = line.match(FENCE_PATTERN);
    if (fence) {
      flags.push(true);
      const closes =
        fenceMatch !== null &&
        fenceMatch[1][0] === fence.marker &&
        fenceMatch[1].length >= fence.length &&
        fenceMatch[2].trim() === '';
      if (closes) fence = null;
      continue;
    }
    if (fenceMatch && !(fenceMatch[1][0] === '`' && fenceMatch[2].includes('`'))) {
      fence = { marker: fenceMatch[1][0], length: fenceMatch[1].length };
    }
    flags.push(fenceMatch !== null && fence !== null);
  }
  return flags;
}

function section(body: string, heading: string): string | null {
  const wanted = `## ${heading}`.toLowerCase();
  const lines = body.split(/\r?\n/);
  const fenced = fencedLineFlags(lines);
  const start = lines.findIndex(
    (line, index) => !fenced[index] && line.trim().toLowerCase() === wanted,
  );
  if (start < 0) return null;
  const content: string[] = [];
  for (let index = start + 1; index < lines.length; index += 1) {
    if (!fenced[index] && /^##\s+/.test(lines[index])) break;
    content.push(lines[index]);
  }
  return content.join('\n');
}

/** Optional short parenthetical qualifier between label and colon, e.g. (commit abc). */
const LABEL_QUALIFIER = '(?:\\s*\\(([^\\n)]{0,80})\\))?';

function labelledMatch(
  content: string | null,
  label: string,
): { value: string | null; line: string | null } {
  if (!content) return { value: null, line: null };
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const plainContent = content.replace(/\*\*/g, '');
  // Keep colon-adjacent whitespace on the same line so an empty value cannot
  // accidentally capture the next labelled line via \\s matching newlines.
  // Require a non-empty trailing value after the colon; a parenthetical
  // qualifier alone (or following bullets) does not satisfy the field.
  const expression = new RegExp(
    `^(\\s*(?:[-*]\\s*)?${escaped}${LABEL_QUALIFIER}[^\\S\\n]*:[^\\S\\n]*)(.*)$`,
    'im',
  );
  const match = plainContent.match(expression);
  if (match) {
    const trailing = String(match[3] ?? '');
    const line = match[0].replace(/\s+/g, ' ').trim();
    return { value: trailing.trim() ? trailing : null, line };
  }

  const nearMissExpression = new RegExp(`(?:^|\\s)(?:[-*]\\s*)?${escaped}\\b`, 'i');
  const nearMiss = plainContent
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line.length > 0 && nearMissExpression.test(line));
  return { value: null, line: nearMiss ? nearMiss.replace(/\s+/g, ' ') : null };
}

export function labelledValue(
  content: string | null,
  label: string,
  options?: { allowNone?: boolean },
): string | null {
  const match = labelledMatch(content, label);
  return normalize(match.value || '', options);
}

function missingLabelMessage(
  sectionName: string,
  label: string,
  content: string | null,
  options?: { allowNone?: boolean },
): string | null {
  const match = labelledMatch(content, label);
  if (normalize(match.value || '', options)) return null;
  const lineNote = match.line ? `found line: ${match.line}` : 'no line found';
  return `${sectionName}: ${label} (${lineNote})`;
}

export function assessPullRequestCommunication(input: {
  title: string;
  body: string | null | undefined;
}): PrCommunicationAssessment {
  const body = input.body || '';
  const overview = section(body, 'CEO overview');
  const ceoOverview = {
    what: labelledValue(overview, 'What is changing'),
    why: labelledValue(overview, 'Why it matters'),
    impact: labelledValue(overview, 'Customer or business impact'),
    riskAndRollout: labelledValue(overview, 'Risk and rollout'),
  } satisfies PrCeoOverview;
  const decisionNeeded = normalize(section(body, 'Decision needed') || '');
  const moduleBoundaryDecision = normalize(section(body, 'Module-boundary decision') || '');
  const missing = REQUIRED_OVERVIEW_FIELDS.flatMap(([label, key]) => {
    if (ceoOverview[key]) return [];
    const message = missingLabelMessage('CEO overview', label, overview);
    return [message || `CEO overview: ${label} (no line found)`];
  });
  if (!decisionNeeded) missing.push('Decision needed');
  if (!moduleBoundaryDecision) missing.push('Module-boundary decision');
  const validation = section(body, 'Validation');
  for (const label of REQUIRED_VALIDATION_FIELDS) {
    const message = missingLabelMessage('Validation', label, validation, { allowNone: true });
    if (message) missing.push(message);
  }

  const clarityWarnings: string[] = [];
  if (input.title.trim().length < 12) {
    clarityWarnings.push('The PR title is very short. State the user or business outcome.');
  }
  if (JARGON_PATTERN.test(input.title) || JARGON_PATTERN.test(overview || '')) {
    clarityWarnings.push('The CEO overview may contain technical jargon. Rewrite it in plain language where possible.');
  }

  return {
    eligible: missing.length === 0,
    ceoOverview,
    decisionNeeded,
    moduleBoundaryDecision,
    missing,
    clarityWarnings,
  };
}
