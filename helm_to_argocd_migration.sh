#!/usr/bin/env bash

set -eo pipefail

RELEASE_NAME="${1}"
NAMESPACE="${2}"
ARGOCD_APP_NAME="${3:-$RELEASE_NAME}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ -z "$RELEASE_NAME" || -z "$NAMESPACE" ]]; then
    echo -e "${RED}Usage: $0 <helm-release-name> <namespace> [argocd-app-name]${NC}"
    echo -e "Example: $0 my-app production my-app"
    exit 1
fi

echo -e "${BLUE}=== Helm to ArgoCD Migration Script ===${NC}"
echo -e "Helm Release: ${YELLOW}$RELEASE_NAME${NC}"
echo -e "Namespace: ${YELLOW}$NAMESPACE${NC}"
echo -e "ArgoCD App: ${YELLOW}$ARGOCD_APP_NAME${NC}"

echo -e "\n${GREEN}Running pre-flight checks...${NC}"

echo -n "  Checking kubectl access... "
if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}✗${NC}"
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster. Check your kubeconfig.${NC}"
    exit 1
fi
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
echo -e "✓ (context: ${YELLOW}$CURRENT_CONTEXT${NC})"

echo -n "  Checking namespace exists... "
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}✗${NC}"
    echo -e "${RED}Error: Namespace '$NAMESPACE' not found${NC}"
    exit 1
fi
echo "✓"

echo -n "  Checking helm command... "
if ! command -v helm &>/dev/null; then
    echo -e "${RED}✗${NC}"
    echo -e "${RED}Error: helm command not found. Please install helm.${NC}"
    exit 1
fi
HELM_VERSION=$(helm version --short 2>/dev/null | cut -d: -f2 | tr -d ' v')
echo "✓ (version: $HELM_VERSION)"

echo -n "  Checking argocd CLI... "
if ! command -v argocd &>/dev/null; then
    echo -e "${YELLOW}⚠${NC}"
    echo -e "${YELLOW}Warning: argocd CLI not found. You'll need to configure ArgoCD manually.${NC}"
    ARGOCD_AVAILABLE=false
else
    ARGOCD_VERSION=$(argocd version --short --client 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' v' || echo "unknown")
    echo "✓ (version: $ARGOCD_VERSION)"
    ARGOCD_AVAILABLE=true
fi

if [[ "$ARGOCD_AVAILABLE" == "true" ]]; then
    echo -n "  Checking ArgoCD login status... "
    if ! argocd account get-user-info --grpc-web &>/dev/null; then
        echo -e "${YELLOW}⚠${NC}"
        echo -e "${YELLOW}Warning: Not logged into ArgoCD. Run: argocd login <server>${NC}"
        echo -e "${RED}You will NOT be able to complete the migration without ArgoCD access.${NC}"
        echo -e "${YELLOW}Continue anyway? You'll need ArgoCD access to sync. (y/N) ${NC}"
        read -r ARGOCD_CONTINUE
        if [[ ! "$ARGOCD_CONTINUE" =~ ^[Yy]$ ]]; then
            echo "Aborted. Please login to ArgoCD first."
            exit 1
        fi
        ARGOCD_LOGGED_IN=false
    else
        ARGOCD_USER=$(argocd account get-user-info --grpc-web -o json 2>/dev/null | jq -r '.username' || echo "unknown")
        ARGOCD_SERVER=$(argocd context 2>/dev/null | grep -E '^\*' | awk '{print $2}' || echo "unknown")
        echo -e "✓ (user: ${YELLOW}$ARGOCD_USER${NC}, server: ${YELLOW}$ARGOCD_SERVER${NC})"
        ARGOCD_LOGGED_IN=true
    fi
fi

if [[ "$ARGOCD_LOGGED_IN" == "true" ]]; then
    echo -n "  Checking ArgoCD application... "
    if argocd app get "$ARGOCD_APP_NAME" --grpc-web &>/dev/null; then
        SYNC_STATUS=$(argocd app get "$ARGOCD_APP_NAME" --grpc-web -o json | jq -r '.status.sync.status' || echo "Unknown")
        HEALTH_STATUS=$(argocd app get "$ARGOCD_APP_NAME" --grpc-web -o json | jq -r '.status.health.status' || echo "Unknown")
        AUTO_SYNC=$(argocd app get "$ARGOCD_APP_NAME" --grpc-web -o json | jq -r '.spec.syncPolicy.automated' || echo "null")
        
        if [[ "$SYNC_STATUS" == "Synced" ]]; then
            echo -e "${RED}✗${NC}"
            echo -e "${RED}Error: ArgoCD app '$ARGOCD_APP_NAME' is already synced!${NC}"
            echo -e "${RED}This will likely cause resource conflicts.${NC}"
            echo -e "${YELLOW}Please delete and recreate the app with sync disabled, or use a different app name.${NC}"
            exit 1
        elif [[ "$AUTO_SYNC" != "null" ]]; then
            echo -e "${RED}✗${NC}"
            echo -e "${RED}Error: ArgoCD app '$ARGOCD_APP_NAME' has auto-sync enabled!${NC}"
            echo -e "${YELLOW}Please disable auto-sync first:${NC}"
            echo -e "${GREEN}argocd app set $ARGOCD_APP_NAME --sync-policy none --grpc-web${NC}"
            exit 1
        else
            echo -e "✓ (status: ${YELLOW}$SYNC_STATUS${NC})"
        fi
    else
        echo -e "${YELLOW}⚠ Not found${NC}"
        echo -e "${YELLOW}  Note: ArgoCD app '$ARGOCD_APP_NAME' doesn't exist yet.${NC}"
        echo -e "${YELLOW}  You'll need to create it after migration with:${NC}"
        echo -e "${GREEN}  argocd app create $ARGOCD_APP_NAME --sync-option ServerSideApply=true --grpc-web ...${NC}"
    fi
fi

echo -n "  Checking jq command... "
if ! command -v jq &>/dev/null; then
    echo -e "${RED}✗${NC}"
    echo -e "${RED}Error: jq command not found. Please install jq.${NC}"
    exit 1
fi
echo "✓"

echo -n "  Checking namespace permissions... "
if ! kubectl auth can-i '*' '*' -n "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}⚠${NC}"
    echo -e "${YELLOW}Warning: May not have full permissions in namespace '$NAMESPACE'${NC}"
else
    echo "✓"
fi

echo -e "${GREEN}Pre-flight checks complete!${NC}\n"

echo -e "${BLUE}ArgoCD App Setup:${NC}"
if [[ "$ARGOCD_LOGGED_IN" == "true" ]] && argocd app get "$ARGOCD_APP_NAME" --grpc-web &>/dev/null; then
    echo -e "  ✓ ArgoCD app '${YELLOW}$ARGOCD_APP_NAME${NC}' exists and is ready for migration"
else
    echo -e "  ${YELLOW}ℹ${NC} ArgoCD app should be created ${BLUE}either before OR after${NC} running this script"
    echo -e "  ${YELLOW}ℹ${NC} If creating before: Use ${GREEN}--sync-policy none${NC} to prevent auto-sync"
    echo -e "  ${YELLOW}ℹ${NC} If creating after: Use ${GREEN}--sync-option ServerSideApply=true${NC} for adoption"
fi

echo -e "\n${BLUE}Migration Process Overview:${NC}"
echo -e "  ${GREEN}Phase 1: Ownership Transfer${NC} (this script - zero downtime)"
echo -e "    • Remove Helm ownership from resources"
echo -e "    • Add ArgoCD tracking labels/annotations"
echo -e "    • Delete Helm release secrets"
echo -e "    • Resources continue running unchanged"
echo -e ""
echo -e "  ${GREEN}Phase 2: ArgoCD Sync${NC} (after script - may trigger rolling updates)"
echo -e "    • Services/ConfigMaps/Secrets: Usually just adopted (no restart)"
echo -e "    • Deployments/StatefulSets: May recreate pods if manifests differ"
echo -e "    • Rolling updates ensure zero downtime (new pods healthy first)"
echo -e "    • StatefulSets update one pod at a time for safety"

echo -e "\n${YELLOW}This script will:${NC}"
echo -e "  1. Remove Helm ownership from all resources in the '$RELEASE_NAME' release"
echo -e "  2. Update resource labels for ArgoCD adoption"
echo -e "  3. Delete Helm release tracking secrets"
echo -e "  4. Add ArgoCD tracking labels to ensure adoption"
if [[ "$ARGOCD_LOGGED_IN" == "true" ]] && argocd app get "$ARGOCD_APP_NAME" --grpc-web &>/dev/null; then
    echo -e "  5. Configure ArgoCD app '$ARGOCD_APP_NAME' for resource adoption"
fi
echo -e "\n${GREEN}Resources will continue running with zero downtime during this phase.${NC}"
echo -e "${YELLOW}The subsequent ArgoCD sync may trigger rolling updates if manifests differ.${NC}"
echo -n -e "\n${YELLOW}Continue? (y/N) ${NC}"
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo -e "\n${GREEN}Step 1: Verifying Helm release exists...${NC}"
if ! helm list -n "$NAMESPACE" | grep -q "^$RELEASE_NAME[[:space:]]"; then
    echo -e "${RED}Error: Helm release '$RELEASE_NAME' not found in namespace '$NAMESPACE'${NC}"
    echo "Available releases in this namespace:"
    helm list -n "$NAMESPACE" --short
    exit 1
fi
echo "✓ Helm release found"

echo -e "\n${GREEN}Step 2: Finding all resources managed by Helm release...${NC}"
RESOURCES=$(kubectl get all,cm,secret,pvc,ingress,service,deployment,statefulset,daemonset,job,cronjob \
    -n "$NAMESPACE" \
    -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations."meta.helm.sh/release-name" == "'$RELEASE_NAME'") | "\(.kind)/\(.metadata.name)"' | \
    sort -u || true)

if [[ -z "$RESOURCES" ]]; then
    echo -e "${RED}No resources found for Helm release '$RELEASE_NAME'${NC}"
    exit 1
fi

RESOURCE_COUNT=$(echo "$RESOURCES" | wc -l)
echo "Found $RESOURCE_COUNT resources:"

# Categorize resources for better visibility
STATEFUL_RESOURCES=""
STATELESS_RESOURCES=""
CONFIG_RESOURCES=""

while IFS= read -r resource; do
    case "$resource" in
        Deployment/*|StatefulSet/*|DaemonSet/*|Job/*|CronJob/*)
            STATEFUL_RESOURCES="$STATEFUL_RESOURCES$resource\n"
            ;;
        Service/*|Ingress/*)
            STATELESS_RESOURCES="$STATELESS_RESOURCES$resource\n"
            ;;
        ConfigMap/*|Secret/*|PersistentVolumeClaim/*)
            CONFIG_RESOURCES="$CONFIG_RESOURCES$resource\n"
            ;;
        *)
            STATELESS_RESOURCES="$STATELESS_RESOURCES$resource\n"
            ;;
    esac
done <<< "$RESOURCES"

if [[ -n "$CONFIG_RESOURCES" ]]; then
    echo -e "  ${GREEN}Config resources (usually just adopted):${NC}"
    echo -e "$CONFIG_RESOURCES" | grep -v '^$' | sed 's/^/    - /'
fi

if [[ -n "$STATELESS_RESOURCES" ]]; then
    echo -e "  ${GREEN}Network resources (usually just adopted):${NC}"
    echo -e "$STATELESS_RESOURCES" | grep -v '^$' | sed 's/^/    - /'
fi

if [[ -n "$STATEFUL_RESOURCES" ]]; then
    echo -e "  ${YELLOW}Workload resources (may trigger rolling updates during sync):${NC}"
    echo -e "$STATEFUL_RESOURCES" | grep -v '^$' | sed 's/^/    - /'
fi

echo -e "\n${GREEN}Step 3: Removing Helm ownership annotations...${NC}"
CLEANED_COUNT=0
while IFS= read -r resource; do
    echo -n "  Cleaning $resource... "
    if kubectl annotate -n "$NAMESPACE" "$resource" \
        meta.helm.sh/release-name- \
        meta.helm.sh/release-namespace- \
        meta.helm.sh/release-version- \
        --overwrite 2>/dev/null; then
        echo "✓"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        if kubectl get -n "$NAMESPACE" "$resource" >/dev/null 2>&1; then
            echo "✓ (no helm annotations)"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        else
            echo "⚠ (resource not found)"
        fi
    fi
done <<< "$RESOURCES"
echo "Processed $CLEANED_COUNT resources"

echo -e "\n${GREEN}Step 4: Updating labels for ArgoCD adoption...${NC}"
echo "Adding ArgoCD tracking labels..."
LABELED_COUNT=0
while IFS= read -r resource; do
    echo -n "  Labeling $resource... "
    if kubectl label -n "$NAMESPACE" "$resource" \
        app.kubernetes.io/instance=$ARGOCD_APP_NAME \
        argocd.argoproj.io/instance=$ARGOCD_APP_NAME \
        --overwrite 2>/dev/null; then
        echo "✓"
        LABELED_COUNT=$((LABELED_COUNT + 1))
    else
        echo "⚠ (failed)"
    fi
done <<< "$RESOURCES"
echo "Labeled $LABELED_COUNT resources"

echo -e "\n${GREEN}Step 5: Adding ArgoCD tracking annotations...${NC}"
echo "Ensuring resources can be adopted by ArgoCD..."
ANNOTATED_COUNT=0
while IFS= read -r resource; do
    echo -n "  Annotating $resource... "
    if kubectl annotate -n "$NAMESPACE" "$resource" \
        argocd.argoproj.io/tracking-id="${ARGOCD_APP_NAME}:${NAMESPACE}:${resource##*/}" \
        --overwrite 2>/dev/null; then
        echo "✓"
        ANNOTATED_COUNT=$((ANNOTATED_COUNT + 1))
    else
        echo "⚠ (failed)"
    fi
done <<< "$RESOURCES"
echo "Annotated $ANNOTATED_COUNT resources"

echo -e "\n${GREEN}Step 6: Removing Helm release tracking secrets...${NC}"
HELM_SECRETS=$(kubectl get secrets -n "$NAMESPACE" -l name="$RELEASE_NAME",owner=helm -o name 2>/dev/null || true)
if [[ -n "$HELM_SECRETS" ]]; then
    SECRET_COUNT=$(echo "$HELM_SECRETS" | wc -l)
    echo "Found $SECRET_COUNT Helm secret(s)"
    echo "$HELM_SECRETS" | while read -r secret; do
        echo -n "  Deleting $secret... "
        if kubectl delete -n "$NAMESPACE" "$secret" 2>/dev/null; then
            echo "✓"
        else
            echo "⚠ (already deleted)"
        fi
    done
else
    echo "  No Helm secrets found"
fi

echo -e "\n${GREEN}Step 7: Verifying Helm no longer tracks the release...${NC}"
if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^$RELEASE_NAME[[:space:]]"; then
    echo -e "${YELLOW}⚠ Warning: Helm still shows the release. This might be a timing issue.${NC}"
else
    echo "✓ Helm release successfully orphaned"
fi

if [[ "$ARGOCD_LOGGED_IN" == "true" ]]; then
    echo -e "\n${GREEN}Step 8: Configuring ArgoCD application for adoption...${NC}"
    if argocd app get "$ARGOCD_APP_NAME" --grpc-web &>/dev/null; then
        echo "Setting sync options for resource adoption..."
        if argocd app set "$ARGOCD_APP_NAME" \
            --sync-option ServerSideApply=true \
            --sync-option CreateNamespace=false \
            --sync-option ApplyOutOfSyncOnly=true \
            --grpc-web; then
            echo "✓ ArgoCD app configured for resource adoption"
        else
            echo -e "${YELLOW}⚠ Failed to set sync options. Set them manually.${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ ArgoCD app '$ARGOCD_APP_NAME' not found.${NC}"
        echo -e "${YELLOW}  Create it with the sync options above.${NC}"
    fi
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Migration Phase 1 Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "\n${BLUE}What just happened:${NC}"
echo -e "  • Removed Helm ownership from $CLEANED_COUNT resources"
echo -e "  • Updated labels on $LABELED_COUNT resources"
echo -e "  • Added ArgoCD tracking to $ANNOTATED_COUNT resources"
echo -e "  • ${GREEN}Resources are still running unchanged (zero downtime)${NC}"
echo -e "  • Resources are ready for ArgoCD adoption"

echo -e "\n${BLUE}Next steps (Phase 2 - ArgoCD Sync):${NC}"

if [[ "$ARGOCD_LOGGED_IN" != "true" ]]; then
    echo -e "${YELLOW}1.${NC} Login to ArgoCD:"
    echo -e "   ${GREEN}argocd login <your-argocd-server>${NC}"
    echo ""
fi

echo -e "${YELLOW}1.${NC} If you haven't already, create your ArgoCD app with:"
echo -e "   ${GREEN}argocd app create $ARGOCD_APP_NAME \\
     --repo <your-repo> \\
     --path <your-path> \\
     --dest-namespace $NAMESPACE \\
     --dest-server https://kubernetes.default.svc \\
     --sync-option ServerSideApply=true \\
     --sync-option ApplyOutOfSyncOnly=true \\
     --sync-option CreateNamespace=false \\
     --grpc-web${NC}"

echo -e "\n${YELLOW}2.${NC} Sync ArgoCD to adopt the orphaned resources:"
echo -e "   ${GREEN}argocd app sync $ARGOCD_APP_NAME --apply-out-of-sync-only --grpc-web${NC}"

echo -e "\n${YELLOW}3.${NC} If resources are still being recreated, try:"
echo -e "   ${GREEN}argocd app sync $ARGOCD_APP_NAME --force --server-side --grpc-web${NC}"

echo -e "\n${YELLOW}4.${NC} Verify the application is healthy:"
echo -e "   ${GREEN}argocd app get $ARGOCD_APP_NAME --grpc-web${NC}"
echo -e "   ${GREEN}kubectl get pods -n $NAMESPACE${NC}"

echo -e "\n${BLUE}Expected behavior during sync:${NC}"
echo -e "  • ${GREEN}Services/ConfigMaps/Secrets:${NC} Usually just adopt (no pod restart)"
echo -e "  • ${YELLOW}Deployments/StatefulSets:${NC} May recreate pods if manifests differ"
echo -e "  • ${GREEN}Rolling updates ensure zero downtime${NC} (new pods healthy first)"
echo -e "  • ${GREEN}StatefulSets update one pod at a time${NC} for extra safety"
echo -e "  • ${YELLOW}Watch progress:${NC} ${GREEN}kubectl get pods -n $NAMESPACE -w${NC}"

echo -e "\n${BLUE}Troubleshooting:${NC}"
echo -e "  • Check what's different: ${GREEN}argocd app diff $ARGOCD_APP_NAME --grpc-web${NC}"
echo -e "  • If labels don't match in Git, update your manifests to include:"
echo -e "    ${YELLOW}app.kubernetes.io/instance: $ARGOCD_APP_NAME${NC}"
echo -e "  • Rollback if needed: ${GREEN}helm rollback $RELEASE_NAME -n $NAMESPACE${NC}"
echo -e "  • Monitor rolling updates: ${GREEN}kubectl rollout status deployment/<name> -n $NAMESPACE${NC}"
