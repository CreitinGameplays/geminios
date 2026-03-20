# GPKG Publisher

This directory contains a bulk importer and publisher for growing a GeminiOS package repository from Debian 13 packages.

The model is simple:

1. Resolve a seed list with APT on a Debian VPS.
2. Download the `.deb` files for the selected closure.
3. Repack safe packages into `.gpkg`.
4. Rebuild `Packages.json.zst`.
5. Upload the static repo to Cloudflare R2 or another S3-compatible target.

It is designed to scale repository size quickly without turning the VPS into a source build farm.

## What This Tool Does

- Uses the host APT metadata to resolve package closures.
- Reuses Debian binary payloads instead of compiling from source.
- Converts each `.deb` into a `.gpkg` that matches the current GeminiOS v2 layout.
- Writes a repo tree that `gpkg` can consume at `<base-url>/x86_64/Packages.json.zst`.
- Supports a JSON overrides file for dependency choices, package skips, renames, and script policy.
- Keeps a local state file so unchanged packages are not rebuilt on every run.

## Safety Model

This is intentionally conservative.

- `Essential: yes` packages are skipped by default.
- A built-in blocklist excludes kernel, init, bootloader, and core host packages.
- Debian maintainer scripts are not copied by default.
- If a package depends on blocked or unresolved packages, the importer reports the failure and continues with other packages.

This is the right default for "grow the repo fast without bricking the design".

## Files

- `publish.py`: bulk resolver, downloader, importer, indexer, and uploader.
- `import_deb.py`: standalone `.deb` to `.gpkg` converter.
- `common.py`: shared helpers.
- `config.env.example`: sample runtime configuration.
- `packages.txt.example`: sample seed list.
- `overrides.example.json`: sample policy overrides.
- `systemd/`: timer and service units for unattended runs.

## VPS Prerequisites

Install the base dependencies on the Debian 13 VPS:

```bash
sudo apt update
sudo apt install -y python3 dpkg-dev zstd rclone
```

`apt`, `apt-cache`, `apt-get`, and `dpkg-deb` are expected to be available on the host already.

## Recommended Layout

Use a split layout so the repo content, config, and code are easy to reason about:

```text
/opt/geminios/                          # this repository checkout
/etc/gpkg-publisher/
  config.env
  packages.txt
  overrides.json
/var/lib/gpkg-publisher/
  cache/debs/
  repo/x86_64/
  state/state.json
  state/last-run.json
```

## Cloudflare R2 Setup

The simplest upload backend is `rclone`.

Configure an R2 remote:

```bash
rclone config
```

Typical values:

- type: `s3`
- provider: `Cloudflare`
- access key / secret key: your R2 credentials
- endpoint: your account endpoint, for example `https://<accountid>.r2.cloudflarestorage.com`

Then test it:

```bash
rclone ls r2:your-bucket
```

Set `RCLONE_DEST` to the bucket path that should contain the published repo root, for example:

```bash
RCLONE_DEST=r2:your-bucket/geminios
```

That produces:

```text
r2:your-bucket/geminios/x86_64/Packages.json.zst
r2:your-bucket/geminios/x86_64/pool/...
```

## Initial Setup

1. Copy `config.env.example` to `/etc/gpkg-publisher/config.env`.
2. Copy `packages.txt.example` to `/etc/gpkg-publisher/packages.txt` and edit it.
3. Copy `overrides.example.json` to `/etc/gpkg-publisher/overrides.json` and trim it to what you need.
4. Create the working directories:

```bash
sudo mkdir -p /etc/gpkg-publisher
sudo mkdir -p /var/lib/gpkg-publisher/cache/debs
sudo mkdir -p /var/lib/gpkg-publisher/repo/x86_64
sudo mkdir -p /var/lib/gpkg-publisher/state
```

## First Dry Run

Run the resolver without downloading or publishing:

```bash
python3 tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env \
  --dry-run
```

This prints:

- the seed packages
- how many packages resolved
- which packages failed policy or dependency resolution

Fix failures in `overrides.json` or reduce the seed list until the result is acceptable.

## First Real Run

```bash
python3 tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env
```

The script will:

1. Resolve seeds and dependencies.
2. Download `.deb` files into `DOWNLOAD_DIR`.
3. Convert changed packages into `.gpkg`.
4. Rebuild `Packages.json.zst` under `REPO_ROOT/x86_64`.
5. Upload `REPO_ROOT` if upload is enabled.

## Incremental Behavior

`publish.py` stores a fingerprint per package in `STATE_FILE`.

If all of the following are unchanged, the package is reused:

- Debian version
- `.deb` file hash
- package-specific override policy
- zstd level
- maintainer script policy

Use `--force-import` when you want a full rebuild.

## Seed List Strategy

Start with userland packages and libraries:

- CLI tools
- desktop applications
- themes and icon packs
- fonts
- X11 and Wayland libraries
- media and graphics libraries

Avoid starting with:

- kernels
- init systems
- boot tooling
- PAM stacks
- `systemd`
- `udev`
- compiler toolchains

The goal is fast breadth, not full base-system parity on day one.

## Overrides File

The overrides file is the pressure valve for imperfect Debian-to-GPKG mapping.

Supported top-level keys:

- `skip_packages`: extra package names or globs to skip.
- `skip_patterns`: extra name globs to treat as blocked.
- `skip_dependency_patterns`: dependency names to ignore during normalization.
- `dependency_choices`: choose one side of a Debian alternative dependency.
- `package_overrides`: package-specific behavior.

Supported `package_overrides.<name>` keys:

- `skip`
- `rename`
- `section`
- `architecture`
- `maintainer`
- `description`
- `depends_add`
- `depends_remove`
- `conflicts_add`
- `provides_add`
- `include_maintainer_scripts`
- `drop_scripts`

Example dependency choice:

```json
{
  "dependency_choices": {
    "debconf | debconf-2.0": "debconf",
    "libgtk-3-0::dconf-gsettings-backend | gsettings-backend": "dconf-gsettings-backend"
  }
}
```

Package-specific choices use the format:

```text
<package-name>::<original-dependency-group>
```

## Standalone Import

You can convert a single `.deb` manually:

```bash
python3 tools/gpkg-publisher/import_deb.py \
  /path/to/package.deb \
  --repo-arch-dir /var/lib/gpkg-publisher/repo/x86_64 \
  --overrides-file /etc/gpkg-publisher/overrides.json
```

## Upload Backends

There are two upload modes:

1. `RCLONE_DEST`
   Best for Cloudflare R2.

2. `UPLOAD_COMMAND`
   Fully custom command template. Available placeholders:
   - `{repo_root}`
   - `{arch_dir}`

If `UPLOAD_COMMAND` is set, it takes precedence over `RCLONE_DEST`.

Example:

```text
UPLOAD_COMMAND=rclone copy {repo_root} r2:your-bucket/geminios --fast-list --checksum
```

## Systemd

The supplied unit files assume:

- repo checkout: `/opt/geminios`
- config file: `/etc/gpkg-publisher/config.env`
- working state: `/var/lib/gpkg-publisher`
- service user: `gpkg-publisher`

Install them like this:

```bash
sudo useradd --system --home /var/lib/gpkg-publisher --shell /usr/sbin/nologin gpkg-publisher
sudo cp tools/gpkg-publisher/systemd/gpkg-publisher.service /etc/systemd/system/
sudo cp tools/gpkg-publisher/systemd/gpkg-publisher.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpkg-publisher.timer
```

Manual run:

```bash
sudo systemctl start gpkg-publisher.service
sudo journalctl -u gpkg-publisher.service -f
```

## Operational Notes

- `last-run.json` is the quickest place to inspect failures after a timer run.
- If a package repeatedly fails because of complex maintainer logic, either override it or drop it.
- The repo scanner runs after conversion finishes. Do not parallelize multiple publisher instances against the same repo root.
- If you want tighter control over categories, use the Debian `Section` via overrides and keep output under `pool/<section>/`.

## Next Improvements

If you want this to go beyond the initial bootstrap, the next useful additions are:

- a review queue for packages that require maintainer scripts
- a mapping table for Debian virtual packages versus GeminiOS equivalents
- trigger-aware post-processing for icons, mime, glib schemas, and font cache
- optional promote-to-stable logic after test installs succeed
