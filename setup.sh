K3S_INSTALL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
K3S_INSTALL_SCRIPT="$K3S_INSTALL_DIR/k3s-install.sh"

mkdir -p "$K3S_INSTALL_DIR"

cat <<'EOF' > "$K3S_INSTALL_SCRIPT"
#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH="$HOME/.kube/config"

K3S_CONTAINERD_CONFIG_DIR="/var/lib/rancher/k3s/agent/etc/containerd"
K3S_CONTAINERD_CONFIG="$K3S_CONTAINERD_CONFIG_DIR/config.toml"
K3S_CONTAINERD_CONFIG_TEMPLATE_V3="$K3S_CONTAINERD_CONFIG_DIR/config-v3.toml.tmpl"
K3S_CONTAINERD_CONFIG_TEMPLATE_V2="$K3S_CONTAINERD_CONFIG_DIR/config.toml.tmpl"
K3S_CONTAINERD_SOCKET="/run/k3s/containerd/containerd.sock"
K3S_CONTAINERD_TEMPLATE_PATH=""

K3S_READY_MAX_ATTEMPTS=60
K3S_READY_SLEEP_SECONDS=5
K3S_READY_CHECK_TIMEOUT="10s"
K3S_CONTAINERD_READY_MAX_ATTEMPTS=60
K3S_CONTAINERD_READY_SLEEP_SECONDS=2

KATA_RELEASE_NAME="kata-deploy"
KATA_NAMESPACE="kube-system"
KATA_CHART_NAME="oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy"
KATA_CHART_VERSION="${KATA_CHART_VERSION:-}"

NVIDIA_GPU_OPERATOR_RELEASE_NAME="gpu-operator"
NVIDIA_GPU_OPERATOR_NAMESPACE="gpu-operator"
NVIDIA_GPU_OPERATOR_REPO_NAME="nvidia"
NVIDIA_GPU_OPERATOR_REPO_URL="https://helm.ngc.nvidia.com/nvidia"
NVIDIA_GPU_OPERATOR_CHART_NAME="nvidia/gpu-operator"
NVIDIA_GPU_OPERATOR_CHART_VERSION="${NVIDIA_GPU_OPERATOR_CHART_VERSION:-}"

NGINX_CLUSTERIP_EXAMPLE_MANIFEST_URL="https://gist.githubusercontent.com/ehsqjfwk99999/b94c0a2578594fe1ad75d17c1458cff9/raw/1fc7c012f99be40c781ea25eb1b7a0352ea433b1/nginx-deployment-clusterip-example.yaml"

if [ -t 1 ]; then
  BOLD="\033[1m"
  BLUE="\033[34m"
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  RESET="\033[0m"
else
  BOLD=""
  BLUE=""
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
fi

section() {
  printf "\n${BOLD}${BLUE}==> %s${RESET}\n" "$1"
}

success() {
  printf "${GREEN}✓ %s${RESET}\n" "$1"
}

warn() {
  printf "${YELLOW}! %s${RESET}\n" "$1"
}

error() {
  printf "${RED}Error: %s${RESET}\n" "$1" >&2
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_k3s() {
  section "Installing K3s"

  curl -sfL https://get.k3s.io | \
    K3S_KUBECONFIG_OUTPUT="$KUBECONFIG_PATH" K3S_KUBECONFIG_MODE="644" \
    INSTALL_K3S_EXEC="--disable=traefik" \
    sh -

  export KUBECONFIG="$KUBECONFIG_PATH"
}

wait_for_k3s() {
  section "Waiting for K3s node to become ready"

  for ((i = 1; i <= K3S_READY_MAX_ATTEMPTS; i++)); do
    if kubectl get nodes >/dev/null 2>&1 && kubectl wait --for=condition=Ready node --all --timeout="$K3S_READY_CHECK_TIMEOUT" >/dev/null 2>&1; then
      success "K3s is ready."
      break
    fi

    if [ "$i" -eq "$K3S_READY_MAX_ATTEMPTS" ]; then
      error "K3s did not become ready in time."
      exit 1
    fi

    sleep "$K3S_READY_SLEEP_SECONDS"
  done
}

wait_for_k3s_containerd() {
  section "Waiting for K3s containerd config"

  if [ "$(id -u)" -ne 0 ]; then
    sudo -v
  fi

  for ((i = 1; i <= K3S_CONTAINERD_READY_MAX_ATTEMPTS; i++)); do
    if as_root test -f "$K3S_CONTAINERD_CONFIG" && as_root test -S "$K3S_CONTAINERD_SOCKET"; then
      success "K3s containerd config is ready."
      return
    fi

    if [ "$i" -eq "$K3S_CONTAINERD_READY_MAX_ATTEMPTS" ]; then
      error "K3s containerd config or socket was not found in time."
      error "Expected config: $K3S_CONTAINERD_CONFIG"
      error "Expected socket: $K3S_CONTAINERD_SOCKET"
      exit 1
    fi

    sleep "$K3S_CONTAINERD_READY_SLEEP_SECONDS"
  done
}

ensure_k3s_containerd_template() {
  wait_for_k3s_containerd

  if as_root test -f "$K3S_CONTAINERD_CONFIG_TEMPLATE_V3"; then
    K3S_CONTAINERD_TEMPLATE_PATH="$K3S_CONTAINERD_CONFIG_TEMPLATE_V3"
  elif as_root test -f "$K3S_CONTAINERD_CONFIG_TEMPLATE_V2"; then
    K3S_CONTAINERD_TEMPLATE_PATH="$K3S_CONTAINERD_CONFIG_TEMPLATE_V2"
  else
    if as_root grep -Eq '^[[:space:]]*version[[:space:]]*=[[:space:]]*3' "$K3S_CONTAINERD_CONFIG"; then
      containerd_template_path="$K3S_CONTAINERD_CONFIG_TEMPLATE_V3"
    else
      containerd_template_path="$K3S_CONTAINERD_CONFIG_TEMPLATE_V2"
    fi

    if ! printf '%s\n' '{{ template "base" . }}' | as_root tee "$containerd_template_path" >/dev/null; then
      error "Failed to create K3s containerd template at $containerd_template_path."
      error "Re-run this script with permission to write under $K3S_CONTAINERD_CONFIG_DIR."
      exit 1
    fi

    K3S_CONTAINERD_TEMPLATE_PATH="$containerd_template_path"
    success "Created K3s containerd template: $K3S_CONTAINERD_TEMPLATE_PATH"
  fi
}

check_helm() {
  section "Checking Helm"

  if ! command -v helm >/dev/null 2>&1; then
    error "helm is not installed or not in PATH."
    warn "Install Helm first, then re-run this script."
    exit 1
  fi

  success "Helm found: $(helm version --short)"
}

install_kata_containers() {
  section "Installing Kata Containers"

  helm_args=(
    upgrade --install "$KATA_RELEASE_NAME" "$KATA_CHART_NAME"
    --namespace "$KATA_NAMESPACE"
    --set k8sDistribution=k3s
    --wait
  )

  if [ -n "$KATA_CHART_VERSION" ]; then
    helm_args+=(--version "$KATA_CHART_VERSION")
  fi

  helm "${helm_args[@]}"
}

install_nvidia_gpu_operator() {
  section "Installing NVIDIA GPU Operator"

  helm repo add "$NVIDIA_GPU_OPERATOR_REPO_NAME" "$NVIDIA_GPU_OPERATOR_REPO_URL" 2>/dev/null || true
  helm repo update

  helm_args=(
    upgrade --install "$NVIDIA_GPU_OPERATOR_RELEASE_NAME" "$NVIDIA_GPU_OPERATOR_CHART_NAME"
    --namespace "$NVIDIA_GPU_OPERATOR_NAMESPACE"
    --create-namespace
    --set "toolkit.env[0].name=CONTAINERD_CONFIG"
    --set "toolkit.env[0].value=$K3S_CONTAINERD_TEMPLATE_PATH"
    --set "toolkit.env[1].name=CONTAINERD_SOCKET"
    --set "toolkit.env[1].value=$K3S_CONTAINERD_SOCKET"
    --set "toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS"
    --set "toolkit.env[2].value=nvidia"
    --wait
  )

  if [ -n "$NVIDIA_GPU_OPERATOR_CHART_VERSION" ]; then
    helm_args+=(--version "$NVIDIA_GPU_OPERATOR_CHART_VERSION")
  fi

  helm "${helm_args[@]}"
}

apply_nginx_clusterip_example() {
  section "Applying NGINX ClusterIP example"

  kubectl apply -f "$NGINX_CLUSTERIP_EXAMPLE_MANIFEST_URL"
}

print_next_steps() {
  section "Next steps"
  success "Done."
  echo
  echo "Check K3s nodes:"
  echo "  kubectl get nodes"
  echo
  echo "Check RuntimeClasses:"
  echo "  kubectl get runtimeclass"
  echo
  echo "Check Kata Containers pods:"
  echo "  kubectl get pods -n $KATA_NAMESPACE"
  echo
  echo "Check NVIDIA GPU Operator pods:"
  echo "  kubectl get pods -n $NVIDIA_GPU_OPERATOR_NAMESPACE"
  echo
  echo "Check NGINX ClusterIP example:"
  echo "  kubectl get deployment,svc"
  echo
}

main() {
  install_k3s
  wait_for_k3s
  ensure_k3s_containerd_template
  check_helm
  install_kata_containers
  install_nvidia_gpu_operator
  apply_nginx_clusterip_example
  print_next_steps
}

main "$@"
EOF

if [[ -f "$K3S_INSTALL_SCRIPT" ]]; then
  chmod +x "$K3S_INSTALL_SCRIPT"
fi
