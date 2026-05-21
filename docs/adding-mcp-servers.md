# Adding another MCP server

The MCP Gateway is designed for federation: a single endpoint that fronts
multiple upstream MCP servers, with tool prefixes preventing name collisions.

Once the gateway is up (Gateway, MCPGatewayExtension, ReferenceGrant, Route
in place), adding a new upstream is a four-object operation:

| Object | What it does |
| --- | --- |
| `Deployment` (and optional `ServiceAccount`/`RBAC`) | Runs the upstream MCP server. |
| `Service` | ClusterIP that exposes the server to the cluster. |
| `HTTPRoute` | Discovery target for the registration. Routes a distinct path to the Service. Must NOT conflict with `/mcp` (the auto-created broker route). |
| `MCPServerRegistration` | Tells the broker about the upstream, where it serves, and what prefix to apply to its tools. |

## Step-by-step

### 1. Pick an MCP server image

The image must support HTTP-streaming mode (not stdio). For example:

* `quay.io/containers/kubernetes_mcp_server` — Kubernetes management
* `ghcr.io/structured-world/gitlab-mcp` — GitLab API
* Any other MCP server with HTTP transport

If the upstream you want is stdio-only, you need to either wrap it in a
stdio-to-HTTP shim or run a different implementation.

### 2. Create the manifests

Copy `manifests/04-mcp-servers/openshift-mcp/` to a new sibling directory
and adjust the values:

```bash
cp -r manifests/04-mcp-servers/openshift-mcp \
      manifests/04-mcp-servers/<your-server-name>
```

Update each file:

* **`01-deployment.yaml`** — change the Deployment/Service `name`, the
  container `image`, args/env, and ports as needed. Update the
  `ServiceAccount` and `ClusterRoleBinding` if your server needs different
  RBAC (some servers need only `Secret` access; some need none).

* **`02-httproute.yaml`** — change the HTTPRoute `name`, change the path
  prefix to something unique like `/backends/<your-server-name>`, and point
  the `backendRefs.name` at your new Service.

* **`03-mcpserverregistration.yaml`** — change the registration `name`, set
  `toolPrefix` to a unique prefix (ending in `_` by convention, e.g.
  `gitlab_`), set `spec.path` to whatever path your upstream serves MCP on
  (commonly `/mcp` or `/`), and point `targetRef.name` at your new HTTPRoute.

### 3. Apply

`install.sh` discovers all server subdirectories under `04-mcp-servers/`
automatically, so a re-run picks up your additions:

```bash
MCP_HOSTNAME=mcp.apps.<cluster-domain> ./scripts/install.sh
```

Or apply just the new directory:

```bash
oc apply -f manifests/04-mcp-servers/<your-server-name>/
```

### 4. Verify

```bash
oc get mcpserverregistration -n demo
```

You should see your new registration with `READY=True` and a non-zero
`TOOLS` count.

Then run `./scripts/validate.sh` and check `tools/list` — you should see
tools from both upstreams, each with its respective prefix
(`openshift-mcp_pods_list`, `<yourprefix>_<toolname>`, etc.).

## Cheat sheet

What changes per server:

| Field | Existing (openshift-mcp) | New (example: gitlab) |
| --- | --- | --- |
| Deployment/Service/HTTPRoute/Registration name | `openshift-mcp-server` / `openshift-mcp` | `gitlab-mcp-server` / `gitlab-mcp` |
| Image | `quay.io/containers/kubernetes_mcp_server:latest` | (your image) |
| HTTPRoute path prefix | `/backends/openshift-mcp` | `/backends/gitlab-mcp` |
| Registration `path` | `/mcp` | (check your server's docs) |
| Registration `toolPrefix` | `openshift-mcp_` | `gitlab_` |
| ServiceAccount RBAC | cluster `view` role | typically none (servers usually use external API tokens) |
| Secrets for credentials | n/a (uses in-cluster SA token) | typically a `Secret` with API token referenced via `env.valueFrom.secretKeyRef` |

## Common gotchas

1. **stdio-only images won't work.** Many community MCP servers default to
   stdio transport designed for Claude Desktop. Confirm the image has an
   HTTP/SSE mode before deploying.
2. **Path collisions.** Two HTTPRoutes on the same gateway listener with
   overlapping path prefixes can produce ambiguous routing. Use distinct
   `/backends/<name>` paths and you're fine.
3. **Wrong `spec.path` on the registration.** This is the path on the
   upstream MCP server, not the gateway path. If you set it wrong, the
   broker dials a URL that 404s and you get
   `failed to initialize client for upstream`.
4. **External authentication.** If your upstream needs an API token
   (GitHub, GitLab, Sentry, etc.), put it in a Secret in `demo` and mount
   it as env vars in the Deployment. Don't bake tokens into images.
