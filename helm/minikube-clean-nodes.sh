#!/bin/sh

for i in {1..4}; do helm uninstall validator-$i --namespace quorum; done
for i in {1..4}; do kubectl delete pvc data-besu-node-validator-$i-0 --namespace quorum; done
#for i in {1..4}; do kubectl delete secret besu-node-validator-$i-keys --namespace quorum; done
minikube ssh 'rm -rf /tmp/besu-node-validator*'

