#!/usr/bin/env bash
# Registers the PS Resource Types and Resource Definitions in an Orchestrator
# through its public API. Terraform modules are inspected from Git first, so
# every Definition pins the exact commit and content digest the server computed.
# Nothing is deployed: inspecting and saving a Definition runs no provider.
#
# Required:
#   AWS_ACCOUNT     key of a READY AWS Driver Account (Platform -> Infrastructure Accounts)
#   EGRESS_CIDR     public IPv4 of the Orchestrator executor as a.b.c.d/32 (EKS API allowlist)
# Optional:
#   ORCH_URL        default http://localhost:8080
#   ORCH_USER       default platform-engineer
#   ORCH_PASSWORD   read from the terminal when unset
#   AWS_REGION      default us-east-1
#   MODULES_URL     default https://github.com/pr3s3nt/terraform-modules.git
#   MODULES_REF     tag or full commit, default v1.1.0
#   HOSTED_ZONE_ID, DOMAIN_NAME   Route 53 zone and host name of the public endpoint (HTTPS); empty = HTTP only
#   RENDER_BUNDLE   score-k8s render bundle, default the first one the server lists
#   TYPES_ONLY=1    register only the Resource Types
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
catalog="$here/catalog.json"
ORCH_URL=${ORCH_URL:-http://localhost:8080}
ORCH_USER=${ORCH_USER:-platform-engineer}
AWS_REGION=${AWS_REGION:-us-east-1}
MODULES_URL=${MODULES_URL:-https://github.com/pr3s3nt/terraform-modules.git}
MODULES_REF=${MODULES_REF:-v1.1.0}
HOSTED_ZONE_ID=${HOSTED_ZONE_ID:-}
DOMAIN_NAME=${DOMAIN_NAME:-}
TYPES_ONLY=${TYPES_ONLY:-0}

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done
if [ "$TYPES_ONLY" != 1 ]; then
  : "${AWS_ACCOUNT:?set AWS_ACCOUNT to a READY AWS Driver Account key}"
  : "${EGRESS_CIDR:?set EGRESS_CIDR to the executor public IPv4 as a.b.c.d/32}"
fi
if [ -z "${ORCH_PASSWORD:-}" ]; then
  read -r -s -p "Password for $ORCH_USER: " ORCH_PASSWORD
  echo
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jar="$work/cookies"

# api METHOD PATH [BODY_FILE] -> prints the body, returns 0 for 2xx; HTTP code in $work/code.
api() {
  local args=(-sS -b "$jar" -c "$jar" -o "$work/body" -w '%{http_code}' -X "$1" "$ORCH_URL$2")
  if [ $# -ge 3 ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$3")
  fi
  curl "${args[@]}" >"$work/code"
  cat "$work/body"
  [[ $(cat "$work/code") == 2* ]]
}

jq -n --arg u "$ORCH_USER" --arg p "$ORCH_PASSWORD" '{username: $u, password: $p}' >"$work/signin"
api POST /api/v1/auth/sign-in "$work/signin" >/dev/null || { echo "sign-in failed (HTTP $(cat "$work/code"))" >&2; exit 1; }

existing_types=$(api GET /api/v1/resource-types | jq -r '.resourceTypes[].key')
jq -c '.types[]' "$catalog" | while read -r typ; do
  key=$(jq -r .key <<<"$typ")
  if grep -qx "$key" <<<"$existing_types"; then
    echo "type $key: exists"
    continue
  fi
  printf '%s' "$typ" >"$work/type"
  if api POST /api/v1/resource-types "$work/type" >/dev/null; then
    echo "type $key: registered"
  else
    echo "type $key: FAILED (HTTP $(cat "$work/code")): $(cat "$work/body")" >&2
    exit 1
  fi
done
[ "$TYPES_ONLY" = 1 ] && exit 0

if [ -z "${RENDER_BUNDLE:-}" ]; then
  RENDER_BUNDLE=$(api GET /api/v1/render-bundles | jq -r '(.renderBundles // .bundles // .)[0] | (.id // .key // .)')
fi

existing_defs=$(api GET /api/v1/resource-definitions | jq -r '.resourceDefinitions[].key')
jq -c '.definitions[]' "$catalog" | while read -r def; do
  key=$(jq -r .key <<<"$def")
  if grep -qx "$key" <<<"$existing_defs"; then
    echo "definition $key: exists (edit it in the Console to change it)"
    continue
  fi
  # Placeholders of the catalog: account-independent literals only.
  def=$(jq -c --arg region "$AWS_REGION" --arg egress "$EGRESS_CIDR" --arg zone "$HOSTED_ZONE_ID" \
    --arg domain "$DOMAIN_NAME" --arg bundle "$RENDER_BUNDLE" '
    walk(if type == "string" then
      gsub("@REGION@"; $region) | gsub("@EGRESS_CIDR@"; $egress) | gsub("@HOSTED_ZONE_ID@"; $zone)
      | gsub("@DOMAIN_NAME@"; $domain) | gsub("@RENDER_BUNDLE@"; $bundle)
    else . end)' <<<"$def")
  driver=$(jq -r .driverType <<<"$def")
  if [ "$driver" = terraform ]; then
    jq -n --arg t "$(jq -r .resourceType <<<"$def")" --arg u "$MODULES_URL" --arg p "$(jq -r .module <<<"$def")" \
      --arg r "$MODULES_REF" '{resourceType: $t, url: $u, path: $p, ref: $r}' >"$work/inspect"
    if ! api POST /api/v1/terraform-modules/inspect "$work/inspect" >"$work/capability"; then
      echo "definition $key: module inspection FAILED (HTTP $(cat "$work/code")): $(cat "$work/body")" >&2
      exit 1
    fi
    jq --argjson d "$def" --arg account "$AWS_ACCOUNT" --arg region "$AWS_REGION" '
      .capability.source as $s
      | {
          key: $d.key, name: $d.name, resourceType: $d.resourceType, driverType: "terraform",
          driverInputs: {values: {
            source: {source_id: $s.sourceId, module_id: $s.moduleId, revision: $s.revision,
                     subdirectory: $s.subdirectory, content_sha256: $s.contentSha256},
            variables: ($d.variables + (if $d.aws then {region: $region} else {} end)),
            input_mapping: ([$d.inputs[] | {key: ., value: {param: .}}] | from_entries),
            output_mapping: $d.outputs,
            provider_bindings: (
              (if $d.aws then {aws: {target: "account"}} else {} end)
              + (if $d.kubernetes then {kubernetes: {target: "resource", resource_ref: "k8s-cluster.eks#environments.@app.@env"}} else {} end))
          }},
          criteria: $d.criteria
        }
      + (if $d.aws then {driverAccount: $account} else {} end)' "$work/capability" >"$work/def"
  else
    jq '{key, name, resourceType, driverType, driverInputs: {values: {variables: .variables}}, criteria}' <<<"$def" >"$work/def"
  fi
  if api POST /api/v1/resource-definitions "$work/def" >/dev/null; then
    echo "definition $key: registered"
  else
    echo "definition $key: FAILED (HTTP $(cat "$work/code")): $(cat "$work/body")" >&2
    exit 1
  fi
done
