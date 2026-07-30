# EVS Helm Chart

A Helm chart for deploying the EVS (Edge Video/Event Storage) application — a Spring Boot service that uploads video and event data from handheld devices to Hanshow servers for processing.

## Chart Overview

| Field | Value |
|-------|-------|
| Chart Name | `evs` |
| Type | `application` |
| Version | `1.0.0` |
| App Version | `1.0.0` |

## Architecture

The chart deploys the following Kubernetes resources:

- **Deployment** — runs the EVS Spring Boot application container
- **Service** — exposes the application ports (HTTP, Prometheus, custom)
- **Route** (OpenShift) — creates an edge-terminated TLS route to the service
- **PersistentVolumeClaim** — provisions storage for application data
- **NetworkPolicy** — controls ingress and egress traffic
- **Kasten Backup Policy** — optional daily backup of PVCs via Kasten K10

## Vendor Onboarding Model: 1:1 Charts vs Standardized Single Chart

You currently have two options for onboarding 3rd-party vendors:

### Option A: Traditional 1:1 chart per vendor

In this model, each vendor provides (or you maintain) a dedicated chart with direct template mappings for that vendor's resources.

**Characteristics**
- Vendor-specific templates and values structures
- Fast initial fit for one vendor, but logic is duplicated across charts
- Drift risk increases over time (security, policies, probes, labels, backups)

**Operational impact**
- More chart repositories/versions to maintain
- More upgrade/review effort for every platform-wide change
- Harder to enforce consistent NetworkPolicy, observability, and naming standards

### Option B: Standardized single chart (this chart's approach)

In this model, vendors onboard by supplying values to a shared schema and shared templates.

**Characteristics in this chart**
- Shared configuration contract via `app.configData` + `configDataKey`
- Resource templates are reusable and data-driven (`services`, `ports`, `env`, `networkPolicy`, `persistence`, `files`)
- Template helpers centralize behavior (`app.configValue`, `app.envValue`, `app.resolvePort`, `app.annotations`)

**Why this scales better for multi-vendor onboarding**
- One chart to patch for CVEs, policy changes, or platform standards
- Uniform security posture across vendors (egress rules, probes, resource QoS, labels)
- Lower long-term maintenance: vendor deltas live mostly in `values.yaml`, not new templates

### Side-by-side comparison

| Area | 1:1 vendor charts | Standardized single chart (current) |
|------|--------------------|--------------------------------------|
| Template ownership | Per vendor | Central shared templates |
| Change location | Template code in many repos | Mostly `values.yaml` per vendor |
| Security/policy consistency | Harder to enforce globally | Enforced once in shared chart |
| Upgrade effort | Repeated per vendor chart | One chart upgrade path |
| Onboarding speed (new vendor) | Fast if vendor gives chart; costly to align | Slightly more modeling upfront; faster repeat onboarding |
| Long-term maintenance | High | Lower |

### Practical examples from this chart

- **Endpoint reuse without template forks**: URL parts are modeled once in `app.configData` (`type: "url"`) and reused with dotted references (for example `buyboostOpenapiHost.host`) in env and network policy.
- **List rendering without custom templates**: list values (for example `storageForbiddenFileTypes`) can define `joinChar` for env serialization.
- **File-based vendor config injection**: `app.files` supports both `configMap` and `secret` generation and pod mounts from values, avoiding vendor-specific templates.

### Recommended onboarding contract for vendors

To keep onboarding consistent, require vendors to submit:
- A vendor-specific values file that conforms to `values.schema.json`
- Endpoint/config additions in `app.configData`
- Required egress entries in `app.networkPolicy.egress.allowedHosts`
- Optional file payloads via `app.files` when application config must be mounted

This keeps your platform on a single Helm codebase while allowing vendor-specific configuration safely through values.

### Vendor onboarding checklist

- Copy the starter template below to `vendor-values.yaml`
- Set vendor identity (`project.name`, labels, image/tag)
- Add or update vendor endpoints in `app.configData` (`type: "url"`)
- Wire vendor credentials/settings through `app.env` using `configDataKey`
- Allow only required egress hosts in `app.networkPolicy.egress.allowedHosts`
- Add optional mounted config in `app.files` (`type: configMap|secret`)
- Validate with `helm lint .` and `helm template -f vendor-values.yaml`

### `vendor-values.yaml` starter template

```yaml
project:
  name: "vendor-a"
  environment: dev
  labels:
    environment: "development"
    team: "VendorA"

app:
  image:
    repository: your.registry/vendor-a/evs
    tag: "dev"
    pullPolicy: IfNotPresent

  configData:
    vendorOpenapiHost:
      description: "Vendor API base URL"
      value:
        scheme: "https"
        host: "api.vendor-a.example"
        port: 443
        path: "/api"
      type: "url"
    vendorOpenapiAk:
      description: "Vendor API access key"
      value: "replace-me"
      type: "string"
    vendorOpenapiSk:
      description: "Vendor API secret key"
      value: "replace-me"
      type: "string"

  env:
    VENDOR_OPENAPI_HOST:
      configDataKey: vendorOpenapiHost
    VENDOR_OPENAPI_AK:
      configDataKey: vendorOpenapiAk
    VENDOR_OPENAPI_SK:
      configDataKey: vendorOpenapiSk

  networkPolicy:
    egress:
      allowedHosts:
        - name: vendor-a
          ip:
            configDataKey: vendorOpenapiHost.host
          port:
            portDefinitionKey: vendorOpenapiHost.port

  files:
    - name: "vendor-a-app-config"
      mountPath: "/app/config/"
      subPath: "vendor-a.yaml"
      type: "secret"
      data: |
        featureFlags:
          useVendorA: true
```

## Configuration Data (`configData`)

This chart uses a centralised configuration pattern. All reusable values are defined in `app.configData` with a consistent structure:

```yaml
configData:
  serverPort:
    description: "The port the server will listen on for HTTP/S requests"
    value: 8080
    type: "int"
```

Each entry has:
- **`description`** — human-readable explanation (rendered as comments in templates)
- **`value`** — the actual value used at render time
- **`type`** — data type hint (`int`, `string`, `list`)

### The `configDataKey` Pattern

Any value in the chart can reference a `configData` entry instead of being hardcoded:

```yaml
# Reference a configData entry
replicaCount:
  configDataKey: replicaCount

# Or use a literal value directly
replicaCount: 1
```

Both forms are handled transparently by the `app.configValue` helper. When a value is a map containing `configDataKey`, the helper looks up the corresponding `configData` entry and returns its `value`. When it's a literal (string, int, etc.), it passes through unchanged.

This pattern is useful for values that are repeated across multiple places (e.g., `serverPort` is used in the deployment container port, service port, route target port, probes, annotations, and network policies).

### Available configData Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `serverPort` | int | `8080` | Server HTTP/S listening port |
| `prometheusPort` | int | `9090` | Prometheus metrics scraping port |
| `tomsPort` | int | `1443` | Custom data port |
| `replicaCount` | int | `1` | Number of pod replicas |
| `memoryRequest` | string | `8Gi` | Memory request for the container |
| `memoryLimit` | string | `8Gi` | Memory limit for the container |
| `cpuRequest` | int | `1000` | CPU request (millicores) |
| `cpuLimit` | int | `1000` | CPU limit (millicores) |
| `serverServletContextPath` | string | `/evs` | Servlet context path |
| `serverVersion` | string | `1.0.1` | Application server version |
| `serverTomcatMaxThreads` | string | `500` | Max Tomcat worker threads |
| `serverTomcatMinSpareThreads` | string | `200` | Min Tomcat spare threads |
| `serverTomcatMaxConnections` | string | `20000` | Max Tomcat connections |
| `serverTomcatAcceptCount` | string | `1000` | Max incoming connection queue length |
| `serverTomcatConnectionTimeout` | string | `600000` | Connection timeout (ms) |
| `serverTomcatKeepAliveTimeout` | string | `600000` | Keep-alive timeout (ms) |
| `serverTomcatMaxHttpFormPostSize` | string | `104857600` | Max HTTP form post size (bytes) |
| `openapiUsers` | list | *(see values.yaml)* | OpenAPI user credentials and org access |
| `storageUploadMaxConcurrency` | string | `5` | Max concurrent uploads |
| `storageForbiddenFileTypes` | list | *(see values.yaml)* | Forbidden file extensions for upload |
| `buyboostOpenapiHost` | string | `http://172.16.125.46:8185/buyboost` | Buyboost cloud service URL |
| `buyboostOpenapiAk` | string | `test` | Buyboost access key |
| `buyboostOpenapiSk` | string | `000000` | Buyboost secret key |
| `haidpOpenapiHost` | string | `http://10.13.108.6:9192/api1` | HaiDP cloud service URL |
| `haidpOpenapiCode` | string | `edge` | HaiDP code identifier |
| `haidpOpenapiDesc` | string | `EVS` | HaiDP description |
| `haidpOpenapiAk` | string | `IJpBSwnImQArnXRarbod` | HaiDP access key |
| `haidpOpenapiSk` | string | *(see values.yaml)* | HaiDP secret key |
| `schedulerUploadStartTime` | string | `09:00` | Upload scheduler start time (HH:mm) |
| `schedulerUploadEndTime` | string | `18:30` | Upload scheduler end time (HH:mm) |

## Template Helpers

Defined in `_helpers.tpl`:

| Helper | Purpose |
|--------|---------|
| `app.name` | Chart name, truncated to 63 chars |
| `app.fullname` | `<release>-<chart>` name |
| `app.labels` | Standard Kubernetes labels |
| `app.selectorLabels` | Selector labels for pod matching |
| `app.kebab` | Converts camelCase to kebab-case |
| `app.configValue` | Resolves a value — either a literal or a `configDataKey` reference |
| `app.configValueStr` | String variant of `app.configValue` |
| `app.resolvePort` | Resolves a port value with numeric output guarantee |

## Resource Management (QoS)

The chart supports three Kubernetes QoS classes via `app.resources.qos`:

### Guaranteed (default)

Requests are automatically set equal to limits. You only need to configure limits:

```yaml
resources:
  qos: Guaranteed
  limits:
    memory:
      configDataKey: memoryLimit
    cpu:
      configDataKey: cpuLimit
```

### Burstable

Requests and limits are configured independently:

```yaml
resources:
  qos: Burstable
  requests:
    memory:
      configDataKey: memoryRequest
    cpu:
      configDataKey: cpuRequest
  limits:
    memory:
      configDataKey: memoryLimit
    cpu:
      configDataKey: cpuLimit
```

### BestEffort

No resource requests or limits are rendered:

```yaml
resources:
  qos: BestEffort
```

## Services and Ports

Ports are defined in `app.ports` and referenced by name throughout the chart. Each port can use a `portDefinitionKey` or a literal value:

```yaml
ports:
  serverPort:
    port:
      portDefinitionKey: serverPort
    name: http_tomcat
    protocol: TCP
```

Services are defined in `app.services` and reference ports by key:

```yaml
services:
  - name: api
    type: ClusterIP
    annotations:
      - prometheus
      - istio
    ports:
      - sourcePort: serverPort
        targetPort: serverPort
```

## Annotation Sets

Reusable annotation groups are defined in `app.annotationSets` and referenced by name in services. Annotation values support the `configDataKey` pattern:

```yaml
annotationSets:
  prometheus:
    prometheus.io/scrape: "true"
    prometheus.io/port:
      configDataKey: prometheusPort
```

## Persistence

Persistent volumes are defined under `app.persistence`. Each volume supports optional Kasten K10 backup configuration:

```yaml
persistence:
  dataVolume:
    backup:
      enabled: true
      frequency: "@daily"
      retention: 7
    storageClass: "local-storage"
    accessMode: ReadWriteOnce
    size: 20Gi
    mountPath: /app/storage
```

When `backup.enabled` is `true`:
- The PVC gets a `k10.kasten.io/backup: "true"` annotation
- A Kasten `Policy` CR is created with the specified `frequency` and `retention`

Each volume can have its own independent backup schedule.

## Network Policies

The chart creates two `NetworkPolicy` resources:

### Ingress

Restricts inbound traffic to specified sources and ports:

```yaml
networkPolicy:
  ingress:
    allowedSources:
      - type: podSelector
        matchLabels:
          app.kubernetes.io/name: evs
    ports:
      - serverPort
```

### Egress

Restricts outbound traffic to specified hosts by IP and port:

```yaml
networkPolicy:
  egress:
    allowedHosts:
      - name: buyboost
        ip: "172.16.125.46"
        port: 8185
      - name: haidp
        ip: "10.13.108.6"
        port: 9192
```

## Environment Variables

All environment variables are defined in `app.env`. Each can use a `configDataKey` reference or a literal value. When using `configDataKey`, the corresponding `configData` description is rendered as a YAML comment above the env entry in the deployment template.

```yaml
env:
  SERVER_PORT:
    configDataKey: serverPort
  CUSTOM_VALUE: "my-literal-value"
```

## Health Probes

Liveness and readiness probes use TCP socket checks against configured ports:

```yaml
probes:
  liveness:
    tcpSocket:
      port: serverPort    # references app.ports key
    initialDelaySeconds: 60
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  readiness:
    tcpSocket:
      port: serverPort
    initialDelaySeconds: 30
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
```

## Quick Start

```bash
# Render all templates
helm template my-release edge_helm/

# Render a specific template
helm template my-release edge_helm/ --show-only templates/deployment.yaml

# Override a configData value
helm template my-release edge_helm/ --set app.configData.serverPort.value=9090

# Change QoS class
helm template my-release edge_helm/ --set app.resources.qos=BestEffort
```
