# fetch-kafka-messages

Fetch messages through a Kafka UI API using a short-lived local
`kubectl port-forward`. Supply the cluster, namespace, Service, Kafka UI cluster
label, and topic.

Run the examples below from the `fetch-kafka-messages/` directory.

## What it does

1. Validates the supplied context and starts a port-forward to Kafka UI.
2. Reads topic offsets and prints the planned offset range.
3. With `--yes`, retrieves messages from the Kafka UI SSE consumer endpoint.
4. Stops the port-forward on exit.

Without `--yes`, no message payloads are retrieved.

## Requirements

- `kubectl` authenticated against the supplied context.
- `curl` and `python3`.
- Kafka UI exposing topic metadata and the SSE messages
  API used by this script, without interactive authentication. This tool does
  not connect directly to Kafka brokers or handle all Kafka UI variants.

## Configuration

Pass `--config-file=FILE` to read the `fetch_kafka_messages` section.
CLI flags override YAML. See the [config reference](../examples/sample/README.md)
for fields, requirements, and path resolution.

```sh
./fetch-kafka-messages.sh --config-file=../examples/sample/config.yaml
```

## Usage

```sh
./fetch-kafka-messages.sh --context CTX \
  --kafka-namespace NS --kafka-service SERVICE --kafka-cluster LABEL \
  --topic TOPIC [options]
```

Instead of `--context`, supply all of `--project`, `--cluster`, and `--region`
(a region or zone). The derived context is
`gke_<project>_<region-or-zone>_<cluster>` and must already exist in kubeconfig.

| Flag | Required | Default | Description |
| --- | :---: | --- | --- |
| `--config-file=FILE` | no | — | Read YAML settings; CLI flags override them. |
| `--topic NAME` | yes | — | Topic to inspect. |
| `--kafka-namespace NS` | yes | — | Namespace containing Kafka UI. |
| `--kafka-service NAME` | yes | — | Service to port-forward. |
| `--kafka-cluster LABEL` | yes | — | Exact cluster label shown in Kafka UI. |
| `--context CTX` | alternative | — | Existing kubeconfig context. |
| `--project PROJECT` | alternative | — | GCP project for context derivation. |
| `--cluster NAME` | alternative | — | GKE cluster for context derivation. |
| `--region LOCATION` | alternative | — | GKE region or zone for context derivation. |
| `--partition N` | no | `0` | Topic partition. |
| `--limit N` | no | `20` | Maximum number of messages. |
| `--seek MODE` | no | `latest` | `latest`, `earliest`, or `offset`. |
| `--offset N` | conditional | — | Required with `--seek offset`. |
| `--local-port PORT` | no | `18080` | Local port-forward port. |
| `--remote-port PORT` | no | `80` | Kafka UI Service port. |
| `--timeout SECONDS` | no | `60` | SSE curl timeout. |
| `--output FILE` | no | stdout | Message JSON output path. |
| `--summary` | no | off | Event-key counts and sample metadata with `--yes`. |
| `--yes` | no | off | Retrieve messages. |
| `-h, --help` | no | — | Show usage. |

## Examples

Read offsets and print the plan:

```sh
./fetch-kafka-messages.sh \
  --context example-cluster --kafka-namespace messaging \
  --kafka-service kafka-ui --kafka-cluster 'Example Cluster' --topic orders
```

Fetch the latest 10 messages from a Service exposing port 8080:

```sh
./fetch-kafka-messages.sh \
  --context example-cluster --kafka-namespace messaging \
  --kafka-service kafka-ui --kafka-cluster 'Example Cluster' \
  --remote-port 8080 --topic orders --limit 10 \
  --output ./messages/orders.json --yes
```

Use the same target flags with `--seek offset --offset 12000` to start at a
specific retained offset, or `--summary --yes` for event-key counts.

## Output format

Each message includes `partition`, `offset`, `timestamp`, `key`, `headers`, and
`value` (parsed JSON where possible, otherwise a string).

## Exit codes

- `0` — plan printed or fetch completed.
- non-zero — invalid input, missing context, kubectl/API failure, or invalid offset.

## Safety

- Does not publish or delete messages.
- Dry runs open a local port-forward and read topic metadata.
- Retrieved messages may contain sensitive data. Keep output under `messages/`,
  the root `local/` directory, or outside the repository. Arbitrary `--output`
  paths are not automatically ignored by Git.
