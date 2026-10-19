# AGENTS.md

Repository conventions for contributors and coding agents.

## Repository purpose

A collection of standalone, ad-hoc operational scripts for GCP and GKE tasks
(Istio multicluster fixes, ESO re-syncs, deployment restarts, Redis cache resets,
GCS file operations, and Kafka inspection). Each tool has its own directory;
there is no build system or package installation. Dependencies are command-line
tools listed in each README.
Run scripts directly with `./<tool>/<tool>.sh`.

## Repository layout

```
.
├── AGENTS.md                           # repository conventions
├── README.md                           # usage and configuration
├── .gitignore                          # keeps operational data out of git
├── hack/
│   └── utils.bash                      # shared logging, command, and YAML helpers
├── local/                              # ignored configuration and output
├── <tool-name>/
│   ├── <tool-name>.sh                  # the script (same name as the directory)
│   ├── config.yml                     # synthetic sample settings
│   ├── README.md                       # per-tool docs: what/when/how, flags, exit codes
│   └── *.example.tsv                  # optional synthetic input templates
```

Targets must come from explicit user input: CLI flags, a supplied YAML config,
or the TSV input referenced by that config.
Never infer a target from an environment label or the current context.
For the restart, Redis, and Kafka tools, supply `--context` or all three of
`--project`, `--cluster`, and `--region` (region or zone). Namespace and resource
names must also be supplied explicitly.

Every tool supports `--config-file=FILE` (or `--config-file FILE`); explicit
CLI flags override YAML. Never store execution flags or secret values in YAML.
Each config file contains top-level fields for one tool, without a tool-name
section. Config files are loaded only when explicitly supplied.
See the root README's Configuration section for precedence and relative-path
rules, and each tool's README for its supported settings.

Each tool's own README.md is authoritative for flags, semantics, and examples
— read it before modifying that tool.

### Operational data (do not commit)

Live cluster configs and generated artifacts stay **local** (see root `.gitignore`):

- `local/` — local configs, target inputs, and generated data.
- `config.local.yml` — local settings beside a tool's committed sample config.
- `*.tsv` except `example.tsv` and `*.example.tsv` — ESO target lists and
  bucket download inputs.
- `fetch-bucket-reports/downloads/` — downloaded GCS files.
- `fetch-kafka-messages/messages/` — fetched Kafka message JSON (may contain PII).

Keep local settings in `config.local.yml`, under `local/`, or outside the
repository.
Committed `config.yml` and example TSV files must contain synthetic values only;
copy them to ignored local filenames before editing.

## How the tools fit together

Most tools are independent. `rsync-external-secrets/` refreshes selected
ExternalSecrets. Follow it with `restart-deployment/` for workloads consuming
Secrets through environment variables.

`move-financial-report-files/` syncs objects between specified GCS prefixes;
`fetch-bucket-reports/` downloads objects by UID from GCS;
`fetch-kafka-messages/` inspects specified Kafka topics through Kafka UI.

`fix-istio-cross-cluster-san/` is standalone (multicluster 503 / SAN-matcher bug).

Other standalone tools:

- `restart-deployment/` — rollout-restart one or more Deployments by name.
- `reset-redis-cache/` — flush Cloud Memorystore Redis via an ephemeral
  `redis-cli` pod and the specified GCP Secret Manager secret.

## Script conventions (follow these when adding or editing)

Every script in this repo follows the same shape — match it for consistency:

- `#!/usr/bin/env bash` and `set -eu -o pipefail`.
- Use tabs for Bash indentation and default `shfmt` formatting. Leave embedded
  jq, awk, and Python text in its own language's indentation.
- Declare functions as `name() {`, with the opening brace on the same line.
  Use lowercase names with underscores and `local` for function arguments
  and scratch variables. Parsed configuration and state shared with cleanup
  traps remain global.
- Keep constants and mutable configuration at the top of the script. Resolve
  paths before marking them read-only, so command failures are not masked by
  `declare`:
  ```bash
  SCRIPT_NAME="$(basename "$0")"
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  declare -r SCRIPT_NAME SCRIPT_DIR

  # config
  declare INPUT=""

  # shellcheck source=../hack/utils.bash
  source "$SCRIPT_DIR/../hack/utils.bash"
  ```
- Define helpers first, then `parse_args()` and `main()`. Put config loading
  and the flag loop in `parse_args()`, validation and operational steps in
  `main()`, and end the script with `main "$@"`. Keep state needed by an `EXIT`
  trap available until the process exits.
- Long-form flags only (`--config-file=FILE`, `--input FILE`, `--yes`, etc.), parsed in a
  `while [[ $# -gt 0 ]]; do case "$1" in … esac done` loop. Use
  `${2:?missing value for --flag}` for required values.
- A `usage()` heredoc that documents flags and includes runnable examples;
  printed on `-h|--help` and on unknown args.
- A local `require_cmd <name>` helper that calls `die` from `hack/utils.bash` when
  a binary is missing. `kubectl`, `gcloud`, `jq`, and `awk` are the
  typical requirements.
- Mutating operations are gated behind `--yes` (or `--dry-run` for the
  opposite default) — running without it must print the plan and exit 0.
- Temporary work goes under `mktemp -d "${TMPDIR:-/tmp}/<tool>.XXXXXX"` with
  `trap 'rm -rf "$workdir"' EXIT`.
- TSV configs: tab-separated, `#` comments and blank lines ignored, validated
  with an `awk` preprocessor that exits non-zero on malformed rows.
- Exit non-zero on any failure. Use `die "..."` from `hack/utils.bash` to print and
  exit; never silently `exit 1`.

### Shared helpers (use them; don't reinvent)

`die <msg>` (exit 1), `info`, `ok`, `warn`, `fail`, `skip`, `err`, `header`,
`line`, `info_run`, `run <cmd...>` (echoes then executes), `wait_until`,
`condition_check`, `is_fn`, `load_config`, `config_value`.
Parse CLI flags first. If a config file was supplied, call
`load_config "$config_file" <allowed field names...>` and fill values omitted
on the CLI using `config_value <field> [scalar|path|bool|list]`. Apply built-in
defaults afterwards. Keep field names and variable assignments in each script;
the shared helper does not know tool names or parse command-line arguments.
Log helpers use the Kepler glyphs and colors, with diagnostics on stderr.
`run` prints the command, then executes it with quoted arguments and stdout
intact. Source `hack/utils.bash` for shared logging, command, and YAML helpers.
Keep message JSON output on stdout; never log credentials.

## Validation

To validate changes:

- Lint: `shellcheck -x -P SCRIPTDIR */*.sh hack/*.bash`.
- Format check: `shfmt -ln bash -i 0 -d */*.sh hack/*.bash`.
- Syntax: `bash -n <tool>/<tool>.sh` and `bash -n hack/utils.bash`.
- Dry-run: every script supports a no-mutation mode (omit `--yes` or pass `--dry-run`) — use this as the smoke test against real clusters.
- Each tool's `README.md` includes usage examples.

## Safety expectations

These scripts are pointed at real GCP projects and GKE clusters. Keep these
invariants when editing:

- Never log credentials or secret values. Kafka message payloads may contain
  PII — never commit `--output` files.
- Anything that calls `kubectl rollout restart`, `kubectl annotate`,
  `kubectl exec`, or similar mutating commands must be
  reachable only via `--yes` (or after explicit confirmation in the script's
  flow). The default execution path is always a dry run / diagnostic.
- Cluster contexts and resource names come from user input — validate them
  before passing them on. Check contexts with `kubectl config get-contexts`.
