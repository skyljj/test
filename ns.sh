#!/bin/bash

# Check if logged into OpenShift
if ! oc whoami &>/dev/null; then
    echo "Error: Please run 'oc login' to authenticate with your OpenShift cluster first!"
    exit 1
fi

# Check if the namespace file exists
NS_FILE="ns.txt"
if [ ! -f "$NS_FILE" ]; then
    echo "Error: File '$NS_FILE' not found. Please ensure it exists in the current directory."
    exit 1
fi

echo "Starting batch deletion from $NS_FILE..."
echo "------------------------------------------------"

count=0

# Read file line by line, removing potential Windows carriage returns (\r)
while IFS= read -r project_name || [ -n "$project_name" ]; do
    # Skip empty lines and lines starting with '#'
    [[ -z "$project_name" || "$project_name" =~ ^# ]] && continue
    
    # Strip any leading/trailing whitespace
    project_name=$(echo "$project_name" | xargs)
    
    echo "[Progress] Processing project: $project_name"
    
    # Delete the Project asynchronously to speed up the loop
    echo "  -> Deleting project..."
    oc delete project "$project_name" --wait=false
    
    # Delete the associated ClusterRoleBinding
    echo "  -> Deleting clusterrolebinding..."
    oc delete clusterrolebinding "${project_name}-cluster-reader"
    
    echo "------------------------------------------------"
    ((count++))
done < <(tr -d '\r' < "$NS_FILE")

echo "Done! Total processed items: $count"
echo "Note: Since '--wait=false' was used, OpenShift will continue recycling resources in the background. You can monitor the progress via 'oc get project'."
