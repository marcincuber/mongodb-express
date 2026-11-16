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
COPY scripts/patch-dependencies.cjs /tmp/patch-dependencies.cjs
# Retain OIDC and apply security fixes to this tag's older dependency lockfile.
RUN yarn install --immutable \
    && node /tmp/patch-dependencies.cjs \
    && yarn install \
    && yarn build \
    && yarn workspaces focus --production \
    && rm -rf lib/scripts node_modules/.cache

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
