#!/usr/bin/env bash
#
# Flush Redis using a connection string from GCP Secret Manager.
#
# Runs redis-cli from a short-lived pod in the supplied cluster and namespace.

set -eu -o pipefail

# constants
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_NAME SCRIPT_DIR

# config
declare PROJECT=""
declare CLUSTER=""
declare NAMESPACE=""
declare REGION=""
declare CONTEXT=""
declare CONTEXT_EXPLICIT="false"
declare SECRET_NAME=""
declare SECRET_PROJECT=""
declare MODE="flushall"
declare REDIS_DB="0"
declare DB_EXPLICIT="false"
declare EXECUTE="false"

declare REDIS_HOST=""
declare REDIS_PORT="6379"
declare REDIS_PASSWORD=""

# shellcheck source=../hack/utils.bash
source "$SCRIPT_DIR/../hack/utils.bash"

# shellcheck source=../hack/config.bash
source "$SCRIPT_DIR/../hack/config.bash"

usage() {
	cat <<USAGE
${SCRIPT_NAME}: flush Redis using a connection string from GCP Secret Manager.

Required flags:
  --namespace NS           Namespace for the temporary redis-cli pod.
  --secret-name NAME       Secret containing host:port,password=... configuration.
  --context CTX            Existing kubectl context; alternatively provide all
                           of --project PROJECT --cluster NAME --region LOCATION.
  --secret-project PROJECT  Project holding the secret. May be omitted when
                           --project is supplied (then uses that project).

Optional flags:
  --config-file=FILE       Read YAML settings; CLI flags override them.
                           Requires Mike Farah yq v4 and jq.
  --project PROJECT        GCP project for deriving a context and secret lookup.
  --cluster NAME           GKE cluster for deriving a context.
  --region LOCATION        Region or zone for deriving a context.
  --mode MODE              flushall (default) or flushdb.
  --db N                   Database for flushdb. Overrides defaultDatabase in
                           the secret; otherwise that value or 0 is used.
  --yes                    Read the secret, create a temporary pod, and flush.
                           Without it, print the plan without reading credentials
                           or creating a pod.
  -h, --help               Show this help.

Examples:
  ./${SCRIPT_NAME} --context example-cluster --namespace app-prod \\
    --secret-project example-project --secret-name example-redis-config
  ./${SCRIPT_NAME} --context example-cluster --namespace app-prod \\
    --secret-project example-project --secret-name example-redis-config \\
    --mode flushdb --db 0 --yes

Notes:
  - Supports a single non-TLS endpoint and a comma-separated password option.
  - Never prints the Redis password or connection string.
  - Uses a short-lived redis:7-alpine pod; FLUSHALL removes all databases.
USAGE
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found in PATH: $1"
}

validate_k8s_name() {
	local label="$1"
	local value="$2"
	[[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] ||
		die "$label contains invalid characters: $value"
}

parse_redis_configuration() {
	local conn_str="$1"
	local part key value
	local parts=()

	REDIS_HOST=""
	REDIS_PORT="6379"
	REDIS_PASSWORD=""

	IFS=',' read -r -a parts <<<"$conn_str"
	for part in "${parts[@]}"; do
		part="${part#"${part%%[![:space:]]*}"}"
		part="${part%"${part##*[![:space:]]}"}"
		[[ -n "$part" ]] || continue

		if [[ "$part" == *=* ]]; then
			key="${part%%=*}"
			value="${part#*=}"
			key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
			case "$key" in
			password) REDIS_PASSWORD="$value" ;;
			defaultdatabase) [[ "$DB_EXPLICIT" == "true" ]] || REDIS_DB="$value" ;;
			ssl) [[ "$value" == [Ff][Aa][Ll][Ss][Ee] ]] || die "TLS Redis connections are not supported" ;;
			esac
			continue
		fi

		[[ -z "$REDIS_HOST" ]] || die "multiple Redis endpoints are not supported"
		[[ "$part" != *"://"* ]] || die "Redis URI connections are not supported"
		if [[ "$part" == *:* ]]; then
			REDIS_HOST="${part%:*}"
			REDIS_PORT="${part##*:}"
		else
			REDIS_HOST="$part"
		fi
	done

	[[ -n "$REDIS_HOST" ]] || die "could not parse Redis host from secret $SECRET_NAME"
	[[ -n "$REDIS_PASSWORD" ]] || die "could not parse Redis password from secret $SECRET_NAME"
}

fetch_redis_configuration() {
	local secret_project="${SECRET_PROJECT:-$PROJECT}"
	local conn_str

	conn_str="$(
		gcloud secrets versions access latest \
			--secret="$SECRET_NAME" \
			--project="$secret_project"
	)" || die "failed to read secret $SECRET_NAME from project $secret_project"

	parse_redis_configuration "$conn_str"
}

redis_cli() {
	local pod="$1"
	shift
	# Send the password on stdin so it is absent from command arguments/logs.
	printf '%s\n' "$REDIS_PASSWORD" | kubectl --context "$CONTEXT" -n "$NAMESPACE" exec -i "$pod" -- \
		sh -c 'IFS= read -r REDISCLI_AUTH; export REDISCLI_AUTH; exec redis-cli "$@"' sh \
		-h "$REDIS_HOST" -p "$REDIS_PORT" --no-auth-warning "$@"
}

redis_dbsize() {
	local pod="$1" raw
	raw="$(redis_cli "$pod" -n "$REDIS_DB" --raw DBSIZE)" || die "failed to read Redis DBSIZE"
	raw="${raw//$'\r'/}"
	[[ "$raw" =~ ^[0-9]+$ ]] || die "Redis DBSIZE did not return a non-negative integer"
	printf '%s' "$raw"
}

create_probe_pod() {
	local pod="$1"
	kubectl --context "$CONTEXT" -n "$NAMESPACE" run "$pod" \
		--image=redis:7-alpine \
		--restart=Never \
		--command -- sleep 300
	kubectl --context "$CONTEXT" -n "$NAMESPACE" wait \
		--for=condition=Ready "pod/$pod" \
		--timeout=120s
}

delete_probe_pod() {
	local pod="$1"
	kubectl --context "$CONTEXT" -n "$NAMESPACE" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
}

parse_args() {
	load_config "reset_redis_cache" "$@"
	set -- ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--project)
			PROJECT="${2:?missing value for --project}"
			shift 2
			;;
		--cluster)
			CLUSTER="${2:?missing value for --cluster}"
			shift 2
			;;
		--namespace)
			NAMESPACE="${2:?missing value for --namespace}"
			shift 2
			;;
		--region)
			REGION="${2:?missing value for --region}"
			shift 2
			;;
		--context)
			CONTEXT="${2:?missing value for --context}"
			CONTEXT_EXPLICIT="true"
			shift 2
			;;
		--secret-name)
			SECRET_NAME="${2:?missing value for --secret-name}"
			shift 2
			;;
		--secret-project)
			SECRET_PROJECT="${2:?missing value for --secret-project}"
			shift 2
			;;
		--mode)
			MODE="${2:?missing value for --mode}"
			shift 2
			;;
		--db)
			REDIS_DB="${2:?missing value for --db}"
			DB_EXPLICIT="true"
			shift 2
			;;
		--yes)
			EXECUTE="true"
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
	local before_dbsize flush_result after_dbsize

	parse_args "$@"

	case "$MODE" in
	flushall | flushdb) ;;
	*) die "unknown --mode: $MODE (expected flushall or flushdb)" ;;
	esac

	[[ "$REDIS_DB" =~ ^[0-9]+$ ]] || die "--db must be a non-negative integer"

	if [[ -z "$CONTEXT" ]]; then
		[[ -n "$PROJECT" ]] || die "provide --context or --project, --cluster, and --region"
		[[ -n "$CLUSTER" ]] || die "--cluster is required when deriving a context"
		[[ -n "$REGION" ]] || die "--region is required when deriving a context"
		CONTEXT="gke_${PROJECT}_${REGION}_${CLUSTER}"
	fi

	[[ -n "$NAMESPACE" ]] || die "--namespace is required"
	[[ -n "$SECRET_NAME" ]] || die "--secret-name is required"
	[[ -n "${SECRET_PROJECT:-$PROJECT}" ]] || die "provide --secret-project or --project for secret lookup"

	validate_k8s_name "namespace" "$NAMESPACE"
	[[ "$CONTEXT" != *[[:cntrl:]]* ]] || die "context must not contain control characters"

	require_cmd kubectl
	require_cmd gcloud

	header "Redis cache reset plan"
	info "mode=$MODE"
	info "context=$CONTEXT"
	info "namespace=$NAMESPACE"
	info "secret=$SECRET_NAME (project=${SECRET_PROJECT:-$PROJECT})"
	echo

	if ! kubectl config get-contexts -o name | grep -Fx -- "$CONTEXT" >/dev/null; then
		if [[ "$CONTEXT_EXPLICIT" == "true" ]]; then
			die "kubectl context not found: $CONTEXT

Fetch credentials with gcloud container clusters get-credentials, then retry."
		fi
		die "kubectl context not found: $CONTEXT

Fetch credentials first, e.g.:
  gcloud container clusters get-credentials $CLUSTER \\
    --region $REGION \\
    --project $PROJECT \\
    --dns-endpoint"
	fi

	if [[ "$EXECUTE" != "true" ]]; then
		info "Plan only. Add --yes to read the secret, create a temporary pod, and run redis-cli $MODE."
		exit 0
	fi

	fetch_redis_configuration
	[[ "$REDIS_DB" =~ ^[0-9]+$ ]] || die "Redis database index must be a non-negative integer"

	info "redis endpoint=$REDIS_HOST:$REDIS_PORT"
	if [[ "$MODE" == "flushdb" ]]; then
		info "flush target=database $REDIS_DB"
	fi

	probe_pod="redis-cache-reset-$(date +%s)-$$"
	trap 'delete_probe_pod "$probe_pod"' EXIT
	create_probe_pod "$probe_pod"

	before_dbsize="$(redis_dbsize "$probe_pod")"
	info "current DBSIZE=$before_dbsize"

	header "Flushing Redis cache"
	warn "Running redis-cli $MODE on $REDIS_HOST:$REDIS_PORT"

	if [[ "$MODE" == "flushall" ]]; then
		flush_result="$(redis_cli "$probe_pod" FLUSHALL SYNC)"
	else
		flush_result="$(redis_cli "$probe_pod" -n "$REDIS_DB" FLUSHDB SYNC)"
	fi

	printf '%s\n' "$flush_result" | awk '{print "  " $0}'
	if ! grep -Fxq OK <<<"$flush_result"; then
		die "redis-cli $MODE did not return OK: $flush_result"
	fi

	after_dbsize="$(redis_dbsize "$probe_pod")"
	info "DBSIZE after flush=$after_dbsize"

	if [[ "$after_dbsize" != "0" ]]; then
		warn "DBSIZE is already $after_dbsize — running apps may have re-cached entries immediately."
	fi

	ok "Redis cache flush completed (before=$before_dbsize after=$after_dbsize)."
}

main "$@"
