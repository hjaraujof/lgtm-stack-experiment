#!/usr/bin/env bash
# Create the two local Secrets the chart expects, with GENERATED values.
#
# WHY THIS IS A SCRIPT AND NOT A HELM TEMPLATE. A Secret rendered by Helm is a Secret whose
# value lives in a values file, in `helm get values`, and in whatever CI log printed the
# command. Keeping it out of the chart means the chart can be published, diffed and reviewed
# with no credential in it.
#
# WHY THE VALUES ARE GENERATED AND NOT WRITTEN DOWN. A default password shipped in a
# repository is a real password on the day somebody copies the repository to a real cluster.
# Nothing here is ever committed; read it back with kubectl if you need it.
#
# THIS IS TIER 2 OF THE LADDER IN values.yaml, AND THAT IS CORRECT HERE - a throwaway local
# cluster. It is NOT correct on EKS. values-eks.yaml uses the Secrets Store CSI driver with
# the pod's own AWS identity, so no Secret object exists there and this script is not run.
#
# Usage:
#   k8s/scripts/create-secrets.sh [namespace]
set -euo pipefail

NAMESPACE="${1:-lgtm}"

gen() {
    # 32 URL-safe characters. `tr -d` first, because base64 emits + / = which break a URL
    # and, in the Compose plane, `$` in a .env file triggers interpolation.
    head -c 48 /dev/urandom | base64 | tr -d '+/=' | cut -c1-32
}

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || kubectl create namespace "$NAMESPACE"

# --- MinIO root credentials -------------------------------------------------------------
# Tempo and Mimir receive the SAME pair as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY. That
# is a local shortcut and not a pattern to copy: on AWS each backend has an identity, not a
# key, and root credentials are never handed to a client.
if kubectl -n "$NAMESPACE" get secret minio-credentials >/dev/null 2>&1; then
    echo "minio-credentials already exists; leaving it alone"
else
    MINIO_USER="lgtm$(gen | cut -c1-8)"
    MINIO_PASS="$(gen)"
    kubectl -n "$NAMESPACE" create secret generic minio-credentials \
        --from-literal=rootUser="$MINIO_USER" \
        --from-literal=rootPassword="$MINIO_PASS"
    kubectl -n "$NAMESPACE" create secret generic lgtm-s3-credentials \
        --from-literal=accessKeyId="$MINIO_USER" \
        --from-literal=secretAccessKey="$MINIO_PASS"
    echo "created minio-credentials and lgtm-s3-credentials"
fi

# --- Grafana credentials ----------------------------------------------------------------
# The KEY NAMES ARE THE FILE NAMES. A Secret volume writes one file per key, and Grafana
# reads /etc/grafana/secrets/admin-password through GF_SECURITY_ADMIN_PASSWORD__FILE. The
# CSI driver on EKS produces files with the same names, which is what makes the two planes
# interchangeable.
if kubectl -n "$NAMESPACE" get secret grafana-admin >/dev/null 2>&1; then
    echo "grafana-admin already exists; leaving it alone"
else
    GRAFANA_PASS="$(gen)"
    kubectl -n "$NAMESPACE" create secret generic grafana-admin \
        --from-literal=admin-password="$GRAFANA_PASS" \
        --from-literal=default-admin-password="$(gen)" \
        --from-literal=default-member-password="$(gen)" \
        --from-literal=oauth-client-secret=""
    echo "created grafana-admin"
    echo
    echo "Grafana admin password:"
    echo "  $GRAFANA_PASS"
    echo
    echo "Read it again later with:"
    echo "  kubectl -n $NAMESPACE get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
fi
