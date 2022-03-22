CLUSTER_NAME="ddt_kubernetes"

function clean_up_k8s {
    local cluster_name="$1"

    echo
    echo "Clean up k8s ..."

    kubectl config delete-cluster "$cluster_name"
    sudo kubeadm reset
    sudo rm $HOME/.kube/config
}

if [[ -f /etc/kubernetes/pki/ca.crt ]] ; then
    if (($# == 1)); then
        clean_up_k8s $1
    else
        clean_up_k8s $CLUSTER_NAME
    fi
fi
