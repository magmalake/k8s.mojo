#!/bin/sh
# Runs tests/kind_client.mojo against a kind cluster: makes the cluster
# unless KIND_CLUSTER names one that's up, a namespace for the test, and a
# service account with no role whose token must be refused. KEEP_CLUSTER=1
# leaves a cluster this made. Needs docker, kind and kubectl.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
cluster=${KIND_CLUSTER:-k8s-mojo}
export KUBECONFIG="$PWD/build/kind-$cluster.yaml"
made=
if ! kind get clusters 2> /dev/null | grep -qx "$cluster"; then
    kind create cluster --name "$cluster" --kubeconfig "$KUBECONFIG" --wait 120s
    made=1
else
    kind get kubeconfig --name "$cluster" > "$KUBECONFIG"
fi
if [ -n "$made" ] && [ "${KEEP_CLUSTER:-0}" != 1 ]; then
    trap 'kind delete cluster --name "$cluster"' EXIT
fi
export K8S_TEST_NAMESPACE=k8s-mojo-test
kubectl delete namespace "$K8S_TEST_NAMESPACE" --ignore-not-found --wait
kubectl create namespace "$K8S_TEST_NAMESPACE"
kubectl -n "$K8S_TEST_NAMESPACE" create serviceaccount nobody
K8S_TEST_TOKEN=$(kubectl -n "$K8S_TEST_NAMESPACE" create token nobody)
export K8S_TEST_TOKEN
# shellcheck disable=SC2086
mojo build -I src $DEP_INC tests/kind_client.mojo -o build/kind-client
./build/kind-client
echo "ok   kind"
