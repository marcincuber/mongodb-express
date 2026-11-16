#!/usr/bin/env bash
set -euo pipefail
umask 077

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
demo_name="${DEMO_NAME:-mongo-express-local}"
demo_port="${DEMO_PORT:-8081}"
image='mongo-express:local'
owner_label='io.mongo-express.local-demo'

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      printf '%s\n' 'Usage: ./scripts/run-local.sh' \
        'Build and start authenticated MongoDB and mongo-express using Docker CLI.' \
        'Optional: DEMO_PORT=8082 DEMO_NAME=my-mongo-demo ./scripts/run-local.sh' \
        'Credentials and database data are retained between runs.'
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
fi

[[ "$demo_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die 'DEMO_NAME must be a valid Docker resource name.'
if [[ ! "$demo_port" =~ ^[1-9][0-9]{0,4}$ ]] || (( demo_port > 65535 )); then
  die 'DEMO_PORT must be between 1 and 65535.'
fi
for executable in docker openssl; do
  command -v "$executable" > /dev/null || die "Required command not found: $executable"
done
docker info > /dev/null 2>&1 || die 'Docker is not running. Start Docker and retry.'

database="${demo_name}-db"
web="${demo_name}-ui"
volume="${demo_name}-data"
credentials_file="$project_dir/.env.$demo_name"

# Refuse to replace or reuse resources created outside this script.
check_owner() {
  local kind="$1" name="$2" template existing_owner
  template="{{ index .Labels \"$owner_label\" }}"
  if [[ "$kind" == container ]]; then
    template="{{ index .Config.Labels \"$owner_label\" }}"
  fi
  if docker "$kind" inspect "$name" > /dev/null 2>&1; then
    existing_owner="$(docker "$kind" inspect --format "$template" "$name")"
    [[ "$existing_owner" == "$demo_name" ]] || die "Resource '$name' already exists outside this script. Choose another DEMO_NAME."
  fi
}
check_owner container "$database"
check_owner container "$web"
check_owner network "$demo_name"
check_owner volume "$volume"

if [[ ! -f "$credentials_file" ]]; then
  if docker volume inspect "$volume" > /dev/null 2>&1; then
    die "Database volume exists but $credentials_file is missing. Restore its original credentials or choose another DEMO_NAME."
  fi
  printf 'Creating credentials in %s\n' "$credentials_file"
  {
    printf 'DEMO_MONGO_USER=mongoexpress\nDEMO_MONGO_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'DEMO_WEB_USER=admin\nDEMO_WEB_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'DEMO_COOKIE_SECRET=%s\n' "$(openssl rand -hex 32)"
    printf 'DEMO_SESSION_SECRET=%s\n' "$(openssl rand -hex 32)"
  } > "$credentials_file"
fi
chmod 600 "$credentials_file"
# shellcheck disable=SC1090 # This local credentials file is generated above.
source "$credentials_file"
: "${DEMO_MONGO_USER:?Missing database username in credentials file}"
: "${DEMO_MONGO_PASSWORD:?Missing database password in credentials file}"
: "${DEMO_WEB_USER:?Missing web username in credentials file}"
: "${DEMO_WEB_PASSWORD:?Missing web password in credentials file}"
: "${DEMO_COOKIE_SECRET:?Missing cookie secret in credentials file}"
: "${DEMO_SESSION_SECRET:?Missing session secret in credentials file}"

printf 'Building %s...\n' "$image"
docker build --pull --tag "$image" "$project_dir"

if ! docker network inspect "$demo_name" > /dev/null 2>&1; then
  docker network create --label "$owner_label=$demo_name" "$demo_name" > /dev/null
fi
if ! docker volume inspect "$volume" > /dev/null 2>&1; then
  docker volume create --label "$owner_label=$demo_name" "$volume" > /dev/null
fi

printf 'Starting MongoDB...\n'
if docker container inspect "$database" > /dev/null 2>&1; then
  docker start "$database" > /dev/null
else
  # shellcheck disable=SC2016 # MongoDB variables expand inside the container.
  docker run -d --name "$database" --label "$owner_label=$demo_name" \
    --network "$demo_name" --network-alias mongo \
    --mount "type=volume,source=$volume,target=/data/db" \
    -e MONGO_INITDB_ROOT_USERNAME="$DEMO_MONGO_USER" \
    -e MONGO_INITDB_ROOT_PASSWORD="$DEMO_MONGO_PASSWORD" \
    --health-cmd='mongosh --quiet --host mongo --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "quit(db.adminCommand({ ping: 1 }).ok ? 0 : 1)"' \
    --health-interval=2s --health-timeout=5s --health-retries=30 \
    mongo:8.0 > /dev/null
fi

wait_healthy() {
  local container="$1" attempt container_health
  for ((attempt=0; attempt<60; attempt++)); do
    container_health="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container")"
    case "$container_health" in
      'running healthy') return 0 ;;
      *unhealthy|exited*|dead*) break ;;
    esac
    sleep 2
  done
  docker logs --tail 40 "$container" >&2 || true
  die "Container '$container' did not become healthy. Database data and credentials have been retained."
}
wait_healthy "$database"

printf 'Starting mongo-express...\n'
# Recreate only our stateless UI container to pick up the build and chosen port.
if docker container inspect "$web" > /dev/null 2>&1; then
  docker rm -f "$web" > /dev/null
fi
docker run -d --name "$web" --label "$owner_label=$demo_name" \
  --network "$demo_name" -p "127.0.0.1:$demo_port:8081" \
  -e ME_CONFIG_MONGODB_URL="mongodb://${DEMO_MONGO_USER}:${DEMO_MONGO_PASSWORD}@mongo:27017/?authSource=admin" \
  -e ME_CONFIG_MONGODB_ENABLE_ADMIN=true \
  -e ME_CONFIG_BASICAUTH_ENABLED=true \
  -e ME_CONFIG_BASICAUTH_USERNAME="$DEMO_WEB_USER" \
  -e ME_CONFIG_BASICAUTH_PASSWORD="$DEMO_WEB_PASSWORD" \
  -e ME_CONFIG_SITE_COOKIESECRET="$DEMO_COOKIE_SECRET" \
  -e ME_CONFIG_SITE_SESSIONSECRET="$DEMO_SESSION_SECRET" \
  --health-cmd='node --input-type=module -e "const r = await fetch(\"http://127.0.0.1:8081/status\"); process.exit(r.ok ? 0 : 1)"' \
  --health-interval=2s --health-timeout=5s --health-retries=30 \
  "$image" > /dev/null
wait_healthy "$web"

printf '\nOpen: http://localhost:%s\nWeb username: %s\nWeb password: %s\nCredentials: %s\n' \
  "$demo_port" "$DEMO_WEB_USER" "$DEMO_WEB_PASSWORD" "$credentials_file"
printf '\nTo stop the demo while retaining data and credentials:\n'
printf '  docker stop %s %s\n' "$web" "$database"
