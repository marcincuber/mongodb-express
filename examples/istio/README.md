# EKS + ECR + DocumentDB TLS with Istio HTTPS access

This example deploys mongo-express from ECR into namespace `mongo-express-istio`. It includes its own namespace, application manifests, credentials template, Istio `Gateway`, and `VirtualService`. Run all commands from the project root.

The traffic path is browser HTTPS → Istio ingress → HTTP Service on port 8081 → mongo-express → validated TLS to DocumentDB. Browser TLS terminates at Istio. The application validates DocumentDB certificates using AWS's mounted CA bundle.

## Prerequisites

- Complete the [EKS prerequisites](../../README.md#eks-prerequisites).
- Install Istio with `networking.istio.io/v1` CRDs and an ingress gateway Service exposing ports 80 and 443. The manifests assume namespace `istio-system`, Service `istio-ingressgateway`, and ingress workload label `istio: ingressgateway`; adjust these to your installation.
- Provide DNS for the browser hostname pointing at the ingress Service's AWS load balancer, reachable by the intended users. Use your organization's private ingress and access restrictions for this administration UI.
- Supply a browser-trusted PEM certificate chain and private key covering that hostname. The certificate Secret belongs in the ingress workload's namespace. An ACM certificate ARN cannot be used directly as the PEM Secret in this example.

The application disables sidecar injection and assumes its namespace is not enrolled in ambient mode. Gateway-to-application traffic is HTTP; adjust any existing `DestinationRule` that forces `ISTIO_MUTUAL` for this non-meshed Service. The application connects directly to DocumentDB, so no DocumentDB `ServiceEntry` is needed.

## 1. Build and configure the image and ingress

Follow [Build, tag, and push to Amazon ECR](../../README.md#build-tag-and-push-to-amazon-ecr), keeping the full unique `$IMAGE_URI`.

1. Replace the `image:` value in `examples/istio/mongo-express.yaml` with `$IMAGE_URI`. Publish a new tag and update this value for every build.
2. Replace `mongo-express.example.com` in `gateway.yaml` and `virtual-service.yaml` with your browser hostname. Keep the `mongo-express-istio/` namespace prefix in the Gateway's host entries.
3. Match the Gateway selector to the ingress workload's labels.
4. If the ingress uses another namespace, update the Gateway namespace, VirtualService `gateways` reference and `exportTo`, and the certificate commands below.

## 2. Create database configuration and credentials

```sh
kubectl apply -f examples/istio/namespace.yaml
mkdir -p .certs
curl --fail --silent --show-error --location \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o .certs/global-bundle.pem

kubectl -n mongo-express-istio create configmap documentdb-ca \
  --from-file=global-bundle.pem=.certs/global-bundle.pem \
  --dry-run=client -o yaml | kubectl apply -f -

cp examples/istio/secrets.env.example .env.istio
chmod 600 .env.istio
```

Edit `.env.istio`: replace the DocumentDB cluster endpoint and URI-encoded database username/password, set a strong web login password, and generate separate cookie/session secrets with `openssl rand -hex 32`. Keep the URI on one line without shell quotes. Database credentials and web login credentials are separate.

The URI uses `authSource=admin`, `tls=true`, `replicaSet=rs0`, `readPreference=secondaryPreferred`, and `retryWrites=false`. The application enables DocumentDB compatibility mode and validates certificates using `/certs/global-bundle.pem`. Keep `ME_CONFIG_MONGODB_TLS_ALLOW_CERTS=false` to enforce certificate validation.

```sh
kubectl -n mongo-express-istio create secret generic mongo-express-secrets \
  --from-env-file=.env.istio \
  --dry-run=client -o yaml | kubectl apply -f -
```

The local `.env.istio` and `.certs/` paths are ignored by Git. This example's credentials and CA ConfigMap are independent of the port-forward example.

## 3. Create the browser certificate Secret

Supply your browser certificate files under `.certs/`:

```sh
kubectl -n istio-system create secret tls mongo-express-ui-tls \
  --cert=.certs/mongo-express.crt \
  --key=.certs/mongo-express.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

This certificate is separate from `global-bundle.pem`, which is the trust bundle for the database connection. If cert-manager manages a suitable Secret in the ingress namespace, reference its name in the Gateway's `credentialName` instead. See [Istio's secure ingress instructions](https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/).

## 4. Deploy and connect

```sh
kubectl apply -f examples/istio/
kubectl -n mongo-express-istio rollout status deployment/mongo-express --timeout=180s
kubectl -n istio-system get service istio-ingressgateway
```

If `istioctl` is installed, you can validate the manifests before applying them with `istioctl validate -f examples/istio/`.

Point the browser hostname at the ingress Service's load balancer, then open `https://YOUR_HOST/` and enter the web credentials. The [VirtualService](https://istio.io/latest/docs/reference/config/networking/virtual-service/) forwards all paths unchanged to the private Service on port 8081, disables automatic retries, and leaves the route timeout at Istio's default. Other gateway and application timeouts still apply.

Verify the HTTP redirect and HTTPS listener using your configured hostname:

```sh
export MONGO_EXPRESS_HOST=mongo-express.example.com
curl --head "http://${MONGO_EXPRESS_HOST}/"
curl --fail --show-error "https://${MONGO_EXPRESS_HOST}/status"
```

HTTP should redirect to HTTPS. The status URL returns `{"status":"ok"}` when the application's database connections respond, or HTTP 503 if they do not. Startup retries database initialization three times within a 120-second deadline before exiting nonzero. Kubernetes restarts failed startups; subsequent database outages affect readiness while TCP liveness keeps the web process running. Confirm the expected DocumentDB database list loads after signing in.

To use an existing shared HTTPS Gateway, omit `gateway.yaml` when applying resources, update the VirtualService's `gateways` and `exportTo`, and ensure the shared Gateway allows the hostname and the `mongo-express-istio` namespace. Apply the remaining files explicitly:

```sh
kubectl apply -f examples/istio/namespace.yaml \
  -f examples/istio/mongo-express.yaml \
  -f examples/istio/virtual-service.yaml
```

## Operations and cleanup

```sh
kubectl -n mongo-express-istio get pods,service,virtualservice
kubectl -n mongo-express-istio logs deployment/mongo-express
kubectl -n istio-system get gateways.networking.istio.io,service
```

For TLS errors, check the hostname, certificate chain, Secret namespace, and `credentialName`. For 404s, check the Gateway selector, allowed hosts, route export, and Gateway reference. For 503s, check ready Service endpoints and any policy forcing gateway-to-backend mTLS.

After changing Secret environment variables or the CA bundle, restart the application:

```sh
kubectl -n mongo-express-istio rollout restart deployment/mongo-express
```

Remove this example's ingress and application resources:

```sh
kubectl delete -f examples/istio/virtual-service.yaml -f examples/istio/gateway.yaml
kubectl delete namespace mongo-express-istio
kubectl -n istio-system delete secret mongo-express-ui-tls
```

Delete the certificate Secret only if you created it exclusively for this example. When using a shared Gateway, keep that Gateway and its certificate. The example Gateway and certificate are in `istio-system`, so deleting the application namespace alone does not remove them.
