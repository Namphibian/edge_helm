# EVS Helm Chart

Helm chart for deploying EVS (Edge Video/Event Storage) on Kubernetes/OpenShift.

## Chart Overview

| Field | Value |
|-------|-------|
| Chart Name | `evs` |
| Type | `application` |
| Version | `1.0.0` |
| App Version | `1.0.0` |

## Current Values Model

The chart uses these top-level keys:

- `project` — namespace/project metadata and quota
- `configData` — shared typed configuration entries
- `annotationSets` — reusable named annotation groups
- `ports` — reusable port definitions
- `services` — service definitions by service type group
- `app` — map of app definitions (multi-app model)
- `secretStores` — External Secrets SecretStore resources
- `externalSecrets` — ExternalSecret resources

## `configData` and `configDataKey`

Shared values are defined once in top-level `configData`:

```yaml
configData:
  serverPort:
    description: "The port the server will listen on for HTTP/S requests"
    value: "8080"
    type: "int"
```

Each entry follows the schema `{ description, value, type }` with an optional `joinChar` for list-type values.

Any field elsewhere in the chart can reference a `configData` entry using:

```yaml
configDataKey: serverPort
```

## Top-Level `annotationSets`

Named annotation groups are defined at the top level and referenced by name in services and other resources:

```yaml
annotationSets:
  prometheus:
    prometheus.io/scrape: "true"
    prometheus.io/port:
      configDataKey: prometheusPort

  awsInternal:
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
```

Annotation values can be literals or `configDataKey` references.

## Top-Level `ports`

Port definitions are top-level and reusable across services, probes, and container port mapping:

```yaml
ports:
  serverPort:
    port:
      configDataKey: serverPort
    name: "http-tomcat"
    protocol: TCP
    description: "Port used by the application to run the server"
```

## Top-Level `services`

Services are top-level and grouped by type (`clusterIp`, `nodePort`, `loadBalancer`, `externalName`, `headless`):

```yaml
services:
  clusterIp:
    api:
      description: "API service"
      exposedRoute: false
      targetApps:
        - evxcs
        - abc
      annotations:
        - prometheus
        - istio
      ports:
        - sourcePort:
            portDefinitionKey: serverPort
          targetPort:
            portDefinitionKey: serverPort

  externalName:
    mysql-dev:
      description: "External MySQL service"
      externalName: "mysql-dev.dev.svc.cluster.local"

  headless:
    evs-storage:
      description: "Headless storage service"
      ports:
        - sourcePort:
            portDefinitionKey: serverPort
          targetPort:
            portDefinitionKey: serverPort
```

- `targetApps` is required for `clusterIp`, `nodePort`, and `loadBalancer` services. Each entry renders one Service per target app.
- `annotations` is a list of `annotationSets` names to merge onto the Service.
- `externalName` services only need `externalName` (no ports or targetApps).
- `headless` services render as `ClusterIP` with `clusterIP: None`.

## Routes

Routes are generated from top-level `services` entries where `exposedRoute: true`.
No routes are rendered when none are explicitly exposed.

## Multi-App Structure

`app` is a map of maps. Each key renders a separate Deployment:

```yaml
app:
  evxcs:
    image:
      repository: your.registry/app1
      tag: dev
      pullPolicy: IfNotPresent
      imagePullSecrets:
        - name: my-secret
    replicaCount: 1
    serviceAccount:
      create: true
      annotations: []
    deployment:
      annotations: []
    route:
      annotations: []
    resources:
      qos: "BestEffort"    # Guaranteed | Burstable | BestEffort
      requests:
        memory: "6Gi"
        cpu: "750"
      limits:
        memory: "8Gi"
        cpu: "1000"
    env:
      SPRING_MAIN_BANNER_MODE: "off"
      BUYBOOST_OPENAPI_AK:
        configDataKey: buyboostOpenapiAk
```

Each app entry can define:

| Key | Purpose |
|-----|---------|
| `image` | Container image (repository, tag, pullPolicy, imagePullSecrets) |
| `replicaCount` | Number of replicas |
| `serviceAccount` | Per-app ServiceAccount creation and annotations |
| `deployment` | Deployment-level annotations |
| `route` | Route-level annotations |
| `resources` | CPU/memory requests and limits with QoS mode |
| `env` | Environment variables (literal or `configDataKey` references) |
| `containerPorts` | List of `portDefinitionKey` references for container ports |
| `probeTypes` | Reusable probe definitions (httpGet, tcpSocket, exec) |
| `probes` | Liveness/readiness probe selectors and timing |
| `persistence` | Named persistent volumes with backup support |
| `networkPolicy` | Per-app ingress/egress network policy rules |
| `configFiles` | ConfigMap/Secret files mounted into the pod |

## App Container Ports

Container ports are defined per app as a list of port definition references:

```yaml
app:
  evxcs:
    containerPorts:
      - portDefinitionKey: serverPort
```

This list is optional.

## App Probes

Probe behavior uses reusable `probeTypes` plus selectors in `probes`:

```yaml
app:
  evxcs:
    probeTypes:
      httpGet:
        path: /evs
        port:
          portDefinitionKey: serverPort
      tcpSocket:
        port:
          portDefinitionKey: serverPort
      exec:
        command: ["/bin/sh", "-c", "curl -f http://localhost:8080/actuator/health || exit 1"]

    probes:
      liveness:
        probeType: exec
        initialDelaySeconds: 60
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 3
      readiness:
        probeType: tcpSocket
        initialDelaySeconds: 30
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 3
```

## App Network Policy

Each app can define its own ingress and egress network policy rules:

```yaml
app:
  evxcs:
    networkPolicy:
      ingress:
        allowedSources:
          - type: podSelector
            matchLabels:
              app.kubernetes.io/name: evs
        ports:
          - serverPort
      egress:
        allowedHosts:
          - name: buyboost
            ip:
              configDataKey: buyboostOpenapiHost.host
            port:
              configDataKey: buyboostOpenapiHost.port
```

## App Config Files

Config files are mounted into the pod as ConfigMaps or Secrets. Use `data` for literal content or `transform` to generate key-value lines from `configData` references:

```yaml
app:
  evxcs:
    configFiles:
      - name: "jul-logging-override"
        mountPath: "/app/config"
        subPath: "logging.properties"
        type: configMap
        data: |
          handlers=java.util.logging.ConsoleHandler.level=INFO

      - name: "application-properties-override"
        mountPath: "/app/config"
        subPath: "application.properties"
        type: configMap
        transform:
          server.port:
            configDataKey: serverPort
          server.servlet.context.path:
            configDataKey: serverServletContextPath
```

## App Persistence

Persistent volumes are defined per app with optional backup support:

```yaml
app:
  evxcs:
    persistence:
      dataVolume:
        storageClass: "crc-csi-hostpath-provisioner"
        accessMode: ReadWriteOnce
        size: 1Gi
        name: evs-storage
        mountPath: /app/storage
        annotations: []
        backup:
          enabled: true
          frequency: "@daily"
          retention: 7
          annotations: []
```

## Secret Stores and External Secrets

```yaml
secretStores:
  evsAksVault:
    tenantId: "123123-some-id-123123"
    vaultName: "evs-akv"
    authSecretRef:
      clientId:
        name: azure-secret-sp
        key: ClientID
      clientSecret:
        name: azure-secret-sp
        key: ClientSecret

externalSecrets:
  buyboostSecrets:
    refreshInterval: 1h
    secretStoreRef:
      name: secret-store-name
      kind: SecretStore
    target:
      name: aksVault
      creationPolicy: Owner
    data:
      - secretKey: DB_PASSWORD
        remoteRef:
          key: prod/db/password
```

## Quick Start

```bash
# Render full chart
helm template my-release .

# Lint chart + values schema
helm lint .

# Render one template
helm template my-release . --show-only templates/deployment.yaml

# Override shared config
helm template my-release . --set configData.serverPort.value=9090

# Override app-specific value
helm template my-release . --set app.evxcs.resources.qos=BestEffort
```

## Notes

- `configData`, `annotationSets`, `ports`, and `services` are intentionally top-level shared definitions.
- `app` is the multi-app deployment map — each key renders a separate Deployment.
- Services reference apps via `targetApps`; one Service resource is rendered per target app.
- If you add a new app key under `app`, a separate Deployment is rendered for it.
