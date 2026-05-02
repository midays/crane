#!/usr/bin/env bash
set -euo pipefail
set -x

# Setup from scratch for same-docker-network MicroShift (OCP) clusters:
# 1) create docker network
# 2) inspect subnet, derive static IPs for src/tgt
# 3) start src/tgt MicroShift containers with static IPs
# 4) wait for API servers to be ready
# 5) extract + merge kubeconfigs with correct context names
# 6) optionally create HTPasswd non-admin users on src/tgt
#
# Config:
#   NETWORK_NAME         default: microshift-mc
#   SRC_CONTAINER        default: microshift-src
#   TGT_CONTAINER        default: microshift-tgt
#   SRC_CONTEXT          default: ocp-dev-src
#   TGT_CONTEXT          default: ocp-dev-tgt
#   MICROSHIFT_IMAGE     default: quay.io/microshift/microshift-aio:latest
#   MICROSHIFT_CPUS      default: 2
#   MICROSHIFT_MEMORY    default: 4096m
#   SRC_OCP_VERSION      default: latest
#   TGT_OCP_VERSION      default: latest
#   ROUTE_WAIT           default: 300s
#   CREATE_USERS         default: false
#   SRC_USER             default: dev
#   TGT_USER             default: dev
#   SRC_USER_CONTEXT     default: ocp-dev-src-dev
#   TGT_USER_CONTEXT     default: ocp-dev-tgt-dev
#   USER_PASSWORD        default: developer
#   STARTUP_TIMEOUT      default: 180
#   RESET_CONTAINERS     default: true
#   RECREATE_NETWORK     default: true

NETWORK_NAME="${NETWORK_NAME:-microshift-mc}"
SRC_CONTAINER="${SRC_CONTAINER:-microshift-src}"
TGT_CONTAINER="${TGT_CONTAINER:-microshift-tgt}"
SRC_CONTEXT="${SRC_CONTEXT:-ocp-dev-src}"
TGT_CONTEXT="${TGT_CONTEXT:-ocp-dev-tgt}"
MICROSHIFT_IMAGE="${MICROSHIFT_IMAGE:-quay.io/microshift/microshift-aio:latest}"
MICROSHIFT_CPUS="${MICROSHIFT_CPUS:-2}"
MICROSHIFT_MEMORY="${MICROSHIFT_MEMORY:-4096m}"
SRC_OCP_VERSION="${SRC_OCP_VERSION:-latest}"
TGT_OCP_VERSION="${TGT_OCP_VERSION:-latest}"
ROUTE_WAIT="${ROUTE_WAIT:-300s}"
CREATE_USERS="${CREATE_USERS:-false}"
SRC_USER="${SRC_USER:-dev}"
TGT_USER="${TGT_USER:-dev}"
SRC_USER_CONTEXT="${SRC_USER_CONTEXT:-${SRC_CONTEXT}-${SRC_USER}}"
TGT_USER_CONTEXT="${TGT_USER_CONTEXT:-${TGT_CONTEXT}-${TGT_USER}}"
USER_PASSWORD="${USER_PASSWORD:-developer}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-180}"
RESET_CONTAINERS="${RESET_CONTAINERS:-true}"
RECREATE_NETWORK="${RECREATE_NETWORK:-true}"

log() {
  printf '[setup-microshift] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

# ── Start a MicroShift container with a static IP on the shared network ───────
start_container() {
  local container="$1"
  local ip="$2"
  local image_tag="$3"

  local image="quay.io/microshift/microshift-aio:${image_tag}"

  log "Starting container=${container} ip=${ip} image=${image}"
  docker run -d \
    --name "$container" \
    --privileged \
    --pid=host \
    --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "${container}-data:/var/lib" \
    --network "$NETWORK_NAME" \
    --ip "$ip" \
    --cpus "$MICROSHIFT_CPUS" \
    --memory "$MICROSHIFT_MEMORY" \
    "$image"
}

# ── Wait for a container's API server to be ready ────────────────────────────
wait_for_ready() {
  local container="$1"

  log "Waiting for ${container} API server (timeout: ${STARTUP_TIMEOUT}s)..."
  timeout "$STARTUP_TIMEOUT" bash -c \
    "until docker exec ${container} kubectl get nodes >/dev/null 2>&1; do
       echo -n '.'; sleep 5
     done"
  echo ""
  log "${container} is ready"
}

# ── Extract kubeconfig, rewrite server URL to container IP, rename context ───
extract_kubeconfig() {
  local container="$1"
  local ip="$2"
  local context_name="$3"
  local out_file="$4"

  log "Extracting kubeconfig from ${container}"
  docker exec "$container" \
    cat /var/lib/microshift/resources/kubeadmin/kubeconfig \
    | sed "s|https://127.0.0.1:6443|https://${ip}:6443|g" \
    | sed "s|https://localhost:6443|https://${ip}:6443|g" \
    > "$out_file"

  # MicroShift names the context "admin" by default — rename to our convention
  KUBECONFIG="$out_file" kubectl config rename-context admin "$context_name"
  log "Kubeconfig written → ${out_file} (context: ${context_name})"
}

# ── Merge a kubeconfig file into ~/.kube/config ───────────────────────────────
merge_kubeconfig() {
  local new_kc="$1"

  mkdir -p ~/.kube
  if [[ -f ~/.kube/config ]]; then
    local backup="${HOME}/.kube/config.bak.$(date +%s)"
    cp ~/.kube/config "$backup"
    log "Backed up existing kubeconfig → ${backup}"
    KUBECONFIG="${HOME}/.kube/config:${new_kc}" \
      kubectl config view --flatten > /tmp/merged-kc.yaml
    mv /tmp/merged-kc.yaml ~/.kube/config
  else
    cp "$new_kc" ~/.kube/config
  fi
  log "Merged ${new_kc} into ~/.kube/config"
}

# ── Create HTPasswd non-admin user and add kubeconfig context ─────────────────
create_user_context() {
  local container="$1"
  local context_name="$2"   # admin context to run oc commands against
  local user_name="$3"
  local user_context_name="$4"
  local ip="$5"

  log "Creating HTPasswd user=${user_name} on context=${context_name}"

  # Generate htpasswd entry (requires htpasswd tool)
  require_cmd htpasswd
  local htpasswd_entry
  htpasswd_entry="$(htpasswd -nbB "$user_name" "$USER_PASSWORD")"

  # Create/update the htpasswd secret on the cluster
  kubectl --context="$context_name" create secret generic htpasswd-secret \
    --from-literal=htpasswd="$htpasswd_entry" \
    -n openshift-config \
    --dry-run=client -o yaml \
    | kubectl --context="$context_name" apply -f -

  # Patch OAuth to add HTPasswd identity provider
  kubectl --context="$context_name" patch oauth cluster --type=merge -p "
spec:
  identityProviders:
  - name: htpasswd
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpasswd-secret
"

  # Wait for OAuth pods to pick up the new config
  log "Waiting for OAuth rollout on context=${context_name}..."
  kubectl --context="$context_name" rollout status \
    deployment/oauth-openshift \
    -n openshift-authentication \
    --timeout="$ROUTE_WAIT" || true   # MicroShift-aio may not have full oauth deployment

  # Log in as the new user to obtain a token
  log "Logging in as ${user_name} to obtain token..."
  local token
  token="$(
    docker exec "$container" \
      oc login \
        --insecure-skip-tls-verify=true \
        -u "$user_name" \
        -p "$USER_PASSWORD" \
        "https://${ip}:6443" 2>/dev/null \
      && docker exec "$container" oc whoami -t
  )"

  # Add the user context to kubeconfig
  kubectl config set-credentials "$user_name" --token="$token"
  kubectl config set-context "$user_context_name" \
    --cluster="$context_name" \
    --user="$user_name"

  log "User context created: ${user_context_name}"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
require_cmd docker
require_cmd kubectl

# ── Reset containers ──────────────────────────────────────────────────────────
if [[ "$RESET_CONTAINERS" == "true" ]]; then
  log "Removing existing containers: ${SRC_CONTAINER}, ${TGT_CONTAINER}"
  docker rm -f "$SRC_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$TGT_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "${SRC_CONTAINER}-data" >/dev/null 2>&1 || true
  docker volume rm "${TGT_CONTAINER}-data" >/dev/null 2>&1 || true
fi

# ── Docker network ────────────────────────────────────────────────────────────
if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  if [[ "$RECREATE_NETWORK" == "true" ]]; then
    log "Recreating docker network: ${NETWORK_NAME}"
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  fi
fi

if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  log "Creating docker network: ${NETWORK_NAME}"
  docker network create "$NETWORK_NAME" >/dev/null
fi

network_subnet="$(docker network inspect "$NETWORK_NAME" --format '{{(index .IPAM.Config 0).Subnet}}')"
if [[ -z "$network_subnet" || "$network_subnet" == "<no value>" ]]; then
  printf 'Error: unable to inspect subnet for network %s\n' "$NETWORK_NAME" >&2
  exit 1
fi
log "Docker network subnet: ${network_subnet}"

# Recreate with explicit subnet so static IPs are assignable (mirrors minikube script)
docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
docker network create --subnet "$network_subnet" "$NETWORK_NAME" >/dev/null

# ── Derive static IPs (same logic as minikube script) ────────────────────────
network_base="${network_subnet%.*}"   # e.g. 172.18.0
SRC_STATIC_IP="${network_base}.2"
TGT_STATIC_IP="${network_base}.3"
log "Assigned src IP: ${SRC_STATIC_IP}"
log "Assigned tgt IP: ${TGT_STATIC_IP}"

# ── Start containers ──────────────────────────────────────────────────────────
start_container "$SRC_CONTAINER" "$SRC_STATIC_IP" "$SRC_OCP_VERSION"
start_container "$TGT_CONTAINER" "$TGT_STATIC_IP" "$TGT_OCP_VERSION"

# ── Wait for both to be ready ─────────────────────────────────────────────────
wait_for_ready "$SRC_CONTAINER"
wait_for_ready "$TGT_CONTAINER"

# ── Extract and merge kubeconfigs ─────────────────────────────────────────────
SRC_KC="$(mktemp)"
TGT_KC="$(mktemp)"

extract_kubeconfig "$SRC_CONTAINER" "$SRC_STATIC_IP" "$SRC_CONTEXT" "$SRC_KC"
extract_kubeconfig "$TGT_CONTAINER" "$TGT_STATIC_IP" "$TGT_CONTEXT" "$TGT_KC"

merge_kubeconfig "$SRC_KC"
merge_kubeconfig "$TGT_KC"
rm -f "$SRC_KC" "$TGT_KC"

# ── Verify contexts ───────────────────────────────────────────────────────────
kubectl config get-contexts
kubectl --context="$SRC_CONTEXT" get nodes
kubectl --context="$TGT_CONTEXT" get nodes

# ── Create non-admin users ────────────────────────────────────────────────────
if [[ "$CREATE_USERS" == "true" ]]; then
  create_user_context "$SRC_CONTAINER" "$SRC_CONTEXT" "$SRC_USER" "$SRC_USER_CONTEXT" "$SRC_STATIC_IP"
  create_user_context "$TGT_CONTAINER" "$TGT_CONTEXT" "$TGT_USER" "$TGT_USER_CONTEXT" "$TGT_STATIC_IP"
else
  log "Skipping user creation (CREATE_USERS=${CREATE_USERS})"
fi

log "Done."
log "Clusters: ${SRC_CONTEXT}(${SRC_STATIC_IP}) ${TGT_CONTEXT}(${TGT_STATIC_IP})"