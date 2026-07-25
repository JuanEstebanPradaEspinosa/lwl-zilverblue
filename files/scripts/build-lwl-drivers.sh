#!/usr/bin/env bash
set -euo pipefail

LWL_VERSION="4.22.2"
SOURCE_DIR="/tmp/lwl-drivers"

echo "Locating the Fedora kernel development tree..."

KDIR="$(
    find /usr/src/kernels \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -print |
    sort -V |
    tail -n 1
)"

if [[ -z "${KDIR}" ]]; then
    echo "ERROR: no kernel development tree found in /usr/src/kernels"
    exit 1
fi

KERNEL="$(basename "${KDIR}")"
MODULE_ROOT="/usr/lib/modules/${KERNEL}"

echo "Fedora image kernel: ${KERNEL}"
echo "Kernel build directory: ${KDIR}"

if [[ ! -f "${KDIR}/Makefile" ]]; then
    echo "ERROR: ${KDIR}/Makefile does not exist"
    exit 1
fi

if [[ ! -d "${MODULE_ROOT}" ]]; then
    echo "ERROR: module directory ${MODULE_ROOT} does not exist"
    exit 1
fi

rm -rf "${SOURCE_DIR}"

echo "Downloading lwl-drivers ${LWL_VERSION}..."

git clone \
    --depth 1 \
    --branch "v${LWL_VERSION}" \
    https://github.com/comexr/lwl-drivers.git \
    "${SOURCE_DIR}"

echo "Building LWL modules for ${KERNEL}..."

(
    cd "${SOURCE_DIR}"

    # Override the upstream Makefile's uname-based kernel selection.
    make \
        KDIR="${KDIR}" \
        -j"$(nproc)"
)

echo "Installing LWL modules into the image..."

make \
    -C "${KDIR}" \
    M="${SOURCE_DIR}" \
    INSTALL_MOD_PATH=/ \
    modules_install

echo "Installing LWL modprobe and udev configuration..."

if [[ -d "${SOURCE_DIR}/files/usr/lib" ]]; then
    cp -a "${SOURCE_DIR}/files/usr/lib/." /usr/lib/
else
    echo "ERROR: driver configuration directory is missing"
    exit 1
fi

# Generate the immutable-image hardware database under /usr.
systemd-hwdb --usr update

# Generate modules.dep, modules.alias, and related indexes.
depmod -a "${KERNEL}"

echo "Recording installed driver version..."

install -d -m 0755 /usr/share/lwl-drivers

printf '%s\n' "${LWL_VERSION}" \
    > /usr/share/lwl-drivers/version

echo "Verifying important driver modules..."

required_modules=(
    clevo_acpi
    clevo_wmi
    lwl_keyboard
    uniwill_wmi
)

for module in "${required_modules[@]}"; do
    if ! modinfo -k "${KERNEL}" "${module}" >/dev/null; then
        echo "ERROR: expected module ${module} was not installed"
        exit 1
    fi

    echo "Found module: ${module}"
done

echo "Installed LWL module files:"

find "${MODULE_ROOT}" \
    -type f \
    \( \
        -name 'clevo*.ko*' \
        -o -name 'lwl*.ko*' \
        -o -name 'uniwill*.ko*' \
        -o -name 'ite*.ko*' \
        -o -name 'tuxi*.ko*' \
        -o -name 'stk8321*.ko*' \
        -o -name 'gxtp7380*.ko*' \
    \) \
    -print \
    | sort \
    | tee /tmp/lwl-installed-modules.txt

if [[ ! -s /tmp/lwl-installed-modules.txt ]]; then
    echo "ERROR: no LWL kernel modules were found after installation"
    exit 1
fi

rm -rf "${SOURCE_DIR}"

echo "LWL drivers ${LWL_VERSION} built successfully for ${KERNEL}"
