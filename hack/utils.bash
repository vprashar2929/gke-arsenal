# shellcheck shell=bash

is_fn() {
	[[ $(type -t "$1") == "function" ]]
	return $?
}

header() {
	local title=" 🔆🔆🔆  $*  🔆🔆🔆 "

	local len=40
	if [[ ${#title} -gt $len ]]; then
		len=${#title}
	fi

	echo -e "\n\n  \033[1m${title}\033[0m" >&2
	echo -n "━━━━━" >&2
	printf '━%.0s' $(seq "$len") >&2
	echo "━━━━━━━" >&2

}

info() {
	echo -e " 🔔 $*" >&2
}

err() {
	echo -e " 😱 $*" >&2
}

warn() {
	echo -e "   $*" >&2
}

ok() {
	echo -e "   ✅ $*" >&2
}

skip() {
	echo -e " 🙈 SKIP: $*" >&2
}

fail() {
	echo -e " ❌ FAIL: $*" >&2
}

info_run() {
	echo -e "      $*\n" >&2
}

run() {
	echo -e " ❯ $*\n" >&2
	"$@"
}

die() {
	echo -e "\n ✋ $* " >&2
	echo -e "──────────────────── ⛔️⛔️⛔️ ────────────────────────\n" >&2
	exit 1
}

line() {
	local len="$1"
	local style="${2:-thin}"
	shift

	local ch='─'
	[[ "$style" == 'heavy' ]] && ch="━"

	printf "$ch%.0s" $(seq "$len") >&2
	echo >&2
}
# condition_check <exp> <cond>
# checks if the condition result matches the expected result
condition_check() {
	local exp="$1"
	local cond="$2"
	shift 2
	[[ -n $exp ]] && [[ $("$cond" "$@") == "$exp" ]] && {
		return 0
	}
	return 1
}

# wait_until <max_tries> <delay> <msg> <condition>
# waits for condition to be true for a max of <max_tries> x <delay> seconds
wait_until() {
	local max_tries="$1"
	local delay="$2"
	local msg="$3"
	local condition="$4"
	shift 4

	info "Waiting [$max_tries x ${delay}s] for $msg"
	local tries=0
	local -i ret=1
	echo " ❯ $condition $*" >&2
	while [[ $tries -lt $max_tries ]]; do

		$condition "$@" && {
			ret=0
			break
		}

		tries=$((tries + 1))
		echo "   ... [$tries / $max_tries] waiting ($delay secs) - $msg" >&2
		sleep "$delay"
	done

	return $ret
}

# Read one flat YAML mapping. The caller supplies its allowed field names.
load_config() {
	local file="$1" version json
	shift
	[[ "$file" != *[[:cntrl:]]* ]] || die "config paths must not contain control characters"
	[[ -f "$file" ]] || die "config file not found: $file"
	command -v yq >/dev/null 2>&1 || die "--config-file requires Mike Farah yq v4"
	command -v jq >/dev/null 2>&1 || die "--config-file requires jq"
	version="$(yq --version 2>/dev/null)" || die "could not determine yq version"
	[[ "$version" == *"github.com/mikefarah/yq/"* && "$version" == *"version v4."* ]] ||
		die "--config-file requires Mike Farah yq v4"
	CONFIG_DIR="$(cd -- "$(dirname -- "$file")" && pwd -P)"
	[[ "$CONFIG_DIR" != *[[:cntrl:]]* ]] || die "config paths must not contain control characters"
	file="$CONFIG_DIR/$(basename -- "$file")"

	# Preserve mapping keys to detect duplicates; suppress excerpts of private data.
	json="$(yq eval -p=yaml -o=json -I=0 '{"data": ., "keys": keys}' "$file" 2>/dev/null)" ||
		die "invalid YAML config: $file"
	CONFIG_JSON="$(jq -sc --args '
    def text_ok:
      length > 0 and (test("[\u0000-\u001f\u007f]") | not);
    def value_ok:
      if type == "string" then text_ok
      elif type == "number" or type == "boolean" then true
      elif type == "array" then length > 0 and all(.[]; type == "string" and text_ok)
      else false end;
    if length != 1 or (.[0].data | type) != "object" then
      error("config must contain exactly one YAML mapping")
    elif (.[0].keys | length != (unique | length)) then
      error("duplicate config fields are not allowed")
    else .[0].data end
    | if ((keys - $ARGS.positional) | length) > 0 then
        error("unknown config field; use the documented fields for this tool")
      elif (all(.[]; value_ok) | not) then
        error("config values must be nonempty scalars or lists of strings without control characters")
      else . end
  ' "$@" <<<"$json")" || die "invalid config settings: $file"

	info "Config: $file"
}

# Missing fields return nothing so the script can apply its own defaults.
config_value() {
	local key="$1" kind="${2:-scalar}"
	jq -r --arg key "$key" --arg kind "$kind" --arg dir "$CONFIG_DIR" '
    if has($key) then
      .[$key]
      | if $kind == "list" and type == "array" then .[]
        elif $kind == "bool" and type == "boolean" then tostring
        elif $kind == "path" and type == "string" then
          if startswith("/") then . else $dir + "/" + . end
        elif $kind == "scalar" and (type == "string" or type == "number") then tostring
        else error("invalid type for config field " + $key) end
    else empty end
  ' <<<"$CONFIG_JSON" || die "could not read config field: $key"
}
