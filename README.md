## Rotoless dpdk-testpmd on OpenShift

### How to run

```
make apply-runtime
make deploy
```

### Dependencies

Change the following (hardcoded) values according to your environment:

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
