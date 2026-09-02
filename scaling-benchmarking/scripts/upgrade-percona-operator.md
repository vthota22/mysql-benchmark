# Upgrading Percona Server MySQL Operator

Guide for upgrading the Percona Server MySQL Operator on a Kubernetes cluster (e.g. DigitalOcean managed MySQL).

## Prerequisites

- `kubectl` configured with cluster access
- Target operator version (e.g. `1.2.0`)
- Namespace where the operator runs (usually `percona`)

```bash
export KUBECONFIG=/path/to/your/kubeconfig
export NAMESPACE=percona
export OPERATOR_VERSION=1.2.0
```

## Check current versions

```bash
# Operator deployment image (actual running version)
kubectl -n "${NAMESPACE}" get deploy percona-server-mysql-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# Cluster CR version (intended version on each MySQL cluster)
kubectl -n "${NAMESPACE}" get ps \
  -o custom-columns='NAME:.metadata.name,CR_VERSION:.spec.crVersion,STATUS:.status.state'

# Operator pod status
kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=percona-server-mysql-operator
```

Operator image tag and `spec.crVersion` on the `PerconaServerMySQL` CR should match.

## Upgrade procedure

**Do NOT use an image-only patch.** Operator 1.2.0+ requires additional environment variables (`POD_NAME`, `POD_NAMESPACE`, `MAX_CONCURRENT_RECONCILES`) and updated RBAC for `perconaservermysqlclustersets`. Patching only the image causes `CrashLoopBackOff`.

### Step 1 — Update CRDs

```bash
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/percona/percona-server-mysql-operator/v${OPERATOR_VERSION}/deploy/crd.yaml"
```

### Step 2 — Update RBAC

On DigitalOcean managed clusters, RBAC may be owned by `dbaas-percona-controller`. Use `--force-conflicts` if apply fails with a conflict:

```bash
kubectl apply --server-side --force-conflicts -f \
  "https://raw.githubusercontent.com/percona/percona-server-mysql-operator/v${OPERATOR_VERSION}/deploy/rbac.yaml" \
  -n "${NAMESPACE}"
```

### Step 3 — Update operator deployment (full manifest)

```bash
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/percona/percona-server-mysql-operator/v${OPERATOR_VERSION}/deploy/operator.yaml" \
  -n "${NAMESPACE}"
```

### Step 4 — Update cluster CR (if needed)

If the `PerconaServerMySQL` CR `crVersion` does not match:

```bash
kubectl -n "${NAMESPACE}" patch ps <cluster-name> --type merge -p "{
  \"spec\": {
    \"crVersion\": \"${OPERATOR_VERSION}\"
  }
}"
```

### Step 5 — Verify

```bash
kubectl -n "${NAMESPACE}" rollout status deployment/percona-server-mysql-operator

kubectl -n "${NAMESPACE}" get deploy percona-server-mysql-operator \
  -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}'

kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=percona-server-mysql-operator

kubectl -n "${NAMESPACE}" logs deploy/percona-server-mysql-operator --tail=20
```

Confirm required env vars are present (1.2.0+):

```bash
kubectl -n "${NAMESPACE}" get deploy percona-server-mysql-operator \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}'
```

Expected includes: `POD_NAME`, `POD_NAMESPACE`, `MAX_CONCURRENT_RECONCILES`.

## What NOT to do

### Image-only patch (insufficient)

```bash
# This is NOT enough for 1.1.0 -> 1.2.0
kubectl -n percona patch deployment percona-server-mysql-operator --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"percona/percona-server-mysql-operator:1.2.0"}
]'
```

Symptom: operator pod enters `CrashLoopBackOff` with:

```
ERROR: unable to create controller PerconaServerMySQLClusterSet
       POD_NAMESPACE or POD_NAME is not set
```

### Wrong container name with `kubectl set image`

The container is named `manager`, not `percona-server-mysql-operator`:

```bash
# Wrong
kubectl -n percona set image deployment/percona-server-mysql-operator \
  percona-server-mysql-operator=percona/percona-server-mysql-operator:1.2.0

# Correct container name (still insufficient without full operator.yaml)
kubectl -n percona set image deployment/percona-server-mysql-operator \
  manager=percona/percona-server-mysql-operator:1.2.0
```

Even with the correct container name, use the full `operator.yaml` from the target release.

## DigitalOcean managed clusters

These clusters are managed by `dbaas-percona-controller`. Manual `kubectl` upgrades can work, but DigitalOcean may reconcile or overwrite operator changes during platform upgrades.

For production:

- Prefer DigitalOcean's official operator upgrade path (API/console) when available
- Document manual changes if you patch via `kubectl`
- Expect RBAC conflicts with `dbaas-percona-controller`; use `--force-conflicts` on RBAC apply

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `CrashLoopBackOff` after image change | Missing `POD_NAME` / `POD_NAMESPACE` env vars | Apply full `operator.yaml` |
| `perconaservermysqlclustersets ... forbidden` in logs | RBAC not updated for 1.2.0 | Apply `rbac.yaml` with `--force-conflicts` |
| Operator image still `1.1.0` after patch | Patch didn't apply or was reverted | Re-apply full manifest; check DO reconciliation |
| `ReconcileError` on PS CR | Transient during upgrade / pod exec failures | Check operator logs; usually resolves once operator is healthy |

## References

- [Percona operator upgrade (manual)](https://github.com/percona/k8sps-docs/blob/main/docs/update-crd-manual.md)
- [Percona operator upgrade (Helm)](https://github.com/percona/k8sps-docs/blob/main/docs/update-crd-helm.md)
- [Operator manifests (v1.2.0)](https://github.com/percona/percona-server-mysql-operator/tree/v1.2.0/deploy)
