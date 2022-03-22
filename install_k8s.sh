DOCKER_VERSION="20.10.13"
DOCKER_PACKAGE_VERSION="${DOCKER_VERSION}~3-0~ubuntu-focal"
K8S_VERSION="1.22.4"

function check_distribution_is_supported {
  if [[ "$(lsb_release -is)" != "Ubuntu" ]] ; then
    echo "ERROR: This script requires Ubuntu, but it detected $(lsb_release -is)." >&2
    return 1
  fi
  if [[ ! "$(lsb_release -rs)" =~ ^20.04$ ]] && [[ ! "$(lsb_release -rs)" =~ ^18.04$ ]]; then
    echo "ERROR: This script only supports Ubuntu 20.04 and 18.04, but it" >&2
    echo "detected $(lsb_release -rs)." >&2
    return 1
  fi
}

function apt_get_install {
    local cmd=()
    if command -v sudo > /dev/null; then
        cmd+=(sudo)
    fi
    cmd+=(apt-get install --no-install-recommends -qq -y)
    if [ -n "$*" ]; then
        "${cmd[@]}" "$@"
    else
        xargs -r "${cmd[@]}"
    fi
}

function snap_install {
    local cmd=()
    if command -v sudo > /dev/null; then
        cmd+=(sudo)
    fi
    cmd+=(snap install)
    if [ -n "$*" ]; then
        "${cmd[@]}" "$@"
    else
        xargs -r "${cmd[@]}"
    fi
}

function add_apt_key {
  local key_url=$1

  curl -fsSL "${key_url}" | sudo apt-key add -
}

function apt_install {
  echo "Installing $*..."
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; then
    echo ""
    echo "ERROR: Failed to install $*. Try:" >&2
    echo "    sudo apt update && sudo apt install $*" >&2
    return 1
  fi
}

function retry {
  for _ in {1..4}; do
    "$@" && return
    echo "$* failed, waiting 60 seconds before retrying..." >&2
    sleep 60
  done
  "$@"
}

function install_common_deps {
  retry sudo apt-get update
  apt_install \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common
}

function install_docker_deps {
  # Install docker if necessary
  if ! docker --version 2>/dev/null | grep -qF "${DOCKER_VERSION}" ; then
    echo "Preparing to install Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null \
     <<< "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable"
    retry sudo apt-get update
    apt_install docker-ce
    echo "Pinning Docker version..."
    sudo apt-mark hold docker-ce
  fi
}

# enable cgroup memery subsystem in debian
function enable_cgroup_memery {
  if [ $(dpkg --print-architecture) == "arm64" ] ; then
    if ! grep -qF 'cgroup_enable=cpuset' /boot/firmware/cmdline.txt ; then
      sudo sed -i '$ s/$/ cgroup_enable=cpuset/' /boot/firmware/cmdline.txt
    fi
    if ! grep -qF 'cgroup_memory=1' /boot/firmware/cmdline.txt ; then
      sudo sed -i '$ s/$/ cgroup_memory=1/' /boot/firmware/cmdline.txt
    fi
    if ! grep -qF 'cgroup_enable=memory' /boot/firmware/cmdline.txt ; then
      sudo sed -i '$ s/$/ cgroup_enable=memory/' /boot/firmware/cmdline.txt
    fi
  fi
}

function install_k8s_deps {
  # Add k8s repo if necessary
  if [[ ! -f /etc/apt/sources.list.d/kubernetes.list ]] ; then
    echo "Preparing to install Kubernetes..."
    add_apt_key https://packages.cloud.google.com/apt/doc/apt-key.gpg
    sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null \
      <<< "deb http://apt.kubernetes.io/ kubernetes-xenial main"

    retry sudo apt-get update
  fi

  if ! kubelet --version 2>/dev/null | grep -qF "${K8S_VERSION}" ; then
    apt_install "kubelet=${K8S_VERSION}-00"
    echo "Pinning kubelet version..."
    sudo apt-mark hold kubelet
  fi
  if ! kubeadm version 2>/dev/null | grep -qF "${K8S_VERSION}" ; then
    apt_install "kubeadm=${K8S_VERSION}-00"
    echo "Pinning kubeadm version..."
    sudo apt-mark hold kubeadm
  fi
}

function install_k8s_master_deps {
  # Add k8s repo if necessary
  if [[ ! -f /etc/apt/sources.list.d/kubernetes.list ]] ; then
    echo "Preparing to install Kubernetes..."
    add_apt_key https://packages.cloud.google.com/apt/doc/apt-key.gpg
    sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null \
      <<< "deb http://apt.kubernetes.io/ kubernetes-xenial main"

    retry sudo apt-get update
  fi

  # Install or upgrade k8s binaries
  if ! kubectl version --client 2>/dev/null | grep -qF "${K8S_VERSION}" ; then
    apt_install "kubectl=${K8S_VERSION}-00"
    echo "Pinning kubectl version..."
    sudo apt-mark hold kubectl
  fi
  if ! kubelet --version 2>/dev/null | grep -qF "${K8S_VERSION}" ; then
    apt_install "kubelet=${K8S_VERSION}-00"
    echo "Pinning kubelet version..."
    sudo apt-mark hold kubelet
  fi
  if ! kubeadm version 2>/dev/null | grep -qF "${K8S_VERSION}" ; then
    apt_install "kubeadm=${K8S_VERSION}-00"
    echo "Pinning kubeadm version..."
    sudo apt-mark hold kubeadm
  fi
  echo "Deleting the old local cluster..."
  sudo kubeadm reset --force
}

function restart_system_service {
  local service="$1"

  sudo systemctl restart "${service}"
}

function docker_daemon_config {
  cat << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
}

function setup_docker {
  if sudo test ! -f /etc/docker/daemon.json; then
    echo "Configuring the docker daemon..."
    docker_daemon_config | sudo tee /etc/docker/daemon.json
    restart_system_service docker
  else
    # Docker daemon config already exists. Check it sets the bridge IP.
    # if ! sudo grep -q "$(partial_docker_daemon_config_for_bridge_ip)" /etc/docker/daemon.json; then
    #   echo "ERROR: /etc/docker/daemon.json doesn't set $(partial_docker_daemon_config_for_bridge_ip)" >&2
    #   echo "Please manually apply this setting to /etc/docker/daemon.json." >&2
    #   return 1
    # fi
    # Check if the log size is limited. Otherwise, the system will have problems with disk space
    # and/or fluentd performance.
    if ! sudo grep -q "\"max-size\"" /etc/docker/daemon.json; then
      echo "ERROR: /etc/docker/daemon.json doesn't enable log rotation." >&2
      echo "Please manually apply this to /etc/docker/daemon.json. See:" >&2
      echo "    https://success.docker.com/article/how-to-setup-log-rotation-post-installation" >&2
      return 1
    fi
  fi

  sudo adduser $USER docker
}

function setup_k8s {
  # Install a basic resolv.conf that kubelet can use. The default is
  # /etc/resolv.conf, which often points to a local cache (eg dnsmasq or
  # systemd-resolved) on the loopback address.
  sudo mkdir -p /etc/kubernetes
  sudo tee /etc/kubernetes/resolv.conf >/dev/null << EOF
# resolv.conf for kubelet. Automatically created by cloud robotics' install_k8s_on_robot.sh.
nameserver 8.8.8.8
EOF
}

function disable_swap {
  echo "Disabling swap on the local system..."

  # Remove swap entries from fstab.
  sudo sed -i '/ swap / s/^/# /' /etc/fstab

  # systemd automatically discovers swap partitions from the partition table and
  # activates them. Repeatedly. Mask the units to work around this charming
  # behavior:
  systemctl list-units --type swap \
    | awk '/ loaded active / {print $1;}' \
    | sudo xargs --no-run-if-empty systemctl mask

  # Temporarily disable swap until the next boot.
  sudo swapoff -a
}
