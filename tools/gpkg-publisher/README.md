# GPKG Publisher

This directory contains a VPS-oriented publisher for GeminiOS `.gpkg` repositories.

It does four things:

1. Discovers package directories by scanning one or more roots for `control.json`.
2. Runs an optional per-package `build.sh` hook.
3. Builds `.gpkg` files with the GeminiOS SDK and generates `Packages.json.zst`.
4. Uploads the resulting repository to object storage with `rclone`.

## Why this storage choice

Start with Backblaze B2 if you want the simplest low-friction S3-compatible backend for a public package repo.

Why:

- It is S3-compatible, so `rclone` can push to it without custom code.
- Backblaze advertises a free starting tier and a `Start Free` flow.
- GitHub Pages is not a good fit for a large binary repo because GitHub documents a `1 GB` published site limit and a soft `100 GB` monthly bandwidth limit.
- Cloudflare R2 is still a good later option, but Cloudflare's R2 auth docs state that you must purchase R2 before you can generate API tokens.
- Backblaze's public bucket guide says your first public bucket may require payment history or a small credited card charge, so treat it as the closest practical free option rather than a guaranteed zero-card option.

Official references to verify before you commit to the backend:

- Backblaze B2 pricing: <https://www.backblaze.com/cloud-storage/pricing>
- Backblaze B2 start-free page: <https://www.backblaze.com/sign-up/cloud-storage>
- Backblaze public bucket delivery guide: <https://www.backblaze.com/docs/cloud-storage-deliver-public-backblaze-b2-content-through-cloudflare-cdn>
- Cloudflare R2 pricing: <https://developers.cloudflare.com/r2/pricing/>
- Cloudflare R2 API tokens / S3 credentials: <https://developers.cloudflare.com/r2/api/tokens/>
- rclone S3 backend docs: <https://rclone.org/s3/>
- GitHub Pages limits: <https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits>

If you need a strict zero-billing setup, use GitHub Pages only for a small test repo. For a real binary package feed, keep this publisher and point `rclone` at whichever S3-compatible backend fits your budget and verification requirements.

## Files

- `publish.py`: main build-and-publish entrypoint
- `config.env.example`: environment file template
- `systemd/gpkg-publisher.service`: service unit
- `systemd/gpkg-publisher.timer`: timer unit

## Package layout expected by the SDK

The publisher relies on the GeminiOS SDK tools in `/home/creitin/Documents/geminios-sdk/`:

- `gpkg-build` builds each package directory into a `.gpkg`
- `gpkg-scanrepo` creates `Packages.json.zst` inside each architecture directory

Each package directory must contain `control.json` and either `root/` or `data/`.

## Recommended repository shape on the VPS

```text
/srv/geminios/
├── packages/                   # package sources scanned by PACKAGE_ROOTS
│   ├── app-a/
│   │   ├── control.json
│   │   ├── root/
│   │   └── build.sh            # optional
│   └── app-b/
└── tools/gpkg-publisher/
```

```text
/srv/gpkg-publisher/
├── work/                       # lock file and failed run artifacts
└── repo/
    ├── x86_64/
    │   ├── foo_1.0.0_x86_64.gpkg
    │   └── Packages.json.zst
    └── aarch64/
```

## 1. Provision the VPS

On Debian 13:

```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-venv zstd rsync rclone
```

Clone both repositories somewhere stable, for example:

```bash
sudo mkdir -p /srv
sudo chown "$USER":"$USER" /srv
git clone https://github.com/CreitinGameplays/geminios.git /srv/geminios
git clone https://github.com/CreitinGameplays/geminios-sdk.git /srv/geminios-sdk
```

Install the SDK commands:

```bash
python3 -m pip install /srv/geminios-sdk
```

## 2. Create the storage bucket and credentials

### Option A: Backblaze B2 (recommended first)

Use the Backblaze dashboard and docs linked above to do this:

1. Create a B2 bucket, for example `geminios-packages`.
2. Set the bucket visibility to `public`.
3. Create an application key with bucket read/write access.
4. Note the S3 endpoint and final public URL, for example `https://f000.backblazeb2.com/file/geminios-packages/repo/`.

Backblaze caveat:

- Backblaze documents that the first public bucket may require verified email plus payment history or a small credited card charge.

### Option B: Cloudflare R2

Use R2 if you already have Cloudflare billing enabled:

1. Create an R2 bucket, for example `geminios-packages`.
2. Generate R2 API credentials with read/write access to that bucket.
3. Make the bucket publicly readable with an R2 custom domain or public bucket URL.
4. Decide the final repository base URL, for example `https://packages.example.com/repo/`.

The publisher does not need the public URL, but GeminiOS clients will.

## 3. Configure `rclone`

Run:

```bash
rclone config
```

Create a new remote for B2:

- `name`: `geminios-b2`
- `storage`: `s3`
- `provider`: `Backblaze`
- `access_key_id`: your B2 key ID
- `secret_access_key`: your B2 application key
- `endpoint`: your B2 S3 endpoint, for example `https://s3.us-west-002.backblazeb2.com`

Test it:

```bash
rclone lsd geminios-b2:
```

If you use R2 instead, create another remote with:

- `provider`: `Cloudflare`
- `endpoint`: `https://<accountid>.r2.cloudflarestorage.com`

## 4. Install the publisher files

Copy this directory into the VPS repo if it is not already there:

```bash
cd /srv/geminios
mkdir -p /srv/gpkg-publisher
cp tools/gpkg-publisher/config.env.example /etc/gpkg-publisher.env
```

Edit `/etc/gpkg-publisher.env`:

```dotenv
PACKAGE_ROOTS=/srv/geminios/packages
WORK_ROOT=/srv/gpkg-publisher/work
PUBLISH_ROOT=/srv/gpkg-publisher/repo
BUILD_JOBS=4
RUN_BUILD_HOOKS=true
PUBLISH_ENABLED=true
UPLOAD_BACKEND=rclone
RCLONE_REMOTE=geminios-b2:geminios-packages/repo
RCLONE_EXTRA_ARGS=--fast-list --s3-no-check-bucket
```

Notes:

- `PACKAGE_ROOTS` is recursive. Every `control.json` below that path is treated as a package.
- `RUN_BUILD_HOOKS=true` runs `build.sh` inside a package directory before `gpkg-build`.
- `BUILD_JOBS` should stay low if package hooks share compiler caches or mutable staging trees.

## 5. Test one manual publish

First list what would be built:

```bash
cd /srv/geminios
set -a
. /etc/gpkg-publisher.env
set +a
python3 tools/gpkg-publisher/publish.py --list-packages
```

Then run the full publisher:

```bash
cd /srv/geminios
set -a
. /etc/gpkg-publisher.env
set +a
python3 tools/gpkg-publisher/publish.py
```

If the run succeeds, the repo will exist locally under `PUBLISH_ROOT` and remotely under `RCLONE_REMOTE`.

## 6. Enable unattended publishing with `systemd`

Install the units:

```bash
sudo cp /srv/geminios/tools/gpkg-publisher/systemd/gpkg-publisher.service /etc/systemd/system/
sudo cp /srv/geminios/tools/gpkg-publisher/systemd/gpkg-publisher.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpkg-publisher.timer
```

Useful commands:

```bash
systemctl list-timers gpkg-publisher.timer
sudo systemctl start gpkg-publisher.service
journalctl -u gpkg-publisher.service -n 200 --no-pager
```

## Operational notes

- The publisher takes an exclusive lock, so overlapping timer runs will fail fast instead of corrupting the repo.
- Build artifacts are staged under `WORK_ROOT/run-*` and synced into `PUBLISH_ROOT` only after indexing completes.
- Failed runs are preserved by default. Set `KEEP_FAILED_RUN=false` if you prefer automatic cleanup.
- The SDK scanner should not be run concurrently on the same repo tree; this publisher avoids that by scanning only inside the per-run staging directory.
