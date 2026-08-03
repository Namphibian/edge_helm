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

The chart now uses these top-level keys:

- `project` - namespace/project metadata and quota
- `configData` - shared typed configuration entries
- `ports` - reusable port definitions
- `services` - service definitions by service type group
- `app` - map of app definitions (multi-app model)
- `secretStores` - External Secrets SecretStore resources
- `externalSecrets` - ExternalSecret resources

## Multi-App Structure (Important)

`app` is a map of maps:

```yaml
app:
  app-name1:
    # app definition elements
    image:
      repository: your.registry/app1
      tag: dev
      pullPolicy: IfNotPresent
    replicaCount: 1
    env:
      SPRING_MAIN_BANNER_MODE: "off"

  app-name2:
    # app definition elements
    image:
      repository: your.registry/app2
      tag: dev
      pullPolicy: IfNotPresent
    replicaCount: 2
```

Each app entry can define its own deployment-centric config (`image`, `env`, `resources`, `probeTypes`, `probes`, `persistence`, `configFiles`, `containerPorts`, etc.).

## `configData` and `configDataKey`

Shared values are defined once in top-level `configData`:

```yaml
configData:
  serverPort:
    description: "The port the server will listen on for HTTP/S requests"
    value: "8080"
    type: "int"
```

Any app field can reference them using:

```yaml
configDataKey: serverPort
```

## Top-Level `ports`

Port definitions are top-level and reusable across services/probes/container port mapping:

```yaml
ports:
  serverPort:
    port:
      configDataKey: serverPort
    name: "http-tomcat"
    protocol: TCP
```

## Top-Level `services`

Services are top-level and grouped by type (`clusterIp`, `nodePort`, `loadBalancer`, `externalName`, `headless`):

```yaml
services:
  clusterIp:
    api:
      exposedRoute: false
      annotations:
        - prometheus
      ports:
        - sourcePort:
            portDefinitionKey: serverPort
          targetPort:
            portDefinitionKey: serverPort
```

## App Container Ports

Container ports are no longer a boolean on `ports.*`. Define them per app:

```yaml
app:
  evs:
    containerPorts:
      - portDefinitionKey: serverPort
```

This list is optional.

## App Probes

Probe behavior uses reusable `probeTypes` plus selectors in `probes`:

```yaml
app:
  evs:
    probeTypes:
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

## Routes

Routes are generated from top-level `services` entries where `exposedRoute: true`.
No routes are rendered when none are explicitly exposed.

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
helm template my-release . --set app.evs.resources.qos=BestEffort
```

## Notes

- `ports` and `services` are intentionally top-level shared definitions.
- `app` is the multi-app deployment map.
- If you add a new app key under `app`, a separate Deployment is rendered for it.
