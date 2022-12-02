#!/bin/sh

pushd helm

#minikube delete && minikube start --memory 16384 --cpus 6 --addons=ingress,ingress-dns && minikube dashboard &
#minikube tunnel -c

echo "Deploying genesis ConfigMap"
minikube ssh docker pull consensys/quorum-k8s-hooks:qgt-0.2.3
helm install genesis ./charts/besu-genesis --namespace quorum --create-namespace --values ./values/genesis-besu.yml
#kubectl wait --for=condition=complete --timeout=300s job/besu-genesis-init --namespace quorum
while ! kubectl get configmap besu-peers --namespace quorum; do echo "Waiting for besu-peers ConfigMap"; sleep 20; done
sleep 60

echo "Adding genesis contracts"
CONTRACT_FILE="../contracts/genesis-contracts.json"
CONFIG_MAP=`kubectl get configmap --namespace quorum -o yaml besu-genesis`
NEW_JSON=`echo "$CONFIG_MAP" | yq e '.data."genesis.json"' | jq --argjson contracts "$(cat $CONTRACT_FILE | jq .)" '.alloc |= . + $contracts'`
echo "$CONFIG_MAP" | json="$NEW_JSON" yq e '.data."genesis.json" = strenv(json)' | kubectl apply -f -

echo "Deploying monitoring tools (Prometheus and Grafana)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
minikube ssh docker pull quay.io/prometheus/alertmanager:v0.24.0
minikube ssh docker pull k8s.gcr.io/ingress-nginx/kube-webhook-certgen:v1.1.1
minikube ssh docker pull quay.io/prometheus-operator/prometheus-operator:v0.55.0
minikube ssh docker pull quay.io/prometheus-operator/prometheus-config-reloader:v0.55.0
minikube ssh docker pull quay.io/thanos/thanos:v0.25.2
minikube ssh docker pull quay.io/prometheus/prometheus
helm install monitoring prometheus-community/kube-prometheus-stack --version 34.10.0 --namespace=quorum --create-namespace --values ./values/monitoring.yml
sleep 60
kubectl --namespace quorum apply -f  ./values/monitoring/

echo "Deploying Quorum Explorer"
helm install quorum-explorer ./charts/explorer --namespace quorum --create-namespace --values ./values/explorer-besu.yaml

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install quorum-network-ingress ingress-nginx/ingress-nginx \
    --namespace quorum \
    --set controller.ingressClassResource.name="network-nginx" \
    --set controller.ingressClassResource.controllerValue="k8s.io/network-ingress-nginx" \
    --set controller.replicaCount=1 \
    --set controller.nodeSelector."kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
    --set controller.admissionWebhooks.patch.nodeSelector."kubernetes\.io/os"=linux \
    --set controller.service.externalTrafficPolicy=Local

sleep 60
kubectl apply -f ../ingress/ingress-rules-besu.yml

for i in {1..4}; do helm install validator-$i ./charts/besu-node --namespace quorum --values ./values/validator.yml; done

echo "Nodes installed, giving time to sync"
sleep 120

#echo "Restarting network with node permissioning enabled"
#for i in {1..4}; do helm upgrade validator-$i --recreate-pods  ./charts/besu-node --namespace quorum --values ./values/validator.yml --set node.besu.permissions.nodesContract.enabled=true --set node.besu.logging=TRACE; done

echo "Deploying BlockScout"
minikube ssh docker pull consensys/blockscout:v4.0.0-beta
helm repo add cetic https://cetic.github.io/helm-charts 
helm dependency update ./charts/blockscout
helm install blockscout ./charts/blockscout --namespace quorum --values ./values/blockscout-besu.yml

echo "Complete!"

INITIAL_ALLOWLISTED_NODES=$(kubectl --namespace quorum get configmap besu-peers -o jsonpath="{.data.static-nodes\.json}" | jq -c '.[]' | tr -d '"' | tr '\n' ',' | sed '$ s/,$//g')

echo "
Next steps:

- If running locally:
	- \`minikube tunnel -c\`
	- Add entries to '/etc/hosts' for explorer.chain.test, grafana.chain.test, nodes.chain.test, blockscout.chain.test pointing to your ingress endpoint

- Deploy ConsenSys/permissioning-smart-contracts using following environment variables, (may need to add 0.0.0.0 host):
  Note we are using insecure test private key here!

CHAIN_ID=1337
BESU_NODE_PERM_ACCOUNT=0x8C9840f00cC5c6da7d76E6045E1D205Cb46162d2
BESU_NODE_PERM_KEY=0xa34c2d3c58837884f4c88da2fd38d0c4e234cd3021618d8304d3b4efed1bfc93
BESU_NODE_PERM_ENDPOINT=http://nodes.chain.test/validator-1
ACCOUNT_INGRESS_CONTRACT_ADDRESS=0x0000000000000000000000000000000000008888
NODE_INGRESS_CONTRACT_ADDRESS=0x0000000000000000000000000000000000009999
INITIAL_ALLOWLISTED_NODES=$INITIAL_ALLOWLISTED_NODES
INITIAL_ALLOWLISTED_ACCOUNTS=0x8C9840f00cC5c6da7d76E6045E1D205Cb46162d2
INITIAL_ADMIN_ACCOUNTS=0x8C9840f00cC5c6da7d76E6045E1D205Cb46162d2
RETAIN_NODE_RULES_CONTRACT=false
RETAIN_ACCOUNT_RULES_CONTRACT=false
RETAIN_ADMIN_CONTRACT=false

- Import above private key to wallet
- Reconnect metamask to chain + reset account
- Restart nodes with permissioning enabled
"

