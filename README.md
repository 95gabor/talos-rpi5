# Talos Raspberry Pi 5 image build

Build a **Raspberry Pi 5** Talos disk image and installer image for **USB SSD / NVMe boot** with release **v1.14.5**.

The upstream `rpi_5` overlay does not boot on all Pi 5 boards ([sbc-raspberrypi#96](https://github.com/siderolabs/sbc-raspberrypi/issues/96)), so the overlay is built from upstream `sbc-raspberrypi` (`bc6af94`, v0.2.0) plus:

- `patches/sbc-raspberrypi/` — [sbc-raspberrypi#88](https://github.com/siderolabs/sbc-raspberrypi/pull/88) (Pi 5 support in the `rpi_generic` U-Boot build)
- `patches/dtb/` — local device tree patches (see below)

Kernel args baked into the images (`EXTRA_KERNEL_ARGS`):

- `usb-storage.delay_use=0` — attach the USB SSD without the default 1s delay. Without it Talos may look for the `STATE` partition before the disk shows up, find no machine config and boot into maintenance mode.
- `talos.device.settle_time=3s` — wait 3s after udev settles before Talos looks for its volumes. Even with `delay_use=0` the SSD partitions appear ~100ms after Talos marks `STATE` missing, so it enters maintenance mode and never retries.

DT patch `0014` disables the microSD controller (`&sdio1`) for USB/NVMe boot; `config.txt` sets `sd=off`. This stops perpetual `mmc0` SDHCI timeouts ([#92](https://github.com/siderolabs/sbc-raspberrypi/issues/92)). Re-enable the slot only if you rebuild without `0014` and use `sd=on` in `config.txt`.

## Prerequisites

- Docker with buildx (`docker buildx ls`)
- GNU `make` on macOS (`brew install make`, then `gmake` is used automatically)
- Enough disk space (~10–20 GB for build caches)

## CI

Every push to `main` builds on a GitHub arm64 runner and pushes the installer to
`ghcr.io/95gabor/talos-rpi5-installer:<talos version>` and `:<talos version>-<short sha>`.
The disk image is uploaded as a workflow artifact, and attached to a GitHub release for `v*` tags.

Upgrade a node in place (keeps the machine config and `EPHEMERAL`):

```bash
talosctl upgrade -n <node> --image ghcr.io/95gabor/talos-rpi5-installer:v1.14.5
```

Use the same image as `machine.install.image` in the machine config.

## Quick build

```bash
./build-rpi5.sh prepare   # clone sbc-raspberrypi and apply ./patches
./build-rpi5.sh all
```

Artifacts land in `_out/`:

- `metal-arm64.raw.xz` — flash to your **USB SSD** (after decompress)
- `installer-arm64.tar` — installer image for `talosctl upgrade` (`docker load -i`, then push)

## Flash to USB SSD

```bash
xz -dk _out/metal-arm64.raw.xz
# Replace /dev/rdiskN with your USB drive (macOS: diskutil list)
sudo dd if=_out/metal-arm64.raw of=/dev/rdiskN bs=4M conv=sync status=progress
```

Configure Pi 5 EEPROM boot order so USB is tried before SD (Raspberry Pi Imager → Misc → Bootloader, or `rpi-eeprom-config`).

## Steps separately

```bash
./build-rpi5.sh prepare     # reset ./sbc-raspberrypi to SBC_BASE and apply ./patches
./build-rpi5.sh overlay     # rebuild after DT / U-Boot changes in sbc-raspberrypi
./build-rpi5.sh image       # Talos disk image only
./build-rpi5.sh installer   # Talos installer image only
```

## mmc0 timeouts (microSD disabled)

| Patch | Board | Change |
|-------|-------|--------|
| `0012` | CM5 | Remove `broken-cd` from `&sdio1` |
| `0013` | Pi 5 Model B | `sd` / `sd_poll_once` in `__overrides__` (optional tuning) |
| `0014` | Pi 5 Model B | `&sdio1 { status = "disabled"; }` — stops `mmc0` spam for USB boot |

`config.txt` appends `sd=off` and `usb_max_current_enable=1`. The DT change is baked into the `.dtb` on the EFI partition; you must **rebuild the overlay and reflash**:

```bash
./build-rpi5.sh all
```

## Pi 5 active cooler fan ([#90](https://github.com/siderolabs/sbc-raspberrypi/issues/90))

The official active cooler uses **RP1 PWM1 channel 3** on **GPIO45**. Upstream device tree defines `cooling_fan` and `&rp1_pwm1`, but both are `status = "disabled"` until the **`pwm-rp1`** kernel driver exists. Talos 1.13.x ships a mainline kernel **without** that driver, so firmware fan control does not run after Linux boots and the fan stays off even at high CPU temperature.

**Proper fix (upstream):** `pwm-rp1` in the kernel (see [raspberrypi/linux](https://github.com/raspberrypi/linux/commit/22f6fa8e2dddce8262c9ee2c8d176d4c2c1b9786)) plus enabling `&rp1_pwm1` and `cooling_fan` in DT — tracked in sbc-raspberrypi, not in this repo’s overlay alone.

**Workaround (now):** drive the fan from userspace via the RP1 PCIe BAR.

One-shot:

```bash
chmod +x scripts/rpi5-fan-control.sh
export NODE=raspberrypi-7c
export TALOS_ENDPOINTS=192.168.1.24
./scripts/rpi5-fan-control.sh max    # or 0–100, off, status
```

**Persistent (CronJob every 5 minutes, thermal auto-speed):**

```bash
chmod +x scripts/deploy-rpi5-fan-cronjob.sh
NODE=raspberrypi-7c ./scripts/deploy-rpi5-fan-cronjob.sh
```

Remove: `kubectl delete cronjob rpi5-fan-control -n kube-system`

Based on [serialx’s fan-control gist](https://gist.github.com/serialx/d3213768026b15222ec8b86d92c06819).

## Overrides

```bash
export TALOS_VERSION=v1.14.5
export OVERLAY_TAG=pr88
export PKGS=v1.14.0-48-gf4bda77
export TOOLS=v1.14.0-11-g8dad45e
./build-rpi5.sh all
```

## How it works

1. **Prepare** — clone `sbc-raspberrypi` at `SBC_BASE`, `git am` the PR #88 patch, copy the DT patches, point the U-Boot source at `UBOOT_MIRROR` (default: the Buildroot mirror, since `ftp.denx.de` is often unreachable; the tarball checksums in the Pkgfile are still verified).
2. **Overlay** — `make docker-sbc-raspberrypi` in `sbc-raspberrypi`.
3. **Registry** — overlay pushed to local `registry:2` on port 5001 for the imager container.
4. **Imager** — `ghcr.io/siderolabs/imager:v1.14.5` with the `rpi_5` overlay, `configTxtAppend` and `EXTRA_KERNEL_ARGS`, once for the disk image and once for the installer.
