#!/bin/bash

set -eux

# https://doc.dpdk.org/guides-20.11/prog_guide/build-sdk-meson.html
# https://doc.dpdk.org/guides/sample_app_ug/compiling.html
# http://patches.dpdk.org/project/dpdk/patch/1625058550-9567-1-git-send-email-juraj.linkes@pantheon.tech/

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# yum install xz meson -y || true
# yum install "@Development Tools" -y || true
# yum install python3-pyelftools.noarch -y || true

if [ -f "${SCRIPT_DIR}/build-dir/dpdk-ethtool" ] && [ -f "${SCRIPT_DIR}/build-dir/dpdk-testpmd" ]; then
  echo "dpdk-ethtool and dpdk-testpmd binaries already exist."
  echo "Run 'make clean' if you wish to force a rebuild."
  exit 0
fi

rm -Rf "${SCRIPT_DIR}/build-dir"
mkdir -p "${SCRIPT_DIR}/build-dir"
cd "${SCRIPT_DIR}/build-dir"
curl -o dpdk.tar.xz https://fast.dpdk.org/rel/dpdk-22.11.1.tar.xz
tar -xf dpdk.tar.xz
rm -f dpdk.tar.xz
mv dpdk* dpdk
cd dpdk
meson -Dplatform=generic --buildtype=debug --optimization 0 build
cd build
meson configure --buildtype=debug --optimization 0 -Dexamples=all
ninja
cd "${SCRIPT_DIR}/build-dir"
cp dpdk/build/app/dpdk-testpmd .
cp ./dpdk/build/examples/dpdk-ethtool .
rm -Rf dpdk
