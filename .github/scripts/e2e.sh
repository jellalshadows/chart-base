#!/usr/bin/env bash
# Real install of every ci/ scenario on the current kube context (a kind cluster in CI):
# namespace enforcing Pod Security "restricted", Gateway API CRDs, External Secrets Operator
# with the fake provider. Usage: e2e.sh <chart-dir>
# Env: GATEWAY_API_VERSION (e.g. v1.6.2), ESO_CHART_VERSION (e.g. 2.11.0)
set -euo pipefail

chart_dir="${1:?usage: e2e.sh <chart-dir>}"
: "${GATEWAY_API_VERSION:?}" "${ESO_CHART_VERSION:?}"
ns=vending

fail() { echo "FAIL: $*" >&2; kubectl get all,externalsecrets -n "$ns" >&2 || true; exit 1; }
pass() { echo "ok - $*"; }

echo "== platform prerequisites"
kubectl apply --server-side \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
helm install external-secrets external-secrets --repo https://charts.external-secrets.io \
  --version "$ESO_CHART_VERSION" --namespace external-secrets --create-namespace --wait --timeout 5m
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: fake
spec:
  provider:
    fake:
      data:
        - key: /sales/db-password
          value: s3cr3t
EOF
kubectl wait clustersecretstore/fake --for=condition=Ready --timeout=120s

kubectl create namespace "$ns"
kubectl label namespace "$ns" \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
# An existing Secret that components reference by name (like the ones CNPG or Strimzi create).
kubectl create secret generic e2e-shared -n "$ns" --from-literal=TOKEN=abc

install() { helm upgrade --install "$1" "$chart_dir" -n "$ns" -f "$chart_dir/ci/$1-values.yaml" --wait --timeout 5m "${@:2}"; }

echo "== deployment"
install deployment || fail "deployment scenario did not become ready under PSS restricted"
pass "API Deployment is Ready in a restricted namespace"
rs_before="$(kubectl get rs -n "$ns" -l app.kubernetes.io/instance=deployment -o name | wc -l)"
install deployment --set config.APP_MODE=api-v2 || fail "config change upgrade failed"
rs_after="$(kubectl get rs -n "$ns" -l app.kubernetes.io/instance=deployment -o name | wc -l)"
[ "$rs_after" -gt "$rs_before" ] || fail "a config change must roll the pods (checksum annotation)"
pass "a config change rolls the Deployment"

echo "== worker"
install worker || fail "worker scenario did not become ready"
kubectl get service -n "$ns" worker-chart-base > /dev/null 2>&1 && fail "worker must not have a Service"
pass "worker runs without a Service"

echo "== cronjob"
install cronjob || fail "cronjob scenario failed"
kubectl create job -n "$ns" --from=cronjob/cronjob-chart-base cronjob-manual-run
kubectl wait -n "$ns" job/cronjob-manual-run --for=condition=Complete --timeout=180s \
  || fail "a CronJob run must complete (restricted pod, config, env references, envFrom with prefix)"
pass "a CronJob run sees config, env references (fieldRef, resourceFieldRef) and envFrom with prefix"

echo "== job (pre-deploy hook)"
install job || fail "job hook failed: it must see APP_MODE, DB_PASSWORD (ESO) and /config/migrations.yaml"
kubectl logs -n "$ns" job/job-chart-base | grep -q migrations-ok || fail "job output missing"
pass "pre-deploy Job ran with its hook ConfigMaps and ExternalSecret"
install job --set-string podAnnotations.revision=2 || fail "second deploy of a job must not hit 'field is immutable'"
pass "the Job hook is recreated on the next deploy"

echo "== full"
install full || fail "full scenario failed"
kubectl wait -n "$ns" externalsecret/full-chart-base-secrets --for=condition=Ready --timeout=120s \
  || fail "ExternalSecret did not sync"
[ "$(kubectl get secret -n "$ns" full-chart-base-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)" = s3cr3t ] \
  || fail "Secret content mismatch"
kubectl get httproute -n "$ns" full-chart-base > /dev/null || fail "HTTPRoute not accepted by the API"
reload="$(kubectl get deployment -n "$ns" full-chart-base -o jsonpath='{.metadata.annotations.secret\.reloader\.stakater\.com/reload}')"
[ "$reload" = "e2e-shared,full-chart-base-secrets" ] || fail "Reloader annotation must list the referenced Secrets, got '$reload'"
kubectl get hpa,pdb,ingress -n "$ns" -l app.kubernetes.io/instance=full
pass "full scenario: ExternalSecret synced, HTTPRoute/HPA/PDB/Ingress accepted"

echo "e2e: all checks passed"
