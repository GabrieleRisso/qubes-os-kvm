# qubes-kvm-fork build environment
# Identical on Qubes AppVM (podman) and Lenovo laptop (docker/podman)
# Based on Fedora 41 to match Qubes OS 4.3 dom0

FROM registry.fedoraproject.org/fedora:41

LABEL maintainer="qubes-kvm-fork" \
      description="Build environment for Qubes KVM fork development"

# Qubes OS build dependencies
RUN dnf install -y \
    # Core build tools
    gcc gcc-c++ make cmake meson ninja-build \
    rpm-build rpmlint createrepo_c \
    git git-lfs patch diffutils \
    # Python (qubesd, core-admin, agents)
    python3-devel python3-pip python3-setuptools python3-wheel \
    python3-sphinx python3-pytest python3-pylint \
    python3-dbus python3-gobject python3-lxml \
    python3-yaml python3-jinja2 python3-docutils \
    # Virtualization libraries
    libvirt-devel qemu-kvm \
    # Xen build deps (for building Xen-shim components)
    xen-devel xen-libs \
    # vchan / IPC
    # GUI deps
    libX11-devel libXext-devel libXcomposite-devel \
    gtk3-devel pulseaudio-libs-devel \
    # Misc
    openssl-devel systemd-devel \
    ShellCheck bash-completion \
    wget curl jq \
    # ARM64 cross-compilation
    qemu-user-static \
    && dnf clean all

# Rust toolchain (for crosvm work in later phases)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal \
    && . /root/.cargo/env \
    && rustup target add aarch64-unknown-linux-gnu

# Set up build user (non-root builds)
RUN useradd -m builder
USER builder
WORKDIR /home/builder

# Rust in PATH for builder user
ENV PATH="/root/.cargo/bin:${PATH}"

CMD ["/bin/bash"]
