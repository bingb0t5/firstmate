#!/usr/bin/env node
/**
 * Fail if the vendored assessor drifts from the pinned SoT hash, or (when
 * reachable) from bingb0t5/lalo-admin@main:src/shared/prCommunication.ts.
 *
 * Remote comparison requires PR_COMMUNICATION_SOT_TOKEN. GITHUB_TOKEN and
 * GH_TOKEN are not substitutes. A missing or unusable token fails closed so
 * a PR cannot compare the vendored file against SOURCE.sha256 alone.
 * Local-pin fallback is only for network errors, HTTP 408, 429, and 5xx.
 * HTTP 401, 403, and 404 fail closed.
 */
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const TRUSTED_ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');
const ROOT = process.env.PR_COMMUNICATION_CANDIDATE_ROOT
  ? join(TRUSTED_ROOT, process.env.PR_COMMUNICATION_CANDIDATE_ROOT)
  : TRUSTED_ROOT;
const VENDORED_PATH = join(ROOT, 'scripts/pr-communication/prCommunication.ts');
const CANDIDATE_PIN_PATH = join(ROOT, 'scripts/pr-communication/SOURCE.sha256');
const TRUSTED_PIN_PATH = join(TRUSTED_ROOT, 'scripts/pr-communication/SOURCE.sha256');
const ENTRYPOINT_PATH = join(ROOT, 'scripts/check-pr-communication.ts');
const ENTRYPOINT_PIN_PATH = join(TRUSTED_ROOT, 'scripts/pr-communication/ENTRYPOINT.sha256');
const SOURCE_REPO = 'bingb0t5/lalo-admin';
const SOURCE_PATH = 'src/shared/prCommunication.ts';
const SOURCE_REF = 'main';

function stripSourceHeader(text) {
  const marker = '\n\n';
  const idx = text.indexOf(marker);
  if (idx < 0 || !text.startsWith('// SOURCE:')) {
    throw new Error(`${VENDORED_PATH} is missing the expected SOURCE header`);
  }
  return text.slice(idx + marker.length);
}

function sha256(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

async function fetchSourceOfTruth(token) {
  const url = `https://api.github.com/repos/${SOURCE_REPO}/contents/${SOURCE_PATH}?ref=${SOURCE_REF}`;
  const headers = {
    Accept: 'application/vnd.github.raw',
    'User-Agent': 'lalo-platform-pr-communication-drift-check',
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  const response = await fetch(url, { headers });
  if (!response.ok) {
    const body = await response.text();
    const error = new Error(
      `Failed to fetch ${SOURCE_REPO}@${SOURCE_REF}:${SOURCE_PATH} (${response.status}): ${body.slice(0, 300)}`,
    );
    error.status = response.status;
    throw error;
  }
  return await response.text();
}

const vendoredBody = stripSourceHeader(readFileSync(VENDORED_PATH, 'utf8'));
const actualHash = sha256(vendoredBody);
const candidatePinnedHash = readFileSync(CANDIDATE_PIN_PATH, 'utf8').trim();
const trustedPinnedHash = readFileSync(TRUSTED_PIN_PATH, 'utf8').trim();

if (actualHash !== candidatePinnedHash) {
  console.error('Vendored PR communication assessor does not match SOURCE.sha256.');
  console.error(`expected: ${candidatePinnedHash}`);
  console.error(`actual:   ${actualHash}`);
  console.error('Re-vendor from lalo-admin and refresh SOURCE.sha256.');
  process.exit(1);
}

console.log(`Local pin OK (${actualHash}).`);

const entrypointHash = sha256(readFileSync(ENTRYPOINT_PATH, 'utf8'));
const pinnedEntrypointHash = readFileSync(ENTRYPOINT_PIN_PATH, 'utf8').trim();

if (entrypointHash !== pinnedEntrypointHash) {
  console.error('PR communication entrypoint does not match ENTRYPOINT.sha256.');
  console.error(`expected: ${pinnedEntrypointHash}`);
  console.error(`actual:   ${entrypointHash}`);
  process.exit(1);
}

console.log(`Entrypoint pin OK (${entrypointHash}).`);

const token = String(process.env.PR_COMMUNICATION_SOT_TOKEN || '').trim();
const requireRemote = String(process.env.PR_COMMUNICATION_REQUIRE_REMOTE_SOT || '').trim() === '1';

if (!token) {
  console.error(
    `PR_COMMUNICATION_SOT_TOKEN is required to verify the private ${SOURCE_REPO} source of truth.`,
  );
  process.exit(1);
}

try {
  const remoteBody = await fetchSourceOfTruth(token);
  if (vendoredBody !== remoteBody) {
    console.error(`Vendored assessor drifted from ${SOURCE_REPO}@${SOURCE_REF}:${SOURCE_PATH}.`);
    console.error(
      'Re-vendor from lalo-admin, refresh SOURCE.sha256, and keep the SOURCE header intact.',
    );
    process.exit(1);
  }
  console.log(`Remote SoT matches ${SOURCE_REPO}@${SOURCE_REF}:${SOURCE_PATH}.`);
} catch (error) {
  const status = error && error.status;
  const networkCodes = new Set([
    'ECONNREFUSED',
    'ECONNRESET',
    'EHOSTUNREACH',
    'ENETDOWN',
    'ENETUNREACH',
    'ENOTFOUND',
    'ETIMEDOUT',
    'UND_ERR_CONNECT_TIMEOUT',
    'UND_ERR_HEADERS_TIMEOUT',
    'UND_ERR_SOCKET',
  ]);
  const networkFailure =
    error instanceof TypeError && networkCodes.has(error.cause && error.cause.code);
  const transientFailure =
    networkFailure || status === 408 || status === 429 || (status >= 500 && status <= 599);
  if (!transientFailure || requireRemote) {
    console.error(error.message || error);
    process.exit(1);
  }
  if (actualHash !== trustedPinnedHash) {
    console.error('Vendored PR communication assessor does not match trusted SOURCE.sha256.');
    console.error(`expected: ${trustedPinnedHash}`);
    console.error(`actual:   ${actualHash}`);
    process.exit(1);
  }
  console.warn(
    `Remote SoT check skipped (${status || 'network error'}). Using the verified local pin.`,
  );
}
