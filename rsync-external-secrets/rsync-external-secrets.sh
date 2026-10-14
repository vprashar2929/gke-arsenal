#!/usr/bin/env bash
#
# Force an External Secrets Operator (ESO) re-sync for the ExternalSecrets
# selected in a TSV input. A config row can name one ExternalSecret for a
# narrowly scoped refresh, or omit that column to select every ExternalSecret
# in the namespace.

set -eu -o pipefail

# constants
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_NAME SCRIPT_DIR

# config
declare INPUT=""
declare WAIT_TIMEOUT="2m"
declare POLL_INTERVAL="5"
declare EXECUTE="false"
declare DRY_RUN="false"

# shellcheck source=../hack/utils.bash
source "$SCRIPT_DIR/../hack/utils.bash"

# shellcheck source=../hack/config.bash
source "$SCRIPT_DIR/../hack/config.bash"

usage() {
	cat <<USAGE
${SCRIPT_NAME}: trigger an ESO force-sync for ExternalSecrets selected in a TSV
                config, then wait for each selected resource to refresh.

Required flags:
  --input FILE             TSV input. Each non-comment line is either:
                      context<TAB>namespace
                    to select every ExternalSecret in that namespace, or:
                      context<TAB>namespace<TAB>external-secret
                    to select exactly one ExternalSecret.

Optional flags:
  --config-file=FILE       Read YAML settings; CLI flags override them.
                           Requires Mike Farah yq v4 and jq.
  --wait-timeout DURATION  Maximum wait per ExternalSecret. Default: 2m
  --poll-interval SECONDS  Refresh-status polling interval. Default: 5
  --yes                    Annotate the selected ExternalSecrets. Without
                           this flag, only the validated plan is printed.
  --dry-run                Alias for the default plan-only behavior.
  -h, --help               Show this help.

Examples:
  Plan a targeted refresh:
    ./${SCRIPT_NAME} --input ../examples/sample/rsync-external-secrets.targets.example.tsv

  Force the refresh and wait for every target to reconcile:
    ./${SCRIPT_NAME} --input local-targets.tsv --yes

  Force every ExternalSecret in one namespace (two-column config):
    ./${SCRIPT_NAME} --input ../examples/sample/rsync-external-secrets.example.tsv --yes

Notes:
  - The script never reads or prints Secret values.
  - Use a three-column config for production changes whenever possible.
  - A successful refresh only updates the Kubernetes Secret. Pods that consume
    it as environment variables still require a rollout restart.
USAGE
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found in PATH: $1"
}

validate_name() {
	local label="$1"
	local value="$2"
	[[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] ||
		die "$label contains invalid characters: $value"
}

duration_to_seconds() {
	local duration="$1"
	local amount unit

	amount="${duration%?}"
	amount=$((10#$amount))
	unit="${duration: -1}"
	case "$unit" in
	s) printf '%s\n' "$amount" ;;
	m) printf '%s\n' "$((amount * 60))" ;;
	h) printf '%s\n' "$((amount * 3600))" ;;
	esac
}

get_refresh_time() {
	kubectl --context "$1" -n "$2" get externalsecret "$3" \
		-o jsonpath='{.status.refreshTime}' 2>/dev/null
}

get_ready_status() {
	kubectl --context "$1" -n "$2" get externalsecret "$3" \
		-o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true
}

wait_for_refresh() {
	local ctx="$1"
	local ns="$2"
	local external_secret="$3"
	local previous_refresh="$4"
	local timeout_seconds="$5"
	local deadline refresh ready

	deadline=$((SECONDS + timeout_seconds))
	while ((SECONDS < deadline)); do
		refresh="$(get_refresh_time "$ctx" "$ns" "$external_secret" || true)"
		ready="$(get_ready_status "$ctx" "$ns" "$external_secret")"

		if [[ -n "$refresh" && "$refresh" != "$previous_refresh" && "$ready" == "True" ]]; then
			ok "refreshed: $ctx / $ns / $external_secret (refreshTime=$refresh)"
			return 0
		fi

		sleep "$POLL_INTERVAL"
	done

	fail "ExternalSecret did not report a new Ready refresh within $WAIT_TIMEOUT: $ctx / $ns / $external_secret"
	return 1
}

parse_args() {
	load_config "rsync_external_secrets" "$@"
	set -- ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--input)
			INPUT="${2:?missing value for --input}"
			shift 2
			;;
		--wait-timeout)
			WAIT_TIMEOUT="${2:?missing value for --wait-timeout}"
			shift 2
			;;
		--poll-interval)
			POLL_INTERVAL="${2:?missing value for --poll-interval}"
			shift 2
			;;
		--yes)
			EXECUTE="true"
			shift
			;;
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage >&2
			die "unknown argument: $1"
			;;
		esac
	done
}

main() {
	local tmp_root clean_input targets_file failures_file ctx ns external_secret
	local namespace_targets listed_secret previous_refresh

	parse_args "$@"

	[[ -n "$INPUT" ]] || die "--input is required"
	[[ -f "$INPUT" ]] || die "input file not found: $INPUT"
	[[ "$POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "--poll-interval must be a positive integer"
	[[ "$DRY_RUN" != "true" || "$EXECUTE" != "true" ]] || die "--dry-run and --yes cannot be used together"
	[[ "$WAIT_TIMEOUT" =~ ^[0-9]+(s|m|h)$ ]] ||
		die "--wait-timeout must use a whole-number s, m, or h duration (for example: 90s, 2m, 1h)"

	WAIT_SECONDS="$(duration_to_seconds "$WAIT_TIMEOUT")"
	((WAIT_SECONDS > 0)) || die "--wait-timeout must be greater than zero"

	require_cmd kubectl
	require_cmd awk
	require_cmd sort

	tmp_root="${TMPDIR:-/tmp}"
	workdir="$(mktemp -d "${tmp_root%/}/rsync-eso.XXXXXX")"
	trap 'rm -rf "$workdir"' EXIT

	clean_input="$workdir/input.tsv"
	targets_file="$workdir/targets.tsv"
	failures_file="$workdir/failures.txt"
	: >"$failures_file"

	awk -F '\t' '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  {
    if (NF < 2 || NF > 3) {
      printf("input line %d has %d columns, expected 2 or 3 (context<TAB>namespace[<TAB>external-secret])\n", NR, NF) > "/dev/stderr"
      exit 1
    }
    for (i = 1; i <= NF; i++) {
      sub(/^[[:space:]]+/, "", $i); sub(/[[:space:]]+$/, "", $i)
    }
    if (length($1) == 0 || length($2) == 0 || (NF == 3 && length($3) == 0)) {
      printf("input line %d has an empty required column\n", NR) > "/dev/stderr"
      exit 1
    }
    if (NF == 2) print $1 "\t" $2 "\t"
    else print $1 "\t" $2 "\t" $3
  }
' "$INPUT" >"$clean_input"

	[[ -s "$clean_input" ]] || die "no usable rows in input: $INPUT"

	while IFS=$'\t' read -r ctx ns external_secret; do
		[[ "$ctx" != *[[:cntrl:]]* ]] || die "context must not contain control characters"
		validate_name "namespace" "$ns"
		[[ -z "$external_secret" ]] || validate_name "external-secret" "$external_secret"

		if ! kubectl config get-contexts -o name | grep -Fx -- "$ctx" >/dev/null; then
			die "kubectl context not found: $ctx"
		fi

		if [[ -n "$external_secret" ]]; then
			if ! kubectl --context "$ctx" -n "$ns" get externalsecret "$external_secret" >/dev/null 2>&1; then
				die "ExternalSecret not found: context=$ctx namespace=$ns external-secret=$external_secret"
			fi
			printf '%s\t%s\t%s\n' "$ctx" "$ns" "$external_secret" >>"$targets_file"
			continue
		fi

		namespace_targets="$(kubectl --context "$ctx" -n "$ns" get externalsecret -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
		if [[ -z "$namespace_targets" ]]; then
			warn "no ExternalSecrets found: context=$ctx namespace=$ns"
			continue
		fi
		while IFS= read -r listed_secret; do
			[[ -n "$listed_secret" ]] || continue
			printf '%s\t%s\t%s\n' "$ctx" "$ns" "$listed_secret" >>"$targets_file"
		done <<<"$namespace_targets"
	done <"$clean_input"

	[[ -s "$targets_file" ]] || die "the config selected no ExternalSecrets"
	sort -u "$targets_file" -o "$targets_file"

	header "ESO force-sync plan"
	info "targets=$(wc -l <"$targets_file" | tr -d ' ')  wait_timeout=$WAIT_TIMEOUT  poll_interval=${POLL_INTERVAL}s"
	printf '%s\t%s\t%s\n' "context" "namespace" "external-secret"
	cat "$targets_file"
	echo

	if [[ "$EXECUTE" != "true" ]]; then
		info "Plan only. Add --yes to annotate the selected ExternalSecrets and wait for refresh."
		exit 0
	fi

	SYNC_TS="$(date +%s)"
	header "ESO force-sync (ts=$SYNC_TS)"

	while IFS=$'\t' read -r ctx ns external_secret; do
		if ! previous_refresh="$(get_refresh_time "$ctx" "$ns" "$external_secret")"; then
			fail "could not read refresh status: $ctx / $ns / $external_secret" 2>&1 | tee -a "$failures_file" >&2
			continue
		fi
		info "Requesting refresh: $ctx / $ns / $external_secret"

		if ! run kubectl --context "$ctx" -n "$ns" annotate externalsecret "$external_secret" "force-sync=$SYNC_TS" --overwrite; then
			fail "annotate failed: $ctx / $ns / $external_secret" 2>&1 | tee -a "$failures_file" >&2
			continue
		fi

		if ! wait_for_refresh "$ctx" "$ns" "$external_secret" "$previous_refresh" "$WAIT_SECONDS"; then
			printf '%s / %s / %s\n' "$ctx" "$ns" "$external_secret" >>"$failures_file"
		fi
	done <"$targets_file"

	if [[ -s "$failures_file" ]]; then
		err "Completed with failures:"
		cat "$failures_file" >&2
		die "one or more operations failed"
	fi

	ok "All selected ExternalSecrets reported a new Ready refresh. Pods using these values through environment variables still need a rollout restart."
}

main "$@"
