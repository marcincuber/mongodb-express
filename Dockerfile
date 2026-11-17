# syntax=docker/dockerfile:1
ARG NODE_IMAGE=node:24-alpine3.24

FROM ${NODE_IMAGE} AS build
ARG MONGO_EXPRESS_TAG=v1.1.0-rc-4

WORKDIR /opt/mongo-express
ADD https://codeload.github.com/mongo-express/mongo-express/tar.gz/refs/tags/${MONGO_EXPRESS_TAG} /tmp/source.tar.gz
RUN tar -xzf /tmp/source.tar.gz --strip-components=1 -C . \
    && rm /tmp/source.tar.gz

# Install locked versions and skip development-only binary downloads.
ENV CYPRESS_INSTALL_BINARY=0 \
    MONGOMS_DISABLE_POSTINSTALL=1 \
    HUSKY=0 \
    DEDUPED=yes
# Retain OIDC and apply security fixes to this tag's older dependency lockfile.
RUN <<'BUILD'
set -eu
yarn install --immutable
node --input-type=commonjs <<'JS'
const fs = require('node:fs');
const packageFile = 'package.json';
const pkg = JSON.parse(fs.readFileSync(packageFile, 'utf8'));
const oidcPackage = 'express-openid-connect';
const oidcVersion = pkg.dependencies?.[oidcPackage] ?? pkg.devDependencies?.[oidcPackage];

if (!oidcVersion) {
  throw new Error('Upstream no longer declares express-openid-connect; review OIDC support before building.');
}

// Retain OIDC when Yarn prunes development packages.
pkg.dependencies ??= {};
pkg.dependencies[oidcPackage] = oidcVersion;
if (pkg.devDependencies) delete pkg.devDependencies[oidcPackage];

// CVE-2026-111181: retain the application's body-parser 2.x major.
pkg.dependencies['body-parser'] = '2.4.0';
pkg.resolutions = {
  ...pkg.resolutions,
  // CVE-2026-19481 and CVE-2026-19484: patch the multipart parser.
  '@fastify/busboy': '3.2.1',
  // CVE-2026-111181: Express 4 needs the patched 1.x copy.
  'express/body-parser': '1.20.9',
  // CVE-2026-118772: retain Joi 17 with its security fix.
  joi: '17.13.9',
  // CVE-2026-4800: patch Lodash within its existing major.
  lodash: '4.18.0',
  // CVE-2026-4867: patch Express 4's route matcher within 0.1.x.
  'path-to-regexp': '0.1.13',
  // CVE-2026-90711 (CRITICAL): patch Express's proxy address dependency.
  'proxy-addr': '2.0.8',
};
fs.writeFileSync(packageFile, JSON.stringify(pkg, null, 2) + '\n');

// Keep the runtime backport here so building needs only this Dockerfile.
fs.writeFileSync('lib/health.js', String.raw`import { setTimeout as delay } from 'node:timers/promises';

export async function connectWithRetry(connect, {
  attempts = 3, retryDelayMs = 2000, timeoutMs = 120000,
} = {}) {
  const deadline = setTimeout(() => {
    console.error('Database startup exceeded its deadline; exiting.');
    process.exit(1);
  }, timeoutMs);
  try {
    for (let attempt = 1; attempt <= attempts; attempt++) {
      try {
        return await connect();
      } catch (error) {
        console.error('Database startup attempt ' + attempt + '/' + attempts + ' failed.', error);
        if (attempt === attempts) {
          throw new Error('Database startup failed after ' + attempts + ' attempts.');
        }
        await delay(retryDelayMs);
      }
    }
  } finally {
    clearTimeout(deadline);
  }
}

async function databaseAvailable(mongo, timeoutMs) {
  if (!mongo?.clients?.length) return false;
  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(new Error('Database readiness timed out')), timeoutMs);
  try {
    await Promise.all(mongo.clients.map(({ client }) => client.db().command(
      { ping: 1 }, { signal: controller.signal, readPreference: client.readPreference },
    )));
    return true;
  } catch {
    // Cancel any other connection probes after one fails.
    controller.abort();
    return false;
  } finally {
    clearTimeout(deadline);
  }
}

export function databaseReadiness(getMongo, { timeoutMs = 2000 } = {}) {
  let inFlight;
  return async (_req, res) => {
    // Share simultaneous probes rather than queueing extra database commands.
    inFlight ??= databaseAvailable(getMongo(), timeoutMs).finally(() => { inFlight = undefined; });
    const available = await inFlight;
    res.set('Cache-Control', 'no-store');
    return res.status(available ? 200 : 503).json(
      available ? { status: 'ok' } : { status: 'error', error: 'Database unavailable' },
    );
  };
}
`);

function replaceOnce(source, before, after) {
  if (source.split(before).length !== 2) {
    throw new Error('Upstream health/startup code changed; review this Dockerfile backport.');
  }
  return source.replace(before, after);
}

let router = fs.readFileSync('lib/router.js', 'utf8');
router = replaceOnce(router, "import db from './db.js';", "import db from './db.js';\nimport { connectWithRetry, databaseReadiness } from './health.js';");
router = replaceOnce(router, `  let mongo = null;
  try {
    mongo = await db(config);
  } catch (error) {
    console.debug(error);
  }`, '  let mongo = await connectWithRetry(() => db(config));');
router = replaceOnce(router, `  appRouter.get(config.healthCheck.path, (req, res) => {
    res.json({ status: 'ok' });
  });`, '  appRouter.get(config.healthCheck.path, databaseReadiness(() => mongo));');
fs.writeFileSync('lib/router.js', router);

// Close every client after a failed attempt, including partial multi-server
// connections and failures while listing databases/collections.
let database = fs.readFileSync('lib/db.js', 'utf8');
const connectionMarker = '  // database connections\n';
const endMarker = '\n};\n\nexport default connect;';
if (database.split(connectionMarker).length !== 2 || database.split(endMarker).length !== 2) {
  throw new Error('Upstream connection lifecycle changed; review this Dockerfile backport.');
}
const [head, rest] = database.split(connectionMarker);
const [connectionCode, tail] = rest.split(endMarker);
let managedConnections = replaceOnce(connectionCode,
  'connectionData.clients = await Promise.all(', 'const results = await Promise.allSettled(');
managedConnections = replaceOnce(managedConnections,
  '      const client = await mongodb.MongoClient.connect(connectionString, connectionOptions);',
  '      const client = new mongodb.MongoClient(connectionString, connectionOptions);\n      clients.push(client);\n      await client.connect();');
managedConnections = replaceOnce(managedConnections, '  if (!connectionData.mainClient) {',
  "  if (!results.length) throw new Error('No database connections configured');\n  const failure = results.find((result) => result.status === 'rejected');\n  if (failure) throw failure.reason;\n  connectionData.clients = results.map((result) => result.value);\n  if (!connectionData.mainClient) {");
database = head + '  const clients = [];\n  try {\n'
  + managedConnections.split('\n').map((line) => '  ' + line).join('\n')
  + '\n  } catch (error) {\n    await Promise.allSettled(clients.map((client) => client.close()));\n    throw error;\n  }'
  + endMarker + tail;
fs.writeFileSync('lib/db.js', database);
JS
yarn install
yarn build
yarn workspaces focus --production
rm -rf lib/scripts node_modules/.cache
BUILD

FROM ${NODE_IMAGE} AS runtime
# hadolint ignore=DL3018
RUN apk add --no-cache tini ca-certificates \
    # The runtime starts Node directly and does not need package managers.
    && rm -rf /usr/local/lib/node_modules /opt/yarn-* \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg

ENV NODE_ENV=production \
    VCAP_APP_HOST=0.0.0.0 \
    PORT=8081 \
    ME_CONFIG_MONGODB_ENABLE_ADMIN=true

WORKDIR /opt/mongo-express
COPY --from=build /opt/mongo-express/node_modules ./node_modules
COPY --from=build /opt/mongo-express/build ./build
COPY --from=build /opt/mongo-express/public ./public
COPY --from=build /opt/mongo-express/lib ./lib
COPY --from=build /opt/mongo-express/app.js /opt/mongo-express/config.default.js /opt/mongo-express/package.json /opt/mongo-express/build-assets.json /opt/mongo-express/LICENSE.md ./

USER node
EXPOSE 8081
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "app.js"]
