#!/usr/bin/env bash
#
# Download all files from a GCS bucket for each UID listed in an input file.
#
# By default (without --yes) the script lists what would be downloaded
# without fetching anything.

set -eu -o pipefail

# constants
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_NAME SCRIPT_DIR

# config
declare INPUT=""
declare GCS_PATH=""
declare OUTPUT=""
declare YES="false"

# shellcheck source=../hack/utils.bash
source "$SCRIPT_DIR/../hack/utils.bash"

usage() {
	cat <<USAGE
${SCRIPT_NAME}: download files from a GCS bucket for each UID in an input file.

Required flags:
  --input FILE             Input file listing UIDs, one per line.
  --gcs-path PATH          GCS prefix up to the UID directory, e.g.
                           gs://example-reports-bucket/reports
  --output DIR             Local download directory, with a subdirectory per UID.

Optional flags:
  --config-file=FILE       Read YAML settings; CLI flags override them.
                           Requires Mike Farah yq v4 and jq.
  --yes                    Download matching objects; otherwise only list them.
  -h, --help               Show this help.

Input format:
  One UID per line. Lines starting with # and blank lines are ignored.

    # comment
    00000000-0000-4000-8000-000000000001
    00000000-0000-4000-8000-000000000002

Examples:
  # Dry run — list files that would be downloaded
  ./fetch-bucket-reports.sh \\
    --input uids.tsv \\
    --gcs-path gs://example-reports-bucket/reports \\
    --output ./downloads

  # Download the matching files
  ./fetch-bucket-reports.sh \\
    --input uids.tsv \\
    --gcs-path gs://example-reports-bucket/reports \\
    --output ./downloads \\
    --yes
USAGE
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found in PATH: $1"
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
		--input)
			INPUT="${2:?missing value for --input}"
			shift 2
			;;
		--gcs-path)
			GCS_PATH="${2:?missing value for --gcs-path}"
			shift 2
			;;
		--output)
			OUTPUT="${2:?missing value for --output}"
			shift 2
			;;
		--yes)
			YES="true"
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
		load_config "$config_file" input gcs_path output
		INPUT="${INPUT:-$(config_value input path)}"
		GCS_PATH="${GCS_PATH:-$(config_value gcs_path)}"
		OUTPUT="${OUTPUT:-$(config_value output path)}"
	fi
}

main() {
	local clean_input uid_count failures downloaded uid src dest
	local file_list file_count f

	parse_args "$@"

	[[ -n "$INPUT" ]] || die "--input is required"
	[[ -f "$INPUT" ]] || die "input file not found: $INPUT"
	[[ -n "$GCS_PATH" ]] || die "--gcs-path is required"
	[[ -n "$OUTPUT" ]] || die "--output is required"

	GCS_PATH="${GCS_PATH%/}"

	require_cmd gsutil

	workdir="$(mktemp -d "${TMPDIR:-/tmp}/fetch-bucket-reports.XXXXXX")"
	trap 'rm -rf "$workdir"' EXIT

	clean_input="$workdir/uids.txt"
	awk '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  {
    sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "")
    if (length($0) == 0) next
    if ($0 == "." || $0 == ".." || $0 ~ /[[:space:][:cntrl:]]/ || $0 ~ /[\/\\*?\[]/) {
      printf("input line %d has an invalid UID; paths, wildcards, whitespace, and control characters are not allowed\n", NR) > "/dev/stderr"
      exit 1
    }
    print
  }
' "$INPUT" >"$clean_input"

	[[ -s "$clean_input" ]] || die "no usable UIDs in input: $INPUT"

	uid_count=$(wc -l <"$clean_input" | tr -d ' ')
	header "Fetch bucket reports ($uid_count UIDs)"

	if [[ "$YES" != "true" ]]; then
		info "DRY RUN — listing objects only (pass --yes to download)"
	fi

	failures=0
	downloaded=0

	while IFS= read -r uid; do
		src="${GCS_PATH}/${uid}/"
		dest="${OUTPUT}/${uid}/"
		info "UID=$uid"
		info_run "src: $src"

		file_list=$(gsutil ls "$src" 2>&1) || {
			fail "no objects found or access denied for $src"
			failures=$((failures + 1))
			continue
		}

		file_count=$(echo "$file_list" | grep -c '^gs://' || true)
		if [[ "$file_count" -eq 0 ]]; then
			skip "no files under $src"
			continue
		fi

		if [[ "$YES" != "true" ]]; then
			info_run "found $file_count file(s):"
			echo "$file_list" | while IFS= read -r f; do
				info_run "  $f"
			done
			continue
		fi

		mkdir -p "$dest"
		if run gsutil -m cp "${src}*" "$dest"; then
			ok "$file_count file(s) downloaded to $dest"
			downloaded=$((downloaded + file_count))
		else
			fail "download failed for UID=$uid"
			failures=$((failures + 1))
		fi

	done <"$clean_input"

	if [[ $failures -gt 0 ]]; then
		die "Completed with $failures failure(s)."
	fi

	if [[ "$YES" == "true" ]]; then
		ok "Done — $downloaded file(s) downloaded to $OUTPUT"
	else
		ok "Dry run complete. Re-run with --yes to download."
	fi
}

main "$@"
