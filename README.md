# meridian-helm

Helm chart for **Meridian** — an open re-implementation of Microsoft Dynamics 365
F&O (Supply Chain Management) and CE (Project Operations). Deploys to RHEL
OpenShift and is driven by Argo CD from
[`adt-grc-gitops`](https://github.com/thearlie82/adt-grc-gitops).

## Layout

Umbrella chart wrapping two subcharts (plus the vendored Collabora chart), mirroring the fleet convention
(`aras2dynamicsf-o_helm`):

```
Chart.yaml                 umbrella (api + web + collabora deps)
values.yaml                dev-safe defaults
templates/
  namespace.yaml           the meridian namespace
  cnpg-cluster.yaml        CloudNativePG Cluster CR (Postgres)
  collabora-*.yaml         Collabora NetworkPolicy + ServiceAccount (when enabled)
  _helpers.tpl / NOTES.txt
charts/api/                Rust axum API (port 8080, /healthz, OpenAPI at /swagger-ui)
charts/web/                React SPA behind nginx (port 8080, proxies /api/ to the api Service)
charts/collabora-online-*.tgz  official Collabora Online chart, vendored (off by default)
```

## Database — CloudNativePG

Postgres is provisioned by the **CloudNativePG** operator (the cluster's DB
pattern, same as `coder`). The chart renders a `postgresql.cnpg.io/v1 Cluster`;
the operator then publishes a Secret named `<clusterName>-app` whose `uri` key is
a ready-to-use connection string. The API's `DATABASE_URL` is wired to that key.
The API applies its own SQL migrations at startup.

> Argo CD must sync this chart with **ServerSideApply=true** — the CNPG CRD
> schema is large and exceeds the client-side apply annotation limit.

## Secrets (never committed)

Create these in the target namespace before the first sync:

```sh
# JWT signing secret
oc create secret generic meridian-secrets \
  --from-literal=MERIDIAN_JWT_SECRET=$(openssl rand -hex 32) -n meridian

# GHES container-registry pull secret
oc create secret docker-registry ghes-pull-secret \
  --docker-server=containers.adt-git01.adt.network \
  --docker-username=<user> --docker-password=<pat> -n meridian
```

The CNPG `<clusterName>-app` secret is created automatically by the operator.

## STEP → GLB conversion (`api.cadConversion`)

```yaml
api:
  cadConversion:
    enabled: true                         # default
    partNumberProperty: "PLM_PART_NUMBER" # STEP property holding the part number
```

When enabled, the api launches one Kubernetes Job per conversion from its own
image, with the api's pull secrets. The Job calls back into the api Service with
a scoped token and mounts no volume and no DB secret. It reuses the test-runner
launcher ServiceAccount, Role and RoleBinding (Jobs create/get/list/watch/delete,
pods + pods/log read), which now render when either `testRunner.enabled` or
`cadConversion.enabled` is set. The api Deployment gets:

| Env | Value |
| --- | --- |
| `POD_NAMESPACE` | downward API `metadata.namespace` (shared with the test runner) |
| `MERIDIAN_CAD_CONVERTER` | `kube` |
| `MERIDIAN_API_IMAGE` | `<image.repository>:<image.tag>` |
| `MERIDIAN_API_IMAGE_PULL_SECRETS` | `global.imagePullSecrets[].name`, comma-joined (empty when unset) |
| `MERIDIAN_INTERNAL_API_URL` | `http://<api fullname>:8080` |
| `MERIDIAN_CAD_PART_NUMBER_PROPERTY` | `cadConversion.partNumberProperty` |

The api image must include `/opt/cadconv` (meridian ≥ the STEP conversion
merge); older images ignore these env vars.

Capacity: each conversion Job requests 500m / 1Gi with limits of 2 CPU / 4Gi. On
CRC, check the node has the headroom (`oc adm top node`) before a large STEP.

The chart ships no NetworkPolicy; if one is added that selects the api pods,
allow ingress on TCP 8080 from pods labelled
`app.kubernetes.io/name: meridian-cad-converter`.

## XJTAG package pull from Quay (`api.xjtag`)

```yaml
api:
  xjtag:
    enabled: false                                 # default; nothing renders while off
    quayUrl: https://quay.apps.cluster.adt.network
    pullRobotTemplate: "{org}+meridian_xjtag_pull" # {org} = lower-cased GHES repo owner
    openbao:
      addr: http://openbao.openbao.svc:8200
      role: meridian-xjtag-pull
      audience: openbao                            # projected SA token audience
      tokenExpirationSeconds: 600
    quayCa:
      configMap: meridian-quay-ca                  # ADT Dev Registry Root CA
      key: ca.crt
    ghesApi: ""                                    # empty = Meridian default
    maxPackageBytes: ""                            # empty = Meridian default
```

Keyless: the api logs in to OpenBao (kubernetes auth) with a projected
ServiceAccount token, mints an OIDC JWT, and exchanges it at Quay's robot
federation endpoint for a pull token on `<org>+meridian_xjtag_pull`. No registry
or GHES credential is mounted. When enabled the api Deployment gets:

| Env | Value |
| --- | --- |
| `MERIDIAN_XJTAG_QUAY_URL` | `xjtag.quayUrl` |
| `MERIDIAN_XJTAG_OPENBAO_ADDR` | `xjtag.openbao.addr` |
| `MERIDIAN_XJTAG_OPENBAO_ROLE` | `xjtag.openbao.role` |
| `MERIDIAN_XJTAG_SA_TOKEN_PATH` | `/var/run/secrets/openbao/token` |
| `MERIDIAN_XJTAG_QUAY_CA_FILE` | `/etc/meridian/quay-ca/ca.crt` |
| `MERIDIAN_XJTAG_PULL_ROBOT_TEMPLATE` | `xjtag.pullRobotTemplate` |
| `MERIDIAN_XJTAG_MAX_PACKAGE_BYTES` | `xjtag.maxPackageBytes` (only when set) |
| `MERIDIAN_XJTAG_GHES_API` | `xjtag.ghesApi` (only when set) |

plus two read-only volumes: a projected `serviceAccountToken` (audience
`xjtag.openbao.audience`, `expirationSeconds` `xjtag.openbao.tokenExpirationSeconds`)
at `/var/run/secrets/openbao`, and the `xjtag.quayCa.configMap` ConfigMap (key
`xjtag.quayCa.key` mounted as `ca.crt`) at `/etc/meridian/quay-ca`.

Prerequisites, all out-of-band:

- The OpenBao role `meridian-xjtag-pull` and the Quay orgs + federated pull
  robots (meridian-infra Terraform). The role binds the pod's ServiceAccount,
  `testRunner.serviceAccountName` (`meridian-test-launcher`); if that name
  changes, meridian-infra `var.meridian_api_service_account` must change too.
- The CA ConfigMap, copied from `openshift-config/registry-certs`:

  ```sh
  oc get configmap registry-certs -n openshift-config \
    -o jsonpath='{.data.quay\.apps\.cluster\.adt\.network}' > ca.crt
  oc create configmap meridian-quay-ca --from-file=ca.crt -n meridian
  ```

## Collabora side-car (`collabora`)

Collabora Online (CODE) edits Office files for Meridian Documents. It is the
official [`collabora-online`](https://collaboraonline.github.io/online/) chart,
vendored as `charts/collabora-online-1.3.8.tgz` (so Argo CD needs no access to
the chart repo; `helm dependency update` refreshes it) and aliased `collabora`.
**Off by default.** Turning it on takes three values together:

```yaml
collabora:
  enabled: true
  collabora:
    server_name: meridian.example            # the web Route host
    extra_params: >-
      --o:ssl.enable=false --o:ssl.termination=true
      --o:net.frame_ancestors=https://meridian.example
      --o:net.post_allow.host[0]=<pod network CIDR>
      --o:storage.wopi.alias_groups[@mode]=groups
      --o:admin_console.enable=false
api:
  documents:
    collabora:
      url: http://collabora:9980             # MERIDIAN_COLLABORA_URL
web:
  collaboraUpstream: http://collabora:9980   # COLLABORA_UPSTREAM (nginx)
```

The chart **refuses to render** if `web.collaboraUpstream` or
`api.documents.collabora.url` is set while `collabora.enabled` is false: the web
tier's nginx resolves the upstream at start and would not start without the
`collabora` Service.

What renders when enabled:

- Deployment/Service/ConfigMap/Secret `collabora` (port 9980) from the upstream
  chart: 1 replica (its HPA is off), image `docker.io/collabora/code:26.04.6.1.1`,
  requests 1 CPU / 2Gi, limits 4 CPU / 6Gi, aliasgroup `http://meridian-api:8080`
  (the only WOPI host it accepts). This holds only with
  `--o:storage.wopi.alias_groups[@mode]=groups` in `extra_params`. Keep it in
  any override: the default mode, `first`, ignores the groups and trusts the
  first host that connects.
- `post_allow` limits Collabora's REST endpoints (convert-to, …) to client
  IPs. Browser traffic all arrives from the web pods, so it can't separate
  browsers. The web image's nginx allow-list (meridian `deploy/nginx.conf`)
  is what keeps those endpoints off the public Route.
- restricted-v2 securityContext (no UID set, all capabilities dropped, no
  privilege escalation, RuntimeDefault seccomp). Without capabilities Collabora
  isolates document processes with landlock instead of a chroot jail.
  `/opt/cool/child-roots` and `/opt/cool/cache` are emptyDirs (the image owns
  them as UID 1001).
- ServiceAccount `meridian-collabora` with no token mounted.
- NetworkPolicy `meridian-collabora`: ingress on 9980 only from the web and api
  pods; egress only to the api pods on 8080 and to cluster DNS.
- The admin Secret holds placeholder values: the admin console (and with it
  `/cool/getMetrics`) is turned off in `extra_params`.

The api Deployment gets:

| Env | Value |
| --- | --- |
| `MERIDIAN_DOCUMENTS_FILE_ROOT` | `<persistence.mountPath>/documents` (whenever persistence is on) |
| `MERIDIAN_COLLABORA_URL` | `api.documents.collabora.url` (only when set) |
| `MERIDIAN_COLLABORA_PUBLIC_BASE` | `api.documents.collabora.publicBase` (empty = same origin) |
| `MERIDIAN_WOPI_SRC_BASE` | `api.documents.collabora.wopiSrcBase` (`http://meridian-api:8080`) |

The web Deployment gets `COLLABORA_UPSTREAM` = `web.collaboraUpstream` (only
when set). Meridian web images that don't proxy Collabora ignore it; newer ones
default it to an address that needs no DNS (Collabora's paths answer 502).

## Local validation

```sh
helm lint .
helm template meridian . --namespace meridian
# with an environment's values, then schema-check the output:
helm template meridian . --namespace meridian -f <env values.yaml> | kubeconform -summary -ignore-missing-schemas
```

## Images

Built and pushed by CI (in the Meridian source repo on GHES) to
`containers.adt-git01.adt.network/adrian-thearle/meridian-api` and
`.../meridian-web`, tagged with the short commit SHA. Set the tags per
environment in `adt-grc-gitops:environments/meridian/<env>/values.yaml`.
