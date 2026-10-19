# reset-redis-cache

Flush Redis using a connection string from GCP Secret Manager. The script
runs `redis-cli` in a temporary pod in the namespace you specify.

Run the examples below from the `reset-redis-cache/` directory.

## Requirements

- `kubectl` authenticated against the supplied context.
- `gcloud` with permission to access the supplied secret version.
- The temporary pod must be able to reach Redis and pull `redis:7-alpine`.

## Configuration

Pass `--config-file=FILE` to read this tool's settings. The adjacent
[config.yml](./config.yml) contains synthetic examples. CLI flags override YAML.
See [configuration](../README.md#configuration) for requirements and path resolution.

```sh
./reset-redis-cache.sh --config-file=./config.yml
```

## Usage

```sh
./reset-redis-cache.sh \
  --context CTX --namespace NS --secret-project PROJECT --secret-name NAME [flags]
```

Instead of `--context`, supply all of `--project`, `--cluster`, and `--region`
(a region or zone). The derived context is
`gke_<project>_<region-or-zone>_<cluster>` and must already exist in kubeconfig.
`--secret-project` defaults to `--project` when that flag is supplied.

| Flag | Required | Default | Description |
| --- | :---: | --- | --- |
| `--config-file=FILE` | no | — | Read YAML settings; CLI flags override them. |
| `--namespace NS` | yes | — | Namespace for the temporary pod. |
| `--secret-name NAME` | yes | — | Secret containing the connection string. |
| `--secret-project PROJECT` | conditional | `--project` | Project holding the secret. |
| `--context CTX` | alternative | — | Existing kubeconfig context. |
| `--project PROJECT` | alternative | — | GCP project for context derivation and secret lookup. |
| `--cluster NAME` | alternative | — | GKE cluster for context derivation. |
| `--region LOCATION` | alternative | — | GKE region or zone for context derivation. |
| `--mode MODE` | no | `flushall` | `flushall` or `flushdb`. |
| `--db N` | no | secret's `defaultDatabase`, otherwise `0` | Database for `flushdb`; explicit flag takes precedence. |
| `--yes` | no | plan only | Read credentials, create a pod, and flush. |
| `-h, --help` | no | — | Show usage. |

The supported connection-string shape is a single non-TLS endpoint with
comma-separated options: `redis.example.com:6379,password=...,defaultDatabase=0`.
Multi-endpoint, TLS, and URI connection strings are not supported.

## Examples

Print the plan without reading the secret or creating a pod:

```sh
./reset-redis-cache.sh \
  --context example-cluster --namespace app-prod \
  --secret-project example-project --secret-name example-redis-config
```

Flush only database 0:

```sh
./reset-redis-cache.sh \
  --context example-cluster --namespace app-prod \
  --secret-project example-project --secret-name example-redis-config \
  --mode flushdb --db 0 --yes
```

## Exit codes

- `0` — plan printed, or flush returned `OK`.
- non-zero — invalid input, missing context, failed secret access, or pod/Redis failure.

## Safety

- Without `--yes`, the script does not read the secret or create a pod.
- The password and full connection string are never printed. The password is
  passed over stdin to the temporary pod rather than in command arguments.
- `FLUSHALL` removes every key in every database. `FLUSHDB` affects the selected database.
- Running applications may repopulate Redis immediately after a successful flush.
