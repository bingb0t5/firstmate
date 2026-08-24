const failure = process.env.PR_COMMUNICATION_FETCH_FAILURE;

if (failure === 'network') {
  globalThis.fetch = async () => {
    throw new TypeError('simulated network failure');
  };
} else if (failure) {
  const status = Number(failure);
  globalThis.fetch = async () => new Response('simulated remote failure', { status });
}
