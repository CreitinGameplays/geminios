#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export GEMINIOS_BOOTSTRAP_CACHE_DIR="${GEMINIOS_BOOTSTRAP_CACHE_DIR:-$ROOT_DIR/external_dependencies/debian-bootstrap}"
export GEMINIOS_ISO_WORK_DIR="${GEMINIOS_ISO_WORK_DIR:-$ROOT_DIR/isodir}"
export GEMINIOS_ISO_OUTPUT_DIR="${GEMINIOS_ISO_OUTPUT_DIR:-$ROOT_DIR/output/iso}"
export GEMINIOS_LOG_DIR="${GEMINIOS_LOG_DIR:-$ROOT_DIR/logs}"
export GEMINIOS_OUTPUT_DIR="${GEMINIOS_OUTPUT_DIR:-$ROOT_DIR/output}"

mkdir -p \
  "$GEMINIOS_BOOTSTRAP_CACHE_DIR" \
  "$GEMINIOS_ISO_WORK_DIR" \
  "$GEMINIOS_ISO_OUTPUT_DIR" \
  "$GEMINIOS_LOG_DIR" \
  "$GEMINIOS_OUTPUT_DIR" \
  "$ROOT_DIR/external_dependencies"

mkdir -p "$HOME/.pyenv/versions/3.11.9/bin"
if command -v python3 >/dev/null 2>&1; then
  ln -sf "$(command -v python3)" "$HOME/.pyenv/versions/3.11.9/bin/python3"
fi
if command -v python3.11 >/dev/null 2>&1; then
  ln -sf "$(command -v python3.11)" "$HOME/.pyenv/versions/3.11.9/bin/python3.11"
elif command -v python3 >/dev/null 2>&1; then
  ln -sf "$(command -v python3)" "$HOME/.pyenv/versions/3.11.9/bin/python3.11"
fi

source "$ROOT_DIR/build_system/env_config.sh"

kernel_name="$KERNEL_VERSION"
kernel_src_dir="$DEP_DIR/$kernel_name"
kernel_archive="$DEP_DIR/$kernel_name.tar.xz"
kernel_version="${kernel_name#linux-}"
kernel_major="${kernel_version%%.*}"

if [[ "$kernel_version" == *-rc* ]]; then
  kernel_series="v${kernel_major}.x/testing"
else
  kernel_series="v${kernel_major}.x"
fi

kernel_url="https://cdn.kernel.org/pub/linux/kernel/${kernel_series}/${kernel_name}.tar.xz"

download_kernel() {
  if [[ -d "$kernel_src_dir" ]]; then
    return
  fi

  echo "[*] Downloading kernel source from $kernel_url"
  wget -q --show-progress -O "$kernel_archive" "$kernel_url"
  tar -xf "$kernel_archive" -C "$DEP_DIR"
  rm -f "$kernel_archive"
}

configure_kernel() {
  local config_tool="./scripts/config"

  make x86_64_defconfig

  "$config_tool" --enable CONFIG_FB
  "$config_tool" --enable CONFIG_FB_VESA
  "$config_tool" --enable CONFIG_FB_EFI
  "$config_tool" --enable CONFIG_DRM
  "$config_tool" --enable CONFIG_DRM_KMS_HELPER
  "$config_tool" --enable CONFIG_DRM_SIMPLEDRM
  "$config_tool" --enable CONFIG_DRM_BOCHS
  "$config_tool" --enable CONFIG_DRM_VIRTIO_GPU
  "$config_tool" --enable CONFIG_FRAMEBUFFER_CONSOLE
  "$config_tool" --enable CONFIG_DRM_FBDEV_EMULATION
  "$config_tool" --set-val CONFIG_DRM_FBDEV_OVERALLOC 100
  "$config_tool" --enable CONFIG_INPUT_EVDEV

  "$config_tool" --enable CONFIG_SQUASHFS
  "$config_tool" --enable CONFIG_SQUASHFS_ZSTD
  "$config_tool" --enable CONFIG_SQUASHFS_XZ
  "$config_tool" --enable CONFIG_OVERLAY_FS
  "$config_tool" --enable CONFIG_BLK_DEV_LOOP
  "$config_tool" --enable CONFIG_ISO9660_FS
  "$config_tool" --enable CONFIG_DEVTMPFS
  "$config_tool" --enable CONFIG_DEVTMPFS_MOUNT
  "$config_tool" --enable CONFIG_TMPFS
  "$config_tool" --enable CONFIG_MSDOS_PARTITION
  "$config_tool" --enable CONFIG_EFI_PARTITION
  "$config_tool" --enable CONFIG_EXT4_FS
  "$config_tool" --enable CONFIG_EXT4_USE_FOR_EXT2

  "$config_tool" --enable CONFIG_SECURITY
  "$config_tool" --enable CONFIG_SECURITYFS
  "$config_tool" --enable CONFIG_AUDIT
  "$config_tool" --enable CONFIG_AUDITSYSCALL
  "$config_tool" --enable CONFIG_NETLABEL
  "$config_tool" --enable CONFIG_DEFAULT_SECURITY_SELINUX
  "$config_tool" --disable CONFIG_DEFAULT_SECURITY_DAC
  "$config_tool" --enable CONFIG_SECURITY_SELINUX
  "$config_tool" --enable CONFIG_SECURITY_SELINUX_BOOTPARAM
  "$config_tool" --set-val CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE 1
  "$config_tool" --enable CONFIG_SECURITY_SELINUX_DEVELOP
  "$config_tool" --enable CONFIG_SECURITY_SELINUX_AVC_STATS
  "$config_tool" --enable CONFIG_EXT4_FS_SECURITY
  "$config_tool" --enable CONFIG_XFS_FS
  "$config_tool" --enable CONFIG_XFS_POSIX_ACL
  "$config_tool" --enable CONFIG_BTRFS_FS

  "$config_tool" --enable CONFIG_FUSE_FS
  "$config_tool" --enable CONFIG_CUSE
  "$config_tool" --enable CONFIG_VFAT_FS
  "$config_tool" --enable CONFIG_EXFAT_FS
  "$config_tool" --enable CONFIG_NTFS3_FS
  "$config_tool" --enable CONFIG_F2FS_FS
  "$config_tool" --enable CONFIG_UDF_FS
  "$config_tool" --enable CONFIG_EXT4_FS_POSIX_ACL
  "$config_tool" --enable CONFIG_BTRFS_FS_POSIX_ACL
  "$config_tool" --enable CONFIG_TMPFS_POSIX_ACL
  "$config_tool" --enable CONFIG_FS_POSIX_ACL
  "$config_tool" --enable CONFIG_AUTOFS_FS

  "$config_tool" --enable CONFIG_ATA
  "$config_tool" --enable CONFIG_SATA_AHCI
  "$config_tool" --enable CONFIG_SCSI
  "$config_tool" --enable CONFIG_BLK_DEV_SD
  "$config_tool" --enable CONFIG_CHR_DEV_SG
  "$config_tool" --enable CONFIG_NVME_CORE
  "$config_tool" --enable CONFIG_BLK_DEV_NVME
  "$config_tool" --enable CONFIG_USB_STORAGE
  "$config_tool" --enable CONFIG_MMC
  "$config_tool" --enable CONFIG_MMC_BLOCK
  "$config_tool" --enable CONFIG_DM_CRYPT
  "$config_tool" --enable CONFIG_MD
  "$config_tool" --enable CONFIG_BLK_DEV_DM

  "$config_tool" --enable CONFIG_INPUT_KEYBOARD
  "$config_tool" --enable CONFIG_INPUT_MOUSE
  "$config_tool" --enable CONFIG_INPUT_TOUCHSCREEN
  "$config_tool" --enable CONFIG_HID
  "$config_tool" --enable CONFIG_HID_GENERIC
  "$config_tool" --enable CONFIG_HID_MULTITOUCH
  "$config_tool" --enable CONFIG_I2C_HID
  "$config_tool" --enable CONFIG_I2C_HID_ACPI
  "$config_tool" --enable CONFIG_SERIO
  "$config_tool" --enable CONFIG_SERIO_I8042
  "$config_tool" --enable CONFIG_LEGACY_PTYS

  "$config_tool" --enable CONFIG_AGP
  "$config_tool" --enable CONFIG_BACKLIGHT_CLASS_DEVICE
  "$config_tool" --enable CONFIG_DRM_AMDGPU
  "$config_tool" --enable CONFIG_DRM_RADEON
  "$config_tool" --enable CONFIG_DRM_I915
  "$config_tool" --enable CONFIG_DRM_NOUVEAU
  "$config_tool" --enable CONFIG_FB_SIMPLE

  "$config_tool" --enable CONFIG_SOUND
  "$config_tool" --enable CONFIG_SND
  "$config_tool" --enable CONFIG_SND_HDA_INTEL
  "$config_tool" --enable CONFIG_SND_HDA_CODEC_HDMI
  "$config_tool" --enable CONFIG_SND_USB_AUDIO
  "$config_tool" --enable CONFIG_SND_HRTIMER
  "$config_tool" --enable CONFIG_SND_SEQ
  "$config_tool" --enable CONFIG_SND_TIMER

  "$config_tool" --enable CONFIG_PACKET
  "$config_tool" --enable CONFIG_UNIX
  "$config_tool" --enable CONFIG_INET
  "$config_tool" --enable CONFIG_IPV6
  "$config_tool" --enable CONFIG_CFG80211
  "$config_tool" --enable CONFIG_MAC80211
  "$config_tool" --enable CONFIG_RFKILL
  "$config_tool" --enable CONFIG_WLAN
  "$config_tool" --enable CONFIG_BT
  "$config_tool" --enable CONFIG_BT_BREDR
  "$config_tool" --enable CONFIG_BT_RFCOMM
  "$config_tool" --enable CONFIG_BT_HIDP

  "$config_tool" --enable CONFIG_USB_SUPPORT
  "$config_tool" --enable CONFIG_USB_XHCI_HCD
  "$config_tool" --enable CONFIG_USB_EHCI_HCD
  "$config_tool" --enable CONFIG_USB_OHCI_HCD
  "$config_tool" --enable CONFIG_USB_HID
  "$config_tool" --enable CONFIG_USB_UAS
  "$config_tool" --enable CONFIG_TYPEC
  "$config_tool" --enable CONFIG_TYPEC_UCSI
  "$config_tool" --enable CONFIG_UCSI_ACPI

  "$config_tool" --enable CONFIG_ACPI
  "$config_tool" --enable CONFIG_ACPI_BATTERY
  "$config_tool" --enable CONFIG_ACPI_BUTTON
  "$config_tool" --enable CONFIG_ACPI_VIDEO
  "$config_tool" --enable CONFIG_CPU_FREQ
  "$config_tool" --enable CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
  "$config_tool" --enable CONFIG_CPU_IDLE
  "$config_tool" --enable CONFIG_THERMAL
  "$config_tool" --enable CONFIG_THERMAL_HWMON
  "$config_tool" --enable CONFIG_HW_RANDOM

  "$config_tool" --enable CONFIG_VIRTIO
  "$config_tool" --enable CONFIG_VIRTIO_PCI
  "$config_tool" --enable CONFIG_VIRTIO_BLK
  "$config_tool" --enable CONFIG_VIRTIO_NET
  "$config_tool" --enable CONFIG_VIRTIO_INPUT
  "$config_tool" --enable CONFIG_VIRTIO_CONSOLE
  "$config_tool" --enable CONFIG_VSOCKETS
  "$config_tool" --enable CONFIG_HYPERV
  "$config_tool" --enable CONFIG_HYPERV_STORAGE
  "$config_tool" --enable CONFIG_HYPERV_NET
  "$config_tool" --enable CONFIG_PARAVIRT

  "$config_tool" --enable CONFIG_NAMESPACES
  "$config_tool" --enable CONFIG_UTS_NS
  "$config_tool" --enable CONFIG_IPC_NS
  "$config_tool" --enable CONFIG_PID_NS
  "$config_tool" --enable CONFIG_NET_NS
  "$config_tool" --enable CONFIG_CGROUPS
  "$config_tool" --enable CONFIG_CGROUP_FREEZER
  "$config_tool" --enable CONFIG_CGROUP_DEVICE
  "$config_tool" --enable CONFIG_CGROUP_PIDS
  "$config_tool" --enable CONFIG_MEMCG
  "$config_tool" --enable CONFIG_BPF
  "$config_tool" --enable CONFIG_BPF_SYSCALL

  make olddefconfig
}

build_kernel() {
  if [[ -f "$kernel_src_dir/arch/x86/boot/bzImage" ]]; then
    echo "[*] Reusing existing kernel image at $kernel_src_dir/arch/x86/boot/bzImage"
    return
  fi

  pushd "$kernel_src_dir" >/dev/null
  echo "[*] Configuring kernel $kernel_name"
  configure_kernel
  echo "[*] Building kernel $kernel_name with $(nproc) jobs"
  make -j"$(nproc)" bzImage
  popd >/dev/null
}

download_kernel
build_kernel

echo "[*] Building GeminiOS ISO"
python3 builder.py

echo "[*] ISO output directory: $GEMINIOS_ISO_OUTPUT_DIR"
find "$GEMINIOS_ISO_OUTPUT_DIR" -maxdepth 1 -type f -name '*.iso' -print | sed -n '1,20p'
