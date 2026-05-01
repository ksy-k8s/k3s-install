K3S_INSTALL_DIR="$HOME/dev/k3s-install"
K3S_INSTALL_SCRIPT="$K3S_INSTALL_DIR/k3s-install.sh"

mkdir $K3S_INSTALL_DIR

cat <<'EOF' > $K3S_INSTALL_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH="$HOME/.kube/config"

K3S_READY_MAX_ATTEMPTS=60
K3S_READY_SLEEP_SECONDS=5
K3S_READY_CHECK_TIMEOUT="10s"

NVDP_RELEASE_NAME="nvdp"
NVDP_NAMESPACE="nvidia-device-plugin"
NVDP_REPO_NAME="nvdp"
NVDP_REPO_URL="https://nvidia.github.io/k8s-device-plugin"
NVDP_CHART_NAME="nvdp/nvidia-device-plugin"

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

check_helm() {
  section "Checking Helm"

  if ! command -v helm >/dev/null 2>&1; then
    error "helm is not installed or not in PATH."
    warn "Install Helm first, then re-run this script."
    exit 1
  fi

  success "Helm found: $(helm version --short)"
}

add_nvidia_helm_repo() {
  section "Adding/updating NVIDIA device plugin Helm repo"

  helm repo add "$NVDP_REPO_NAME" "$NVDP_REPO_URL" 2>/dev/null || true
  helm repo update
}

install_nvidia_device_plugin() {
  section "Installing NVIDIA device plugin"

  helm install "$NVDP_RELEASE_NAME" "$NVDP_CHART_NAME" \
    --namespace "$NVDP_NAMESPACE" \
    --create-namespace
}

print_next_steps() {
  section "Next steps"
  success "Done."
  echo
  echo "Check K3s nodes:"
  echo "  kubectl get nodes"
  echo
  echo "Check NVIDIA device plugin pods:"
  echo "  kubectl get pods -n $NVDP_NAMESPACE"
  echo
}

main() {
  install_k3s
  wait_for_k3s
  check_helm
  add_nvidia_helm_repo
  install_nvidia_device_plugin
  print_next_steps
}

main "$@"
EOF

if [[ -f "$K3S_INSTALL_SCRIPT" ]]; then
  chmod +x "$K3S_INSTALL_SCRIPT"
fi
