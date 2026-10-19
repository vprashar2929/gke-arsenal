#!/usr/bin/env bash
#
# Fetch messages from a Kafka topic via the cluster's Kafka UI API.
#
# Opens a short-lived kubectl port-forward to the kafka-ui service, reads
# topic offsets, and streams messages through the Kafka UI SSE endpoint.
#
# By default (without --yes) the script only prints the fetch plan and topic
# metadata without retrieving message payloads.

set -eu -o pipefail

# constants
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_NAME SCRIPT_DIR

# config
declare PROJECT=""
declare CLUSTER=""
declare REGION=""
declare CONTEXT=""
declare CONTEXT_EXPLICIT="false"
declare KAFKA_NAMESPACE=""
declare KAFKA_SERVICE=""
declare KAFKA_CLUSTER=""
declare TOPIC=""
declare PARTITION=""
declare LIMIT=""
declare SEEK=""
declare START_OFFSET=""
declare OFFSET_EXPLICIT="false"
declare LOCAL_PORT=""
declare REMOTE_PORT=""
declare TIMEOUT=""
declare OUTPUT=""
declare SUMMARY=""
declare EXECUTE="false"

declare PORT_FORWARD_PID=""
declare TOPIC_JSON=""
declare OFFSET_MIN=""
declare OFFSET_MAX=""
declare RETAINED_COUNT=""
declare SEEK_OFFSET=""

# shellcheck source=../hack/utils.bash
source "$SCRIPT_DIR/../hack/utils.bash"

usage() {
	cat <<USAGE
${SCRIPT_NAME}: fetch messages from a Kafka topic via Kafka UI.

Required flags:
  --topic NAME             Kafka topic name.
  --kafka-namespace NS     Namespace containing Kafka UI.
  --kafka-service NAME     Kafka UI Service to port-forward.
  --kafka-cluster NAME     Cluster label as shown in Kafka UI.
  --context CTX            Existing kubectl context; alternatively provide all
                           of --project PROJECT --cluster NAME --region LOCATION.

Optional flags:
  --config-file=FILE       Read YAML settings; CLI flags override them.
                           Requires Mike Farah yq v4 and jq.
  --project PROJECT        GCP project for deriving a GKE context.
  --cluster NAME           GKE cluster for deriving a context.
  --region LOCATION        Region or zone for deriving a context.
  --partition N            Topic partition. Default: 0
  --limit N                Maximum messages to fetch. Default: 20
  --seek MODE              latest (default), earliest, or offset.
  --offset N               Start offset, required with --seek offset.
  --local-port PORT        Local port-forward port. Default: 18080
  --remote-port PORT       Kafka UI Service port. Default: 80
  --timeout SECONDS        SSE curl timeout. Default: 60
  --output FILE            Write message JSON here; otherwise use stdout.
  --summary                With --yes, print event-key counts and sample metadata.
  --yes                    Retrieve messages. Without it, only read topic metadata.
  -h, --help               Show this help.

Examples:
  ./${SCRIPT_NAME} --context example-cluster --kafka-namespace messaging \\
    --kafka-service kafka-ui --kafka-cluster 'Example Cluster' --topic orders
  ./${SCRIPT_NAME} --context example-cluster --kafka-namespace messaging \\
    --kafka-service kafka-ui --kafka-cluster 'Example Cluster' --topic orders \\
    --remote-port 8080 --limit 10 --output ./messages/orders.json --yes

Notes:
  - Dry runs open a local port-forward and read topic offsets.
  - Requires the Kafka UI API used by this script, without interactive login.
  - Message bodies can contain sensitive data; keep output files local.
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

urlencode() {
	python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

start_port_forward() {
	local pf_log="$workdir/port-forward.log"

	info_run "kubectl --context $CONTEXT -n $KAFKA_NAMESPACE port-forward --address=127.0.0.1 svc/$KAFKA_SERVICE $LOCAL_PORT:$REMOTE_PORT"
	kubectl --context "$CONTEXT" -n "$KAFKA_NAMESPACE" port-forward \
		--address=127.0.0.1 "svc/$KAFKA_SERVICE" "$LOCAL_PORT:$REMOTE_PORT" >"$pf_log" 2>&1 &
	PORT_FORWARD_PID=$!

	# Wait for this process to bind; an existing listener might also answer HTTP.
	wait_until 15 1 "port-forward on localhost:$LOCAL_PORT" \
		grep -Fq -- "Forwarding from 127.0.0.1:${LOCAL_PORT} ->" "$pf_log" ||
		{
			[[ -f "$pf_log" ]] && tail -20 "$pf_log" >&2 || true
			die "kafka-ui port-forward did not become ready on localhost:$LOCAL_PORT"
		}
	kill -0 "$PORT_FORWARD_PID" 2>/dev/null || die "kafka-ui port-forward exited before metadata could be read"
}

stop_port_forward() {
	if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
		kill "$PORT_FORWARD_PID" 2>/dev/null || true
		wait "$PORT_FORWARD_PID" 2>/dev/null || true
		PORT_FORWARD_PID=""
	fi
}

fetch_topic_metadata() {
	local cluster_enc topic_enc url

	cluster_enc="$(urlencode "$KAFKA_CLUSTER")"
	topic_enc="$(urlencode "$TOPIC")"
	url="http://127.0.0.1:${LOCAL_PORT}/api/clusters/${cluster_enc}/topics/${topic_enc}"

	TOPIC_JSON="$(curl -sf "$url")" ||
		die "failed to fetch topic metadata for $TOPIC (cluster=$KAFKA_CLUSTER)"
}

compute_seek() {
	local offsets

	offsets="$(
		python3 - "$TOPIC_JSON" "$PARTITION" "$SEEK" "$LIMIT" "$OFFSET_EXPLICIT" "$START_OFFSET" <<'PY'
import json, sys

topic = json.loads(sys.argv[1])
partition = int(sys.argv[2])
seek = sys.argv[3]
limit = int(sys.argv[4])
offset_explicit = sys.argv[5] == "true"
start_offset = sys.argv[6]

parts = {p["partition"]: p for p in topic.get("partitions", [])}
if partition not in parts:
    raise SystemExit(f"partition {partition} not found on topic {topic.get('name')}")

p = parts[partition]
offset_min = int(p["offsetMin"])
offset_max = int(p["offsetMax"])
retained = max(0, offset_max - offset_min)

if seek == "offset":
    if not offset_explicit:
        raise SystemExit("--seek offset requires --offset")
    start = int(start_offset)
    if start < offset_min or start > offset_max:
        raise SystemExit(
            f"--offset {start} outside retained range [{offset_min}, {offset_max})"
        )
elif seek == "earliest":
    start = offset_min
elif seek == "latest":
    start = max(offset_min, offset_max - limit)
else:
    raise SystemExit(f"unknown seek mode: {seek}")

print(f"{offset_min}\t{offset_max}\t{retained}\t{start}")
PY
	)" || die "failed to compute seek offsets"

	IFS=$'\t' read -r OFFSET_MIN OFFSET_MAX RETAINED_COUNT SEEK_OFFSET <<<"$offsets"
}

fetch_messages() {
	local cluster_enc topic_enc seek_to url

	cluster_enc="$(urlencode "$KAFKA_CLUSTER")"
	topic_enc="$(urlencode "$TOPIC")"
	seek_to="${PARTITION}::${SEEK_OFFSET}"
	url="http://127.0.0.1:${LOCAL_PORT}/api/clusters/${cluster_enc}/topics/${topic_enc}/messages"
	url+="?limit=${LIMIT}&seekType=OFFSET&seekTo=${seek_to}&partition=${PARTITION}"

	SSE_RAW="$workdir/messages.sse"
	curl -fsSN --max-time "$TIMEOUT" "$url" >"$SSE_RAW" ||
		die "SSE fetch timed out or failed (timeout=${TIMEOUT}s)"

	python3 - "$SSE_RAW" "$OUTPUT" "$SUMMARY" <<'PY'
import json, sys, collections
from pathlib import Path

sse_path = Path(sys.argv[1])
output_path = sys.argv[2]
summary_only = sys.argv[3] == "true"

messages = []
for line in sse_path.read_text(encoding="utf-8", errors="replace").splitlines():
    line = line.strip()
    if not line.startswith("data:"):
        continue
    payload = json.loads(line[5:])
    if payload.get("type") != "MESSAGE":
        continue
    msg = payload["message"]
    content = msg.get("content", "")
    try:
        value = json.loads(content)
    except json.JSONDecodeError:
        value = content
    messages.append(
        {
            "partition": msg["partition"],
            "offset": msg["offset"],
            "timestamp": msg["timestamp"],
            "key": msg.get("key"),
            "headers": msg.get("headers", {}),
            "value": value,
        }
    )

counter = collections.Counter(m["key"] for m in messages)
print(f"messages_fetched={len(messages)}")
for key, count in counter.most_common():
    print(f"event_key\t{key}\t{count}")

if summary_only:
    for m in messages[-5:]:
        print(
            "sample\t{offset}\t{ts}\t{key}".format(
                offset=m["offset"], ts=m["timestamp"], key=m["key"]
            )
        )
    sys.exit(0)

if output_path:
    out = Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(messages, indent=2, default=str) + "\n", encoding="utf-8")
    print(f"output_file\t{out}")
else:
    print(json.dumps(messages, indent=2, default=str))
PY
}

parse_args() {
	local config_file=""

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
		--project)
			PROJECT="${2:?missing value for --project}"
			shift 2
			;;
		--cluster)
			CLUSTER="${2:?missing value for --cluster}"
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
		--kafka-namespace)
			KAFKA_NAMESPACE="${2:?missing value for --kafka-namespace}"
			shift 2
			;;
		--kafka-service)
			KAFKA_SERVICE="${2:?missing value for --kafka-service}"
			shift 2
			;;
		--kafka-cluster)
			KAFKA_CLUSTER="${2:?missing value for --kafka-cluster}"
			shift 2
			;;
		--topic)
			TOPIC="${2:?missing value for --topic}"
			shift 2
			;;
		--partition)
			PARTITION="${2:?missing value for --partition}"
			shift 2
			;;
		--limit)
			LIMIT="${2:?missing value for --limit}"
			shift 2
			;;
		--seek)
			SEEK="${2:?missing value for --seek}"
			shift 2
			;;
		--offset)
			START_OFFSET="${2:?missing value for --offset}"
			shift 2
			;;
		--remote-port)
			REMOTE_PORT="${2:?missing value for --remote-port}"
			shift 2
			;;
		--local-port)
			LOCAL_PORT="${2:?missing value for --local-port}"
			shift 2
			;;
		--timeout)
			TIMEOUT="${2:?missing value for --timeout}"
			shift 2
			;;
		--output)
			OUTPUT="${2:?missing value for --output}"
			shift 2
			;;
		--summary)
			SUMMARY="true"
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

	if [[ -n "$config_file" ]]; then
		load_config "$config_file" \
			context project cluster region kafka_namespace kafka_service \
			kafka_cluster topic partition limit seek offset \
			local_port remote_port timeout output summary
		# CLI derivation fields take precedence over a saved context.
		if [[ -z "$PROJECT$CLUSTER$REGION" ]]; then
			CONTEXT="${CONTEXT:-$(config_value context)}"
		fi
		PROJECT="${PROJECT:-$(config_value project)}"
		CLUSTER="${CLUSTER:-$(config_value cluster)}"
		REGION="${REGION:-$(config_value region)}"
		KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-$(config_value kafka_namespace)}"
		KAFKA_SERVICE="${KAFKA_SERVICE:-$(config_value kafka_service)}"
		KAFKA_CLUSTER="${KAFKA_CLUSTER:-$(config_value kafka_cluster)}"
		TOPIC="${TOPIC:-$(config_value topic)}"
		PARTITION="${PARTITION:-$(config_value partition)}"
		LIMIT="${LIMIT:-$(config_value limit)}"
		SEEK="${SEEK:-$(config_value seek)}"
		START_OFFSET="${START_OFFSET:-$(config_value offset)}"
		LOCAL_PORT="${LOCAL_PORT:-$(config_value local_port)}"
		REMOTE_PORT="${REMOTE_PORT:-$(config_value remote_port)}"
		TIMEOUT="${TIMEOUT:-$(config_value timeout)}"
		OUTPUT="${OUTPUT:-$(config_value output path)}"
		SUMMARY="${SUMMARY:-$(config_value summary bool)}"
	fi
	if [[ -n "$CONTEXT" ]]; then CONTEXT_EXPLICIT="true"; fi
	if [[ -n "$START_OFFSET" ]]; then OFFSET_EXPLICIT="true"; fi

	PARTITION="${PARTITION:-0}"
	LIMIT="${LIMIT:-20}"
	SEEK="${SEEK:-latest}"
	LOCAL_PORT="${LOCAL_PORT:-18080}"
	REMOTE_PORT="${REMOTE_PORT:-80}"
	TIMEOUT="${TIMEOUT:-60}"
	SUMMARY="${SUMMARY:-false}"
}

main() {
	local port tmp_root line key count offset ts path

	parse_args "$@"

	[[ -n "$TOPIC" ]] || die "--topic is required"
	validate_k8s_name "topic" "$TOPIC"

	case "$SEEK" in
	latest | earliest | offset) ;;
	*) die "unknown --seek: $SEEK (expected latest, earliest, or offset)" ;;
	esac

	[[ "$PARTITION" =~ ^[0-9]+$ ]] || die "--partition must be a non-negative integer"
	[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || die "--limit must be a positive integer"
	for port in "$LOCAL_PORT" "$REMOTE_PORT"; do
		[[ "$port" =~ ^[1-9][0-9]*$ && "$port" -le 65535 ]] ||
			die "--local-port and --remote-port must be between 1 and 65535"
	done
	[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be seconds"
	if [[ -n "$START_OFFSET" ]]; then
		[[ "$START_OFFSET" =~ ^[0-9]+$ ]] || die "--offset must be a non-negative integer"
	fi

	if [[ -z "$CONTEXT" ]]; then
		[[ -n "$PROJECT" ]] || die "provide --context or --project, --cluster, and --region"
		[[ -n "$CLUSTER" ]] || die "--cluster is required when deriving a context"
		[[ -n "$REGION" ]] || die "--region is required when deriving a context"
		CONTEXT="gke_${PROJECT}_${REGION}_${CLUSTER}"
	fi

	[[ -n "$KAFKA_NAMESPACE" ]] || die "--kafka-namespace is required"
	[[ -n "$KAFKA_SERVICE" ]] || die "--kafka-service is required"
	[[ -n "$KAFKA_CLUSTER" ]] || die "--kafka-cluster is required"

	[[ "$CONTEXT" != *[[:cntrl:]]* ]] || die "context must not contain control characters"
	validate_k8s_name "kafka namespace" "$KAFKA_NAMESPACE"
	validate_k8s_name "kafka service" "$KAFKA_SERVICE"

	require_cmd kubectl
	require_cmd curl
	require_cmd python3

	header "Kafka message fetch plan"
	info "topic=$TOPIC  partition=$PARTITION  limit=$LIMIT  seek=$SEEK"
	info "context=$CONTEXT"
	info "kafka_ui=$KAFKA_NAMESPACE/svc/$KAFKA_SERVICE  cluster=$KAFKA_CLUSTER"
	info "local_port=$LOCAL_PORT  remote_port=$REMOTE_PORT  timeout=${TIMEOUT}s"
	if [[ -n "$OUTPUT" ]]; then
		info "output=$OUTPUT"
	fi
	if [[ "$SUMMARY" == "true" ]]; then
		info "mode=summary (event key breakdown)"
	fi
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

	tmp_root="${TMPDIR:-/tmp}"
	workdir="$(mktemp -d "${tmp_root%/}/fetch-kafka-messages.XXXXXX")"
	trap 'stop_port_forward; rm -rf "$workdir"' EXIT

	start_port_forward
	fetch_topic_metadata
	compute_seek

	info "retained_offsets=[$OFFSET_MIN, $OFFSET_MAX)  count=$RETAINED_COUNT"
	info "planned_start_offset=$SEEK_OFFSET"

	if [[ "$EXECUTE" != "true" ]]; then
		info "Dry run only. Add --yes to fetch up to $LIMIT message(s)."
		exit 0
	fi

	header "Fetching Kafka messages"
	fetch_messages | while IFS= read -r line; do
		case "$line" in
		messages_fetched=*) info "${line#messages_fetched=} message(s) fetched" ;;
		event_key*)
			IFS=$'\t' read -r _ key count <<<"$line"
			info "  $key: $count"
			;;
		sample*)
			IFS=$'\t' read -r _ offset ts key <<<"$line"
			info "  sample offset=$offset ts=$ts key=$key"
			;;
		output_file*)
			IFS=$'\t' read -r _ path <<<"$line"
			ok "Wrote messages to $path"
			;;
		*) printf '%s\n' "$line" ;;
		esac
	done

	ok "Kafka message fetch completed."
}

main "$@"
