#!/bin/bash

# This script intends to simplify launching, configuring and joining a set of
# Couchbase Server instances running in Docker containers on a single physical host
# into a cluster.
# Configuration happens via environment variables taken from the runtime environment,
# redirected input, or provided on the command line.

Usage() {
  echo "Usage: $0 [VAR=value] ... [< file]"
}

# Read configuration from stdin when redirected (e.g. $0 < config)
[[ ! -t 0 ]] && source /dev/stdin

# Override configuration based on supplied arguments
until [ -z "$1" ]; do
  [[ "$1" =~ ^[^=]+=[^=]+$ ]] || {
    echo Malformed argument "$1"
    Usage
    exit 1
  }
  eval "$1" || {
    echo Failed processing argument "$1"
    Usage
    exit 1
  }
  shift
done

# Use supplied parameters or try for sensible defaults
: ${DOCKER:=docker}

# create virtual network
"$DOCKER" network rm "$COUCHBASE_NETWORK"
"$DOCKER" network create --subnet 10.10.0.0/16 "$COUCHBASE_NETWORK"

# create couchbase services array
IFS=',' read -r -a services <<<$COUCHBASE_SERVICES
: ${COUCHBASE_NODE_COUNT:=${#services[@]}}

cluster_url="couchbase://127.0.0.1"

read -r -d '' ports_script <<EOF || true
{
  split(\$1, maps, /::/)

  for (map in maps) {
    split(maps[map], ranges, /:/)
    count = split(ranges[1], ports, "-")
     
    for (port in ports) {
      ports[port] += offset
    }
     
    ranges[1] = ports[1]
    
    if (count > 1) ranges[1] = ports[1] "-" ports[2]
    
    printf "-p " ranges[1] ":" ranges[2] " "
  }
}
EOF

echo "creating services: ... ${services[@]} ..."

for ((node = 0; node < $COUCHBASE_NODE_COUNT; ++node)); do
  echo "Starting node ${COUCHBASE_NODE_NAME}_${node}"
  let offset=${node}*1000 || true
  ports=$(awk -v offset=$offset "$ports_script" <<<"${COUCHBASE_SERVER_PORTS}")
  mkdir -p "/data/couchbase/${services[node]}"
  "$DOCKER" run -d --name "${COUCHBASE_NODE_NAME}_${node}" --network "$COUCHBASE_NETWORK" $ports \
    -v /data/couchbase/${services[node]}:/opt/couchbase/var couchbase
done

sleep 15

# Setup initial cluster/initialize node
IFS='_' read -r -a service_name <<<${services[0]}
"$DOCKER" exec "${COUCHBASE_NODE_NAME}_0" couchbase-cli cluster-init --cluster ${cluster_url} --cluster-name "$COUCHBASE_CLUSTER_NAME" \
  --cluster-username "$COUCHBASE_ADMINISTRATOR_USERNAME" --cluster-password "$COUCHBASE_ADMINISTRATOR_PASSWORD" \
  --services "${service_name[0]}" --cluster-ramsize "$MEMORY" --cluster-index-ramsize "$MEMORY" --cluster-fts-ramsize "$MEMORY" \
  --cluster-analytics-ramsize "$(($MEMORY * 2))" --cluster-eventing-ramsize "$MEMORY" --index-storage-setting default

# Setup Bucket
"$DOCKER" exec "${COUCHBASE_NODE_NAME}_0" couchbase-cli bucket-create --cluster ${cluster_url} \
  --username "$COUCHBASE_ADMINISTRATOR_USERNAME" --password "$COUCHBASE_ADMINISTRATOR_PASSWORD" \
  --bucket "$COUCHBASE_BUCKET" --bucket-type couchbase --bucket-ramsize "$MEMORY_BUCKET"

# Setup RBAC user using CLI
"$DOCKER" exec "${COUCHBASE_NODE_NAME}_0" couchbase-cli user-manage --cluster ${cluster_url} \
  --username "$COUCHBASE_ADMINISTRATOR_USERNAME" --password "$COUCHBASE_ADMINISTRATOR_PASSWORD" \
  --set --rbac-username "$COUCHBASE_RBAC_USERNAME" --rbac-password "$COUCHBASE_RBAC_PASSWORD" \
  --rbac-name "$COUCHBASE_RBAC_NAME" --roles "$COUCHBASE_RBAC_ROLES" --auth-domain local

# Add nodes
docker_ip() {
  "$DOCKER" inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$@"
}

for ((node = 1; node < $COUCHBASE_NODE_COUNT; ++node)); do
  IFS='_' read -r -a servicename <<<${services[node]}
  "$DOCKER" exec "${COUCHBASE_NODE_NAME}_${node}" couchbase-cli server-add \
    --cluster $(docker_ip "${COUCHBASE_NODE_NAME}_0"):8091 \
    --username "$COUCHBASE_ADMINISTRATOR_USERNAME" --password "$COUCHBASE_ADMINISTRATOR_PASSWORD" \
    --server-add $(docker_ip "${COUCHBASE_NODE_NAME}_${node}"):8091 \
    --server-add-username "$COUCHBASE_ADMINISTRATOR_USERNAME" --server-add-password "$COUCHBASE_ADMINISTRATOR_PASSWORD" \
    --services "${servicename[0]}"
done

# Rebalance (needed to fully enable added nodes)
"$DOCKER" exec "${COUCHBASE_NODE_NAME}_0" couchbase-cli rebalance --cluster ${cluster_url} \
  --username "$COUCHBASE_ADMINISTRATOR_USERNAME" --password "$COUCHBASE_ADMINISTRATOR_PASSWORD" \
  --no-wait
