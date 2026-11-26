#!/bin/bash
set -euo pipefail

CONTAINER_NAME="${GARAGE_CONTAINER:-cloudsync-garage}"

# 1. Get local node ID from the running Garage container
STATUS_OUT=$(docker exec "$CONTAINER_NAME" /garage status 2>&1) || {
    echo "Error: could not reach '$CONTAINER_NAME'. Make sure it is running (docker compose up -d)."
    exit 1
}

NODE_ID=$(echo "$STATUS_OUT" | grep -oE '^[0-9a-f]{16}' | head -n1 || true)
if [ -z "$NODE_ID" ]; then
    echo "Error: could not parse node ID from /garage status."
    echo "$STATUS_OUT"
    exit 1
fi

echo "Found Garage node: $NODE_ID"

# 2. Check if a cluster layout is already applied
LAYOUT_OUT=$(docker exec "$CONTAINER_NAME" /garage layout show 2>&1 || true)
CURRENT_VERSION=$(echo "$LAYOUT_OUT" | grep -i "Current cluster layout version:" | awk '{print $NF}' || true)
CURRENT_VERSION="${CURRENT_VERSION:-0}"

if [ "$CURRENT_VERSION" -gt 0 ]; then
    echo "Cluster layout is already initialized (version $CURRENT_VERSION):"
    echo "$LAYOUT_OUT" | grep -v "garage_net"
    read -p "Update zone/capacity anyway? (y/N): " UPDATE_CHOICE
    if [[ ! "$UPDATE_CHOICE" =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# 3. Assign zone & capacity and apply layout
read -p "Zone [dc1]: " ZONE
ZONE="${ZONE:-dc1}"

read -p "Capacity (e.g. 50G, 100G) [50G]: " CAPACITY
CAPACITY="${CAPACITY:-50G}"

NEXT_VERSION=$((CURRENT_VERSION + 1))

docker exec "$CONTAINER_NAME" /garage layout assign -z "$ZONE" -c "$CAPACITY" "$NODE_ID" 2>&1 | grep -v "garage_net" || true
docker exec "$CONTAINER_NAME" /garage layout apply --version "$NEXT_VERSION" 2>&1 | grep -v "garage_net"

echo "Done! Garage is ready. Run ./init_bucket.sh to create a bucket and S3 keys."
