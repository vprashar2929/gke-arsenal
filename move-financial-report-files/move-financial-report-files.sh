#!/usr/bin/env bash
#
# Sync objects between two GCS prefixes.
#
# By default (without --yes) the script prints source/destination context and
# the command that would run, without copying or deleting anything.

set -eu -o pipefail

# constants
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_NAME SCRIPT_DIR

# config
declare SOURCE_PATH=""
declare DEST_PATH=""
declare YES="false"
declare DELETE_SOURCE="false"
declare SUMMARIZE=""
declare SHOW_RSYNC_PLAN=""

# shellcheck source=../hack/utils.bash
source "$SCRIPT_DIR/../hack/utils.bash"

usage() {
	cat <<USAGE
${SCRIPT_NAME}: move/sync financial report files between GCS prefixes.

Required flags:
  --source PATH            Source GCS prefix, e.g. gs://example-source/reports/files.
  --dest PATH              Destination GCS prefix, e.g. gs://example-dest/reports/files.

Optional flags:
  --config-file=FILE       Read YAML settings; CLI flags override them.
                           Requires Mike Farah yq v4 and jq.
  --yes                    Sync objects; otherwise print the plan and exit.
  --delete-source          Delete source objects after sync succeeds. Requires --yes.
  --summarize              Run 'gsutil du -s' for source and destination.
                           Can be slow on large prefixes.
  --show-rsync-plan        Run 'gsutil rsync -n -r' in dry-run mode to list
                           objects that would be copied. Output can be large.
  -h, --help               Show this help.

Examples:
  # Dry run -- verify prefixes and print the planned command
  ./${SCRIPT_NAME} --source gs://example-source/reports/files \\
    --dest gs://example-dest/reports/files

  # Copy/sync, keeping the source intact
  ./${SCRIPT_NAME} --source gs://example-source/reports/files \\
    --dest gs://example-dest/reports/files --yes

  # Sync, then delete the source objects only if sync succeeds
  ./${SCRIPT_NAME} --source gs://example-source/reports/files \\
    --dest gs://example-dest/reports/files --yes --delete-source
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
		--source)
			SOURCE_PATH="${2:?missing value for --source}"
			shift 2
			;;
		--dest)
			DEST_PATH="${2:?missing value for --dest}"
			shift 2
			;;
		--yes)
			YES="true"
			shift
			;;
		--delete-source)
			DELETE_SOURCE="true"
			shift
			;;
		--summarize)
			SUMMARIZE="true"
			shift
			;;
		--show-rsync-plan)
			SHOW_RSYNC_PLAN="true"
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
		load_config "$config_file" source dest summarize show_rsync_plan
		SOURCE_PATH="${SOURCE_PATH:-$(config_value source)}"
		DEST_PATH="${DEST_PATH:-$(config_value dest)}"
		SUMMARIZE="${SUMMARIZE:-$(config_value summarize bool)}"
		SHOW_RSYNC_PLAN="${SHOW_RSYNC_PLAN:-$(config_value show_rsync_plan bool)}"
	fi

	SUMMARIZE="${SUMMARIZE:-false}"
	SHOW_RSYNC_PLAN="${SHOW_RSYNC_PLAN:-false}"
}

main() {
	local source_summary dest_summary

	parse_args "$@"

	[[ -n "$SOURCE_PATH" ]] || die "--source is required"
	[[ -n "$DEST_PATH" ]] || die "--dest is required"

	SOURCE_PATH="${SOURCE_PATH%/}"
	DEST_PATH="${DEST_PATH%/}"

	[[ "$SOURCE_PATH" == gs://*/* ]] || die "--source must be a GCS prefix like gs://bucket/path"
	[[ "$DEST_PATH" == gs://*/* ]] || die "--dest must be a GCS prefix like gs://bucket/path"
	[[ "$SOURCE_PATH" != "$DEST_PATH" ]] || die "--source and --dest must be different"
	[[ "${SOURCE_PATH}/" != "${DEST_PATH}/"* && "${DEST_PATH}/" != "${SOURCE_PATH}/"* ]] ||
		die "--source and --dest must not overlap"

	if [[ "$DELETE_SOURCE" == "true" && "$YES" != "true" ]]; then
		die "--delete-source requires --yes"
	fi

	if [[ "$SHOW_RSYNC_PLAN" == "true" && "$YES" == "true" ]]; then
		warn "--show-rsync-plan is ignored with --yes; it only applies in dry-run mode"
		SHOW_RSYNC_PLAN="false"
	fi

	require_cmd gsutil

	header "Move financial report files"

	info "source: $SOURCE_PATH"
	info "dest:   $DEST_PATH"

	if [[ "$YES" != "true" ]]; then
		info "DRY RUN -- no objects will be copied or deleted (pass --yes to sync)"
	fi

	info "Checking source prefix"
	if ! gsutil ls -d "${SOURCE_PATH}/" >/dev/null; then
		die "source prefix not found or access denied: ${SOURCE_PATH}/"
	fi

	info "Checking destination prefix"
	if gsutil ls -d "${DEST_PATH}/" >/dev/null 2>&1; then
		ok "destination prefix exists"
	else
		warn "destination prefix is not currently listed; rsync will create objects under it if the bucket is writable"
	fi

	if [[ "$SUMMARIZE" == "true" ]]; then
		workdir="$(mktemp -d "${TMPDIR:-/tmp}/move-financial-report-files.XXXXXX")"
		trap 'rm -rf "$workdir"' EXIT

		source_summary="$workdir/source-du.txt"
		dest_summary="$workdir/dest-du.txt"

		info "Summarizing source prefix"
		if gsutil du -s "${SOURCE_PATH}/" >"$source_summary"; then
			info_run "source size: $(cat "$source_summary")"
		else
			die "failed to summarize source prefix: ${SOURCE_PATH}/"
		fi

		info "Summarizing destination prefix"
		if gsutil du -s "${DEST_PATH}/" >"$dest_summary"; then
			info_run "dest size: $(cat "$dest_summary")"
		else
			warn "destination size summary failed: ${DEST_PATH}/"
		fi
	fi

	if [[ "$YES" != "true" ]]; then
		info "Planned sync command:"
		info_run "gsutil -m rsync -r '$SOURCE_PATH' '$DEST_PATH'"

		if [[ "$SHOW_RSYNC_PLAN" == "true" ]]; then
			info "Object-level rsync dry-run plan follows"
			run gsutil -m rsync -n -r "$SOURCE_PATH" "$DEST_PATH"
		else
			info "Use --show-rsync-plan to ask gsutil for the exact object-level diff."
		fi

		ok "Dry run complete. Re-run with --yes to sync."
		exit 0
	fi

	info "Syncing source contents into destination"
	run gsutil -m rsync -r "$SOURCE_PATH" "$DEST_PATH"
	ok "Sync complete"

	if [[ "$DELETE_SOURCE" == "true" ]]; then
		warn "Deleting source objects after successful sync: ${SOURCE_PATH}/**"
		run gsutil -m rm -r "${SOURCE_PATH}/**"
		ok "Source cleanup complete"
	else
		ok "Source objects retained."
	fi
}

main "$@"
