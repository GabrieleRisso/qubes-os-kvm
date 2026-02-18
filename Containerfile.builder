# qubes-kvm-fork build environment
# Based on Fedora 41 to match Qubes OS 4.3 dom0

FROM registry.fedoraproject.org/fedora:42

LABEL maintainer="qubes-kvm-fork" \
      description="Build environment for Qubes KVM fork development"

RUN dnf install -y \
    gcc gcc-c++ make cmake meson ninja-build \
    rpm-build rpmlint createrepo_c mock \
    git git-lfs patch diffutils \
    python3-devel python3-pip python3-setuptools python3-wheel \
    python3-sphinx python3-pytest python3-pylint \
    python3-dbus python3-gobject python3-lxml \
    python3-yaml python3-jinja2 python3-docutils \
    python3-cffi \
    libvirt-devel qemu-kvm qemu-system-x86-core qemu-img \
    qemu-system-aarch64-core qemu-user-static edk2-ovmf edk2-aarch64 \
    gcc-aarch64-linux-gnu \
    libX11-devel libXext-devel libXcomposite-devel \
    gtk3-devel pulseaudio-libs-devel \
    openssl-devel systemd-devel \
    ShellCheck bash-completion \
    wget curl jq file \
    && dnf clean all

RUN useradd -m builder && usermod -aG mock builder
USER builder
WORKDIR /home/builder

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal \
    && . "$HOME/.cargo/env" \
    && rustup target add aarch64-unknown-linux-gnu

ENV PATH="/home/builder/.cargo/bin:${PATH}"
ENV BACKEND_VMM=kvm

CMD ["/bin/bash"]
