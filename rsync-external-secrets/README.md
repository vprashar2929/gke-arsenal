# rsync-external-secrets

Force selected External Secrets Operator (ESO) `ExternalSecret` resources to
re-sync with their backing secret store, then wait until each target reports a
new successful refresh. This is useful after creating a new GCP Secret Manager
version.

ESO re-sync is requested by setting `force-sync=<unix-timestamp>` on the
`ExternalSecret`. The script never prints Secret values.

Run the examples below from the `rsync-external-secrets/` directory.

## What it does

1. Reads target rows from a TSV input.
2. Validates every context and selected `ExternalSecret` before making changes.
3. Adds or replaces the `force-sync` annotation with one run-wide timestamp.
4. Waits until every target has a new `status.refreshTime` and `Ready=True`.

ESO refreshes the backing Kubernetes Secrets. A pod that gets a Secret via environment
variables will not see the new value until it is recreated. Follow this tool
with [`restart-deployment`](../restart-deployment/) for those workloads.

## Requirements

- `kubectl` — authenticated against every context referenced in the input.
- `awk` and `sort`.
- An ESO controller running in each target cluster.

## Configuration

Pass `--config-file=FILE` to read this tool's settings. The adjacent
[config.yml](./config.yml) contains synthetic examples. CLI flags override YAML.
See [configuration](../README.md#configuration) for requirements and path resolution.

```sh
./rsync-external-secrets.sh --config-file=./config.yml
```

## Usage

```
./rsync-external-secrets.sh --input path/to/targets.tsv [--yes]
```

| Flag | Required | Default | Description |
| --- | :---: | --- | --- |
| `--config-file=FILE` | no | — | Read YAML settings; CLI flags override them. |
| `--input FILE` | yes | — | TSV target configuration. |
| `--wait-timeout DURATION` | no | `2m` | Maximum wait per target. Whole-number `s`, `m`, or `h` duration. |
| `--poll-interval SECONDS` | no | `5` | Status polling interval. |
| `--yes` | no | plan only | Required to annotate and wait for refresh. |
| `--dry-run` | no | — | Explicit alias for plan-only behavior. |
| `-h, --help` | no | — | Show usage. |

## Input format

Each non-comment row is tab-separated. Two-column rows select every
`ExternalSecret` in that `(context, namespace)`. Three-column rows select one
specific resource and are the recommended production form.

```text
# context<TAB>namespace<TAB>external-secret (optional)
example-cluster    app-prod    orders-api
example-cluster    app-prod    orders-worker

# Two columns select every ExternalSecret in the namespace.
example-test-cluster    app-test
```

The displayed spacing illustrates the columns; actual config files must use tabs.
See [`rsync-external-secrets.example.tsv`](./rsync-external-secrets.example.tsv) for namespace-wide targets and
[`rsync-external-secrets.targets.example.tsv`](./rsync-external-secrets.targets.example.tsv) for individually selected targets.
All examples are synthetic; copy and replace their values before use.

## Examples

Prepare a local list and inspect its plan:

```sh
cp ./rsync-external-secrets.targets.example.tsv ./targets.tsv
# Edit ./targets.tsv for your context, namespace, and ExternalSecrets.
./rsync-external-secrets.sh --input ./targets.tsv
```

Force refresh and wait for the targets:

```sh
./rsync-external-secrets.sh --input ./targets.tsv --yes
```

For pods consuming Secrets as environment variables, restart the relevant
Deployments after refresh succeeds. ExternalSecret and Deployment names need
not match; supply the deployment names explicitly:

```sh
../restart-deployment/restart-deployment.sh \
  --context example-cluster --namespace app-prod \
  --deployment orders-api --deployment orders-worker --yes
```

Both tools require `--yes` to change cluster resources.

## Exit codes

- `0` — plan-only run, or every selected ExternalSecret refreshed and reached
  `Ready=True`.
- non-zero — invalid input, missing context/resource, annotation failure, or a
  target did not refresh before `--wait-timeout`.
