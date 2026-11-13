#!/usr/bin/env bash
# Build Raspberry Pi 5 Talos artifacts using:
#   - Talos imager
#   - sbc-raspberrypi overlay (upstream base + PR #88 + local DT patches)
# Outputs a flashable disk image (metal-arm64.raw.xz) and an installer image
# tarball (installer-arm64.tar) for `talosctl upgrade`.
set -euo pipefail

# BSD make on macOS cannot parse kres-generated Makefiles.
if command -v gmake >/dev/null 2>&1; then
	MAKE=gmake
elif [[ -x /opt/homebrew/opt/make/bin/gmake ]]; then
	MAKE=/opt/homebrew/opt/make/bin/gmake
else
	MAKE=make
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBC_DIR="${ROOT}/sbc-raspberrypi"
OUT_DIR="${OUT_DIR:-${ROOT}/_out}"

TALOS_VERSION="${TALOS_VERSION:-v1.13.2}"
IMAGER_IMAGE="${IMAGER_IMAGE:-ghcr.io/siderolabs/imager:${TALOS_VERSION}}"

# Upstream sbc-raspberrypi commit the patches in ./patches apply to (v0.2.0)
SBC_REPO="${SBC_REPO:-https://github.com/siderolabs/sbc-raspberrypi.git}"
SBC_BASE="${SBC_BASE:-bc6af94b2}"

# Match pkgs/tools used by Talos v1.13.2 release builds
PKGS="${PKGS:-v1.13.0-11-g969f61c}"
TOOLS="${TOOLS:-v1.13.0-2-g1fb762a}"

OVERLAY_REGISTRY="${OVERLAY_REGISTRY:-local}"
OVERLAY_USER="${OVERLAY_USER:-sbc-raspberrypi}"
OVERLAY_TAG="${OVERLAY_TAG:-pr88}"
# make tags: ${REGISTRY}/${USERNAME}/sbc-raspberrypi:${TAG}
OVERLAY_IMAGE="${OVERLAY_IMAGE:-${OVERLAY_REGISTRY}/${OVERLAY_USER}/sbc-raspberrypi:${OVERLAY_TAG}}"

PROFILE="${PROFILE:-rpi_5}"
ARCH="${ARCH:-arm64}"

CONFIG_TXT_APPEND="${CONFIG_TXT_APPEND:-sd=off
usb_max_current_enable=1}"

# usb-storage.delay_use=0: attach the USB SSD without the default 1s delay,
# otherwise STATE is not found in time on boot and the node falls into
# maintenance mode.
EXTRA_KERNEL_ARGS="${EXTRA_KERNEL_ARGS:-usb-storage.delay_use=0}"

prepare() {
	echo "==> Preparing ${SBC_DIR} at ${SBC_BASE}"
	if [[ ! -d "${SBC_DIR}/.git" ]]; then
		git clone "${SBC_REPO}" "${SBC_DIR}"
	fi
	(
		cd "${SBC_DIR}"
		git fetch origin
		git checkout --detach "${SBC_BASE}"
		git clean -fdq artifacts/dtb/raspberrypi/patches
		git -c user.name=build -c user.email=build@localhost am --quiet --whitespace=nowarn "${ROOT}"/patches/sbc-raspberrypi/*.patch
	)
	cp "${ROOT}"/patches/dtb/*.patch "${SBC_DIR}/artifacts/dtb/raspberrypi/patches/"
}

build_overlay() {
	echo "==> Building overlay image ${OVERLAY_IMAGE} from ${SBC_DIR}"
	(
		cd "${SBC_DIR}"
		"${MAKE}" docker-sbc-raspberrypi \
			REGISTRY="${OVERLAY_REGISTRY}" \
			USERNAME="${OVERLAY_USER}" \
			PLATFORM=linux/arm64 \
			PUSH=false \
			PKGS="${PKGS}" \
			TOOLS="${TOOLS}" \
			TAG_SUFFIX="" \
			IMAGE_TAG="${OVERLAY_TAG}" \
			TARGET_ARGS="--tag=${OVERLAY_IMAGE} --output=type=docker"
	)
}

publish_overlay_to_registry() {
	local reg_port="${LOCAL_REGISTRY_PORT:-5001}"
	local reg_image="localhost:${reg_port}/sbc-raspberrypi:${OVERLAY_TAG}"

	if ! docker image inspect "${OVERLAY_IMAGE}" >/dev/null 2>&1; then
		echo "overlay image ${OVERLAY_IMAGE} not found; run: $0 overlay" >&2
		exit 1
	fi

	if ! docker container inspect talos-build-registry >/dev/null 2>&1; then
		echo "==> Starting local registry on port ${reg_port}"
		docker run -d --restart=unless-stopped --name talos-build-registry \
			-p "127.0.0.1:${reg_port}:5000" registry:2
	fi

	docker tag "${OVERLAY_IMAGE}" "${reg_image}"
	docker push "${reg_image}"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		IMAGER_OVERLAY_REF="host.docker.internal:${reg_port}/sbc-raspberrypi:${OVERLAY_TAG}"
		IMAGER_NETWORK=()
	else
		IMAGER_OVERLAY_REF="${reg_image}"
		IMAGER_NETWORK=(--network host)
	fi
}

# run_imager <output yaml block> <profile name>
run_imager() {
	local output="$1"
	local profile_file="${OUT_DIR}/imager-profile-$2.yaml"

	cat >"${profile_file}" <<EOF
arch: ${ARCH}
platform: metal
secureboot: false
${output}
customization:
  extraKernelArgs:
$(for arg in ${EXTRA_KERNEL_ARGS}; do echo "    - ${arg}"; done)
overlay:
  name: ${PROFILE}
  image:
    imageRef: ${IMAGER_OVERLAY_REF}
    forceInsecure: true
  options:
    configTxtAppend: |
$(echo "${CONFIG_TXT_APPEND}" | sed 's/^/      /')
EOF

	echo "==> Running ${IMAGER_IMAGE} with profile $2"
	cat "${profile_file}"
	# /dev bind-mount breaks some Docker Desktop setups; --privileged is enough on Linux.
	docker run --rm -i \
		--privileged \
		${IMAGER_NETWORK[@]+"${IMAGER_NETWORK[@]}"} \
		-v "${OUT_DIR}:/out" \
		"${IMAGER_IMAGE}" - --output /out \
		<"${profile_file}"
}

build_image() {
	mkdir -p "${OUT_DIR}"
	publish_overlay_to_registry
	docker pull "${IMAGER_IMAGE}"

	run_imager "output:
  kind: image
  outFormat: .xz
  imageOptions:
    diskSize: 1306525696
    diskFormat: raw
    bootloader: grub" image
}

build_installer() {
	mkdir -p "${OUT_DIR}"
	publish_overlay_to_registry
	docker pull "${IMAGER_IMAGE}"

	run_imager "output:
  kind: installer
  outFormat: raw" installer
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [prepare|overlay|image|installer|all]

  prepare     Clone sbc-raspberrypi at SBC_BASE and apply ./patches
  overlay     Build only the sbc-raspberrypi OCI image from ./sbc-raspberrypi
  image       Run Talos imager to build the disk image (requires overlay)
  installer   Run Talos imager to build the installer image (requires overlay)
  all         overlay, image, installer (default)

Environment:
  TALOS_VERSION        Talos release tag (default: v1.13.2)
  SBC_BASE             sbc-raspberrypi commit the patches apply to (default: bc6af94b2)
  OVERLAY_IMAGE        Full overlay image ref (default: local/sbc-raspberrypi:pr88)
  PKGS, TOOLS          pkgs/tools versions aligned with Talos release
  OUT_DIR              Output directory (default: ./_out)
  CONFIG_TXT_APPEND    config.txt lines (default disables microSD for USB/NVMe boot)
  EXTRA_KERNEL_ARGS    Space separated kernel args (default: usb-storage.delay_use=0)

Output artifacts:
  \${OUT_DIR}/metal-arm64.raw.xz
  \${OUT_DIR}/installer-arm64.tar
EOF
}

main() {
	local step="${1:-all}"
	case "${step}" in
	prepare) prepare ;;
	overlay) build_overlay ;;
	image) build_image ;;
	installer) build_installer ;;
	all)
		build_overlay
		build_image
		build_installer
		;;
	-h | --help | help) usage ;;
	*)
		echo "unknown step: ${step}" >&2
		usage >&2
		exit 1
		;;
	esac
	echo "==> Done. Artifacts in ${OUT_DIR}"
}

main "$@"
