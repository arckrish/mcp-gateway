# Architecture

This document describes how a request flows through the MCP Gateway sample
deployment, what each component does, and why certain configuration choices
exist in this sample.

## Call Flow

```
External client (e.g. Claude Desktop, MCP Inspector, curl)
        │
        │  HTTPS to mcp.apps.<cluster-domain>/mcp
        │  TLS terminated by OpenShift router (wildcard ingress cert)
        ▼
OpenShift Router  (openshift-ingress namespace)
        │  Route: mcp-gateway-edge
        │  termination: edge → plain HTTP downstream
        ▼
Service: mcp-gateway-openshift-default:80  (openshift-ingress)
        │  ClusterIP backing the Istio gateway pod
        ▼
Istio Gateway pod  (mcp-gateway-openshift-default)
        │  Listener: http on port 80, hostname mcp.apps.<cluster-domain>
        │  EnvoyFilter (ext_proc) installed by MCPGatewayExtension
        │  HTTPRoute: mcp-gateway-route, /mcp → broker Service
        ▼
MCP Broker pod  (demo namespace, Service: mcp-gateway)
        │  Strips toolPrefix from incoming tool names
        │  Looks up upstream URL in /config/config.yaml (rendered from
        │  MCPServerRegistration objects)
        ▼
Upstream MCP server  (demo/openshift-mcp-server)
        │  Service: openshift-mcp-server:8080 → pod:8080
        │  Plain HTTP, /mcp endpoint
        │  Executes the tool using its ServiceAccount RBAC
        ▼
        Response flows back along the same path, with tool prefixes
        re-applied on the way out.
```

## Components

### Gateway resources (`manifests/02-gateway`)

| Object | Purpose |
| --- | --- |
| `ConfigMap/mcp-gateway-config` | Tells OpenShift's service-CA operator to mint a serving cert for the Gateway's backing Service into `Secret/mcp-gateway-tls`. The Gateway's HTTPS listener references that Secret. |
| `Gateway/mcp-gateway` | Defines three listeners on a single hostname: `http:80`, `mcps:8080`, and `https:443`. The MCP Gateway extension attaches to the `http` listener. The `mcps` listener is reserved for direct MCP traffic. The `https` listener is created by the manifest but is not actually exposed externally in this sample (we use an edge-terminated Route on port 80 instead). |

### MCP control plane (`manifests/03-extension`)

| Object | Purpose |
| --- | --- |
| `ReferenceGrant/allow-demo-mcp-extension` | Authorizes the `MCPGatewayExtension` in `demo` to target the `Gateway` in `openshift-ingress`. Required because Gateway API denies cross-namespace references by default. |
| `MCPGatewayExtension/mcp-extension` | Drives the broker Deployment (`demo/mcp-gateway`) and installs the Envoy ext_proc filter on the gateway listener. `httpRouteManagement: Enabled` makes the controller auto-create the `mcp-gateway-route` HTTPRoute that routes `/mcp` to the broker. `targetRef.sectionName: http` causes the controller to write `url: http://...` for upstream calls in the broker config Secret. |
| `Service/mcp-gateway-istio` | Workaround Service in `openshift-ingress` that aliases the real Gateway Service. The broker is started with `--mcp-gateway-private-host=mcp-gateway-istio.openshift-ingress.svc.cluster.local:443` (a vanilla-Istio assumption that doesn't match OpenShift Gateway naming). Without this alias, tool calls fail with a DNS lookup error. |

### Upstream MCP server (`manifests/04-mcp-servers/openshift-mcp`)

| Object | Purpose |
| --- | --- |
| `ServiceAccount/openshift-mcp-server` (`demo`) | Identity the MCP server uses when calling the Kubernetes API. |
| `ClusterRoleBinding/openshift-mcp-server-view` | Binds the SA to the cluster-wide `view` role. The server runs with `--disable-destructive`, so it can only read by default. Adjust the role/binding if you need write tools. |
| `Deployment/openshift-mcp-server` (`demo`) | Runs `quay.io/containers/kubernetes_mcp_server` with toolsets `core,config,helm`. Listens on port 8080 in plain HTTP. |
| `Service/openshift-mcp-server` (`demo`) | ClusterIP exposing port 8080. |
| `HTTPRoute/openshift-mcp-server` (`demo`) | Discovery target for the `MCPServerRegistration`. Routes `/backends/openshift-mcp` to the backend Service. The non-`/mcp` path avoids conflicting with `mcp-gateway-route`. |
| `MCPServerRegistration/openshift-mcp` (`demo`) | Registers the upstream with the broker. `path: /mcp` is the path the upstream serves. `toolPrefix: openshift-mcp_` ensures tool names are namespaced at the broker. |

### External exposure (`manifests/05-route`)

| Object | Purpose |
| --- | --- |
| `Route/mcp-gateway-edge` (`openshift-ingress`) | Edge-terminated OpenShift Route that exposes the gateway externally. The OpenShift router terminates TLS using the cluster's default ingress cert, then forwards plain HTTP to the gateway's port 80 listener. |

## Why the http listener instead of https?

The MCP Gateway 0.6.0 broker uses one hard-coded scheme for upstream MCP
calls. The controller picks that scheme based on the listener protocol the
`MCPGatewayExtension` targets:

* `sectionName: http`  → broker dials upstreams over `http://`
* `sectionName: https` → broker dials upstreams over `https://`

In 0.6.0 there is no API to configure trusted CAs or skip TLS verification
on the broker's upstream client. If you target the HTTPS listener and your
upstream serves HTTPS with a cert signed by the OpenShift service-CA (the
default and recommended pattern), the broker rejects the response with
`x509: certificate signed by unknown authority` because the service-CA is
not in the broker's trust store.

The workaround used in this sample:

1. Make the broker talk plain HTTP to upstreams by targeting the HTTP
   listener. The upstream MCP server runs in plain HTTP mode.
2. Keep external TLS by putting an edge-terminated OpenShift Route in front
   of the gateway's HTTP listener. This uses the OpenShift router's wildcard
   ingress cert, so clients still get a valid TLS connection.

When MCP Gateway 0.7 ships (see Kuadrant issues
[#659](https://github.com/Kuadrant/mcp-gateway/issues/659) and
[#917](https://github.com/Kuadrant/mcp-gateway/issues/917)), the broker is
expected to support HTTPS upstreams cleanly. At that point you can:

1. Annotate the upstream Service with
   `service.beta.openshift.io/serving-cert-secret-name` and mount the
   resulting Secret into the MCP server pod.
2. Pass `--tls-cert` and `--tls-key` to the MCP server.
3. Retarget the `MCPGatewayExtension` to `sectionName: https`.
4. Remove the OpenShift Route — clients can use the Gateway's own HTTPS
   listener directly (provided cluster-external DNS reaches it).
