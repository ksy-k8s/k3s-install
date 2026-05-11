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

CERT_MANAGER_RELEASE_NAME="cert-manager"
CERT_MANAGER_NAMESPACE="cert-manager"
CERT_MANAGER_CHART_NAME="oci://quay.io/jetstack/charts/cert-manager"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-}"

NVIDIA_GPU_OPERATOR_RELEASE_NAME="gpu-operator"
NVIDIA_GPU_OPERATOR_NAMESPACE="gpu-operator"
NVIDIA_GPU_OPERATOR_REPO_NAME="nvidia"
NVIDIA_GPU_OPERATOR_REPO_URL="https://helm.ngc.nvidia.com/nvidia"
NVIDIA_GPU_OPERATOR_CHART_NAME="nvidia/gpu-operator"
NVIDIA_GPU_OPERATOR_CHART_VERSION="${NVIDIA_GPU_OPERATOR_CHART_VERSION:-}"
NVIDIA_DRIVER_PREINSTALLED="false"
NVIDIA_CONTAINER_TOOLKIT_PREINSTALLED="false"
NVIDIA_K3S_RUNTIME_PRECONFIGURED="false"
NVIDIA_CONTAINER_RUNTIME_DRIVER_ROOT_CONFIGURED="false"
NVIDIA_CUDA_TOOLKIT_PREINSTALLED="false"

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

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

debian_package_installed() {
  command_exists dpkg-query && dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

rpm_package_installed() {
  command_exists rpm && rpm -q "$1" >/dev/null 2>&1
}

# Install docs:
# https://docs.k3s.io/installation
# https://docs.k3s.io/installation/configuration
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

# Install docs:
# https://cert-manager.io/docs/installation/helm/
install_cert_manager() {
  section "Installing cert-manager"

  helm_args=(
    upgrade --install "$CERT_MANAGER_RELEASE_NAME" "$CERT_MANAGER_CHART_NAME"
    --namespace "$CERT_MANAGER_NAMESPACE"
    --create-namespace
    --set crds.enabled=true
    --wait
  )

  if [ -n "$CERT_MANAGER_CHART_VERSION" ]; then
    helm_args+=(--version "$CERT_MANAGER_CHART_VERSION")
  fi

  helm "${helm_args[@]}"
}

# Install docs:
# https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kata-deploy/helm-chart/kata-deploy
# https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/deploy-kata-containers.html
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

detect_nvidia_host_state() {
  section "Checking NVIDIA host state"

  NVIDIA_DRIVER_PREINSTALLED="false"
  NVIDIA_CONTAINER_TOOLKIT_PREINSTALLED="false"
  NVIDIA_K3S_RUNTIME_PRECONFIGURED="false"
  NVIDIA_CONTAINER_RUNTIME_DRIVER_ROOT_CONFIGURED="false"
  NVIDIA_CUDA_TOOLKIT_PREINSTALLED="false"

  if command_exists nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
    NVIDIA_DRIVER_PREINSTALLED="true"
    success "Working NVIDIA driver detected with nvidia-smi."
  elif [ -r /proc/driver/nvidia/version ]; then
    NVIDIA_DRIVER_PREINSTALLED="true"
    success "Loaded NVIDIA driver detected."
  else
    warn "No working host NVIDIA driver detected; GPU Operator will manage the driver."
  fi

  if command_exists nvidia-ctk || command_exists nvidia-container-runtime || command_exists nvidia-container-cli || \
    debian_package_installed nvidia-container-toolkit || rpm_package_installed nvidia-container-toolkit; then
    NVIDIA_CONTAINER_TOOLKIT_PREINSTALLED="true"
    success "NVIDIA Container Toolkit/runtime detected on the host."
  else
    warn "No host NVIDIA Container Toolkit/runtime detected; GPU Operator will manage the toolkit."
  fi

  if as_root grep -Eq 'runtimes[.]nvidia|nvidia-container-runtime|BinaryName[[:space:]]*=[[:space:]]*".*nvidia' "$K3S_CONTAINERD_CONFIG" "$K3S_CONTAINERD_TEMPLATE_PATH" 2>/dev/null; then
    NVIDIA_K3S_RUNTIME_PRECONFIGURED="true"
    success "K3s containerd already appears to have an NVIDIA runtime configured."
  else
    warn "K3s containerd does not appear preconfigured for NVIDIA; GPU Operator toolkit will configure it."
  fi

  if as_root test -f /etc/nvidia-container-runtime/config.toml && \
    as_root grep -Eq '^[[:space:]]*root[[:space:]]*=[[:space:]]*"/run/nvidia/driver"' /etc/nvidia-container-runtime/config.toml; then
    NVIDIA_CONTAINER_RUNTIME_DRIVER_ROOT_CONFIGURED="true"
    success "NVIDIA Container Runtime is configured for GPU Operator driver containers."
  fi

  if command_exists nvcc || debian_package_installed nvidia-cuda-toolkit || rpm_package_installed nvidia-cuda-toolkit; then
    NVIDIA_CUDA_TOOLKIT_PREINSTALLED="true"
    warn "CUDA toolkit detected, but CUDA alone does not change GPU Operator Helm settings."
  fi
}

# Install docs:
# https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html
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

  if [ "$NVIDIA_DRIVER_PREINSTALLED" = "true" ]; then
    helm_args+=(--set driver.enabled=false)
    success "Using pre-installed NVIDIA driver: driver.enabled=false"
  fi

  if [ "$NVIDIA_CONTAINER_TOOLKIT_PREINSTALLED" = "true" ] && [ "$NVIDIA_K3S_RUNTIME_PRECONFIGURED" = "true" ] && \
    { [ "$NVIDIA_DRIVER_PREINSTALLED" = "true" ] || [ "$NVIDIA_CONTAINER_RUNTIME_DRIVER_ROOT_CONFIGURED" = "true" ]; }; then
    helm_args+=(--set toolkit.enabled=false)
    success "Using pre-installed NVIDIA Container Toolkit/runtime: toolkit.enabled=false"
  else
    success "GPU Operator will manage NVIDIA Container Toolkit for K3s containerd."
  fi

  if [ -n "$NVIDIA_GPU_OPERATOR_CHART_VERSION" ]; then
    helm_args+=(--version "$NVIDIA_GPU_OPERATOR_CHART_VERSION")
  fi

  helm "${helm_args[@]}"
}

# Manifest source:
# https://gist.github.com/ehsqjfwk99999/b94c0a2578594fe1ad75d17c1458cff9
apply_nginx_clusterip_example() {
  section "Applying NGINX ClusterIP example"

  kubectl apply -f "$NGINX_CLUSTERIP_EXAMPLE_MANIFEST_URL"
}

print_next_steps() {
  section "Next steps"
  success "Done."
  echo
  echo "  kubectl get nodes"
  echo
  echo "  kubectl get pods -n $CERT_MANAGER_NAMESPACE"
  echo
  echo "  kubectl get pods -n $KATA_NAMESPACE"
  echo
  echo "  kubectl get runtimeclass"
  echo
  echo "  kubectl get pods -n $NVIDIA_GPU_OPERATOR_NAMESPACE"
  echo
  echo "  kubectl get deployment,svc"
  echo
}

main() {
  install_k3s
  wait_for_k3s
  ensure_k3s_containerd_template
  check_helm
  install_cert_manager
  install_kata_containers
  detect_nvidia_host_state
  install_nvidia_gpu_operator
  apply_nginx_clusterip_example
  print_next_steps
}

main "$@"
EOF

if [[ -f "$K3S_INSTALL_SCRIPT" ]]; then
  chmod +x "$K3S_INSTALL_SCRIPT"
fi
