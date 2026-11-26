#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

CONTAINER_NAME="${GARAGE_CONTAINER:-cloudsync-garage}"
ENDPOINT="${CLOUDSYNC_ENDPOINT:-https://cloudsync.example.com}"

# Read s3_region from garage.toml (pointed to by config_cloudsync_toml in .env)
TOML_PATH="${config_cloudsync_toml:-./docker/config/garage.toml}"
if [[ "$TOML_PATH" != /* ]]; then
    TOML_PATH="$SCRIPT_DIR/$TOML_PATH"
fi
REGION=""
if [ -f "$TOML_PATH" ]; then
    REGION=$(grep -E '^[[:space:]]*s3_region[[:space:]]*=' "$TOML_PATH" | head -n1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/')
fi
REGION="${REGION:-garage}"

read -p "Enter bucket/vault name: " BUCKET
if [ -z "$BUCKET" ]; then
    echo "Error: bucket name cannot be empty."
    exit 1
fi

KEY_NAME="${BUCKET}-key"
RECREATE_KEY=true

# 1. Find existing keys with this name. Garage allows duplicate names, and
#    name lookups fail when several match, so everything below uses key IDs.
KEY_IDS=$(docker exec "$CONTAINER_NAME" /garage key list 2>/dev/null | grep -F "$KEY_NAME" | grep -oE "GK[0-9a-f]+")
KEY_COUNT=$(echo "$KEY_IDS" | grep -c .)

if [ "$KEY_COUNT" -gt 0 ]; then
    echo "------------------------------------------------------------"
    echo "⚠️  S3 credentials for '$KEY_NAME' already exist ($KEY_COUNT):"
    echo "$KEY_IDS" | sed 's/^/    /'
    echo "------------------------------------------------------------"
    echo "Select an option:"
    echo "  [1] Reuse existing credentials (prints the current Access Key and Secret Key)"
    echo "  [2] Reset credentials (deletes ALL existing keys with this name and creates a new pair)"
    echo "------------------------------------------------------------"
    read -p "Enter choice (1 or 2): " CHOICE

    if [ "$CHOICE" = "2" ]; then
        for ID in $KEY_IDS; do
            echo "Deleting old S3 credentials $ID..."
            docker exec "$CONTAINER_NAME" /garage key delete --yes "$ID" 2>&1 | grep -v "garage_net"
        done
        RECREATE_KEY=true
    else
        echo "Reusing existing credentials..."
        RECREATE_KEY=false
        REUSE_ID=$(echo "$KEY_IDS" | head -n1)
        if [ "$KEY_COUNT" -gt 1 ]; then
            echo "Several keys share this name; reusing $REUSE_ID. Choose Reset to remove the duplicates."
        fi
        # Garage v1.x: "key info --show-secret" prints the stored secret
        KEY_INFO=$(docker exec "$CONTAINER_NAME" /garage key info --show-secret "$REUSE_ID" 2>&1)
        ACCESS_KEY="$REUSE_ID"
        SECRET_KEY=$(echo "$KEY_INFO" | grep -i "secret key:" | awk '{print $NF}')
        if [ -z "$SECRET_KEY" ]; then
            echo "Could not parse the secret automatically. Raw Garage output:"
            echo "$KEY_INFO" | grep -v "garage_net"
        fi
    fi
fi

# 2. Create S3 credentials if required/recreated
if [ "$RECREATE_KEY" = true ]; then
    echo "Creating S3 credentials..."
    # Redirect stderr to stdout to capture the returned key details
    KEYS=$(docker exec "$CONTAINER_NAME" /garage key create "$KEY_NAME" 2>&1)
    # Garage v1.x labels: "Key ID:" and "Secret key:"
    ACCESS_KEY=$(echo "$KEYS" | grep -m1 -oE "GK[0-9a-f]+")
    SECRET_KEY=$(echo "$KEYS" | grep -i "secret key:" | awk '{print $NF}')
    if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
        echo "Could not parse keys automatically. Raw Garage output:"
        echo "$KEYS" | grep -v "garage_net"
    fi
fi

# 3. Create bucket (does nothing / safe if it already exists)
echo "Creating bucket..."
docker exec "$CONTAINER_NAME" /garage bucket create "$BUCKET" 2>&1 | grep -v "garage_net"

# 4. Enforce permissions
echo "Binding credentials to bucket..."
if [ -n "$ACCESS_KEY" ]; then
    KEY_REF="$ACCESS_KEY"
else
    KEY_REF="$KEY_NAME"
fi
docker exec "$CONTAINER_NAME" /garage bucket allow "$BUCKET" --read --write --key "$KEY_REF" 2>&1 | grep -v "garage_net"

echo "----------------------------------------"
echo "Success! Add these to your plugin settings:"
echo "Endpoint:   $ENDPOINT"
echo "Region:     $REGION"
echo "Bucket:     $BUCKET"
echo "Access Key: $ACCESS_KEY"
echo "Secret Key: $SECRET_KEY"
if [ "$RECREATE_KEY" = false ]; then
    echo ""
    echo "Note: these are the existing credentials; they were not changed."
fi
echo "----------------------------------------"
