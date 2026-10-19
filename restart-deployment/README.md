# restart-deployment

Rollout-restart one or more Kubernetes Deployments, wait for readiness, and
print recent application-container logs. Each deployment is restarted once.

Run the examples below from the `restart-deployment/` directory.

## Requirements

- `kubectl` authenticated against the supplied context.

## Configuration

Pass `--config-file=FILE` to read this tool's settings. The adjacent
[config.yml](./config.yml) contains synthetic examples. CLI flags override YAML.
See [configuration](../README.md#configuration) for requirements and path resolution.

```sh
./restart-deployment.sh --config-file=./config.yml
```

## Usage

```sh
./restart-deployment.sh --context CTX --namespace NS --deployment NAME [flags]
```

Instead of `--context`, supply all of `--project`, `--cluster`, and `--region`
(a region or zone). The derived context is
`gke_<project>_<region-or-zone>_<cluster>` and must already exist in kubeconfig.

| Flag | Required | Default | Description |
| --- | :---: | --- | --- |
| `--config-file=FILE` | no | — | Read YAML settings; CLI flags override them. |
| `--deployment NAME` | yes | — | Repeat for multiple deployments. |
| `--namespace NS` | yes | — | Namespace containing the deployments. |
| `--context CTX` | alternative | — | Existing kubeconfig context. |
| `--project PROJECT` | alternative | — | GCP project for context derivation. |
| `--cluster NAME` | alternative | — | GKE cluster for context derivation. |
| `--region LOCATION` | alternative | — | GKE region or zone for context derivation. |
| `--timeout DURATION` | no | `10m` | Rollout wait timeout. |
| `--since DURATION` | no | `10m` | Log lookback after rollout. |
| `--tail N` | no | `40` | Log lines per application container. |
| `--yes` | no | plan only | Execute restarts. |
| `-h, --help` | no | — | Show usage. |

## Examples

Validate the target and print the plan:

```sh
./restart-deployment.sh \
  --context example-cluster --namespace app-prod --deployment orders-api
```

Restart two workloads:

```sh
./restart-deployment.sh \
  --context example-cluster --namespace app-prod \
  --deployment orders-api --deployment orders-worker --yes
```

Derive the context for a GKE cluster:

```sh
./restart-deployment.sh \
  --project example-project --region us-central1 --cluster example-cluster \
  --namespace app-prod --deployment orders-api
```

## Exit codes

- `0` — plan printed, or all selected deployments became ready.
- non-zero — invalid arguments, missing context/deployment, or rollout failure.

The script does not modify Secrets. Default runs only read context/deployment
metadata. Logs retrieved with `--yes` may contain application data; keep them local.
