#!/bin/bash
# One open-loop k6 step against the Xolo Service, run from inside the cluster
# on the infra node, with the CPU used by every Xolo replica and by PostgreSQL
# read from their cgroups (cpu.stat), throttling included.
#
#   ./k6.sh <name> <model> <rate> <duration> [prompt_set] [stream]
#
# Writes results/<name>.json (k6 summary) and results/<name>.meta.json.
set -euo pipefail
cd "$(dirname "$0")"
NAME=$1 MODEL=$2 RATE=$3 DURATION=$4 SET=${5:-plain} STREAM=${6:-true}
NS=bench
CHAOS_DIR=${CHAOS_DIR:-../../xolo-chaos}
TOKEN=${XOLO_TOKEN:-xolo-e2e-alice-acme}

SCRIPT=${SCRIPT:-profile.js}
kubectl -n $NS create configmap k6-scripts --from-file="$CHAOS_DIR/k6/profile.js" --from-file=k6/multi.js \
  --from-file=xolo.js="$CHAOS_DIR/k6/lib/xolo.js" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

pods() { kubectl -n $NS get pods -l app.kubernetes.io/name=xolo --field-selector=status.phase=Running -o name; }
# usage and throttled microseconds summed over the given pods.
cpu() {
  local u=0 th=0 line
  for p in "$@"; do
    # A pod replaced during the step (rollout, loss) is gone: it counts zero,
    # and the CPU of such a step is not meaningful.
    line=$(kubectl -n $NS exec "$p" -c "${CONTAINER:-xolo}" -- cat /sys/fs/cgroup/cpu.stat 2>/dev/null | awk '/^usage_usec/{u=$2}/^throttled_usec/{t=$2}END{print u+0, t+0}')
    [ -n "$line" ] || line="0 0"
    u=$((u + ${line% *})); th=$((th + ${line#* }))
  done
  echo "$u $th"
}
mem_max() {
  local m=0 v
  for p in $(pods); do
    v=$(kubectl -n $NS exec "$p" -c xolo -- cat /sys/fs/cgroup/memory.peak 2>/dev/null || true)
    v=${v:-0}
    [ "$v" -gt "$m" ] && m=$v
  done
  echo $m
}

PODS=$(pods)
REPLICAS=$(echo "$PODS" | wc -l)
read -r x0 t0 <<<"$(cpu $PODS)"
read -r d0 _ <<<"$(CONTAINER=postgres cpu pod/postgres-0)"
s0=$(date +%s.%N)

kubectl -n $NS delete pod k6 --ignore-not-found --wait=true >/dev/null
kubectl -n $NS run k6 --restart=Never --image=grafana/k6:1.1.0 --overrides='{
  "spec": {
    "nodeSelector": {"bench/role": "infra"},
    "volumes": [{"name": "s", "configMap": {"name": "k6-scripts", "items": [
      {"key": "profile.js", "path": "profile.js"}, {"key": "multi.js", "path": "multi.js"},
      {"key": "xolo.js", "path": "lib/xolo.js"}]}}],
    "containers": [{"name": "k6", "image": "grafana/k6:1.1.0",
      "args": ["run", "--quiet", "--summary-trend-stats", "avg,med,p(95),p(99),max",
               "--summary-export", "/tmp/summary.json", "/s/'"$SCRIPT"'"],
      "env": [{"name": "XOLO_URL", "value": "http://xolo:3002"},
              {"name": "XOLO_TOKEN", "value": "'"$TOKEN"'"},
              {"name": "MODEL", "value": "'"$MODEL"'"}, {"name": "RATE", "value": "'"$RATE"'"},
              {"name": "DURATION", "value": "'"$DURATION"'"}, {"name": "PROMPT_SET", "value": "'"$SET"'"},
              {"name": "STREAM", "value": "'"$STREAM"'"},
              {"name": "TARGETS", "value": "'"${TARGETS:-}"'"}],
      "command": ["sh", "-c", "k6 \"$@\" >/dev/null 2>&1; cat /tmp/summary.json", "--"],
      "resources": {"requests": {"cpu": "2"}},
      "volumeMounts": [{"name": "s", "mountPath": "/s"}]}]}}' >/dev/null

kubectl -n $NS wait pod/k6 --for=jsonpath='{.status.phase}'=Succeeded --timeout=15m >/dev/null
s1=$(date +%s.%N)
read -r x1 t1 <<<"$(cpu $PODS)"
read -r d1 _ <<<"$(CONTAINER=postgres cpu pod/postgres-0)"
kubectl -n $NS logs k6 > "results/$NAME.json"
kubectl -n $NS delete pod k6 --wait=false >/dev/null

python3 - "$NAME" "$MODEL" "$RATE" "$REPLICAS" "$x0" "$x1" "$t0" "$t1" "$d0" "$d1" "$s0" "$s1" "$(mem_max)" <<'PY'
import json, sys
name, model, rate, replicas, x0, x1, t0, t1, d0, d1, s0, s1, mem = sys.argv[1:]
summ = json.load(open(f"results/{name}.json"))
m = summ["metrics"]
reqs = m["http_reqs"]["count"]
wall = float(s1) - float(s0)
it = m.get("iterations", {}).get("rate", 0)
ok = m.get("checks", {})
meta = dict(
    name=name, model=model, target_rate=int(rate), replicas=int(replicas),
    achieved_rate=round(it, 1),
    dropped=m.get("dropped_iterations", {}).get("count", 0),
    ttft_med_ms=round(m["llm_ttft"]["med"], 1), ttft_p95_ms=round(m["llm_ttft"]["p(95)"], 1),
    dur_p95_ms=round(m["llm_duration"]["p(95)"], 1),
    errors=round(1 - ok.get("passes", 0) / max(1, ok.get("passes", 0) + ok.get("fails", 0)), 4),
    xolo_vcpu=round((int(x1) - int(x0)) / 1e6 / wall, 3),
    xolo_cpu_ms_per_req=round((int(x1) - int(x0)) / 1e3 / max(1, reqs), 2),
    throttled_s=round((int(t1) - int(t0)) / 1e6, 1),
    db_vcpu=round((int(d1) - int(d0)) / 1e6 / wall, 3),
    db_cpu_ms_per_req=round((int(d1) - int(d0)) / 1e3 / max(1, reqs), 2),
    mem_peak_mb=int(mem) // 1048576,
)
json.dump(meta, open(f"results/{name}.meta.json", "w"), indent=1)
print(" ".join(f"{k}={v}" for k, v in meta.items()))
PY
