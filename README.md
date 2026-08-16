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

# ghcr.io pull secret (fleet-standard name)
oc create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<pat> -n meridian
```

The CNPG `<clusterName>-app` secret is created automatically by the operator.

## Local validation

```sh
helm lint .
helm template meridian . --namespace meridian
```

## Images

Built and pushed by CI to `ghcr.io/thearlie82/meridian-api` and
`ghcr.io/thearlie82/meridian-web`, tagged with the short commit SHA. Set the
tags per environment in `adt-grc-gitops:environments/meridian/<env>/values.yaml`.
