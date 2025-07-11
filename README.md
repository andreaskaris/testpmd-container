## Rootless dpdk-testpmd on OpenShift

### Prerequisites

#### For both

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

* Reserve CPU, memory and hugepages via requests/limits

```
         resources:                                                                                                      
           limits:                                                                                                       
             hugepages-1Gi: 6Gi                                                                                          
             memory: 1Gi                                                                                                 
             cpu: "8"                                                                                                    
           requests:                                                                                                     
             hugepages-1Gi: 6Gi                                                                                          
             memory: 1Gi                                                                                                 
             cpu: "8"
```

#### For rootless KNI vhost tap interface

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

##### Overriding the MAC address

DPDK uses the the ioctl systemcall with the SIOCSIFHWADDR op to change the interface MAC address. This operation does
not need NET_ADMIN privileges. Therefore, if you want to set a different MAC address via DPDK than the one that was
assigned to the TAP interface by the net-attach-def, you can do this if the following prerequisites are fulfilled.

First, update `yamls/prerequisites/sriovnetwork.yaml` and enable trust and disable spoof checking for the VF:

```
@@ -7,3 +7,5 @@ spec:
   logLevel: info
   networkNamespace: dpdktest
   resourceName: vfio_pci_0
+  spoofChk: "off"
+  trust: "on"
```

Then, update the `dpdk-testpmd` command and set the interface MAC address with `mac=${MACADDR}`. For example, here's a diff
with the changes that I made:

```
diff --git a/yamls/testpmd-tap/configmap.yaml b/yamls/testpmd-tap/configmap.yaml
index e824860..22d58e0 100644
--- a/yamls/testpmd-tap/configmap.yaml
+++ b/yamls/testpmd-tap/configmap.yaml
@@ -34,6 +34,8 @@ data:
         echo "Mac addresses of PCI device $PCI_DEVICE_ID and of tap interface $TAP_INTERFACE do not match"
         exit 1
     fi
+    MAC_DPDK_OVERRIDE="${MAC_DPDK_OVERRIDE:-$TAP_MACADDR}"
     
     if [ "$PINNED_LCORES" == "" ]; then
        echo "Get available CPUs from the Cpus_allowed: list"
@@ -45,8 +47,9 @@ data:
     
     echo "Run testpmd and forward everything between dp0 tunnel interface and vfio interface"
     ( while true ; do echo 'show port stats all' ; sleep 60 ; done ) | \
+        strace -f -tt -o /tmp/strace.txt -s1024 \
         dpdk-testpmd --log-level=10 --legacy-mem \
-        --vdev=virtio_user0,path=/dev/vhost-net,queues=2,queue_size=1024,iface=${TAP_INTERFACE},mac=${MACADDR} \
+        --vdev=virtio_user0,path=/dev/vhost-net,queues=2,queue_size=1024,iface=${TAP_INTERFACE},mac=${MAC_DPDK_OVERRIDE} \
         -l $PINNED_LCORES -n 4 -a $PCI_DEVICE_ID -- \
         --nb-cores=1 --nb-ports=2  --total-num-mbufs=2048 -i --cmdline-file=/testpmd/commands.txt
       
diff --git a/yamls/testpmd-tap/deployment.yaml b/yamls/testpmd-tap/deployment.yaml
index 31f30e9..5c11c0e 100644
--- a/yamls/testpmd-tap/deployment.yaml
+++ b/yamls/testpmd-tap/deployment.yaml
@@ -43,6 +43,8 @@ spec:
             value: "PCIDEVICE_OPENSHIFT_IO"
           - name: TAP_INTERFACE
             value: "dp0"  # set this to overrirde the tap name
+          - name: MAC_DPDK_OVERRIDE
+            value: "20:04:0f:f1:88:02"
           - name: PINNED_LCORES
             value: ""  # set this to override lcores of dpdk-testpmd process. Otherwise, all CPUs will be chosen from cgroup's allowed cpu list
         imagePullPolicy: IfNotPresent
```

I documented the reason why this works in https://andreaskaris.github.io/blog/linux/set-tun-mac-privileges/.

### Deployment

First, deploy the MachineConfig prerequisites:

```
make deploy-machineconfig
```

In order to deploy the port-forwarder which forwards between 2 VFs, run:

```
make deploy-testpmd-portforwarder
```

In order to deploy a DPDK application that creates a TAP interface, uses the KNI vhost path, and connects the VF via
the virtio driver to the TAP, run:

```
make deploy-testpmd-tap
```

> In both of the above cases, add `ROOT=true` to run with root privileges or PRIVILEGED=true to run a privileged pod (e.g. for testing).

Change the following values (and possibly others) according to your environment, otherwise use the same names:

* `runtimeClassName: "performance-sno-pp"`  # set this to: oc get runtimeclass
*  SRIOV network resource name is `vfio_pci_0`

### Verification

Deploy:

```
$ make deploy-testpmd-tap
make kustomize-prerequisites | oc apply -f -
namespace/dpdktest created
serviceaccount/dpdktest created
clusterrolebinding.rbac.authorization.k8s.io/system:openshift:scc:privileged-to-dpdktest created
sriovnetwork.sriovnetwork.openshift.io/vfio-pci-0-ns-dpdktest created
make kustomize-testpmd-tap | oc apply -f -
networkattachmentdefinition.k8s.cni.cncf.io/tap-one created
configmap/testpmd-commands created
deployment.apps/fedora-deployment created
```

List pod:

```
$ oc get pods -n dpdktest 
NAME                                 READY   STATUS    RESTARTS   AGE
fedora-deployment-7668bdc89d-hmntc   1/1     Running   0          15s
```

Check logs:

```
$ oc logs -n dpdktest deployment/fedora-deployment --tail=-1 -f 
====================================================
Information about current user and privilege status:
====================================================
Current: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_ipc_lock,cap_sys_resource=i
Bounding set =cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_ipc_lock,cap_sys_resource
Ambient set =
Current IAB: cap_chown,cap_dac_override,!cap_dac_read_search,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,!cap_linux_immutable,cap_net_bind_service,!cap_net_broadcast,!cap_net_admin,!cap_net_raw,cap_ipc_lock,!cap_ipc_owner,!cap_sys_module,!cap_sys_rawio,!cap_sys_chroot,!cap_sys_ptrace,!cap_sys_pacct,!cap_sys_admin,!cap_sys_boot,!cap_sys_nice,cap_sys_resource,!cap_sys_time,!cap_sys_tty_config,!cap_mknod,!cap_lease,!cap_audit_write,!cap_audit_control,!cap_setfcap,!cap_mac_override,!cap_mac_admin,!cap_syslog,!cap_wake_alarm,!cap_block_suspend,!cap_audit_read,!cap_perfmon,!cap_bpf,!cap_checkpoint_restore
Securebits: 00/0x0/1'b0 (no-new-privs=1)
 secure-noroot: no (unlocked)
 secure-no-suid-fixup: no (unlocked)
 secure-keep-caps: no (unlocked)
 secure-no-ambient-raise: no (unlocked)
uid=1001(1001) euid=1001(1001)
gid=2001(???)
groups=2001(???),2002(???)
Guessed mode: HYBRID (4)
uid=1001(1001) gid=2001 groups=2001,2002
====================================================

Get PCI_DEVICE_ID from filter expression
Get MAC ADDRESS
EAL: Detected CPU lcores: 64
EAL: Detected NUMA nodes: 1
EAL: Detected static linkage of DPDK
EAL: Multi-process socket /tmp/dpdk/rte/mp_socket
EAL: Selected IOVA mode 'VA'
EAL: VFIO support initialized
EAL: Using IOMMU type 1 (Type 1)
EAL: Probe PCI driver: net_bnxt (14e4:1806) device: 0000:19:01.0 (socket 0)
TELEMETRY: No legacy callbacks, legacy socket not created
Get available CPUs from the Cpus_allowed: list
Pinned lcores will be: 2-5,34-37
Run testpmd and forward everything between dp0 tunnel interface and vfio interface
Log level 10 higher than maximum (8)
EAL: Detected CPU lcores: 64
EAL: Detected NUMA nodes: 1
EAL: Static memory layout is selected, amount of reserved memory can be adjusted with -m or --socket-mem
EAL: Detected static linkage of DPDK
EAL: Multi-process socket /tmp/dpdk/rte/mp_socket
EAL: Selected IOVA mode 'VA'
EAL: VFIO support initialized
EAL: Using IOMMU type 1 (Type 1)
EAL: Probe PCI driver: net_bnxt (14e4:1806) device: 0000:19:01.0 (socket 0)
TELEMETRY: No legacy callbacks, legacy socket not created
Interactive-mode selected
CLI commands to be read from /testpmd/commands.txt
Warning: NUMA should be configured manually by using --port-numa-config and --ring-numa-config parameters along with --numa.
testpmd: create a new mbuf pool <mb_pool_0>: n=2048, size=2176, socket=0
testpmd: preferred mempool ops selected: ring_mp_mc
Configuring Port 0 (socket 0)
Port 0: 20:04:0F:F1:88:01
Configuring Port 1 (socket 0)
Port 1: 20:04:0F:F1:88:01
Checking link statuses...
Done
Error during enabling promiscuous mode for port 1: Operation not supported - ignore

********************* Infos for port 0  *********************
MAC address: 20:04:0F:F1:88:01
Device name: 0000:19:01.0
Driver name: net_bnxt
Firmware-version: 218.0.169.1
Devargs: 
Connect to socket: 0
memory allocation on the socket: 0
Link status: up
Link speed: 25 Gbps
Link duplex: full-duplex
Autoneg status: On
MTU: 1500
Promiscuous mode: enabled
Allmulticast mode: disabled
Maximum number of MAC addresses: 4
Maximum number of MAC addresses of hash filtering: 0
VLAN offload: 
  strip off, filter off, extend off, qinq strip off
Hash key size in bytes: 40
Redirection table size: 64
Supported RSS offload flow types:
  ipv4  ipv4-tcp  ipv4-udp  ipv6  ipv6-tcp  ipv6-udp
  user-defined-50  user-defined-51
Minimum size of RX buffer: 1
Maximum configurable length of RX packet: 9600
Maximum configurable size of LRO aggregated packet: 0
Maximum number of VMDq pools: 16
Current number of RX queues: 1
Max possible RX queues: 31
Max possible number of RXDs per queue: 8192
Min possible number of RXDs per queue: 16
RXDs number alignment: 1
Current number of TX queues: 1
Max possible TX queues: 31
Max possible number of TXDs per queue: 4096
Min possible number of TXDs per queue: 16
TXDs number alignment: 1
Max segment number per packet: 65535
Max segment number per MTU/TSO: 65535
Device capabilities: 0x3( RUNTIME_RX_QUEUE_SETUP RUNTIME_TX_QUEUE_SETUP )
Device error handling mode: proactive

********************* Infos for port 1  *********************
MAC address: 20:04:0F:F1:88:01
Device name: virtio_user0
Driver name: net_virtio_user
Firmware-version: not available
Devargs: path=/dev/vhost-net,queues=2,queue_size=1024,iface=dp0,mac=20:04:0f:f1:88:01
Connect to socket: 0
memory allocation on the socket: 0
Link status: up
Link speed: Unknown
Link duplex: full-duplex
Autoneg status: On
MTU: 1500
Promiscuous mode: disabled
Allmulticast mode: disabled
Maximum number of MAC addresses: 64
Maximum number of MAC addresses of hash filtering: 0
VLAN offload: 
  strip off, filter off, extend off, qinq strip off
No RSS offload flow type is supported.
Minimum size of RX buffer: 64
Maximum configurable length of RX packet: 9728
Maximum configurable size of LRO aggregated packet: 0
Current number of RX queues: 1
Max possible RX queues: 2
Max possible number of RXDs per queue: 32768
Min possible number of RXDs per queue: 32
RXDs number alignment: 1
Current number of TX queues: 1
Max possible TX queues: 2
Max possible number of TXDs per queue: 32768
Min possible number of TXDs per queue: 32
TXDs number alignment: 1
Max segment number per packet: 65535
Max segment number per MTU/TSO: 65535
Device capabilities: 0x0( )
Device error handling mode: none

  ######################## NIC statistics for port 0  ########################
  RX-packets: 0          RX-missed: 0          RX-bytes:  0
  RX-errors: 0
  RX-nombuf:  0         
  TX-packets: 0          TX-errors: 0          TX-bytes:  0

  Throughput (since last show)
  Rx-pps:            0          Rx-bps:            0
  Tx-pps:            0          Tx-bps:            0
  ############################################################################

  ######################## NIC statistics for port 1  ########################
  RX-packets: 0          RX-missed: 0          RX-bytes:  0
  RX-errors: 0
  RX-nombuf:  0         
  TX-packets: 0          TX-errors: 0          TX-bytes:  0

  Throughput (since last show)
  Rx-pps:            0          Rx-bps:            0
  Tx-pps:            0          Tx-bps:            0
  ############################################################################
io packet forwarding - ports=2 - cores=1 - streams=2 - NUMA support enabled, MP allocation mode: native
Logical Core 3 (socket 0) forwards packets on 2 streams:
  RX P=0/Q=0 (socket 0) -> TX P=1/Q=0 (socket 0) peer=02:00:00:00:00:01
  RX P=1/Q=0 (socket 0) -> TX P=0/Q=0 (socket 0) peer=02:00:00:00:00:00

  io packet forwarding packets/burst=32
  nb forwarding cores=1 - nb forwarding ports=2
  port 0: RX queue number: 1 Tx queue number: 1
    Rx offloads=0x0 Tx offloads=0x10000
    RX queue: 0
      RX desc=512 - RX free threshold=64
      RX threshold registers: pthresh=0 hthresh=0  wthresh=0
      RX Offloads=0x0
    TX queue: 0
      TX desc=512 - TX free threshold=64
      TX threshold registers: pthresh=0 hthresh=0  wthresh=0
      TX offloads=0x10000 - TX RS bit threshold=0
  port 1: RX queue number: 1 Tx queue number: 1
    Rx offloads=0x0 Tx offloads=0x0
    RX queue: 0
      RX desc=0 - RX free threshold=0
      RX threshold registers: pthresh=0 hthresh=0  wthresh=0
      RX Offloads=0x0
    TX queue: 0
      TX desc=0 - TX free threshold=0
      TX threshold registers: pthresh=0 hthresh=0  wthresh=0
      TX offloads=0x0 - TX RS bit threshold=0
Read CLI commands from /testpmd/commands.txt
testpmd> show port stats all

  ######################## NIC statistics for port 0  ########################
  RX-packets: 1          RX-missed: 0          RX-bytes:  60
  RX-errors: 0
  RX-nombuf:  0         
  TX-packets: 0          TX-errors: 0          TX-bytes:  0

  Throughput (since last show)
  Rx-pps:           47          Rx-bps:        22656
  Tx-pps:            0          Tx-bps:            0
  ############################################################################

  ######################## NIC statistics for port 1  ########################
  RX-packets: 1          RX-missed: 0          RX-bytes:  42
  RX-errors: 0
  RX-nombuf:  0         
  TX-packets: 1          TX-errors: 0          TX-bytes:  60

  Throughput (since last show)
  Rx-pps:           47          Rx-bps:        15856
  Tx-pps:           47          Tx-bps:        22656
  ############################################################################
^C
```

Run a ping test:

```
$ oc rsh -n dpdktest fedora-deployment-7668bdc89d-hmntc 
sh-5.2$ ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
2: eth0@if141: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default 
    link/ether 0a:58:0a:80:00:73 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.128.0.115/23 brd 10.128.1.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::858:aff:fe80:73/64 scope link 
       valid_lft forever preferred_lft forever
3: dp0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 20:04:0f:f1:88:01 brd ff:ff:ff:ff:ff:ff
    inet 192.168.18.110/25 brd 192.168.18.127 scope global dp0
       valid_lft forever preferred_lft forever
    inet6 fe80::2204:fff:fef1:8801/64 scope link 
       valid_lft forever preferred_lft forever
sh-5.2$ ping 192.168.18.1
PING 192.168.18.1 (192.168.18.1) 56(84) bytes of data.
64 bytes from 192.168.18.1: icmp_seq=1 ttl=64 time=0.501 ms
64 bytes from 192.168.18.1: icmp_seq=2 ttl=64 time=0.258 ms
^C
--- 192.168.18.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1010ms
rtt min/avg/max/mdev = 0.258/0.379/0.501/0.121 ms
sh-5.2$ 
```

### Caveats

The testpmd-tap pod can only ping its destination when the other side runs a ping to it, first.
I suspect that this is a problem with my testpmd configuration. ARP resolution works fine in
both directions but `arping` from the target host does not solve this issue. 
