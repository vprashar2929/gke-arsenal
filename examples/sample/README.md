# YAML configuration and sample inputs

The files here contain synthetic values. Copy what you need, edit it for your
environment, and keep local settings and output in `local/` or outside the repo.

## Usage

From the repository root, copy the sample files and edit their targets:

```sh
mkdir -p local/example
cp examples/sample/config.yaml local/example/config.yaml
cp examples/sample/*.tsv local/example/
# Edit the YAML and any TSV inputs.
./restart-deployment/restart-deployment.sh \
  --config-file=./local/example/config.yaml
```

`--config-file FILE` also works. Include only the script sections you need.
For example, a restart configuration can contain:

```yaml
restart_deployment:
  context: example-cluster
  namespace: example-namespace
  deployments:
    - example-api
```

## Fields

Each script reads its own section. Field names match CLI flags with hyphens
replaced by underscores, except the deployment list described below. Tool
READMEs explain what each setting does.

| YAML section | Supported fields |
| --- | --- |
| `restart_deployment` | `context`, `namespace`, `project`, `cluster`, `region`, `deployments` (list), `timeout`, `since`, `tail` |
| `reset_redis_cache` | `context`, `namespace`, `project`, `cluster`, `region`, `secret_project`, `secret_name`, `mode`, `db` |
| `fetch_kafka_messages` | `context`, `project`, `cluster`, `region`, `kafka_namespace`, `kafka_service`, `kafka_cluster`, `topic`, `partition`, `limit`, `seek`, `offset`, `local_port`, `remote_port`, `timeout`, `output`, `summary` (boolean) |
| `fix_istio_cross_cluster_san` | `context`, `namespace`, `apps_context`, `pod`, `rollout_timeout`, `resync_wait`, `probe_host`, `probe_ip`, `probe_path` |
| `rsync_external_secrets` | `input` (TSV path), `wait_timeout`, `poll_interval` |
| `fetch_bucket_reports` | `input` (UID TSV path), `gcs_path`, `output` (directory path) |
| `move_financial_report_files` | `source`, `dest`, `summarize` (boolean), `show_rsync_plan` (boolean) |

`deployments` maps to the repeatable `--deployment` flag. Supplying that flag
on the CLI replaces the YAML list.

The External Secrets and bucket download tools take their TSV data through
`input` in YAML or `--input FILE` on the CLI.

## Requirements and validation

YAML use requires [Mike Farah yq v4](https://github.com/mikefarah/yq) and `jq`.
Direct flags and `--help` do not require the YAML parser. Scripts support Bash
3.2 and newer.

Use one YAML mapping document. Unknown sections or fields, duplicate keys,
empty values, nulls, and control characters are rejected before cloud commands
run. Scalars accept strings or numbers; paths must be strings. Lists contain
strings and booleans use YAML `true` or `false`. Values are passed as arguments;
they are never executed as shell code or expanded as environment variables.

CLI flags override YAML. For tools that derive a GKE context, CLI `--project`,
`--cluster`, or `--region` selects derivation instead of the YAML context;
supply all three derivation values in YAML or on the CLI.

## Paths and execution

YAML `input` and `output` paths resolve relative to the config file. CLI paths
resolve relative to the working directory. The sample output paths point to
`local/runs/` when the file is kept here or copied to `local/example/`; adjust
them if you place the file elsewhere.

Execution choices (`--yes`, `--dry-run`, `--delete-source`, `--escalate`) stay
on the command line. Mutating tools print a plan without `--yes`. See each
tool's README for the read-only checks performed before execution.
