# EKS + ECR + DocumentDB TLS with port-forward access

This example deploys mongo-express from ECR into namespace `mongo-express`. It connects to DocumentDB with validated TLS and exposes a private `ClusterIP` Service accessed through `kubectl port-forward`.

The directory contains its own namespace, application manifests, and credentials template. Run all commands from the project root. Complete the [EKS prerequisites](../../README.md#eks-prerequisites) first.

## 1. Build and configure the image

Follow [Build, tag, and push to Amazon ECR](../../README.md#build-tag-and-push-to-amazon-ecr), keeping the full unique `$IMAGE_URI`. Replace the `image:` value in `examples/port-forward/mongo-express.yaml` with that URI. Publish a new tag and update this value for every build.

## 2. Create database configuration and credentials

Create the namespace and download AWS's public database CA bundle:

```sh
kubectl apply -f examples/port-forward/namespace.yaml
mkdir -p .certs
curl --fail --silent --show-error --location \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o .certs/global-bundle.pem

kubectl -n mongo-express create configmap documentdb-ca \
  --from-file=global-bundle.pem=.certs/global-bundle.pem \
  --dry-run=client -o yaml | kubectl apply -f -

cp examples/port-forward/secrets.env.example .env.port-forward
chmod 600 .env.port-forward
```

Edit `.env.port-forward`: replace the DocumentDB cluster endpoint and URI-encoded database username/password, set a strong web login password, and generate separate cookie/session secrets with `openssl rand -hex 32`. Keep the URI on one line without shell quotes. Database credentials and web login credentials are separate.

The URI uses `authSource=admin`, `tls=true`, `replicaSet=rs0`, `readPreference=secondaryPreferred`, and `retryWrites=false`. The application enables DocumentDB compatibility mode and validates certificates using `/certs/global-bundle.pem`. Keep `ME_CONFIG_MONGODB_TLS_ALLOW_CERTS=false` to enforce certificate validation.

Create the credentials Secret after editing the file:

```sh
kubectl -n mongo-express create secret generic mongo-express-secrets \
  --from-env-file=.env.port-forward \
  --dry-run=client -o yaml | kubectl apply -f -
```

The local `.env.port-forward` and `.certs/` paths are ignored by Git.

## 3. Deploy and connect

```sh
kubectl apply -f examples/port-forward/
kubectl -n mongo-express rollout status deployment/mongo-express --timeout=180s
kubectl -n mongo-express port-forward service/mongo-express 8081:8081
```

Open <http://localhost:8081> and enter the web credentials. Keep the port-forward command running. The forwarded connection uses Kubernetes API access; the application-to-DocumentDB connection uses validated TLS.

The app retries database initialization three times within a 120-second deadline and exits nonzero on failure so Kubernetes can restart it. `/status` pings the application's existing database clients and returns HTTP 503 if the database is unavailable; readiness recovers after reconnection. TCP liveness stays independent of database availability. Use the UI and logs to confirm the expected databases and permissions.

## Operations and cleanup

```sh
kubectl -n mongo-express get pods,service
kubectl -n mongo-express logs deployment/mongo-express
```

After changing Secret environment variables or the CA bundle, restart the application:

```sh
kubectl -n mongo-express rollout restart deployment/mongo-express
```

Remove this example, including its credentials and CA ConfigMap:

```sh
kubectl delete namespace mongo-express
```
