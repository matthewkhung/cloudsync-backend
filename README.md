# CloudSync Backend

Self-hosted S3 object storage backend for **CloudSync** (an end-to-end encrypted backup and sync solution for Obsidian).

CloudSync uses a **stateless S3 storage** architecture: all encryption (AES-256-GCM), deduplication, conflict resolution, and version tracking happen client-side inside Obsidian. This repository provides a Docker Compose deployment for **Garage S3 (`v1.1.0`)**, helper scripts for initializing Garage and provisioning per-vault buckets/S3 keys, and reverse-proxy CORS configurations for Obsidian Desktop and Mobile.

---

## Repository Structure

```text
.
├── docker-compose.yml                   # Garage S3 container definition
├── .env.example                         # Template for host paths and endpoint setting
├── init_garage.sh                       # Initializes the Garage node cluster layout (zone & capacity)
├── init_bucket.sh                       # Interactive bucket & S3 credential provisioning script
└── docker.sample/
    ├── config/
    │   └── garage.toml.sample           # Template Garage v1.1.0 node configuration
    └── data/                            # Empty runtime data directory template
```

---

## Quick Start (Garage S3 + Docker Compose)

### 1. Create local configuration files

Copy the sample directory and templates:

```bash
cp .env.example .env
cp -r docker.sample docker
mv docker/config/garage.toml.sample docker/config/garage.toml
```

Generate a 32-byte hex `rpc_secret` and `admin_token` and paste them into `docker/config/garage.toml`:

```bash
openssl rand -hex 32   # use for rpc_secret
openssl rand -hex 32   # use for admin_token
```

Update `CLOUDSYNC_ENDPOINT` in `.env` to match the HTTPS domain where your reverse proxy will expose Garage.

### 2. Start the Garage container

```bash
docker compose up -d
```

### 3. Initialize the Garage cluster layout (first-time setup)

Run the initialization script to assign a zone and storage capacity to the local Garage node and apply the initial layout:

```bash
./init_garage.sh
```

### 4. Provision a vault bucket & S3 credentials

Run the bucket provisioning script to create a bucket and a dedicated S3 key pair scoped only to that bucket:

```bash
./init_bucket.sh
```

The script will:
1. Check if a `<bucket>-key` already exists (offering to reuse or reset credentials).
2. Create the bucket if it does not exist yet.
3. Grant `--read --write` permissions for the key on the bucket.
4. Print the **Endpoint** (from `.env`), **Region** (read from `garage.toml`), **Bucket**, **Access Key**, and **Secret Key** to enter into CloudSync.

---

## Reverse Proxy & CORS Configuration

Obsidian runs inside Electron (desktop) and Capacitor WebViews (mobile), so your HTTPS reverse proxy **must** inject CORS headers and expose `ETag` (required for optimistic locking with `If-Match` / `If-None-Match`).

### Traefik (`dynamic.yml`)

Attach the `cloudsync-garage` container to your proxy network (e.g. `traefik-proxy`) and add the following router, service, and middleware:

```yaml
http:
  middlewares:
    cloudsync-cors:
      headers:
        accessControlAllowMethods:
          - "GET"
          - "PUT"
          - "HEAD"
          - "POST"
          - "DELETE"
          - "OPTIONS"
        accessControlAllowHeaders:
          - "Authorization"
          - "Content-Type"
          - "If-Match"
          - "If-None-Match"
          - "X-Amz-Content-Sha256"
          - "X-Amz-Date"
          - "X-Amz-Security-Token"
          - "X-Amz-User-Agent"
        accessControlExposeHeaders:
          - "ETag"
          - "Content-Length"
          - "x-amz-request-id"
        accessControlMaxAge: 86400
        accessControlAllowOriginList:
          - "app://obsidian.md"
          - "capacitor://localhost"
          - "http://localhost"
        addVaryHeader: true

  routers:
    cloudsync-garage:
      rule: Host(`cloudsync.example.com`)
      service: cloudsync-garage-service
      entrypoints: websecure
      middlewares: cloudsync-cors@file

  services:
    cloudsync-garage-service:
      loadBalancer:
        servers:
          - url: http://cloudsync-garage:3900
```

> **Note:** In `docker-compose.yml`, ports `3900` (S3 API) and `3903` (Admin API) are published for local testing. In production behind a reverse proxy, bind them to `127.0.0.1` or omit `ports:` entirely and communicate over an internal Docker network.

---

## Alternative: Cloud S3 Providers (AWS S3 / Cloudflare R2 / MinIO)

CloudSync works with any S3-compatible provider that supports Signature V4 and conditional `If-Match` / `If-None-Match` PUTs. Configure the following CORS policy on your bucket:

```json
[
  {
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["GET", "PUT", "HEAD", "POST", "DELETE"],
    "AllowedOrigins": [
      "app://obsidian.md",
      "capacitor://localhost",
      "http://localhost"
    ],
    "ExposeHeaders": ["ETag", "Content-Length"],
    "MaxAgeSeconds": 86400
  }
]
```

---

## Bucket Object Layout

Each vault bucket contains only two top-level entries managed by the CloudSync plugin:

```text
<bucket>/
├── manifest.json          # Vault file index & full revision history (ETag-locked)
└── blobs/
    └── <sha256_hex>       # Immutable, content-addressed file payloads
```

When client-side encryption is enabled in the plugin, both `manifest.json` and every blob under `blobs/` are encrypted locally with AES-256-GCM before upload.

---

## Security Notes

- **Never commit secrets or runtime data:** `.env`, `docker/`, `data/`, and `garage.toml` are excluded via `.gitignore`.
- **Keep Admin API private:** Port `3903` (`/garage` admin API) should never be exposed publicly through your reverse proxy.
- **Per-vault isolation:** Run `./init_bucket.sh` separately for each vault so every vault receives its own bucket and scoped S3 credentials.
