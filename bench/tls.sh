#!/bin/bash
# Creates the certificates of the provisionning API for the bench: a CA, a
# server certificate for the xolo-provisionning Service and a client
# certificate carrying the URI urn:xolo:client:bench, which values-release.yaml
# authorizes. Stores them in the Secrets the chart and validate.sh read:
#
#   xolo-provisionning-tls     tls.crt, tls.key and ca.crt, for Xolo
#   xolo-provisionning-client  tls.crt and tls.key, for validate.sh
#
#   ./tls.sh
set -euo pipefail
NS=bench
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

key() { openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$1" -keyout "$2.key" -out "$2.csr" 2>/dev/null; }
sign() { openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -out "$1.crt" -extfile <(printf '%b' "$2") 2>/dev/null; }

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj /CN=bench-ca -keyout ca.key -out ca.crt 2>/dev/null
key xolo-provisionning srv
sign srv "subjectAltName=DNS:xolo-provisionning,DNS:xolo-provisionning.$NS\nextendedKeyUsage=serverAuth"
key bench-client cli
sign cli "subjectAltName=URI:urn:xolo:client:bench\nextendedKeyUsage=clientAuth"

kubectl -n $NS create secret generic xolo-provisionning-tls \
  --from-file=tls.crt=srv.crt --from-file=tls.key=srv.key --from-file=ca.crt=ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $NS create secret tls xolo-provisionning-client --cert=cli.crt --key=cli.key \
  --dry-run=client -o yaml | kubectl apply -f -
