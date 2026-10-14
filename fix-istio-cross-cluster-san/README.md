# fix-istio-cross-cluster-san

Check Istio sidecars for SPIFFE SAN matchers with an empty trust domain, then
restart istiod and check again. Use this when Envoy reports SAN certificate
verification failures and the affected sidecar has matchers such as:

```json
{ "exact": "spiffe:///ns/example-namespace/sa/default" }
```

The empty component after `spiffe://` is where the trust domain belongs.
For a mesh using `cluster.local`, the corresponding identity starts with
`spiffe://cluster.local/ns/`. Check the mesh trust domain and CA configuration
when investigating this condition.

Run the examples below from the `fix-istio-cross-cluster-san/` directory.

## Behavior

Without `--yes`, the script validates contexts and prints the plan. It does
not inspect pod configuration or restart anything.

With `--yes`, it reads the SAN matchers from a sidecar, restarts istiod in
`--context`, waits for the rollout and resync delay, then reads the matchers
again. **It restarts istiod even if the initial matchers are valid.**
Verification uses the same inspection pod. After a workload restart, it selects
a Running sidecar pod owned by that same Deployment.

If verification fails and `--escalate` is set, it also restarts the inspected
pod's owning Deployment and istiod in `--apps-context`, when supplied. An
optional HTTP probe runs before and after the restart.

## Requirements

- `kubectl` authenticated against every supplied context, and `awk`.
- A Running pod with an `istio-proxy` sidecar in the selected namespace.
- Permission to execute commands in the sidecar and restart the selected
  Deployments when using `--yes`.
- For HTTP probes, `curl` available inside the sidecar.

## Configuration

Pass `--config-file=FILE` to read the `fix_istio_cross_cluster_san` section.
CLI flags override YAML. See the [config reference](../examples/sample/README.md)
for fields, requirements, and path resolution.

```sh
./fix-istio-cross-cluster-san.sh --config-file=../examples/sample/config.yaml
```

## Usage

```sh
./fix-istio-cross-cluster-san.sh --context CTX --namespace NS [flags]
```

| Flag | Required | Default | Description |
| --- | :---: | --- | --- |
| `--context CTX` | yes | — | Failing cluster; its istiod is restarted. |
| `--namespace NS` | yes | — | Namespace containing a sidecar to inspect. |
| `--config-file=FILE` | no | — | Read YAML settings; CLI flags override them. |
| `--pod NAME` | no | auto | Pod to inspect; otherwise selects the first Running pod with an `istio-proxy` container. |
| `--apps-context CTX` | no | — | Peer cluster; its istiod is restarted during escalation. |
| `--rollout-timeout DURATION` | no | `3m` | Timeout for each Deployment rollout. |
| `--resync-wait SECONDS` | no | `20` | Delay after rollout before checking sidecars. |
| `--probe-host HOST` | no | — | HTTP probe Host header; requires `--probe-ip`. |
| `--probe-ip IP` | no | — | Ingress IP for the HTTP probe; requires `--probe-host`. |
| `--probe-path PATH` | no | `/` | HTTP probe path. |
| `--escalate` | no | off | Restart the workload and, when supplied, peer istiod after a failed check. |
| `--yes` | no | plan only | Inspect sidecars and perform restarts. |
| `-h, --help` | no | — | Show usage. |

Supply `--probe-host` and `--probe-ip` together. `--probe-path` is optional.

## Examples

Print the plan:

```sh
./fix-istio-cross-cluster-san.sh \
  --context example-cluster --namespace example-namespace
```

Restart istiod and probe through the ingress:

```sh
./fix-istio-cross-cluster-san.sh \
  --context example-cluster --namespace example-namespace \
  --probe-host gateway.example.com --probe-ip 203.0.113.10 \
  --probe-path /health --yes
```

Allow workload and peer control-plane restarts if verification fails:

```sh
./fix-istio-cross-cluster-san.sh \
  --context example-cluster --namespace example-namespace \
  --apps-context example-peer-cluster --escalate --yes
```

## Exit codes and limits

- `0` — plan printed, or SAN matchers read successfully with no empty trust
  domain after the restart. An HTTP 503 probe result fails verification;
  other unexpected HTTP codes produce a warning and may still exit `0`.
- Non-zero — invalid input, missing context or inspection pod, command
  failure, or failed verification after the requested restarts.

The script checks SAN matcher strings in one selected sidecar. A successful
check does not establish that every cross-cluster route works. Restarts do not
change mesh configuration; their availability impact depends on replicas,
readiness, and rollout strategy.
