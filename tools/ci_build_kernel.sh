#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export GEMINIOS_LOG_DIR="${GEMINIOS_LOG_DIR:-$ROOT_DIR/logs}"
export GEMINIOS_OUTPUT_DIR="${GEMINIOS_OUTPUT_DIR:-$ROOT_DIR/output}"
export GEMINIOS_KERNEL_OUTPUT_DIR="${GEMINIOS_KERNEL_OUTPUT_DIR:-$GEMINIOS_OUTPUT_DIR/kernel}"
export GEMINIOS_KERNEL_STAGE_DIR="${GEMINIOS_KERNEL_STAGE_DIR:-/tmp/geminios-kernel-stage}"
export GEMINIOS_KERNEL_BUILD_DIR="${GEMINIOS_KERNEL_BUILD_DIR:-/tmp/geminios-kernel-build}"

mkdir -p \
  "$GEMINIOS_LOG_DIR" \
  "$GEMINIOS_OUTPUT_DIR" \
  "$GEMINIOS_KERNEL_OUTPUT_DIR" \
  "$GEMINIOS_KERNEL_STAGE_DIR" \
  "$GEMINIOS_KERNEL_BUILD_DIR" \
  "$ROOT_DIR/external_dependencies"

source "$ROOT_DIR/build_system/env_config.sh"

KERNEL_VERSION="linux-7.1-rc2"
KERNEL_SOURCE_URL="https://git.kernel.org/torvalds/t/linux-7.1-rc2.tar.gz"
KERNEL_SRC_DIR="$DEP_DIR/$KERNEL_VERSION"
KERNEL_ARCHIVE="$DEP_DIR/$(basename "$KERNEL_SOURCE_URL")"
KERNEL_ARTIFACT_DIR="$GEMINIOS_KERNEL_OUTPUT_DIR/$KERNEL_VERSION"

mkdir -p "$KERNEL_ARTIFACT_DIR"

download_kernel() {
  if [[ -d "$KERNEL_SRC_DIR" ]]; then
    echo "[*] Reusing kernel source tree at $KERNEL_SRC_DIR"
    return 0
  fi

  echo "[*] Downloading kernel source from $KERNEL_SOURCE_URL"
  mkdir -p "$DEP_DIR"
  rm -f "$KERNEL_ARCHIVE"
  wget -q --show-progress -O "$KERNEL_ARCHIVE" "$KERNEL_SOURCE_URL"
  tar -xzf "$KERNEL_ARCHIVE" -C "$DEP_DIR"
  rm -f "$KERNEL_ARCHIVE"
}

configure_kernel() {
  local config_tool="./scripts/config"

  make mrproper
  make x86_64_defconfig

  # GeminiOS baseline kernel support from the README.
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

  # Broader hardware and VM support for kernel package upgrades.
  "$config_tool" --enable CONFIG_PCI
  "$config_tool" --enable CONFIG_PCI_MSI
  "$config_tool" --enable CONFIG_PCIEPORTBUS
  "$config_tool" --enable CONFIG_VT
  "$config_tool" --enable CONFIG_VT_CONSOLE
  "$config_tool" --enable CONFIG_UNIX98_PTYS
  "$config_tool" --enable CONFIG_RTC_CLASS
  "$config_tool" --enable CONFIG_RTC_HCTOSYS
  "$config_tool" --set-str CONFIG_RTC_HCTOSYS_DEVICE rtc0
  "$config_tool" --enable CONFIG_RTC_DRV_CMOS
  "$config_tool" --enable CONFIG_HIDRAW
  "$config_tool" --enable CONFIG_USB_ACM
  "$config_tool" --enable CONFIG_USB_SERIAL
  "$config_tool" --enable CONFIG_USB_SERIAL_GENERIC
  "$config_tool" --enable CONFIG_DRM_VMWGFX
  "$config_tool" --enable CONFIG_FB_VIRTUAL
  "$config_tool" --enable CONFIG_E1000
  "$config_tool" --enable CONFIG_E1000E
  "$config_tool" --enable CONFIG_R8169
  "$config_tool" --enable CONFIG_8139CP
  "$config_tool" --enable CONFIG_BT_HCIBTUSB
  "$config_tool" --enable CONFIG_BT_HCIUSB
  "$config_tool" --enable CONFIG_CRYPTO_USER_API
  "$config_tool" --enable CONFIG_CRYPTO_USER_API_HASH
  "$config_tool" --enable CONFIG_CRYPTO_USER_API_SKCIPHER
  "$config_tool" --enable CONFIG_CRYPTO_USER_API_AEAD

  "$config_tool" --disable CONFIG_LOCALVERSION_AUTO
  "$config_tool" --set-str CONFIG_LOCALVERSION "-geminios"

  make olddefconfig
}

build_kernel() {
  pushd "$KERNEL_SRC_DIR" >/dev/null
  echo "[*] Configuring kernel $KERNEL_VERSION"
  configure_kernel
  echo "[*] Building kernel $KERNEL_VERSION with $(nproc) jobs"
  make -j"$(nproc)" bzImage modules
  echo "[*] Installing kernel modules into staged artifact tree"
  make modules_install INSTALL_MOD_PATH="$KERNEL_STAGE_DIR"
  popd >/dev/null
}

save_kernel_artifacts() {
  local kernel_release
  kernel_release="$(make -s -C "$KERNEL_SRC_DIR" kernelrelease)"

  cp -f "$KERNEL_SRC_DIR/arch/x86/boot/bzImage" "$KERNEL_ARTIFACT_DIR/bzImage"
  cp -f "$KERNEL_SRC_DIR/.config" "$KERNEL_ARTIFACT_DIR/config"
  cp -f "$KERNEL_SRC_DIR/System.map" "$KERNEL_ARTIFACT_DIR/System.map"
  printf '%s\n' "$kernel_release" > "$KERNEL_ARTIFACT_DIR/kernelrelease.txt"

  if [[ -d "$KERNEL_STAGE_DIR/lib/modules/$kernel_release" ]]; then
    mkdir -p "$KERNEL_ARTIFACT_DIR/modules"
    rsync -a "$KERNEL_STAGE_DIR/lib/modules/$kernel_release" "$KERNEL_ARTIFACT_DIR/modules/"
  fi

  echo "[*] Saved kernel image and metadata in $KERNEL_ARTIFACT_DIR"
}

download_kernel
build_kernel
save_kernel_artifacts
