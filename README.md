## Rotoless dpdk-testpmd on OpenShift

### How to run

#### Prerequisites

The nodes need to be tuned. For rootless DPDK in general, make capabilities inheritable (runtime setting). In addition,
for the TAP CNI plugin, enable the container_use_devices boolean.

```
make apply-machineconfig
```
> This is hardcoded to deploy on the master role as testing was done on an SNO server.

The tap example uses virtio-user as an exceptional datapath for KNI communication:
https://doc.dpdk.org/guides-17.11/howto/virtio_user_as_exceptional_path.html 
Therefore,for the tap example, you will also need to enable `needVhostNet: true` in SriovNetworkNodePolicy:
https://docs.openshift.com/container-platform/4.16/networking/hardware_networks/configuring-sriov-device.html#nw-sriov-networknodepolicy-object_configuring-sriov-device


You will need a PerformanceProfile on the node, in this case, the PerformanceProfile is named `sno-pp`.

Change the following values according to your environment, otherwise use the same names:

* `runtimeClassName: "performance-sno-pp"`  # set this to: oc get runtimeclass
*  SRIOV network resource name is `vfio_pci_0`

The vfio-pci network used for this test is:

```
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: vfio-pci-0
  namespace: openshift-sriov-network-operator
spec:
  deviceType: vfio-pci
  isRdma: false
  linkType: eth
  needVhostNet: true
  nicSelector:
    deviceID: "1751"
    rootDevices:
    - "0000:18:00.1"
    vendor: "14e4"
  nodeSelector:
    feature.node.kubernetes.io/network-sriov.capable: "true"
  numVfs: 8
  priority: 99
  resourceName: vfio_pci_0
```

#### Deployment

In order to deploy the port-forwarder which forwards between 2 VFs, run:

```
make deploy-testpmd-portforwarder
```

In order to deploy a DPDK application that creates a TAP interface, uses the KNI vhost path, and connects the VF via
the virtio driver to the TAP, run:

```
make deploy-testpmd-tap
```

> In both of the above cases, add `ROOT=true` to run with root privileges (e.g. for testing).

