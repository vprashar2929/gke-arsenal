#!/usr/bin/env bash
#
# Check for SPIFFE SAN matchers with an empty trust domain (spiffe:///ns/).
# With --yes, restart istiod and check again. Optional escalation restarts
# the inspected workload and the peer control plane. See README.md for scope.

set -eu -o pipefail

# constants
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_NAME SCRIPT_DIR

# config
declare CONTEXT=""
declare APPS_CONTEXT=""
declare NAMESPACE=""
declare POD=""
declare ROLLOUT_TIMEOUT="3m"
declare RESYNC_WAIT="20"
declare PROBE_HOST=""
declare PROBE_IP=""
declare PROBE_PATH="/"
declare ESCALATE="false"
declare EXECUTE="false"

# shellcheck source=../hack/utils.bash
source "$SCRIPT_DIR/../hack/utils.bash"

# shellcheck source=../hack/config.bash
source "$SCRIPT_DIR/../hack/config.bash"

usage() {
	cat <<USAGE
${SCRIPT_NAME}: check malformed Istio SAN matchers and restart istiod.

Required flags:
  --context CTX            Context of the failing cluster; its istiod is restarted.
  --namespace NS           Namespace containing a sidecar-injected pod to inspect.

Optional flags:
  --config-file=FILE       Read YAML settings; CLI flags override them.
                           Requires Mike Farah yq v4 and jq.
  --pod NAME               Specific pod to inspect. Default: first Running
                           pod in --namespace that has an 'istio-proxy'
                           container.
  --apps-context CTX       Peer cluster context. Used only with
                           --escalate.
  --rollout-timeout DUR    Wait for istiod rollout to be Ready. Default: 3m.
  --resync-wait SECONDS    Wait after istiod becomes Ready, to let sidecars
                           pull fresh xDS. Default: 20.
  --probe-host HOST        Host header for the HTTP probe.
  --probe-ip IP            Ingress LoadBalancer IP for the HTTP probe.
  --probe-path PATH        URL path for the HTTP probe. Default: /
                           --probe-host and --probe-ip must be supplied together.
  --escalate               If verification fails after the istiod restart,
                           also: rollout-restart the inspected
                           pod's owning Deployment, then (if --apps-context
                           is set) rollout-restart istiod in that cluster.
  --yes                    Required to perform any restart. Without it, the
                           script prints the plan without executing in pods.
  -h, --help               Show this help.

With --yes, istiod is restarted even if the initial SAN matchers are valid.

Examples:
  Print the plan (no changes):
    ./${SCRIPT_NAME} \\
      --context example-edge-test \\
      --namespace app-test

  Restart the failing cluster's istiod and probe through the ingress:
    ./${SCRIPT_NAME} \\
      --context example-edge-test \\
      --namespace app-test \\
      --probe-host  gateway.example.com \\
      --probe-ip    203.0.113.10 \\
      --probe-path  /health \\
      --yes

  Also restart the workload and peer istiod if verification fails:
    ./${SCRIPT_NAME} \\
      --context      example-edge-test \\
      --apps-context example-apps-test \\
      --namespace    app-test \\
      --escalate \\
      --yes
USAGE
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found in PATH: $1"
}

find_sidecar_pod() {
	local ctx="$1" ns="$2" deployment="${3:-}"
	local pods pod owner
	# Read the full list to avoid SIGPIPE under pipefail.
	# Istio can run istio-proxy as a native sidecar (init container with
	# restartPolicy: Always), so we scan both .spec.containers and
	# .spec.initContainers.
	pods="$(kubectl --context "$ctx" -n "$ns" get pods \
		-o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{","}{end}{"\t"}{range .spec.initContainers[*]}{.name}{","}{end}{"\n"}{end}' \
		2>/dev/null |
		awk -F '\t' '($2 $3) ~ /(^|,)istio-proxy(,|$)/ { print $1 }')" || return 1
	while IFS= read -r pod; do
		[[ -n "$pod" ]] || continue
		if [[ -n "$deployment" ]]; then
			owner="$(owning_deployment_of_pod "$ctx" "$ns" "$pod")" || continue
			[[ "$owner" == "$deployment" ]] || continue
		fi
		printf '%s\n' "$pod"
		return 0
	done <<<"$pods"
	return 1
}

dump_unique_sans() {
	local ctx="$1" ns="$2" pod="$3"
	kubectl --context "$ctx" -n "$ns" exec "$pod" -c istio-proxy -- \
		pilot-agent request GET config_dump 2>/dev/null |
		grep -oE '"exact": *"spiffe:[^"]*"' |
		sort -u
}

count_malformed_sans() {
	grep -cE '"spiffe:///ns/' <<<"${1:-}" || true
}

probe_http() {
	local ctx="$1" ns="$2" pod="$3" host="$4" ip="$5" path="$6"
	kubectl --context "$ctx" -n "$ns" exec "$pod" -c istio-proxy -- \
		curl -s -o /dev/null -w "%{http_code}" -m 10 \
		-H "Host: ${host}" "http://${ip}${path}" 2>/dev/null || echo "000"
}

owning_deployment_of_pod() {
	local ctx="$1" ns="$2" pod="$3"
	local rs
	rs="$(kubectl --context "$ctx" -n "$ns" get pod "$pod" \
		-o jsonpath='{.metadata.ownerReferences[?(@.kind=="ReplicaSet")].name}' 2>/dev/null)" || return 1
	[[ -n "$rs" ]] || return 1
	kubectl --context "$ctx" -n "$ns" get rs "$rs" \
		-o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null
}

verify_and_probe() {
	local label="$1"
	header "Post-fix: $label SAN matchers"

	local after_sans
	if ! after_sans="$(dump_unique_sans "$CONTEXT" "$NAMESPACE" "$POD")" || [[ -z "$after_sans" ]]; then
		fail "could not read SPIFFE SAN matchers from pod $POD after $label"
		return 1
	fi
	printf '   %s\n' "${after_sans//$'\n'/$'\n'   }"

	local after_bad
	after_bad="$(count_malformed_sans "$after_sans")"
	if [[ "$after_bad" -gt 0 ]]; then
		fail "Still $after_bad malformed SAN matcher(s) after $label"
		return 1
	fi
	ok "SAN matchers are well-formed (every entry has a trust domain)."

	if [[ "$do_probe" == "true" ]]; then
		local after_code
		after_code="$(probe_http "$CONTEXT" "$NAMESPACE" "$POD" "$PROBE_HOST" "$PROBE_IP" "$PROBE_PATH")"
		info "GET ${PROBE_PATH}  (Host: $PROBE_HOST)  ->  HTTP $after_code"
		case "$after_code" in
		2* | 3* | 401 | 403) ok "HTTP probe returned $after_code." ;;
		503)
			fail "HTTP probe still returns 503; inspect Envoy and upstream logs."
			return 1
			;;
		*) warn "Probe returned HTTP $after_code — inspect manually." ;;
		esac
	fi
	return 0
}

parse_args() {
	load_config "fix_istio_cross_cluster_san" "$@"
	set -- ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"}

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--context)
			CONTEXT="${2:?missing value for --context}"
			shift 2
			;;
		--apps-context)
			APPS_CONTEXT="${2:?missing value for --apps-context}"
			shift 2
			;;
		--namespace)
			NAMESPACE="${2:?missing value for --namespace}"
			shift 2
			;;
		--pod)
			POD="${2:?missing value for --pod}"
			shift 2
			;;
		--rollout-timeout)
			ROLLOUT_TIMEOUT="${2:?missing value for --rollout-timeout}"
			shift 2
			;;
		--resync-wait)
			RESYNC_WAIT="${2:?missing value for --resync-wait}"
			shift 2
			;;
		--probe-host)
			PROBE_HOST="${2:?missing value for --probe-host}"
			shift 2
			;;
		--probe-ip)
			PROBE_IP="${2:?missing value for --probe-ip}"
			shift 2
			;;
		--probe-path)
			PROBE_PATH="${2:?missing value for --probe-path}"
			shift 2
			;;
		--escalate)
			ESCALATE="true"
			shift
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
	local do_probe before_sans before_bad before_code deploy

	parse_args "$@"

	[[ -n "$CONTEXT" ]] || die "--context is required"
	[[ -n "$NAMESPACE" ]] || die "--namespace is required"
	[[ "$CONTEXT$APPS_CONTEXT" != *[[:cntrl:]]* ]] || die "contexts must not contain control characters"
	[[ "$RESYNC_WAIT" =~ ^[0-9]+$ ]] || die "--resync-wait must be a non-negative integer"

	require_cmd kubectl
	require_cmd awk

	# A probe requires a host and IP; the path defaults to /.
	do_probe="false"
	if [[ -n "$PROBE_HOST$PROBE_IP" ]]; then
		if [[ -z "$PROBE_HOST" || -z "$PROBE_IP" ]]; then
			die "--probe-host and --probe-ip must both be set, or neither"
		fi
		do_probe="true"
	fi

	# Confirm contexts exist before doing anything.
	kubectl config get-contexts -o name | grep -Fx -- "$CONTEXT" >/dev/null ||
		die "context not in kubeconfig: $CONTEXT"
	if [[ -n "$APPS_CONTEXT" ]]; then
		kubectl config get-contexts -o name | grep -Fx -- "$APPS_CONTEXT" >/dev/null ||
			die "context not in kubeconfig: $APPS_CONTEXT"
	fi

	if [[ "$EXECUTE" != "true" ]]; then
		header "Istio SAN repair plan"
		info "context=$CONTEXT namespace=$NAMESPACE pod=${POD:-auto}"
		info "Would inspect SAN matchers via kubectl exec, then restart istiod in $CONTEXT."
		[[ "$do_probe" != "true" ]] || info "Would probe Host=$PROBE_HOST via $PROBE_IP$PROBE_PATH."
		[[ "$ESCALATE" != "true" ]] || info "May also restart the workload and peer istiod (context=${APPS_CONTEXT:-unset})."
		info "Plan only. Add --yes to inspect and repair."
		exit 0
	fi

	header "Pre-flight: locate an inspection pod"

	if [[ -z "$POD" ]]; then
		POD="$(find_sidecar_pod "$CONTEXT" "$NAMESPACE")" ||
			die "no Running pod with an 'istio-proxy' container found in $CONTEXT / $NAMESPACE"
	fi
	info "context=$CONTEXT  namespace=$NAMESPACE  pod=$POD"

	header "Pre-flight: snapshot SPIFFE SAN matchers"
	if ! before_sans="$(dump_unique_sans "$CONTEXT" "$NAMESPACE" "$POD")" || [[ -z "$before_sans" ]]; then
		die "could not read SPIFFE SAN matchers from pod $POD"
	fi
	printf '   %s\n' "${before_sans//$'\n'/$'\n'   }"

	before_bad="$(count_malformed_sans "$before_sans")"
	if [[ "$before_bad" -gt 0 ]]; then
		warn "Detected $before_bad SAN matcher(s) with empty trust domain (spiffe:///...)"
		warn "Check Envoy logs for SAN verification failures."
	else
		ok "All SAN matchers carry a trust domain. No malformed entries detected."
	fi

	if [[ "$do_probe" == "true" ]]; then
		header "Pre-flight HTTP probe"
		before_code="$(probe_http "$CONTEXT" "$NAMESPACE" "$POD" "$PROBE_HOST" "$PROBE_IP" "$PROBE_PATH")"
		info "GET ${PROBE_PATH}  (Host: $PROBE_HOST)  ->  HTTP $before_code"
	fi

	if [[ "$before_bad" -eq 0 ]]; then
		info "No bug detected, but --yes was given. Restarting istiod anyway."
	fi

	header "Rolling istiod in $CONTEXT"
	run kubectl --context "$CONTEXT" -n istio-system rollout restart deployment/istiod
	run kubectl --context "$CONTEXT" -n istio-system rollout status deployment/istiod \
		--timeout="$ROLLOUT_TIMEOUT"

	info "Waiting ${RESYNC_WAIT}s for sidecars to pull fresh xDS..."
	sleep "$RESYNC_WAIT"

	if verify_and_probe "istiod restart"; then
		ok "Done."
		exit 0
	fi

	if [[ "$ESCALATE" != "true" ]]; then
		die "Run with --escalate (and ideally --apps-context CTX) to also restart the workload and the peer cluster's istiod."
	fi

	header "Escalation: restart the inspected pod's owning Deployment"
	deploy="$(owning_deployment_of_pod "$CONTEXT" "$NAMESPACE" "$POD" || true)"
	if [[ -n "$deploy" ]]; then
		run kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout restart "deployment/$deploy"
		run kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout status "deployment/$deploy" \
			--timeout="$ROLLOUT_TIMEOUT"
		POD="$(find_sidecar_pod "$CONTEXT" "$NAMESPACE" "$deploy")" ||
			die "no Running sidecar pod found for deployment $deploy after restart"
	else
		warn "Could not resolve owning Deployment for pod $POD — skipping workload rollout."
	fi

	if [[ -n "$APPS_CONTEXT" ]]; then
		header "Escalation: rolling istiod in $APPS_CONTEXT"
		run kubectl --context "$APPS_CONTEXT" -n istio-system rollout restart deployment/istiod
		run kubectl --context "$APPS_CONTEXT" -n istio-system rollout status deployment/istiod \
			--timeout="$ROLLOUT_TIMEOUT"
	else
		warn "No --apps-context set, skipping peer-cluster istiod restart."
	fi

	info "Waiting ${RESYNC_WAIT}s for sidecars to re-sync after escalation..."
	sleep "$RESYNC_WAIT"

	if verify_and_probe "escalation"; then
		ok "Done."
		exit 0
	fi

	die "SAN matchers are still malformed after escalation. Manual investigation required (mesh config, trust domain, revision tags)."
}

main "$@"
