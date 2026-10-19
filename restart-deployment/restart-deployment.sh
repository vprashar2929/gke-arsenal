#!/usr/bin/env bash
#
# Rollout-restart one or more Kubernetes Deployments in a GKE cluster.
# The target context and namespace are supplied by the caller.

set -eu -o pipefail

# constants
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_NAME SCRIPT_DIR

# config
declare -a DEPLOYMENTS=()
declare PROJECT=""
declare CLUSTER=""
declare NAMESPACE=""
declare REGION=""
declare CONTEXT=""
declare CONTEXT_EXPLICIT="false"
declare TIMEOUT=""
declare SINCE=""
declare TAIL=""
declare EXECUTE="false"

# shellcheck source=../hack/utils.bash
source "$SCRIPT_DIR/../hack/utils.bash"

usage() {
	cat <<USAGE
${SCRIPT_NAME}: rollout-restart one or more Deployments.

Required flags:
  --deployment NAME        Deployment to restart. Repeatable.
  --namespace NS           Kubernetes namespace.
  --context CTX            Existing kubectl context; alternatively provide all
                           of --project PROJECT --cluster NAME --region LOCATION.

Optional flags:
  --config-file=FILE       Read YAML settings; CLI flags override them.
                           Requires Mike Farah yq v4 and jq.
  --project PROJECT        GCP project for deriving a GKE context.
  --cluster NAME           GKE cluster for deriving a context.
  --region LOCATION        Region or zone for deriving a context.
  --timeout DURATION       Rollout wait timeout. Default: 10m
  --since DURATION         Log lookback after rollout. Default: 10m
  --tail N                 Log lines per container. Default: 40
  --yes                    Execute restarts. Without it, print the plan.
  -h, --help               Show this help.

Examples:
  ./${SCRIPT_NAME} --context example-cluster --namespace app-prod \\
    --deployment orders-api
  ./${SCRIPT_NAME} --project example-project --cluster example-cluster \\
    --region us-central1 --namespace app-prod \\
    --deployment orders-api --deployment orders-worker --yes

The derived context is gke_<project>_<region-or-zone>_<cluster>.
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

parse_args() {
	local config_file="" configured_deployments deployment

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--config-file)
			[[ -z "$config_file" ]] || die "--config-file may only be supplied once"
			config_file="${2:?missing value for --config-file}"
			shift 2
			;;
		--config-file=*)
			[[ -z "$config_file" ]] || die "--config-file may only be supplied once"
			config_file="${1#*=}"
			[[ -n "$config_file" ]] || die "--config-file requires a file path"
			shift
			;;
		--deployment)
			DEPLOYMENTS+=("${2:?missing value for --deployment}")
			shift 2
			;;
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
			shift 2
			;;
		--timeout)
			TIMEOUT="${2:?missing value for --timeout}"
			shift 2
			;;
		--since)
			SINCE="${2:?missing value for --since}"
			shift 2
			;;
		--tail)
			TAIL="${2:?missing value for --tail}"
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

	if [[ -n "$config_file" ]]; then
		load_config "$config_file" \
			context namespace project cluster region deployments \
			timeout since tail
		# CLI derivation fields take precedence over a saved context.
		if [[ -z "$PROJECT$CLUSTER$REGION" ]]; then
			CONTEXT="${CONTEXT:-$(config_value context)}"
		fi
		NAMESPACE="${NAMESPACE:-$(config_value namespace)}"
		PROJECT="${PROJECT:-$(config_value project)}"
		CLUSTER="${CLUSTER:-$(config_value cluster)}"
		REGION="${REGION:-$(config_value region)}"
		if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
			configured_deployments="$(config_value deployments list)"
			if [[ -n "$configured_deployments" ]]; then
				while IFS= read -r deployment; do
					DEPLOYMENTS+=("$deployment")
				done <<<"$configured_deployments"
			fi
		fi
		TIMEOUT="${TIMEOUT:-$(config_value timeout)}"
		SINCE="${SINCE:-$(config_value since)}"
		TAIL="${TAIL:-$(config_value tail)}"
	fi
	if [[ -n "$CONTEXT" ]]; then CONTEXT_EXPLICIT="true"; fi

	TIMEOUT="${TIMEOUT:-10m}"
	SINCE="${SINCE:-10m}"
	TAIL="${TAIL:-40}"
}

main() {
	local -a unique_deployments
	local seen_deployments deploy tmp_root failures_file skip_regex app_containers container_name

	parse_args "$@"

	[[ ${#DEPLOYMENTS[@]} -gt 0 ]] || die "--deployment is required (repeatable)"
	[[ "$TAIL" =~ ^[0-9]+$ ]] || die "--tail must be a non-negative integer"

	if [[ -z "$CONTEXT" ]]; then
		[[ -n "$PROJECT" ]] || die "provide --context or --project, --cluster, and --region"
		[[ -n "$CLUSTER" ]] || die "--cluster is required when deriving a context"
		[[ -n "$REGION" ]] || die "--region is required when deriving a context"
		CONTEXT="gke_${PROJECT}_${REGION}_${CLUSTER}"
	fi

	[[ -n "$NAMESPACE" ]] || die "--namespace is required"

	validate_k8s_name "namespace" "$NAMESPACE"
	[[ "$CONTEXT" != *[[:cntrl:]]* ]] || die "context must not contain control characters"

	unique_deployments=()
	seen_deployments="|"
	for deploy in "${DEPLOYMENTS[@]}"; do
		validate_k8s_name "deployment" "$deploy"
		if [[ "$seen_deployments" != *"|$deploy|"* ]]; then
			unique_deployments+=("$deploy")
			seen_deployments+="$deploy|"
		fi
	done
	DEPLOYMENTS=("${unique_deployments[@]}")

	require_cmd kubectl

	header "Deployment restart plan"
	info "deployments=${DEPLOYMENTS[*]}"
	info "context=$CONTEXT"
	info "namespace=$NAMESPACE"
	info "timeout=$TIMEOUT  logs_since=$SINCE  log_tail=$TAIL"
	echo

	# Consume all context output: grep -q can close the pipe early and make
	# kubectl fail with SIGPIPE under pipefail, even when the context exists.
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

	for deploy in "${DEPLOYMENTS[@]}"; do
		if ! kubectl --context "$CONTEXT" -n "$NAMESPACE" get deploy "$deploy" >/dev/null 2>&1; then
			die "deployment not found: context=$CONTEXT namespace=$NAMESPACE deployment=$deploy"
		fi
	done

	if [[ "$EXECUTE" != "true" ]]; then
		info "Dry run only. Add --yes to rollout-restart: ${DEPLOYMENTS[*]}"
		exit 0
	fi

	tmp_root="${TMPDIR:-/tmp}"
	workdir="$(mktemp -d "${tmp_root%/}/restart-deployment.XXXXXX")"
	trap 'rm -rf "$workdir"' EXIT
	failures_file="$workdir/failures.txt"
	: >"$failures_file"

	skip_regex='^(istio-proxy|istio-init|linkerd-proxy|cloud-sql-proxy|cloudsql-proxy|prometheus-to-sd|fluentbit|filebeat|vault-agent|vault-agent-init)$'

	header "Starting rollout restarts"

	for deploy in "${DEPLOYMENTS[@]}"; do
		line 80 heavy
		info "Restarting: context=$CONTEXT namespace=$NAMESPACE deployment=$deploy"

		if ! kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout restart "deploy/$deploy"; then
			fail "rollout restart failed: $CONTEXT / $NAMESPACE / $deploy" 2>&1 | tee -a "$failures_file" >&2
			continue
		fi

		if ! kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout status "deploy/$deploy" --timeout="$TIMEOUT"; then
			fail "rollout did not become ready: $CONTEXT / $NAMESPACE / $deploy" 2>&1 | tee -a "$failures_file" >&2
			info "Recent pod state:"
			kubectl --context "$CONTEXT" -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=$deploy" 2>/dev/null || true
			kubectl --context "$CONTEXT" -n "$NAMESPACE" get pods 2>/dev/null | grep -E "(^NAME|$deploy)" || true
			continue
		fi

		info "Latest application logs for deploy/$deploy, since=$SINCE, tail=$TAIL:"
		app_containers="$(
			kubectl --context "$CONTEXT" -n "$NAMESPACE" get deploy "$deploy" \
				-o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' |
				grep -Ev "$skip_regex" ||
				true
		)"

		if [[ -z "$app_containers" ]]; then
			echo "  No non-sidecar application containers found for deploy/$deploy."
		else
			while IFS= read -r container_name; do
				[[ -n "$container_name" ]] || continue
				echo "  --- container: $container_name ---"
				kubectl --context "$CONTEXT" -n "$NAMESPACE" logs "deploy/$deploy" \
					-c "$container_name" \
					--since="$SINCE" \
					--tail="$TAIL" \
					--prefix=true 2>&1 |
					sed 's/^/  /' || true
			done <<<"$app_containers"
		fi
		echo
	done

	line 80 heavy
	if [[ -s "$failures_file" ]]; then
		err "Completed with failures:"
		cat "$failures_file" >&2
		die "one or more operations failed"
	fi

	ok "All selected deployments restarted and reached rollout ready state."
}

main "$@"
