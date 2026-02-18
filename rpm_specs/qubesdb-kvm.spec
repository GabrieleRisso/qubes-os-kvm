%{!?_unitdir: %global _unitdir /usr/lib/systemd/system}

Name:           qubes-qubesdb-kvm
Version:        4.3.0
Release:        1%{?dist}
Summary:        KVM virtio-serial config injection/reading tools for QubesDB
License:        GPLv2
Group:          Qubes
URL:            https://github.com/QubesOS/qubes-core-qubesdb
BuildRequires:  gcc make
BuildRequires:  systemd-rpm-macros
Requires:       qubes-core-qubesdb

Source0:        %{name}-%{version}.tar.gz

%description
KVM-specific tools for QubesDB boot-time configuration.

qubesdb-config-inject runs on the host (dom0 or sys-admin) and pushes
initial VM configuration through a virtio-serial Unix socket into a
guest before the main vchan-socket QubesDB channel is established.

qubesdb-config-read runs inside the guest VM early in boot, reads
configuration from the virtio-serial port, and caches it locally.

%package -n qubes-qubesdb-kvm-dom0
Summary:        Host-side QubesDB config injector for KVM VMs
Requires:       libvirt-daemon

%description -n qubes-qubesdb-kvm-dom0
Host-side tool that injects initial QubesDB entries into KVM guests
through the virtio-serial Unix socket created by libvirt.

%package -n qubes-qubesdb-kvm-vm
Summary:        Guest-side QubesDB config reader for KVM VMs
Requires:       qubes-core-agent

%description -n qubes-qubesdb-kvm-vm
Guest-side service that reads initial QubesDB configuration from a
virtio-serial port at boot time and caches it locally.

%prep
%setup -q

%build
%set_build_flags
make -C daemon/kvm all

%install
make -C daemon/kvm DESTDIR=%{buildroot} BINDIR=%{_bindir} install

install -d %{buildroot}%{_unitdir}
install -m 0644 daemon/kvm/qubesdb-config-read.service \
    %{buildroot}%{_unitdir}/qubesdb-config-read.service

%files -n qubes-qubesdb-kvm-dom0
%{_bindir}/qubesdb-config-inject

%files -n qubes-qubesdb-kvm-vm
%{_bindir}/qubesdb-config-read
%{_unitdir}/qubesdb-config-read.service

%changelog
* Wed Feb 18 2026 Qubes KVM Contributors - 4.3.0-1
- Initial KVM virtio-serial QubesDB config tools
