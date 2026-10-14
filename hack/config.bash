# shellcheck shell=bash
# YAML configs supply ordinary argument defaults. They never execute shell
# code or authorize mutations. Keep compatibility with macOS Bash 3.2.

# load_config TOOL_SECTION [original arguments...]
# Sets CONFIG_ARGS to defaults followed by the original CLI arguments.
load_config() {
	local tool="$1"
	shift
	local cli_args=() cli_flags=()
	local config_file="" config_dir version json overrides defaults value

	CONFIG_ARGS=("$@")
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			CONFIG_ARGS=("$1")
			return 0
			;;
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
		--yes | --dry-run | --summary | --summarize | --show-rsync-plan | --delete-source | --escalate)
			cli_flags+=("$1")
			cli_args+=("$1")
			shift
			;;
		*)
			cli_flags+=("$1")
			cli_args+=("$1")
			shift
			if [[ $# -gt 0 ]]; then
				cli_args+=("$1")
				shift
			fi
			;;
		esac
	done

	# Direct flags and --help do not require a YAML parser.
	[[ -n "$config_file" ]] || return 0
	[[ "$config_file" != *[[:cntrl:]]* ]] || die "config paths must not contain control characters"
	[[ -f "$config_file" ]] || die "config file not found: $config_file"
	command -v yq >/dev/null 2>&1 || die "--config-file requires Mike Farah yq v4"
	command -v jq >/dev/null 2>&1 || die "--config-file requires jq"
	version="$(yq --version 2>/dev/null)" || die "could not determine yq version"
	[[ "$version" == *"github.com/mikefarah/yq/"* && "$version" == *"version v4."* ]] ||
		die "--config-file requires Mike Farah yq v4 (other yq implementations are incompatible)"

	config_dir="$(cd -- "$(dirname -- "$config_file")" && pwd -P)"
	config_file="$config_dir/$(basename -- "$config_file")"
	[[ "$config_file" != *[[:cntrl:]]* ]] || die "config paths must not contain control characters"
	# Include original mapping keys so duplicate YAML keys cannot silently pick
	# a target after conversion to JSON. Suppress parser excerpts of private data.
	json="$(yq eval -p=yaml -o=json -I=0 \
		'{"data": ., "key_sets": [.. | select(tag == "!!map") | keys]}' \
		"$config_file" 2>/dev/null)" || die "invalid YAML config: $config_file"
	overrides="$(printf '%s\n' ${cli_flags[@]+"${cli_flags[@]}"} | jq -Rsc 'split("\n") | map(select(length > 0))')"

	defaults="$(jq -sr --arg tool "$tool" --arg dir "$config_dir" \
		--argjson overrides "$overrides" '
    def schemas: {
      restart_deployment: {
        context:"scalar", namespace:"scalar", project:"scalar", cluster:"scalar", region:"scalar",
        deployments:"list:deployment", timeout:"scalar", since:"scalar", tail:"scalar"
      },
      reset_redis_cache: {
        context:"scalar", namespace:"scalar", project:"scalar", cluster:"scalar", region:"scalar",
        secret_project:"scalar", secret_name:"scalar", mode:"scalar", db:"scalar"
      },
      fetch_kafka_messages: {
        context:"scalar", project:"scalar", cluster:"scalar", region:"scalar",
        kafka_namespace:"scalar", kafka_service:"scalar", kafka_cluster:"scalar", topic:"scalar",
        partition:"scalar", limit:"scalar", seek:"scalar", offset:"scalar", local_port:"scalar",
        remote_port:"scalar", timeout:"scalar", output:"path", summary:"bool"
      },
      fix_istio_cross_cluster_san: {
        context:"scalar", namespace:"scalar", apps_context:"scalar", pod:"scalar",
        rollout_timeout:"scalar", resync_wait:"scalar", probe_host:"scalar", probe_ip:"scalar", probe_path:"scalar"
      },
      rsync_external_secrets: {input:"path", wait_timeout:"scalar", poll_interval:"scalar"},
      fetch_bucket_reports: {input:"path", gcs_path:"scalar", output:"path"},
      move_financial_report_files: {source:"scalar", dest:"scalar", summarize:"bool", show_rsync_plan:"bool"}
    };
    def scalar_ok:
      (type == "string" or type == "number") and
      (tostring | length > 0 and (test("[\u0000-\u001f\u007f]") | not));
    def valid_value($kind):
      if $kind == "bool" then type == "boolean"
      elif $kind == "path" then type == "string" and scalar_ok
      elif ($kind | startswith("list:")) then
        type == "array" and length > 0 and all(.[]; type == "string" and scalar_ok)
      else scalar_ok end;

    if length != 1 or (.[0].data | type) != "object" then
      error("config must contain exactly one YAML mapping document")
    elif (.[0].key_sets | all(.[]; length == (unique | length)) | not) then
      error("duplicate YAML mapping keys are not allowed")
    else .[0].data end
    | . as $config
    | schemas as $schemas
    | if (($config | keys) - ($schemas | keys) | length) > 0 then
        error("unknown config section; use the documented tool names")
      else . end
    | reduce ($config | to_entries[]) as $section (.;
        if ($section.value | type) != "object" then
          error("config section " + $section.key + " must be a mapping")
        elif (($section.value | keys) - ($schemas[$section.key] | keys) | length) > 0 then
          error("unknown field in " + $section.key + "; execution flags and secret values are not config fields")
        else
          reduce ($section.value | to_entries[]) as $field (.;
            if ($field.value | valid_value($schemas[$section.key][$field.key])) then .
            else error("invalid type or empty/control-character value in " + $section.key + "." + $field.key) end)
        end)
    | ($schemas[$tool] // error("unknown script config section")) as $schema
    | ($config[$tool] // {})
    # Explicit derivation fields must not be hidden by a saved context.
    | if ($tool == "restart_deployment" or $tool == "reset_redis_cache" or $tool == "fetch_kafka_messages") and
         ($overrides | any(. == "--project" or . == "--cluster" or . == "--region"))
      then del(.context) else . end
    | to_entries[]
    | . as $field
    | ($schema[$field.key]) as $kind
    | (if ($kind | startswith("list:")) then ($kind | split(":")[1])
       else ($field.key | gsub("_"; "-")) end) as $name
    | ("--" + $name) as $flag
    | select(($overrides | index($flag)) == null)
    | if $kind == "bool" then if $field.value then $flag else empty end
      elif ($kind | startswith("list:")) then $field.value[] | $flag, .
      elif $kind == "path" then $flag,
        (if ($field.value | startswith("/")) then $field.value else $dir + "/" + $field.value end)
      else $flag, ($field.value | tostring) end
  ' <<<"$json")" || die "invalid config settings: $config_file"

	CONFIG_ARGS=()
	if [[ -n "$defaults" ]]; then
		while IFS= read -r value; do
			CONFIG_ARGS+=("$value")
		done <<<"$defaults"
	fi
	CONFIG_ARGS+=(${cli_args[@]+"${cli_args[@]}"})
	info "Config: $config_file"
}
