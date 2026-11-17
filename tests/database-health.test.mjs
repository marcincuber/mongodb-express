import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { connectWithRetry, databaseReadiness } from '/opt/mongo-express/lib/health.js';

function databaseConnector(MongoClient) {
  // Inject a driver into the built application's actual connection lifecycle.
  const source = readFileSync('/opt/mongo-express/lib/db.js', 'utf8')
    .replace("import mongodb from 'mongodb';", '')
    .replace('export default connect;', 'return connect;');
  return new Function('mongodb', source)({ MongoClient });
}

test('failed multi-server startup closes every client, including late connections', async () => {
  const clients = [];
  class Client {
    constructor(uri) { this.uri = uri; this.closed = false; clients.push(this); }
    async connect() {
      if (this.uri.includes('failed')) throw new Error('Connection failed');
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    db() { return {}; }
    async close() { this.closed = true; }
  }
  const connect = databaseConnector(Client);
  await assert.rejects(connect({ mongodb: [
    { connectionString: 'mongodb://late' }, { connectionString: 'mongodb://failed' },
  ] }), /Connection failed/);
  assert.equal(clients.length, 2);
  assert.ok(clients.every((client) => client.closed));
});

test('failed metadata initialization closes the successfully connected client', async () => {
  let closed = false;
  class Client {
    async connect() {}
    db() {
      return { databaseName: 'test', listCollections: () => ({
        toArray: async () => { throw new Error('Metadata access denied'); },
      }) };
    }
    async close() { closed = true; }
  }
  await assert.rejects(databaseConnector(Client)({ mongodb: {
    connectionString: 'mongodb://connected', admin: false,
  } }), /Metadata access denied/);
  assert.equal(closed, true);
});

function response() {
  return {
    headers: {},
    set(name, value) { this.headers[name] = value; return this; },
    status(code) { this.code = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

test('startup recovers after a transient error and returns the connected state', async () => {
  let attempts = 0;
  const connected = { clients: ['existing client'] };
  const actual = await connectWithRetry(async () => {
    if (++attempts < 3) throw new Error('Temporary startup failure');
    return connected;
  }, { retryDelayMs: 0, timeoutMs: 1000 });
  assert.equal(attempts, 3);
  assert.equal(actual, connected);
});

test('startup stops retrying after the configured attempt limit', async () => {
  let attempts = 0;
  await assert.rejects(connectWithRetry(async () => {
    attempts++;
    throw new Error('Unavailable');
  }, { retryDelayMs: 0, timeoutMs: 1000 }), /failed after 3 attempts/);
  assert.equal(attempts, 3);
});

test('a stalled startup exits nonzero at the overall deadline', () => {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import { connectWithRetry } from '/opt/mongo-express/lib/health.js';
    await connectWithRetry(() => new Promise(() => {}), { timeoutMs: 25 });
  `], { encoding: 'utf8', timeout: 5000 });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /startup exceeded its deadline/);
});

test('readiness rejects missing application connections', async () => {
  for (const state of [null, { clients: [] }]) {
    const res = response();
    await databaseReadiness(() => state)({}, res);
    assert.equal(res.code, 503);
    assert.deepEqual(res.body, { status: 'error', error: 'Database unavailable' });
  }
});

test('readiness checks every existing client and recovers after an outage', async () => {
  let unavailable = false;
  let calls = 0;
  const readPreference = { mode: 'secondaryPreferred' };
  const clients = Array.from({ length: 2 }, () => ({ client: {
    readPreference,
    db: () => ({ command: async (command, options) => {
      calls++;
      assert.deepEqual(command, { ping: 1 });
      assert.equal(options.readPreference, readPreference);
      assert.ok(options.signal instanceof AbortSignal);
      assert.equal(options.timeoutMS, undefined);
      if (unavailable) throw new Error('Sensitive database error');
    } }),
  } }));
  const handler = databaseReadiness(() => ({ clients }));
  for (const [failure, expected] of [[false, 200], [true, 503], [false, 200]]) {
    unavailable = failure;
    const res = response();
    await handler({}, res);
    assert.equal(res.code, expected);
    assert.equal(res.headers['Cache-Control'], 'no-store');
    assert.ok(!JSON.stringify(res.body).includes('Sensitive'));
  }
  assert.equal(calls, 6);
});

test('concurrent probes share one database operation', async () => {
  let calls = 0;
  let finish;
  const handler = databaseReadiness(() => ({ clients: [{ client: {
    db: () => ({ command: () => { calls++; return new Promise((resolve) => { finish = resolve; }); } }),
  } }] }));
  const responses = [response(), response(), response()];
  const pending = responses.map((res) => handler({}, res));
  assert.equal(calls, 1);
  finish();
  await Promise.all(pending);
  assert.ok(responses.every((res) => res.code === 200));
});

test('a hanging readiness operation is aborted and later probes can recover', async () => {
  let hanging = true;
  let aborted = false;
  const handler = databaseReadiness(() => ({ clients: [{ client: {
    db: () => ({ command: (_command, { signal }) => hanging ? new Promise((_resolve, reject) => {
      signal.addEventListener('abort', () => { aborted = true; reject(signal.reason); }, { once: true });
    }) : Promise.resolve() }),
  } }] }), { timeoutMs: 25 });
  const unavailable = response();
  await handler({}, unavailable);
  assert.equal(unavailable.code, 503);
  assert.equal(aborted, true);
  hanging = false;
  const recovered = response();
  await handler({}, recovered);
  assert.equal(recovered.code, 200);
});
