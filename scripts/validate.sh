#!/usr/bin/env bash
#
# validate.sh — Send an initialize, then list and call a tool through the
# MCP Gateway to confirm end-to-end routing works.
#
# Usage:
#   export MCP_HOSTNAME=mcp.apps.<your-cluster-domain>
#   ./validate.sh

set -euo pipefail

if [[ -z "${MCP_HOSTNAME:-}" ]]; then
  echo "ERROR: MCP_HOSTNAME environment variable is not set." >&2
  echo "       Example: export MCP_HOSTNAME=mcp.apps.example.com" >&2
  exit 1
fi

URL="https://${MCP_HOSTNAME}/mcp"

echo "==> Initializing MCP session against ${URL}"
INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-gateway-sample","version":"1.0"}}}'

# Capture both headers and body; pull the session ID from the headers.
HEADERS=$(mktemp)
trap 'rm -f "$HEADERS"' EXIT

BODY=$(curl -sk -D "$HEADERS" -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d "$INIT_BODY")

SESSION_ID=$(grep -i 'mcp-session-id:' "$HEADERS" | awk '{print $2}' | tr -d '\r\n' || true)

if [[ -z "$SESSION_ID" ]]; then
  echo "ERROR: No Mcp-Session-Id header in response. Initialize may have failed." >&2
  echo "Response body:" >&2
  echo "$BODY" >&2
  exit 1
fi

echo "    Session: $SESSION_ID"
echo "    Init response: $BODY"
echo

echo "==> Sending initialized notification"
curl -sk -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

echo
echo "==> Listing tools (filtered by openshift-mcp_ prefix)"
TOOLS=$(curl -sk -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')

# Pretty-print the tools list with python if available; otherwise dump raw.
if command -v python3 >/dev/null 2>&1; then
  echo "$TOOLS" | python3 -c '
import json, sys
data = json.load(sys.stdin)
tools = data.get("result", {}).get("tools", [])
print(f"  Discovered {len(tools)} tool(s):")
for t in tools:
    print(f"    - {t.get(\"name\")}")
' || echo "$TOOLS"
else
  echo "$TOOLS"
fi

echo
echo "==> Sample tool call: openshift-mcp_namespaces_list"
curl -sk -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"openshift-mcp_namespaces_list","arguments":{}}}' \
  | head -c 2000
echo
echo
echo "Done."
