#!/usr/bin/env bash
# Renders every ci/*-values.yaml scenario and validates the manifests with kubeconform
# against Kubernetes (strict) schemas and pinned CRD schemas (Gateway API, ESO).
# Usage: validate-manifests.sh <chart-dir> <kubernetes-version, e.g. 1.33.12>
set -euo pipefail

chart_dir="${1:?usage: validate-manifests.sh <chart-dir> <k8s-version>}"
kube_version="${2:?usage: validate-manifests.sh <chart-dir> <k8s-version>}"

# Pinned schema sources (bump deliberately, Renovate does not track raw URLs).
k8s_schemas="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/a6f9a32d2ccb64b6e4f5b41419b9c2e8ee0cce18/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
crd_schemas="https://raw.githubusercontent.com/datreeio/CRDs-catalog/ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

for values in "$chart_dir"/ci/*-values.yaml; do
  echo "== $(basename "$values") (Kubernetes $kube_version)"
  helm template vending "$chart_dir" --namespace vending --kube-version "$kube_version" -f "$values" \
    | kubeconform -strict -summary \
        -kubernetes-version "$kube_version" \
        -schema-location "$k8s_schemas" \
        -schema-location "$crd_schemas"
done
