#!/bin/bash

set -eu

# https://doc.dpdk.org/guides/linux_gsg/linux_eal_parameters.html
# https://doc.dpdk.org/guides/sample_app_ug/kernel_nic_interface.html

echo "Get PCI_DEVICE_ID from filter expression"
PCI_DEVICE_FILTER=${PCI_DEVICE_FILTER:-PCIDEVICE_OPENSHIFT_IO}
PCI_DEVICE_IDS=$(env | grep -E "^$PCI_DEVICE_FILTER" | awk -F '=' '{print $NF}' | sort | head -1 | sed 's/,/ /g')
PCI_DEVICE_ALLOW_LIST=""
for pci_device_id in ${PCI_DEVICE_IDS}; do
  PCI_DEVICE_ALLOW_LIST="${PCI_DEVICE_ALLOW_LIST} -a ${pci_device_id}"
done

PINNED_LCORES=${PINNED_LCORES:-""}
if [ "$PINNED_LCORES" == "" ]; then
	echo "Get available CPUs from the Cpus_allowed_list"
	PINNED_LCORES=$(awk '/Cpus_allowed_list:/ {print $NF}' < /proc/self/status)
	echo "Pinned lcores will be: ${PINNED_LCORES}"
else
	echo "Using PINNED_LCORES '${PINNED_LCORES}' from configuration"
fi

echo "Running testpmd, showing statistics every 10 seconds:"
( while true ; do echo 'show port stats all' ; sleep 10 ; done ) | \
dpdk-testpmd -l "${PINNED_LCORES}" -n 4 ${PCI_DEVICE_ALLOW_LIST} -- \
    -i --nb-cores=1 --nb-ports=2 --total-num-mbufs=2048 --cmdline-file=/testpmd/commands.txt

echo "FAILURE! If we got here, this means that it's time for troubleshooting. Testpmd did not run or crashed!"
sleep infinity
