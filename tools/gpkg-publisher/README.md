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
- Can discover packages automatically from the local APT cache instead of relying only on a hand-written seed list.
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

## Quick Start

This is the shortest clean setup path on a Debian 13 VPS.

### 1. Install dependencies

```bash
sudo apt update
sudo apt install -y git python3 dpkg-dev zstd rclone jq
```

### 2. Create the service user and directories

```bash
sudo useradd --system --home /var/lib/gpkg-publisher --shell /usr/sbin/nologin gpkg-publisher || true

sudo mkdir -p /etc/gpkg-publisher
sudo mkdir -p /var/lib/gpkg-publisher/cache/debs
sudo mkdir -p /var/lib/gpkg-publisher/repo/x86_64
sudo mkdir -p /var/lib/gpkg-publisher/tmp
sudo mkdir -p /var/lib/gpkg-publisher/state

sudo chown -R gpkg-publisher:gpkg-publisher /var/lib/gpkg-publisher
sudo chmod 755 /var/lib/gpkg-publisher
sudo chmod 755 /var/lib/gpkg-publisher/cache
sudo chmod 755 /var/lib/gpkg-publisher/cache/debs
```

### 3. Clone the repo and install the config files

```bash
sudo git clone https://github.com/CreitinGameplays/geminios.git /opt/geminios

sudo cp /opt/geminios/tools/gpkg-publisher/config.env.example /etc/gpkg-publisher/config.env
sudo cp /opt/geminios/tools/gpkg-publisher/overrides.example.json /etc/gpkg-publisher/overrides.json
sudo cp /opt/geminios/tools/gpkg-publisher/packages.txt.example /etc/gpkg-publisher/packages.txt
```

### 4. Configure `rclone` for Cloudflare R2

Do this as the `gpkg-publisher` user, not as `root`:

```bash
sudo -u gpkg-publisher -H rclone config
sudo -u gpkg-publisher -H rclone config file
```

Typical R2 values:

- type: `s3`
- provider: `Cloudflare`
- endpoint: `https://<accountid>.r2.cloudflarestorage.com`
- access key / secret key: your R2 credentials

If you want the service to use a fixed config path, copy it into `/etc/gpkg-publisher`:

```bash
sudo cp /var/lib/gpkg-publisher/.config/rclone/rclone.conf /etc/gpkg-publisher/rclone.conf
sudo chown root:gpkg-publisher /etc/gpkg-publisher/rclone.conf
sudo chmod 640 /etc/gpkg-publisher/rclone.conf
```

### 5. Edit `/etc/gpkg-publisher/config.env`

For aggressive automatic discovery, start with:

```text
DISCOVERY_MODE=all
REPO_ROOT=/var/lib/gpkg-publisher/repo
DOWNLOAD_DIR=/var/lib/gpkg-publisher/cache/debs
TEMP_DIR=/var/lib/gpkg-publisher/tmp
STATE_FILE=/var/lib/gpkg-publisher/state/state.json
REPORT_FILE=/var/lib/gpkg-publisher/state/last-run.json
OVERRIDES_FILE=/etc/gpkg-publisher/overrides.json
SYSTEM_PROVIDES_FILE=/opt/geminios/build_system/gpkg_system_provides.txt
RCLONE_DEST=r2:your-bucket/geminios
RCLONE_CONFIG=/etc/gpkg-publisher/rclone.conf
SECTION_ALLOWLIST=admin,editors,fonts,graphics,libs,misc,net,python,shells,sound,utils,vcs,video,x11,xfce
PACKAGE_LIMIT=500
```

If you want seed mode instead, set `DISCOVERY_MODE=seeds` and edit `/etc/gpkg-publisher/packages.txt`.

### 6. Run a dry run first

```bash
cd /opt/geminios
sudo -u gpkg-publisher -H python3 tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env \
  --dry-run
```

This prints:

- the package discovery mode
- how many packages resolved
- which packages failed policy or dependency resolution

Adjust `BLOCKLIST_PATTERNS`, `SECTION_ALLOWLIST`, `PACKAGE_LIMIT`, or `overrides.json` until the output looks sane.

### 7. Run the real publish

```bash
cd /opt/geminios
sudo -u gpkg-publisher -H python3 tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env
```

That will populate:

```text
/var/lib/gpkg-publisher/repo/x86_64/Packages.json.zst
/var/lib/gpkg-publisher/repo/x86_64/pool/<section>/*.gpkg
```

If upload is enabled, the same tree is copied to `RCLONE_DEST`, for example:

```text
r2:your-bucket/geminios/x86_64/Packages.json.zst
r2:your-bucket/geminios/x86_64/pool/...
```

## Automatic Full Discovery Mode

If you want the VPS to pull package names automatically instead of maintaining `packages.txt`, switch the config to:

```text
DISCOVERY_MODE=all
SECTION_ALLOWLIST=
SECTION_BLOCKLIST=debug,doc,devel,kernel,libdevel,metapackages,oldlibs
PRIORITY_BLOCKLIST=required,important
PACKAGE_LIMIT=0
```

What that does:

- `DISCOVERY_MODE=all` reads package names from `apt-cache dumpavail`.
- `SECTION_ALLOWLIST` lets you restrict discovery to a subset like `utils,net,python,xfce`.
- `SECTION_BLOCKLIST` removes noisy or risky sections.
- `PRIORITY_BLOCKLIST` keeps the importer away from core host packages by default.
- `PACKAGE_LIMIT` is useful for controlled ramp-up. Set `200` first, then grow.

The safest way to start is not literally "everything". Start with a broad but bounded set:

```text
DISCOVERY_MODE=all
SECTION_ALLOWLIST=admin,editors,fonts,graphics,libs,misc,net,python,shells,sound,utils,vcs,video,x11,xfce
PACKAGE_LIMIT=500
```

Then run:

```bash
python3 tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env \
  --dry-run
```

When that looks sane, remove the limit or raise it gradually.

## First Real Run

```bash
python3 tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env
```

You can also force full discovery without editing config:

```bash
python3 tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env \
  --all-packages
```

The script will:

1. Resolve seeds and dependencies.
2. Download `.deb` files into `DOWNLOAD_DIR`.
3. Convert changed packages into `.gpkg`.
4. Rebuild `Packages.json.zst` under `REPO_ROOT/x86_64`.
5. Upload `REPO_ROOT` if upload is enabled.

Large temporary files are now written under `TEMP_DIR`, so you do not need to rely on `/tmp` having enough space.

## Incremental Behavior

`publish.py` stores a fingerprint per package in `STATE_FILE`.

If all of the following are unchanged, the package is reused:

- Debian version
- `.deb` file hash
- package-specific override policy
- zstd level
- maintainer script policy

It also writes a small sidecar file next to each generated `.gpkg`, so a rerun can recover reuse even if the state file was incomplete.

Use `--force-import` when you want a full rebuild.

### Useful rerun commands

Retry everything except upload:

```bash
sudo -u gpkg-publisher -H python3 /opt/geminios/tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env \
  --skip-upload
```

Check how much state is already recorded:

```bash
sudo jq '.packages | length' /var/lib/gpkg-publisher/state/state.json
```

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

If you really want "as much of Debian as possible", do it in phases:

1. `DISCOVERY_MODE=all` with `PACKAGE_LIMIT=200`
2. widen to `PACKAGE_LIMIT=1000`
3. remove the limit only after you inspect `last-run.json` and the repo contents

That prevents your first run from becoming an unbounded failure pile.

## Overrides File

The overrides file is the pressure valve for imperfect Debian-to-GPKG mapping.

Supported top-level keys:

- `skip_packages`: extra package names or globs to skip.
- `skip_patterns`: extra name globs to treat as blocked.
- `skip_dependency_patterns`: dependency names to ignore during normalization.
- `provided_by_system_patterns`: dependency names or globs that should be dropped entirely because GeminiOS already ships the runtime or base-system equivalent.
- `dependency_choices`: choose one side of a Debian alternative dependency.
- `dependency_rewrites`: rewrite one dependency name to another before resolution. Use this for Debian-to-GeminiOS substitutions such as `libpam-systemd -> libpam-elogind`.
- `provider_choices`: choose a concrete package for a Debian virtual package when multiple providers exist.
- `package_overrides`: package-specific behavior.

The publisher already merges the base defaults from `SYSTEM_PROVIDES_FILE` into `provided_by_system_patterns`, so you usually only need to add site-specific extras in `overrides.json`.

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
- `drop_paths`
- `drop_path_patterns`
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

Example virtual-package provider choice:

```json
{
  "dependency_choices": {
    "lightdm::libpam-systemd | logind": "logind"
  },
  "dependency_rewrites": {
    "libpam-systemd": "libpam-elogind",
    "systemd": "elogind"
  },
  "provider_choices": {
    "logind": "libpam-elogind"
  }
}
```

Example payload filtering for packages that ship Debian config files GeminiOS must own itself:

```json
{
  "package_overrides": {
    "lightdm": {
      "drop_paths": [
        "/etc/pam.d/lightdm",
        "/etc/pam.d/lightdm-autologin",
        "/etc/pam.d/lightdm-greeter"
      ]
    }
  }
}
```

Use this when the imported Debian package installs config files that are valid on Debian but wrong for GeminiOS. The files are removed from the generated `.gpkg` payload before publish, so future installs and upgrades stop reintroducing them.

Example extra base-system dependency suppression:

```json
{
  "provided_by_system_patterns": [
    "debianutils",
    "init-system-helpers",
    "libc6",
    "libcrypt1",
    "libgcc-s1",
    "libstdc++6",
    "lsb-base",
    "perl-base",
    "python3-minimal",
    "sysvinit-utils"
  ]
}
```

Use that only for things GeminiOS already provides globally. This is the main lever for packages that fail only because they depend on Debian base runtime packages.

The resolver will automatically follow a virtual package to a provider when there is exactly one viable provider. If multiple providers exist, use `provider_choices` to make the selection explicit.

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

## Remote Cleanup

If older publishes left behind `%3a`-encoded object names or remote `.gpkg.build.json` sidecars, clean them with:

```bash
sudo -u gpkg-publisher -H python3 /opt/geminios/tools/gpkg-publisher/cleanup_remote.py \
  --config /etc/gpkg-publisher/config.env \
  --dry-run
```

If the dry run looks correct, run it again without `--dry-run`:

```bash
sudo -u gpkg-publisher -H python3 /opt/geminios/tools/gpkg-publisher/cleanup_remote.py \
  --config /etc/gpkg-publisher/config.env
```

By default it removes:

- remote `*.gpkg.build.json` sidecars
- legacy remote object names that still contain `%3a`

## Common Problems

### `RCLONE_CONFIG ... permission denied`

The file exists but the user running `publish.py` cannot read it.

Fix:

```bash
sudo chown root:gpkg-publisher /etc/gpkg-publisher/rclone.conf
sudo chmod 640 /etc/gpkg-publisher/rclone.conf
```

### `_apt` sandbox warnings during download

You are usually running the publisher as the wrong user or the cache directory permissions are too tight.

Fix:

```bash
sudo chown -R gpkg-publisher:gpkg-publisher /var/lib/gpkg-publisher
sudo chmod 755 /var/lib/gpkg-publisher
sudo chmod 755 /var/lib/gpkg-publisher/cache
sudo chmod 755 /var/lib/gpkg-publisher/cache/debs
```

Then run as:

```bash
sudo -u gpkg-publisher -H python3 /opt/geminios/tools/gpkg-publisher/publish.py --config /etc/gpkg-publisher/config.env
```

### `No space left on device`

Set `TEMP_DIR` to a location with real disk space and make sure it exists:

```bash
sudo mkdir -p /var/lib/gpkg-publisher/tmp
sudo chown -R gpkg-publisher:gpkg-publisher /var/lib/gpkg-publisher/tmp
```

### Package URL returns `404`, especially for versions with `:`

Older publisher runs generated repo object names like `1%3a2.0-1.gpkg`. Cloudflare R2 public URLs decode that path segment, so the object key and the public URL stop matching.

Fix:

1. Update the repo checkout to the newer publisher code.
2. Rerun the publisher once.

```bash
cd /opt/geminios
sudo -u gpkg-publisher -H python3 /opt/geminios/tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env \
  --skip-upload
sudo -u gpkg-publisher -H python3 /opt/geminios/tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env
```

The publisher now migrates legacy `%3a` repo filenames to literal `:` names before rebuilding `Packages.json.zst`, so it can usually repair the repo without rebuilding everything.

### Too many packages fail dependency resolution

Your filters are too strict for `DISCOVERY_MODE=all`.

Start by loosening:

```text
SECTION_ALLOWLIST=admin,editors,fonts,graphics,libs,misc,net,python,shells,sound,utils,vcs,video,x11,xfce
PACKAGE_LIMIT=500
```

If you want maximum repository growth, you may also need to trim `BLOCKLIST_PATTERNS`.

If failures look like this:

- `dependency libc6 could not be resolved`
- `dependency libgcc-s1 could not be resolved`
- `dependency python3-minimal could not be resolved`
- `dependency init-system-helpers could not be resolved`

then the fix is usually not "import more Essential packages". The better fix is to add those names to `provided_by_system_patterns` in `overrides.json`, assuming GeminiOS already ships the equivalent runtime.

If failures look like this:

- `package is marked Essential: yes`
- `matched the configured blocklist`

then those are expected policy skips. Usually leave them skipped. Only relax them if you deliberately want to import core base-system packages and accept the risk.

Top-level packages skipped by policy now appear under `skipped` in `last-run.json` instead of `failures`, so intentionally blocked packages such as `systemd` should no longer look like unresolved repository errors.

### Desktop package wants `libsystemd0`

`libsystemd0` is a shared runtime library, not the `systemd` init system itself. Desktop packages may legitimately need the library even if GeminiOS does not boot with `systemd`.

Recommended approach:

1. Keep `systemd*`, `udev`, and `libpam-systemd` blocked.
2. Do not mark `libsystemd0` as "provided by system" unless GeminiOS already ships a compatible `libsystemd.so.0`.
3. Allow the publisher to import `libsystemd0` and republish.
4. Rewrite dependency names that should map to GeminiOS equivalents instead of Debian `systemd` packages.

Example:

```json
{
  "skip_packages": [
    "systemd",
    "libpam-systemd"
  ],
  "dependency_choices": {
    "lightdm::libpam-systemd | logind": "logind"
  },
  "dependency_rewrites": {
    "libpam-systemd": "libpam-elogind",
    "systemd": "elogind"
  },
  "provider_choices": {
    "logind": "libpam-elogind"
  }
}
```

If your local config still blocks `libsystemd*`, change it to something narrower, for example:

```text
BLOCKLIST_PATTERNS=base-files,base-passwd,bash,debianutils,dpkg,gcc-*,glibc-*,grub*,init,initramfs-tools*,linux-*,libc6,libpam*,libpam-systemd,mount,openssh-server,passwd,systemd*,sysvinit*,udev,util-linux
```

Then rerun:

```bash
sudo -u gpkg-publisher -H python3 /opt/geminios/tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env \
  --skip-upload
sudo -u gpkg-publisher -H python3 /opt/geminios/tools/gpkg-publisher/publish.py \
  --config /etc/gpkg-publisher/config.env
```

After that, inside GeminiOS:

```bash
sudo gpkg update
sudo gpkg install libsystemd0
sudo gpkg install xfce4 xfce4-goodies
```

If `libsystemd0` itself pulls in something genuinely unsupported, that is the point where you either package a compatibility shim or drop the affected desktop packages. Do not solve it by globally pretending `libsystemd0` exists when it does not.

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
