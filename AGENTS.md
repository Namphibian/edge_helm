# AGENTS.md

## Big Picture
- `edge_helm` is a Helm chart that deploys EVS on OpenShift/Kubernetes.
- Core resources are split across `templates/`: `deployment.yaml`, `service.yaml`, `networkpolicy.yaml`, `pvc.yaml`, `route.yaml`, `project.yaml`, `resourcequota.yaml`.
- Data path: client traffic enters via Service/Route, reaches the EVS container, then egresses to external services allowed by `networkpolicy.yaml`.
- OpenShift-specific boundaries are explicit: `Project` and `Route` templates are used in addition to standard Kubernetes objects.

## Configuration Model (Most Important)
- Treat `values.yaml` as the source of truth; most reusable settings live under top-level `configData`.
- `configData` entries use `{ description, value, type }`; templates resolve these via `configDataKey` references.
- Resolution logic is centralized in `templates/_helpers.tpl` (`app.configValue`, `app.resolvePort`).
- When adding config, prefer: define once in `configData` -> reference by key in templates.
- Example pattern: server/management/metrics ports are defined in `values.yaml` and consumed by Deployment, Service, probes, and annotations.

## Template Conventions
- Use helper templates from `templates/_helpers.tpl` for naming, labels, annotations, and value resolution.
- Services are configured as lists under top-level `services` and usually reference named ports from top-level `ports`.
- Annotations are composed through named sets (`app.annotationSets`) and rendered via `app.annotations` helper.
- Deployment env vars are generated from `app.env`; many values reference `configDataKey` and include inline description comments.
- Resource requests/limits behavior depends on `app.resources.qos` (Guaranteed/Burstable/BestEffort) in `deployment.yaml`.

## Integrations and Cross-Component Links
- External egress destinations are controlled in `templates/networkpolicy.yaml`; update this when adding outbound integrations.
- Backup integration is optional and template-gated: `templates/kasten-backup.yaml` plus backup flags under persistence in `values.yaml`.
- OpenShift route exposure is managed in `templates/route.yaml` and links to service/port settings from values.

## Developer Workflow (Local Iteration)
- Render full chart:
  ```bash
  helm template my-release .
  ```
- Render one template while iterating:
  ```bash
  helm template my-release . --show-only templates/deployment.yaml
  ```
- Test value overrides quickly:
  ```bash
  helm template my-release . --set configData.serverPort.value=9090
  ```

## Safe Change Patterns
- Add new app setting: create `configData.<key>` first, then reference it via `configDataKey`.
- Add a new exposed port: update top-level `ports` and then reference by name in top-level `services`/probes/routes.
- Add outbound dependency: add env/config in values, then allow destination in `networkPolicy.egress`.
- Enable backups per volume by toggling persistence backup flags; keep retention/frequency aligned with existing keys.

## Key Files to Read First
- `README.md`
- `values.yaml`
- `templates/_helpers.tpl`
- `templates/deployment.yaml`
- `templates/service.yaml`
- `templates/networkpolicy.yaml`

