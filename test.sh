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
