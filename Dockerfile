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
