# mongo-express container

Build [mongo-express](https://github.com/mongo-express/mongo-express) directly from its source, with its original application and environment-variable handling. There is no custom configuration wrapper. The default source is GitHub tag [`v1.1.0-rc-4`](https://github.com/mongo-express/mongo-express/releases/tag/v1.1.0-rc-4), a prerelease.

The image includes OIDC dependencies, compiled frontend assets, and production packages. It runs as UID/GID 1000 with `tini` forwarding signals to Node.js.

The build is self-contained in the [Dockerfile](Dockerfile): it downloads the upstream tag, retains OIDC support, applies dependency security fixes, and builds frontend assets before installing production packages. Each version override documents the vulnerability it fixes. A small runtime backport adds bounded database startup retries and database-aware readiness. The runtime omits npm and Yarn; upstream environment-variable configuration is preserved.

## Build and run

Requires Docker with BuildKit and access to GitHub, Docker Hub, Alpine, and the npm registry. Run commands from this directory:

```sh
docker build --pull -t mongo-express:local .
cp .env.example .env
```

Edit `.env`: set the MongoDB URI, web login password, and two independent secrets (generate each with `openssl rand -hex 32`). Then start the container:

```sh
docker run --rm --name mongo-express \
  --env-file .env \
  -p 127.0.0.1:8081:8081 \
  mongo-express:local
```

Open <http://localhost:8081>. The sample URI uses `host.docker.internal`, which Docker Desktop provides for reaching a database on the host. On Linux, add `--add-host=host.docker.internal:host-gateway`, or use your database's reachable hostname. For another container, attach both to the same Docker network and use its service name.

### Run with environment variables only

After building `mongo-express:local`, configure it directly with Docker's `-e` options. This example connects to an existing MongoDB instance and requires no `.env` file or custom `config.js`:

```sh
docker run --rm --name mongo-express \
  -p 127.0.0.1:8081:8081 \
  -e ME_CONFIG_MONGODB_URL='mongodb://DB_USER:ENCODED_DB_PASSWORD@host.docker.internal:27017/?authSource=admin' \
  -e ME_CONFIG_MONGODB_ENABLE_ADMIN=true \
  -e ME_CONFIG_BASICAUTH_ENABLED=true \
  -e ME_CONFIG_BASICAUTH_USERNAME=mongo-express \
  -e ME_CONFIG_BASICAUTH_PASSWORD='REPLACE_WITH_A_STRONG_WEB_PASSWORD' \
  -e ME_CONFIG_SITE_COOKIESECRET="$(openssl rand -hex 32)" \
  -e ME_CONFIG_SITE_SESSIONSECRET="$(openssl rand -hex 32)" \
  -e VCAP_APP_HOST=0.0.0.0 \
  -e PORT=8081 \
  mongo-express:local
```

Replace the MongoDB URI and web password before running. Percent-encode the database username and password in the URI; these are separate from the web login credentials. For a database without authentication, use `mongodb://host.docker.internal:27017/`. The two OpenSSL commands generate independent cookie and session secrets. Apply the networking guidance above, then open <http://localhost:8081> and sign in with the web credentials.

### Run MongoDB and mongo-express together with Docker CLI

For a single-command setup, run:

```sh
./scripts/run-local.sh
```

The script builds the mongo-express image, creates a shared network and persistent MongoDB volume, generates credentials, starts both containers, and waits for their health checks. It prints the browser URL and web login details when ready. It requires Docker and OpenSSL and can be executed from any working directory.

Credentials are saved with permissions `600` in the Git-ignored `.env.mongo-express-local` file. Rerunning the script reuses those credentials and the database volume, starts MongoDB if it was stopped, and recreates the UI container using the latest local build. Keep the credentials file while retaining database data.

To use another browser port or create a separate demo:

```sh
DEMO_PORT=8082 ./scripts/run-local.sh
DEMO_NAME=my-mongo-demo DEMO_PORT=8083 ./scripts/run-local.sh
```

The default containers are `mongo-express-local-db` and `mongo-express-local-ui`; the network is `mongo-express-local` and the volume is `mongo-express-local-data`. The script refuses to replace resources it did not create. To stop its default containers while retaining data and credentials:

```sh
docker stop mongo-express-local-ui mongo-express-local-db
```

The following commands show the equivalent manual setup with separate `mongo-express-demo` resource names.

After building `mongo-express:local`, run this local development example in one shell session. It creates an authenticated MongoDB 8.0 container, a persistent data volume, and a shared network. Passwords are generated as hexadecimal strings so the database password can be used directly in the connection URI.

```sh
export DEMO_MONGO_USER=mongoexpress
export DEMO_MONGO_PASSWORD="$(openssl rand -hex 24)"
export DEMO_WEB_USER=admin
export DEMO_WEB_PASSWORD="$(openssl rand -hex 24)"

docker network create mongo-express-demo
docker volume create mongo-express-demo-data

docker run -d --name mongo-express-demo-db \
  --network mongo-express-demo --network-alias mongo \
  --mount type=volume,source=mongo-express-demo-data,target=/data/db \
  -e MONGO_INITDB_ROOT_USERNAME="$DEMO_MONGO_USER" \
  -e MONGO_INITDB_ROOT_PASSWORD="$DEMO_MONGO_PASSWORD" \
  --health-cmd='mongosh --quiet --host mongo --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "quit(db.adminCommand({ ping: 1 }).ok ? 0 : 1)"' \
  --health-interval=2s --health-timeout=5s --health-retries=30 \
  mongo:8.0
```

Wait up to approximately one minute for authenticated database access, then start mongo-express on the same network:

```sh
for attempt in {1..30}; do
  mongo_health="$(docker inspect --format '{{.State.Health.Status}}' mongo-express-demo-db)"
  [ "$mongo_health" = healthy ] && break
  sleep 2
done

[ "$mongo_health" = healthy ] &&
docker run -d --name mongo-express-demo-ui \
  --network mongo-express-demo \
  -p 127.0.0.1:8081:8081 \
  -e ME_CONFIG_MONGODB_URL="mongodb://${DEMO_MONGO_USER}:${DEMO_MONGO_PASSWORD}@mongo:27017/?authSource=admin" \
  -e ME_CONFIG_MONGODB_ENABLE_ADMIN=true \
  -e ME_CONFIG_BASICAUTH_ENABLED=true \
  -e ME_CONFIG_BASICAUTH_USERNAME="$DEMO_WEB_USER" \
  -e ME_CONFIG_BASICAUTH_PASSWORD="$DEMO_WEB_PASSWORD" \
  -e ME_CONFIG_SITE_COOKIESECRET="$(openssl rand -hex 32)" \
  -e ME_CONFIG_SITE_SESSIONSECRET="$(openssl rand -hex 32)" \
  mongo-express:local
```

Open <http://localhost:8081>. Display the web login credentials with:

```sh
printf 'Web username: %s\nWeb password: %s\n' "$DEMO_WEB_USER" "$DEMO_WEB_PASSWORD"
```

MongoDB is reachable as `mongo:27017` inside the shared Docker network. Only the UI port is published to the host, so this works on Docker Desktop and Linux without `host.docker.internal`. If startup fails, inspect `docker logs mongo-express-demo-db` and `docker logs mongo-express-demo-ui`.

The [official MongoDB image](https://github.com/docker-library/docs/blob/master/mongo/README.md#environment-variables) creates the root account only when the data directory is empty. Retain the original database credentials when reusing the volume; changing the initialization variables does not change an existing account's password.

Remove the demo containers and network when finished:

```sh
docker rm -f mongo-express-demo-ui mongo-express-demo-db
docker network rm mongo-express-demo
```

To also delete the demo database's stored data:

```sh
docker volume rm mongo-express-demo-data
```

## Environment variables

All variables implemented by the pinned upstream tag are supported unchanged, including MongoDB/TLS options, Basic/OIDC authentication, site HTTPS, UI options, `PORT`, `VCAP_APP_HOST`, `VCAP_SERVICES`, and supported `_FILE` variants. [.env.example](.env.example) lists them. The authoritative references are upstream's [configuration](https://github.com/mongo-express/mongo-express/blob/v1.1.0-rc-4/config.default.js) and [README](https://github.com/mongo-express/mongo-express/blob/v1.1.0-rc-4/README.md#usage-docker).

This tag predates the previous `master` snapshot. `ME_CONFIG_AUTH_STRATEGY` (including form login), `ME_CONFIG_MONGODB_TLS_CRL_FILE`, and `ME_CONFIG_OPTIONS_NO_RAW_COMMAND` are not implemented by this tag.

Pass variables using `--env-file`, `-e`, or Kubernetes `env`/`envFrom`. Mount referenced files read-only and ensure UID 1000 can read them. Only variables with upstream `_FILE` support accept that suffix; it is not a generic feature for every variable. File values take precedence over direct values. The container sets `VCAP_APP_HOST=0.0.0.0`, `PORT=8081`, `ME_CONFIG_MONGODB_ENABLE_ADMIN=true`, and `NODE_ENV=production`. Supply `ME_CONFIG_MONGODB_URL` or `ME_CONFIG_MONGODB_URL_FILE` yourself.

`ME_CONFIG_MONGODB_TLS_ALLOW_CERTS` maps to the driver's **`tlsAllowInvalidCertificates`** option: set it to **`false` to validate certificates**. Upstream's default is `true`. `ME_CONFIG_SITE_SSL_*` controls browser-facing HTTPS separately from database TLS. If you change the port, base URL, health path, or site HTTPS setting in Kubernetes, update the Service and probes accordingly. `ME_CONFIG_REQUEST_SIZE` accepts a size such as `50mb`.

For settings only available through upstream `config.js`, mount that file at `/opt/mongo-express/config.js`.

## Container vulnerability scanning

[Container security](.github/workflows/container-scan.yml) builds and scans fresh Linux amd64 and arm64 images on pull requests, pushes to `main`, daily at 06:23 UTC, and manual runs. It uses a version- and digest-pinned Trivy scanner with an updated vulnerability database. Any HIGH or CRITICAL finding fails the job, including findings without a fix. There are no vulnerability exceptions or ignore lists. Scanner/database failures also fail the job.

Run the same gate locally after building:

```sh
bash scripts/scan-image.sh mongo-express:local
```

The scanner reads an archive of the local image without access to the Docker socket. JSON and SARIF reports include every severity; the text report shows HIGH/CRITICAL findings. Reports are written to `reports/security/` and uploaded as GitHub Actions artifacts even when the gate fails. A passing result means no HIGH/CRITICAL vulnerabilities known to the scanner's database at scan time.

Configure both `HIGH/CRITICAL scan (amd64)` and `HIGH/CRITICAL scan (arm64)` as required checks in GitHub branch protection to block merges on failed scans. Review and update the scanner pin regularly. The daily run catches newly disclosed vulnerabilities in a fresh rebuild; it does not rescan images already deployed to EKS.

## Build, tag, and push to Amazon ECR

Requires Docker with Buildx, OpenSSL, AWS CLI v2, and AWS credentials with permission to authenticate to ECR and push images. Creating a repository also requires `ecr:CreateRepository`; updating an existing repository's tag policy requires `ecr:PutImageTagMutability`. Run these commands from this project directory in the same shell session. See [AWS's ECR push instructions](https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html) for the required access setup.

Set the target account, region, repository, image tag, and platform:

```sh
export AWS_REGION=eu-west-2
export ECR_REPOSITORY=mongo-express
export IMAGE_TAG="1.1.0-rc-4-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 6)"
export PLATFORM=linux/amd64
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export LOCAL_IMAGE="mongo-express:${IMAGE_TAG}"
export IMAGE_URI="${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"
```

The default platform targets x86 EKS nodes, including when building on an Apple Silicon laptop. Set `PLATFORM=linux/arm64` for Graviton nodes. These steps publish one platform; a mixed-architecture cluster requires a multi-platform image with each architecture scanned before publishing. `IMAGE_TAG` labels the image; the upstream source tag is selected by `MONGO_EXPRESS_TAG` in the Dockerfile.

Generate a new `IMAGE_TAG` for every build, including rebuilds of the same upstream release. The UTC timestamp and random suffix distinguish images containing different base-image updates or dependency patches. Rerun the variable block before each build. CI uses the commit, run ID, attempt, and architecture to distinguish its image tags.

Create the ECR repository once with [immutable tags](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html), so an existing image tag cannot be overwritten:

```sh
aws ecr create-repository \
  --repository-name "$ECR_REPOSITORY" \
  --image-tag-mutability IMMUTABLE \
  --region "$AWS_REGION"
```

If the repository already exists, use this command instead to enable immutability:

```sh
aws ecr put-image-tag-mutability \
  --repository-name "$ECR_REPOSITORY" \
  --image-tag-mutability IMMUTABLE \
  --region "$AWS_REGION"
```

Authenticate Docker to the target registry:

```sh
aws ecr get-login-password --region "$AWS_REGION" |
  docker login --username AWS --password-stdin "$ECR_REGISTRY"
```

Build and load the image locally, scan it, apply the ECR tag, and push. The `&&` operators stop the sequence if any step fails, so a failed security scan prevents the push:

```sh
docker buildx build --pull --platform "$PLATFORM" --load \
  --tag "$LOCAL_IMAGE" . &&
bash scripts/scan-image.sh "$LOCAL_IMAGE" &&
docker tag "$LOCAL_IMAGE" "$IMAGE_URI" &&
docker push "$IMAGE_URI"
```

Confirm the pushed image is present and print the URI to use in Kubernetes:

```sh
aws ecr describe-images \
  --repository-name "$ECR_REPOSITORY" \
  --image-ids "imageTag=${IMAGE_TAG}" \
  --region "$AWS_REGION" \
  --query 'imageDetails[0].{Tags:imageTags,Digest:imageDigest}'
printf '%s\n' "$IMAGE_URI"
```

## EKS deployment examples

Both examples deploy the ECR image and connect to an existing instance-based DocumentDB cluster with validated TLS. Each directory contains complete, independent YAML manifests, a credentials template, and deployment instructions. Run commands from the project root.

| Example | Browser access | Application namespace |
| --- | --- | --- |
| [Port-forward](examples/port-forward/README.md) | Private Service through `kubectl port-forward` | `mongo-express` |
| [Istio](examples/istio/README.md) | HTTPS Gateway and VirtualService | `mongo-express-istio` |

The examples use separate namespaces and credentials, so they can be deployed and removed independently. Follow the selected example's README to create its CA ConfigMap and Secret before deploying. Neither example provisions AWS infrastructure.

### EKS prerequisites

- Configure AWS CLI credentials and `kubectl` for the intended EKS cluster.
- Use an existing DocumentDB cluster with TLS enabled. Pods must resolve and reach the cluster and discovered instance endpoints on TCP 27017. Configure VPC routing, security groups, network ACLs, and any Kubernetes network policies for the actual node or pod traffic source.
- Ensure EKS node roles, or the Fargate execution role, can pull the unique image from ECR. This username/password database example needs no application IAM role.
- Use a database account with the required permissions. Admin mode lists all databases; disable it and include a database name in the URI to limit access to one database.

Both examples follow [AWS's DocumentDB connection guidance](https://docs.aws.amazon.com/documentdb/latest/developerguide/connect_programmatically.html). They mount the public AWS CA bundle and explicitly set `ME_CONFIG_MONGODB_TLS_ALLOW_CERTS=false` to validate certificates. DocumentDB compatibility mode is experimental; not every MongoDB administrative operation is supported.

The app attempts database initialization up to three times with two-second pauses and a 120-second overall deadline. It starts the web listener only after initialization succeeds, closes clients from failed attempts, and exits nonzero if retries or the deadline are exhausted. Kubernetes then restarts the container. The examples allow 150 seconds for the startup probe.

The configured health endpoint (`/status` by default, relative to `ME_CONFIG_SITE_BASEURL`) pings the application's existing database clients. It returns HTTP 200 when every connection responds and HTTP 503 on failure, with a two-second probe deadline and no database error details in the response. Concurrent checks share a probe. Readiness recovers when the driver reconnects; TCP liveness stays independent of database availability, so an established process is not restarted solely because DocumentDB is temporarily unavailable.

CI verifies startup retries, deadline exhaustion, invalid TLS rejection, and readiness failure/recovery against a temporary TLS-enabled MongoDB container. These tests do not replace validation against your actual DocumentDB cluster.

## Updating upstream

Update `MONGO_EXPRESS_TAG` in the Dockerfile, or pass it as a build argument. For example:

```sh
docker build \
  --build-arg MONGO_EXPRESS_TAG=v1.1.0-rc-4 \
  -t mongo-express:1.1.0-rc-4 .
```

Review upstream configuration changes and refresh `.env.example` when updating. Review the security overrides in the [Dockerfile](Dockerfile) when upstream dependencies change. `NODE_IMAGE` is also a build argument; it must satisfy upstream's Node.js engine requirements. Publish a new unique image tag and update the EKS example's `image:` value for every build.
