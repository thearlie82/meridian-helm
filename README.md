# meridian-helm

Helm chart for **Meridian** — an open re-implementation of Microsoft Dynamics 365
F&O (Supply Chain Management) and CE (Project Operations). Deploys to RHEL
OpenShift and is driven by Argo CD from
[`adt-grc-gitops`](https://github.com/thearlie82/adt-grc-gitops).

## Layout

Umbrella chart wrapping two subcharts, mirroring the fleet convention
(`aras2dynamicsf-o_helm`):

```
Chart.yaml                 umbrella (api + web deps)
values.yaml                dev-safe defaults
templates/
  namespace.yaml           the meridian namespace
  cnpg-cluster.yaml        CloudNativePG Cluster CR (Postgres)
  _helpers.tpl / NOTES.txt
charts/api/                Rust axum API (port 8080, /healthz, OpenAPI at /swagger-ui)
charts/web/                React SPA behind nginx (port 8080, proxies /api/ to the api Service)
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

## Web extra hosts

`web.route.extraHosts` (default `[]`) is a list of `{ name, host }`. Each entry
renders an additional Route `<web fullname>-<name>` for `host`, with the same
path, target port and edge TLS as the main Route (one Service, several hostnames).
TLS certs for extra hosts are applied out-of-band, like the main Route. An empty
list renders only the single main Route.

## Local validation

```sh
helm lint .
helm template meridian . --namespace meridian
```

## Images

Built and pushed by CI (in the Meridian source repo on GHES) to
`containers.adt-git01.adt.network/adrian-thearle/meridian-api` and
`.../meridian-web`, tagged with the short commit SHA. Set the tags per
environment in `adt-grc-gitops:environments/meridian/<env>/values.yaml`.
