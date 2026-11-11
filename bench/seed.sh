#!/bin/bash
# Fills the benchmark database: Xolo's deterministic fixture (cmd/seed), then
# the chaos provider, its models, pipelines and the metrics token from
# ../xolo-chaos. Needs kubectl on the kind cluster and Go.
set -euo pipefail
cd "$(dirname "$0")"
XOLO_DIR=${XOLO_DIR:-../../xolo}
CHAOS_DIR=${CHAOS_DIR:-../../xolo-chaos}
PORT=${PG_LOCAL_PORT:-55433}
NS=bench

kubectl -n $NS port-forward svc/postgres $PORT:5432 >/dev/null &
PF=$!
trap 'kill $PF' EXIT
sleep 2

(cd "$XOLO_DIR" && go run ./cmd/seed -dsn "postgres://xolo:xolo@localhost:$PORT/xolo?sslmode=disable" -force -days "${SEED_DAYS:-30}")

psql() { kubectl -n $NS exec -i postgres-0 -- psql -q -v ON_ERROR_STOP=1 -U xolo -d xolo "$@"; }
id() { psql -Atc "$1"; }

# The chaos scripts still name the fixture's pre-UUID identifiers: resolve
# the current ones by slug and email instead of editing them.
ORG=$(id "select id from organizations where slug='acme'")
subst=(-e "s|'org-acme'|'$ORG'|g")
for u in root alice carol dave; do
  domain=acme.test; [ $u = root ] && domain=xolo.test
  subst+=(-e "s|'usr-$u'|'$(id "select id from users where email='$u@$domain'")'|g")
done

sed "${subst[@]}" \
    -e "s|@@PROVIDER_URL@@|http://chaos-provider.$NS:9090/v1|" \
    -e 's|@@RATE_LIMIT@@|{"enabled":false}|' \
    -e 's|@@RETRY@@|{"enabled":false}|' "$CHAOS_DIR/deploy/prepare-db.sql" | psql
sed "${subst[@]}" "$CHAOS_DIR/deploy/pipelines.sql" | psql
psql < sql/globex.sql
# The chaos providers under a production-shaped subscription plan, so the
# plan checks are part of every measure (PLAN=0 leaves them pay-as-you-go).
# Run it again after a campaign to re-spread the records it added.
[ "${PLAN:-1}" = 0 ] || psql < sql/plan.sql
echo "seeded (org acme = $ORG)"
