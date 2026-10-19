# move-financial-report-files

Sync objects between two GCS prefixes. Add `--delete-source` to remove the
source objects after a successful sync.

Run the examples below from the `move-financial-report-files/` directory.

## What it does

1. Checks the source prefix and destination prefix.
2. Optionally prints size summaries with `--summarize`.
3. Without `--yes`, prints the planned sync command and exits.
4. With `--yes`, runs `gsutil -m rsync -r`.
5. With `--yes --delete-source`, deletes source objects after sync succeeds.

## Requirements

- `gsutil` with read access to the source and write access to the destination.
- Source delete permission only when using `--delete-source`.
- Plan-only runs still call `gsutil ls` to check prefixes.

## Configuration

Pass `--config-file=FILE` to read this tool's settings. The adjacent
[config.yml](./config.yml) contains synthetic examples. CLI flags override YAML.
See [configuration](../README.md#configuration) for requirements and path resolution.

```sh
./move-financial-report-files.sh --config-file=./config.yml
```

## Usage

```sh
./move-financial-report-files.sh --source gs://BUCKET/PREFIX \
  --dest gs://OTHER_BUCKET/PREFIX [flags]
```

| Flag | Required | Description |
| --- | :---: | --- |
| `--config-file=FILE` | no | Read YAML settings; CLI flags override them. |
| `--source PATH` | yes | Source GCS prefix. |
| `--dest PATH` | yes | Destination GCS prefix. |
| `--yes` | no | Execute the sync. |
| `--delete-source` | no | Delete source objects after sync; requires `--yes`. |
| `--summarize` | no | Run `gsutil du -s`; can be slow on large prefixes. |
| `--show-rsync-plan` | no | Run `gsutil rsync -n -r` in plan-only mode. |
| `-h, --help` | no | Show usage. |

## Examples

Print the plan:

```sh
./move-financial-report-files.sh \
  --source gs://example-source/reports/files \
  --dest gs://example-dest/reports/files
```

Add `--yes` to sync. Add `--yes --delete-source` for a move. Use
`--show-rsync-plan` without `--yes` to inspect the object diff.

Source and destination must be distinct, non-overlapping prefixes. Keep the
source unchanged during a move: deletion applies to the source prefix after
sync, including objects added while the sync was running.

## Exit codes

- `0` — plan printed or transfer succeeded.
- non-zero — invalid input, inaccessible source, failed sync, or failed deletion.
