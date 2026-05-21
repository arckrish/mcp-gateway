#!/usr/bin/env bash
#
# uninstall.sh — Remove everything install.sh created.
#
# This does NOT uninstall the MCP Gateway Operator itself. Remove that via
# OperatorHub if you no longer need it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"

if [[ -z "${MCP_HOSTNAME:-}" ]]; then
  echo "WARN: MCP_HOSTNAME not set. Using placeholder for deletion — this is fine"
  echo "      because 'oc delete' matches by object name/namespace, not hostname."
  MCP_HOSTNAME="__MCP_HOSTNAME__"
fi

delete_dir() {
  local dir="$1"
  echo "==> Deleting ${dir#"${MANIFESTS_DIR}"/}"
  # Delete in reverse lexical order so dependents come down before dependencies.
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(ls -1r "$dir"/*.yaml 2>/dev/null || true)
  for f in "${files[@]}"; do
    echo "  -> ${f#"${MANIFESTS_DIR}"/}"
    sed "s|__MCP_HOSTNAME__|${MCP_HOSTNAME}|g" "$f" | oc delete --ignore-not-found=true -f - || true
  done
}

delete_dir "${MANIFESTS_DIR}/05-route"

for server_dir in "${MANIFESTS_DIR}"/04-mcp-servers/*/; do
  delete_dir "${server_dir%/}"
done

delete_dir "${MANIFESTS_DIR}/03-extension"
delete_dir "${MANIFESTS_DIR}/02-gateway"

# Don't delete the namespace by default — users may have other workloads there.
echo
echo "==> Skipping namespace deletion (demo). Delete it manually if desired:"
echo "      oc delete namespace demo"
echo
echo "Uninstall complete."
