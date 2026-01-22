find . -name "*.yaml" -exec sed -i '/^support-os:/,/^[^[:space:]]/d' {} +


for ns in $(oc get managedclusters -o jsonpath='{.items[*].metadata.name}'); do
  oc get secret ${ns}-admin-kubeconfig -n ${ns}
done


for ns in $(oc get managedclusters -o jsonpath='{.items[*].metadata.name}'); do
  oc get secret ${ns}-admin-kubeconfig \
    -n ${ns} \
    -o yaml > ${ns}-admin-kubeconfig.yaml
done

oc apply -f *-admin-kubeconfig.yaml


#!/bin/bash

ansible-playbook site.yml
rc=$?

if [ $rc -eq 0 ]; then
  echo "playbook succeeded"
else
  echo "playbook failed, rc=$rc"
  exit 1
fi


for f in *-admin-kubeconfig.yaml; do
  ns=$(grep '^  name:' "$f" | head -1 | awk '{print $2}')
  oc get ns "$ns" >/dev/null 2>&1 || oc create ns "$ns"
done
