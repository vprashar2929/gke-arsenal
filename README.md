# gke-arsenal

Standalone Bash utilities for operational tasks on GCP and GKE.
Run each tool directly with `./<tool-name>/<tool-name>.sh`.

## Tools

| Tool | Purpose |
| ---- | ------- |
| [`rsync-external-secrets`](./rsync-external-secrets/) | Force ESO re-sync of ExternalSecrets |
| [`restart-deployment`](./restart-deployment/) | Rollout-restart named Deployments (one-off) |
| [`reset-redis-cache`](./reset-redis-cache/) | Flush Cloud Memorystore Redis cache |
| [`fetch-bucket-reports`](./fetch-bucket-reports/) | Download GCS objects by UID |
| [`move-financial-report-files`](./move-financial-report-files/) | Sync files between supplied GCS prefixes |
| [`fetch-kafka-messages`](./fetch-kafka-messages/) | Consume Kafka topic messages via Kafka UI |
| [`fix-istio-cross-cluster-san`](./fix-istio-cross-cluster-san/) | Check malformed Istio SAN matchers and restart istiod |

## Requirements

Bash 3.2 or newer and the command-line tools listed in each tool's README.
Authenticate the relevant cloud or Kubernetes CLI before use. There is
no package installation or build step.

YAML configuration requires [Mike Farah yq v4](https://github.com/mikefarah/yq)
and `jq`. Direct flags and `--help` work without the YAML dependencies.

## Configuration

Each tool contains a sample `config.yml` beside its script and README.
Pass a config with `--config-file=FILE` (or `--config-file FILE`). Files are
loaded only when explicitly supplied. CLI flags override YAML.

The committed configs contain synthetic values. For local settings, copy the
sample to `config.local.yml` in the same folder; that filename is ignored by Git:

```sh
cp restart-deployment/config.yml restart-deployment/config.local.yml
# Edit the YAML and required TSV inputs before running.
./restart-deployment/restart-deployment.sh \
  --config-file=./restart-deployment/config.local.yml
```

Each config contains top-level fields for one tool. Field names match CLI
flags with hyphens replaced by underscores, except `deployments`, which is a
list of names for the repeatable `--deployment` flag. Supplying that flag on
the CLI replaces the YAML list. Each tool's README documents its flags.

YAML `input` and `output` paths resolve relative to the config file. CLI paths
resolve relative to the working directory. Example TSV inputs sit beside the
scripts; copy them to a local `.tsv` filename before editing.

Use one YAML mapping document. Unknown fields, duplicate keys, empty values,
nulls, and control characters are rejected before cloud commands run. Scalars
accept strings or numbers; paths must be strings. Lists contain strings, and
booleans use YAML `true` or `false`. Values are read as data and are never
executed as shell code or expanded as environment variables.

YAML contains resource identifiers and secret references; supply credential
values through the tools' authentication mechanisms. The `local/` directory is
ignored by Git and can hold configuration and generated output. Arbitrary
output paths are not automatically ignored; see [`.gitignore`](./.gitignore).

CLI flags also work on their own:

```sh
./restart-deployment/restart-deployment.sh \
  --context example-cluster --namespace example-namespace \
  --deployment example-api
```

The restart, Redis, and Kafka tools accept an existing `--context` or all three
of `--project`, `--cluster`, and `--region` (a region or zone). They require
explicit resource names and do not fetch cluster credentials automatically.
Other tools take their targets from their own flags or TSV inputs.

For tools that derive a context, CLI `--project`, `--cluster`, or `--region`
selects derivation instead of a saved YAML context. Supply all three values
in YAML or on the CLI.

## Execution

Mutating operations require `--yes` on the command line. Run without it to
review the plan first. Each tool's README describes its read-only checks and
output. For example, Kafka opens a local port-forward to inspect metadata.

## Contributing

Keep changes focused on one tool or a shared helper. Update the relevant
README when flags or behavior change, and use synthetic values in examples.
For bug reports, include the command, tool versions, and redacted error output.

Use tab indentation, `name() {` functions, and a `main "$@"` entry point.
Keep argument parsing in `parse_args()` and operations in `main()`.
Shared shell helpers live in [`hack/`](./hack/).

Check Bash syntax, lint, and formatting before submitting a change:

```sh
for script in */*.sh hack/*.bash; do bash -n "$script"; done
shellcheck -x -P SCRIPTDIR */*.sh hack/*.bash
shfmt -ln bash -i 0 -d */*.sh hack/*.bash
```

Repository conventions for contributors and coding agents are in
[`AGENTS.md`](./AGENTS.md).
