import { afterEach, describe, expect, it, vi } from 'vitest';

const init = vi.fn();

vi.mock('@sentry/node', () => ({ init }));

afterEach(() => {
  vi.unstubAllEnvs();
});

describe('extension Sentry initialisation', () => {
  it('turns every Sentry 11 data-collection category off', async () => {
    vi.stubEnv('BURNBAR_EXTENSION_SENTRY_DSN', 'https://public@example.test/1');
    const { initSentry } = await import('../../src/telemetry/sentry');

    await initSentry('1.2.3', 'production');

    expect(init).toHaveBeenCalledTimes(1);
    const options = init.mock.calls[0][0];
    expect(options.release).toBe('openburnbar-extension@1.2.3');
    expect(options.dataCollection).toEqual({
      userInfo: false,
      cookies: false,
      httpHeaders: false,
      httpBodies: [],
      urlQueryParams: { deny: ['forwarded', '-ip', 'remote-', 'via', '-user'] },
      genAI: { inputs: false, outputs: false },
      databaseQueryData: false,
      queues: false,
      graphQL: { document: false, variables: false }
    });
  });
});
