# fetch-bucket-reports

Download all files from a GCS bucket for each UID listed in an input file.
Designed for bulk-fetching financial reports stored under per-UID prefixes
such as `gs://example-reports-bucket/reports/<UID>/`.

Run the examples below from the `fetch-bucket-reports/` directory.

## What it does

1. Reads UIDs from an input file (one per line).
2. For each UID, lists objects at `<gcs-path>/<UID>/`.
3. Downloads every object into a local `<output>/<UID>/` directory.

Without `--yes` the script only lists the objects that would be fetched.

## Requirements

- `gsutil` — authenticated with read access to the target bucket.

## Configuration

Pass `--config-file=FILE` to read this tool's settings. The adjacent
[config.yml](./config.yml) contains synthetic examples. CLI flags override YAML.
See [configuration](../README.md#configuration) for requirements and path resolution.

```sh
./fetch-bucket-reports.sh --config-file=./config.yml
```

## Usage

```
./fetch-bucket-reports.sh --input FILE --gcs-path PATH --output DIR [--yes]
```

| Flag         | Required | Description                                                        |
| ------------ | :------: | ------------------------------------------------------------------ |
| `--config-file=FILE` | no | Read YAML settings; CLI flags override them. |
| `--input`   |   yes    | File with one UID per line (comments and blank lines ignored).     |
| `--gcs-path` |   yes    | GCS prefix up to the UID directory (e.g. `gs://bucket/path`).     |
| `--output`   |   yes    | Local directory for downloads. A subdirectory per UID is created.  |
| `--yes`      |    no    | Download matching objects. Without it the script lists objects and exits.  |
| `-h, --help` |    no    | Show usage.                                                        |

### Input format

One UID per line. `#` comments and blank lines are ignored.
Each UID must be a single directory name. `.`, `..`, path separators, wildcard
patterns, whitespace, and control characters are rejected.

```
# comment
00000000-0000-4000-8000-000000000001
00000000-0000-4000-8000-000000000002
```

See [`fetch-bucket-reports.example.tsv`](./fetch-bucket-reports.example.tsv) for a ready-to-edit starting point.

## Examples

Dry run — list what would be downloaded:

```sh
./fetch-bucket-reports.sh \
  --input ./fetch-bucket-reports.example.tsv \
  --gcs-path gs://example-reports-bucket/reports \
  --output ./downloads
```

Download the matching files:

```sh
./fetch-bucket-reports.sh \
  --input ./fetch-bucket-reports.example.tsv \
  --gcs-path gs://example-reports-bucket/reports \
  --output ./downloads \
  --yes
```

## Exit codes

- `0` — all UIDs processed without error.
- non-zero — bad invocation, missing tool, malformed config, or at least one
  download failed.
