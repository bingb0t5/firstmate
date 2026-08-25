import { readFileSync } from 'node:fs';

const failure = process.env.PR_COMMUNICATION_FETCH_FAILURE;
const bodyPath = process.env.PR_COMMUNICATION_FETCH_BODY_PATH;

if (bodyPath) {
  globalThis.fetch = async () => new Response(readFileSync(bodyPath, 'utf8'));
} else if (failure === 'network') {
  globalThis.fetch = async () => {
    throw new TypeError('simulated network failure', { cause: { code: 'ENETUNREACH' } });
  };
} else if (failure) {
  const status = Number(failure);
  globalThis.fetch = async () => new Response('simulated remote failure', { status });
}
