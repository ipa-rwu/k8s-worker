source "./install_k8s.sh"

function install_k8s_on_robot {
  check_distribution_is_supported

  # Install required dependencies. Once we move the k8s-on-robot bootstrapping to a debian package,
  # all of the following package installs should be enforced via package dependencies.
  install_common_deps
  install_docker_deps
  install_k8s_deps

  # Setup and configure docker and k8s.
  setup_docker
  setup_k8s

  echo
  echo "The local Kubernetes cluster has been installed."
}

function clean_up_k8s {
  echo
  echo "Clean up k8s ..."

  sudo kubeadm reset --force
}

function main {
  local master_address=$1
  local token=$2
  local discovery_token=$3

  install_k8s_on_robot
  disable_swap
  enable_cgroup_memery

  clean_up_k8s

  echo
  echo "Join cluster ..."
  sudo kubeadm join $master_address --token $token --discovery-token-ca-cert-hash $discovery_token

}

if [[ "$#" == 3 ]]; then
    main $1 $2 $3
else
    echo "Usage: $1 [<kubernetes cluster master address>]" >&2
    echo "Usage: $2 [<token>]" >&2
    echo "Usage: $3 [<discovery token>]" >&2
fi
