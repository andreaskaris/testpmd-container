## Rootless dpdk-testpmd on OpenShift

### How to run

#### Prerequisites

##### For both

* Create and apply a PerformanceProfile

* Make capabilities inheritable https://access.redhat.com/solutions/6243491:

[embedmd]:# (yamls/machineconfig/runtime.yaml)
```yaml
# Prerequisite for rootless DPDK, uses to make capabilities inheritable.
# For example, required for cases where DPDK is run by a wrapper script.
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 02-master-container-runtime
spec:
  config:
    ignition:
      version: 3.1.0
    storage:
      files:
        - contents:
            source: data:text/plain;charset=utf-8;base64,ICBbY3Jpby5ydW50aW1lXQogIGFkZF9pbmhlcml0YWJsZV9jYXBhYmlsaXRpZXMgPSB0cnVlCiAgZGVmYXVsdF91bGltaXRzID0gWwogICJtZW1sb2NrPS0xOi0xIgpdCg==
          mode: 420
          overwrite: true
          path: /etc/crio/crio.conf.d/10-custom
```

##### For rootless KNI vhost tap interface

* Enable SELinux bool for tap interface:
https://docs.openshift.com/container-platform/4.14/networking/multiple_networks/configuring-additional-network.html#nw-multus-enable-container_use_devices_configuring-additional-network

[embedmd]:# (yamls/machineconfig/tapcnisebool.yaml)
```yaml
# Prerequisite for tap interaces for rootless DPDK.
# https://docs.openshift.com/container-platform/4.14/networking/multiple_networks/configuring-additional-network.html#nw-multus-enable-container_use_devices_configuring-additional-network
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-setsebool
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - enabled: true
        name: setsebool.service
        contents: |
          [Unit]
          Description=Set SELinux boolean for the TAP CNI plugin
          Before=kubelet.service

          [Service]
          Type=oneshot
          ExecStart=/usr/sbin/setsebool container_use_devices=on
          RemainAfterExit=true

          [Install]
          WantedBy=multi-user.target graphical.target
```

* Enable needVhostNet: true in the SriovNetworkNodePolicy:
https://docs.openshift.com/container-platform/4.16/networking/hardware_networks/configuring-sriov-device.html#nw-sriov-networknodepolicy-object_configuring-sriov-device

```
---
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: vfio-pci-0
  namespace: openshift-sriov-network-operator
spec:
  deviceType: vfio-pci
  isRdma: false
  linkType: eth
  needVhostNet: true    # <---- this
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

[embedmd]:# (yamls/prerequisites/sriovnetwork.yaml)
```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: vfio-pci-0-ns-dpdktest
  namespace: openshift-sriov-network-operator
spec:
  logLevel: info
  networkNamespace: dpdktest
  resourceName: vfio_pci_0
```

* Create tap interface for pod via NetworkAttachmentDefinition
https://docs.openshift.com/container-platform/4.14/networking/hardware_networks/using-dpdk-and-rdma.html#nw-running-dpdk-rootless-tap_using-dpdk-and-rdma

[embedmd]:# (yamls/testpmd-tap/tap.yaml)
```yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
 name: tap-one
 namespace: dpdktest
spec:
 config: '{
   "cniVersion": "0.4.0",
   "name": "tap",
   "plugins": [
     {
        "type": "tap",
        "multiQueue": true,
        "selinuxcontext": "system_u:system_r:container_t:s0",
        "ipam": {
            "type": "static",
            "addresses": [
              {
                "address": "192.168.18.110/25",
                "gateway": "192.168.18.1"
              }
            ]
        }
     },
     {
       "type":"tuning",
       "capabilities":{
         "mac":true
       }
     }
   ]
 }'
```

In the above NetworkAttachmentDefinition for the tap, you must set the selinuxcontext, the mac capabilities, as well as assign an IP address to the interface. Because the pod is run as non-root, this is the only way to assign an IP address to the kernel tap interface.


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

Change the following values (and possibly others) according to your environment, otherwise use the same names:

* `runtimeClassName: "performance-sno-pp"`  # set this to: oc get runtimeclass
*  SRIOV network resource name is `vfio_pci_0`
