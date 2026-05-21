#!/usr/bin/env bash
#
# install.sh — Apply all MCP Gateway sample manifests to the current cluster.
#
# Prerequisites:
#   1. Logged in to an OpenShift cluster (`oc whoami` returns your user).
#   2. MCP Gateway Operator v0.6.0 installed via OLM (Software Catalog ->
#      "MCP Gateway Operator", channel "preview"). The operator deploys the
#      mcp_controller to namespace openshift-operators.
#   3. Red Hat OpenShift Service Mesh / Gateway API enabled — the
#      'openshift-default' GatewayClass must exist on the cluster.
#
# Usage:
#   export MCP_HOSTNAME=mcp.apps.<your-cluster-domain>
#   ./install.sh
#
# Or pass the hostname inline:
#   MCP_HOSTNAME=mcp.apps.example.com ./install.sh
#
# To uninstall everything this script created, run ./uninstall.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"

# --- Pre-flight checks --------------------------------------------------------

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: 'oc' CLI not found in PATH." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: Not logged in to a cluster. Run 'oc login ...' first." >&2
  exit 1
fi

if [[ -z "${MCP_HOSTNAME:-}" ]]; then
  echo "ERROR: MCP_HOSTNAME environment variable is not set." >&2
  echo "       Example: export MCP_HOSTNAME=mcp.apps.\$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')" >&2
  exit 1
fi

echo "==> Using MCP_HOSTNAME=${MCP_HOSTNAME}"

# Sanity-check the MCP Gateway Operator is installed.
if ! oc get crd mcpgatewayextensions.mcp.kuadrant.io >/dev/null 2>&1; then
  echo "ERROR: CRD mcpgatewayextensions.mcp.kuadrant.io not found." >&2
  echo "       Install the MCP Gateway Operator (channel: preview) from OperatorHub first." >&2
  exit 1
fi

# Sanity-check the openshift-default GatewayClass.
if ! oc get gatewayclass openshift-default >/dev/null 2>&1; then
  echo "ERROR: GatewayClass 'openshift-default' not found." >&2
  echo "       Enable OpenShift Service Mesh / Gateway API on this cluster." >&2
  exit 1
fi

# --- Helper to substitute the hostname placeholder ---------------------------

apply_with_hostname() {
  local f="$1"
  echo "  -> ${f#"${MANIFESTS_DIR}"/}"
  sed "s|__MCP_HOSTNAME__|${MCP_HOSTNAME}|g" "$f" | oc apply -f -
}

apply_dir() {
  local dir="$1"
  echo "==> Applying ${dir#"${MANIFESTS_DIR}"/}"
  # Apply files in lexical order. Files that contain the placeholder will
  # have it substituted; the rest are passed through unchanged.
  for f in "$dir"/*.yaml; do
    [[ -e "$f" ]] || continue
    if grep -q "__MCP_HOSTNAME__" "$f"; then
      apply_with_hostname "$f"
    else
      echo "  -> ${f#"${MANIFESTS_DIR}"/}"
      oc apply -f "$f"
    fi
  done
}

# --- Apply manifests in order -------------------------------------------------

apply_dir "${MANIFESTS_DIR}/01-namespace"
apply_dir "${MANIFESTS_DIR}/02-gateway"
apply_dir "${MANIFESTS_DIR}/03-extension"

# Each MCP server subdirectory under 04-mcp-servers is its own bundle.
for server_dir in "${MANIFESTS_DIR}"/04-mcp-servers/*/; do
  apply_dir "${server_dir%/}"
done

apply_dir "${MANIFESTS_DIR}/05-route"

# --- Wait for readiness -------------------------------------------------------

echo
echo "==> Waiting for Gateway 'mcp-gateway' to be Programmed..."
oc wait --for=condition=Programmed gateway/mcp-gateway -n openshift-ingress --timeout=120s || true

echo
echo "==> Waiting for the openshift-mcp-server Deployment to roll out..."
oc rollout status deploy/openshift-mcp-server -n demo --timeout=120s || true

echo
echo "==> Waiting up to 90s for the MCPServerRegistration to become Ready..."
for i in {1..18}; do
  if oc get mcpserverregistration openshift-mcp -n demo \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    break
  fi
  sleep 5
done

# --- Summary ------------------------------------------------------------------

echo
echo "============================================================"
echo " Installation complete. Status summary:"
echo "============================================================"
oc get gateway mcp-gateway -n openshift-ingress -o wide 2>/dev/null || true
echo
oc get mcpgatewayextension mcp-extension -n demo 2>/dev/null || true
echo
oc get mcpserverregistration openshift-mcp -n demo 2>/dev/null || true
echo
oc get route mcp-gateway-edge -n openshift-ingress 2>/dev/null || true
echo
echo "If the MCPServerRegistration shows READY=True with a non-zero TOOLS count,"
echo "you're ready to validate. Run ./scripts/validate.sh to send a test request."
echo
