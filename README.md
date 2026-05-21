# MCP Gateway on OpenShift — Sample Deployment

A reference deployment of the [Red Hat MCP Gateway](https://github.com/Kuadrant/mcp-gateway)
(part of Red Hat Connectivity Link 1.3 Tech Preview) on OpenShift, with a
working upstream MCP server registered behind it.

This sample exists because the documented happy-path install has several
OpenShift-specific rough edges in the v0.6.0 Tech Preview. Every workaround
needed for a fully working setup is captured here, with comments in each
manifest explaining why.

## What you get

* A `Gateway` listening on `mcp.apps.<your-cluster-domain>` with HTTP, MCPS,
  and HTTPS listeners.
* The `MCPGatewayExtension` and broker deployed in the `demo` namespace.
* The [`kubernetes-mcp-server`](https://github.com/containers/kubernetes-mcp-server)
  (openshift-mcp-server) registered as an upstream, exposing core, config,
  and helm toolsets.
* An edge-terminated OpenShift `Route` providing external HTTPS using the
  cluster's default ingress certificate.
* An `install.sh` script that applies everything in order and waits for
  readiness, and a `validate.sh` that initializes an MCP session and lists
  available tools.

## Prerequisites

1. **OpenShift cluster** with `oc` access.
2. **MCP Gateway Operator v0.6.0** installed via OperatorHub:
   * Software Catalog → "MCP Gateway Operator" → channel `preview`
   * Operator runs in `openshift-operators`. Confirm the
     `mcp-gateway-controller` pod is `Running`.
3. **Red Hat OpenShift Service Mesh / Gateway API** enabled. The
   `openshift-default` `GatewayClass` must exist:
   ```bash
   oc get gatewayclass openshift-default
   ```
4. **DNS for your gateway hostname**. The hostname you choose must resolve
   to your cluster's ingress endpoint. The simplest option is to use a name
   under your cluster's wildcard domain (e.g. `mcp.apps.<cluster-domain>`),
   which already resolves correctly because OpenShift creates a wildcard
   DNS record for `*.apps.<cluster-domain>` at install time.

## Quick start

```bash
# Find your cluster's apps domain (auto-detected from the cluster).
export MCP_HOSTNAME="mcp.apps.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' | sed 's/^apps\.//')"

# Install everything.
./scripts/install.sh

# Run the end-to-end validation.
./scripts/validate.sh
```

`validate.sh` performs an `initialize` handshake, the `initialized`
notification, lists tools, and invokes one tool. On success you'll see the
list of `openshift-mcp_*` tools and a namespaces-list response.

To remove everything (except the operator itself):

```bash
./scripts/uninstall.sh
```

## Repository layout

```
.
├── README.md
├── docs/
│   ├── architecture.md          # call flow + why each component exists
│   └── adding-mcp-servers.md    # how to register additional upstream servers
├── manifests/
│   ├── 01-namespace/
│   │   └── namespace.yaml
│   ├── 02-gateway/
│   │   ├── 01-gateway-configmap.yaml
│   │   └── 02-gateway.yaml
│   ├── 03-extension/
│   │   ├── 01-referencegrant.yaml
│   │   ├── 02-mcpgatewayextension.yaml
│   │   └── 03-broker-service-alias.yaml
│   ├── 04-mcp-servers/
│   │   └── openshift-mcp/
│   │       ├── 01-deployment.yaml
│   │       ├── 02-httproute.yaml
│   │       └── 03-mcpserverregistration.yaml
│   └── 05-route/
│       └── 01-edge-route.yaml
└── scripts/
    ├── install.sh
    ├── uninstall.sh
    └── validate.sh
```

Manifests are organized by lifecycle order. `install.sh` walks subdirectories
in lexical order and applies their contents.

## Architecture at a glance

```
Client
  │ HTTPS to mcp.apps.<cluster-domain>/mcp
  ▼
OpenShift Router (edge TLS termination)
  │ HTTP to mcp-gateway-openshift-default:80
  ▼
Istio Gateway pod (http listener, ext_proc filter)
  │ HTTPRoute /mcp → broker Service
  ▼
MCP Broker (demo/mcp-gateway)
  │ Strips tool prefix, looks up upstream
  ▼
openshift-mcp-server (demo)
  │ Plain HTTP on :8080/mcp, toolsets: core, config, helm
  ▼
Tool result, prefixed and returned through the chain
```

See [`docs/architecture.md`](docs/architecture.md) for the full call flow
and component responsibilities.

## Adding more MCP servers

The broker is a multi-upstream federation point. Each additional server is
four objects (Deployment, Service, HTTPRoute, MCPServerRegistration) and
gets a distinct tool prefix to avoid name collisions.

See [`docs/adding-mcp-servers.md`](docs/adding-mcp-servers.md) for the
step-by-step.

## Known limitations (v0.6.0 Tech Preview)

This sample carries three OpenShift-specific workarounds that are expected
to be unnecessary in MCP Gateway 0.7:

1. **Upstream MCP servers must speak plain HTTP.** The broker has no API to
   configure trusted CAs for HTTPS upstreams, so an HTTPS upstream signed by
   the OpenShift service-CA (the default OpenShift TLS pattern) is rejected
   with `x509: certificate signed by unknown authority`. The sample targets
   the gateway's HTTP listener to make the broker dial upstreams via
   `http://`. See [Kuadrant issue #659](https://github.com/Kuadrant/mcp-gateway/issues/659)
   and [#917](https://github.com/Kuadrant/mcp-gateway/issues/917).

2. **The broker's `--mcp-gateway-private-host` flag uses a vanilla-Istio
   Service name.** The broker is hardcoded to call back into
   `mcp-gateway-istio.openshift-ingress.svc.cluster.local`, which doesn't
   exist on OpenShift (the real name is `mcp-gateway-openshift-default`).
   The sample creates an alias Service to bridge this naming mismatch.

3. **External TLS is provided by an OpenShift Route, not the gateway's own
   HTTPS listener.** Because the broker uses the HTTP listener to dial
   upstreams (workaround #1), the gateway's HTTPS listener has no broker
   ext_proc filter attached. An edge-terminated `Route` adds TLS at the
   OpenShift router layer using the cluster's default ingress cert.

When 0.7 lands, the upstream can move back to HTTPS, the alias Service can
be removed, and the Route can be replaced with direct use of the gateway's
HTTPS listener.

## References

* [Red Hat Connectivity Link 1.3 — Installing the MCP Gateway](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/installing_the_mcp_gateway/mcp-gateway-install)
* [Kuadrant MCP Gateway](https://github.com/Kuadrant/mcp-gateway)
* [kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server)
* [Model Context Protocol](https://modelcontextprotocol.io/)
* [Red Hat blog: Control your AI agent traffic at scale](https://www.redhat.com/en/blog/control-your-ai-agent-traffic-scale-model-context-protocol-gateway-red-hat-openshift-now-technology-preview)

## Contributing

Issues and pull requests welcome, especially for additional upstream MCP
server samples or improvements to the install/validate scripts.
