FROM registry.fedoraproject.org/fedora:latest
RUN yum install xz meson "@development-tools" python3-pyelftools.noarch -y
COPY build-dpdk.sh /build-dpdk.sh
RUN /bin/bash -x /build-dpdk.sh

FROM registry.fedoraproject.org/fedora-minimal:latest
COPY --from=0 /build-dir/dpdk-ethtool /usr/bin/dpdk-ethtool
COPY --from=0 /build-dir/dpdk-testpmd /usr/bin/dpdk-testpmd
# COPY entrypoint.sh /entrypoint.sh
RUN microdnf install tar iproute iputils strace elfutils-libelf libatomic -y && microdnf clean all -y
# CMD ["/entrypoint.sh"]
