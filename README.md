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

All tools accept `--config-file=FILE` (or `--config-file FILE`). Each
script reads its own section from the YAML file. CLI flags override YAML;
input and output paths in YAML resolve relative to that file. See the
[config reference](./examples/sample/README.md) for supported fields.

Templates in [`examples/sample/`](./examples/sample/) contain synthetic values.
Copy the inputs you need and edit them for your environment:

```sh
mkdir -p local/example
cp examples/sample/config.yaml local/example/config.yaml
cp examples/sample/*.tsv local/example/
# Edit the YAML and required TSV inputs before running.
./restart-deployment/restart-deployment.sh \
  --config-file=./local/example/config.yaml
```

Include only the sections needed for your workload. YAML contains resource
identifiers and secret references; supply credential values through the tools'
authentication mechanisms. The `local/` directory is ignored by Git and can
hold configuration and generated output. Arbitrary output paths are not
automatically ignored; see [`.gitignore`](./.gitignore).

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
[`CLAUDE.md`](./CLAUDE.md), also available as [`AGENTS.md`](./AGENTS.md).
