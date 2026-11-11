#!/bin/bash
# Functional validation of a deployed release: probes, completions (streamed
# and not), plugin pipelines, provisionning API over mTLS, the replicas' logs
# and restarts. Needs the release deployed with values-bench.yaml and
# values-release.yaml.
#
#   ./validate.sh
set -uo pipefail
cd "$(dirname "$0")"
NS=bench
TOKEN=xolo-e2e-alice-acme
failures=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }

kubectl -n $NS delete pod validate --ignore-not-found --wait=true >/dev/null
kubectl -n $NS run validate --restart=Never --image=curlimages/curl:8.11.1 --overrides='{
  "spec": {"volumes": [{"name": "c", "secret": {"secretName": "xolo-provisionning-client"}}],
    "containers": [{"name": "validate", "image": "curlimages/curl:8.11.1", "command": ["sleep", "3600"],
      "volumeMounts": [{"name": "c", "mountPath": "/c"}]}]}}' >/dev/null
kubectl -n $NS wait pod/validate --for=condition=Ready --timeout=60s >/dev/null
trap 'kubectl -n $NS delete pod validate --wait=false >/dev/null 2>&1' EXIT
run() { kubectl -n $NS exec validate -- sh -c "$1"; }

mapfile -t PODS < <(kubectl -n $NS get pods -l app.kubernetes.io/name=xolo --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}')
echo "release image $(kubectl -n $NS get deploy xolo -o jsonpath='{.spec.template.spec.containers[0].image}'), replicas ${PODS[*]}"

echo "probes"
for ip in "${PODS[@]}"; do
  for path in /healthz /readyz; do
    code=$(run "curl -s -o /dev/null -w '%{http_code}' http://$ip:3002$path")
    [ "$code" = 200 ] && pass "$ip$path" || fail "$ip$path answered $code"
  done
done
code=$(run "curl -s -o /dev/null -w '%{http_code}' -X POST http://${PODS[0]}:3002/readyz")
[ "$code" = 405 ] && pass "POST /readyz refused" || fail "POST /readyz answered $code"

chat() { # model stream
  run "curl -s -N http://xolo:3002/api/v1/chat/completions -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
    -d '{\"model\":\"acme/$1\",\"stream\":$2,\"messages\":[{\"role\":\"user\",\"content\":\"Bonjour, je suis Claire Beaumont de Villeurbanne.\"}]}'"
}
echo "completions"
out=$(chat chaos-fast true); grep -q '\[DONE\]' <<<"$out" && pass "streamed completion" || fail "streamed completion: ${out:0:200}"
out=$(chat chaos-fast false); grep -q '"choices"' <<<"$out" && pass "non-streamed completion" || fail "non-streamed completion: ${out:0:200}"
for model in chaos-guard chaos-pseudo chaos-smart; do
  out=$(chat $model true); grep -q '\[DONE\]' <<<"$out" && pass "pipeline $model" || fail "pipeline $model: ${out:0:200}"
done
code=$(run "curl -s -o /dev/null -w '%{http_code}' http://xolo:3002/api/v1/models -H 'Authorization: Bearer invalid'")
[ "$code" = 401 ] && pass "unknown token refused" || fail "unknown token answered $code"

echo "provisionning API (mTLS)"
TENANT=$(kubectl -n $NS exec postgres-0 -- psql -qAt -U xolo -d xolo -c "select tenant_id from users where email='carol@acme.test'")
code=$(run "curl -sk --cert /c/tls.crt --key /c/tls.key -o /dev/null -w '%{http_code}' https://xolo-provisionning:3003/v1/xolo/tenants/$TENANT/users?limit=1")
[ "$code" = 200 ] && pass "authorized client" || fail "authorized client answered $code"
code=$(run "curl -sk -o /dev/null -w '%{http_code}' https://xolo-provisionning:3003/v1/xolo/tenants/$TENANT/users?limit=1")
case "$code" in 000|403) pass "client without certificate refused ($code)";; *) fail "client without certificate answered $code";; esac

echo "logs"
errors=$(kubectl -n $NS logs -l app.kubernetes.io/name=xolo --since=10m --tail=-1 2>/dev/null | grep -c 'level=ERROR')
[ "$errors" = 0 ] && pass "no ERROR in the replicas' logs" || fail "$errors ERROR lines in the replicas' logs"

echo "restarts"
restarts=$(kubectl -n $NS get pods -l app.kubernetes.io/name=xolo -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}')
[ -z "$(tr -d ' 0' <<<"$restarts")" ] && pass "no restart" || fail "restarts: $restarts"

echo
[ $failures = 0 ] && echo "all checks passed" || { echo "$failures check(s) failed"; exit 1; }
