%{!?_unitdir: %global _unitdir /usr/lib/systemd/system}

Name:           qubes-core-agent-kvm
Version:        4.3.0
Release:        1%{?dist}
Summary:        KVM-specific Qubes OS agent components
License:        GPLv2
Group:          Qubes
URL:            https://github.com/QubesOS/qubes-core-agent-linux
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
Requires:       qubes-core-agent
Requires:       qubes-qubesdb-kvm-vm
Requires:       qubes-libvchan-socket

Source0:        %{name}-%{version}.tar.gz

%description
KVM backend support for the Qubes OS agent. Provides:
- Hypervisor detection (KVM vs Xen)
- Domain ID resolution via QubesDB/DMI
- vif-route-qubes-kvm network setup using QubesDB
- qubes-vhost-bridge firewall bridge daemon
- qubesdb-hotplug-watcher for device attach/detach events
- Systemd service units for KVM-specific boot

%prep
%setup -q

%build

%install
install -d %{buildroot}/usr/lib/qubes/init
install -m 0755 init/hypervisor.sh      %{buildroot}/usr/lib/qubes/init/
install -m 0755 init/qubes-domain-id.sh %{buildroot}/usr/lib/qubes/init/

install -d %{buildroot}/etc/qubes/kvm
install -m 0755 network/vif-route-qubes-kvm %{buildroot}/etc/qubes/kvm/

install -d %{buildroot}/usr/lib/qubes/network
install -m 0755 network/qubes-vhost-bridge.py %{buildroot}/usr/lib/qubes/network/

install -d %{buildroot}/usr/lib/qubes
install -m 0755 network/qubesdb-hotplug-watcher.sh %{buildroot}/usr/lib/qubes/

install -d %{buildroot}%{_unitdir}
install -m 0644 vm-systemd/qubes-vhost-bridge.service \
    %{buildroot}%{_unitdir}/
install -m 0644 vm-systemd/qubes-kvm-hotplug-watcher.service \
    %{buildroot}%{_unitdir}/

%files
/usr/lib/qubes/init/hypervisor.sh
/usr/lib/qubes/init/qubes-domain-id.sh
/etc/qubes/kvm/vif-route-qubes-kvm
/usr/lib/qubes/network/qubes-vhost-bridge.py
/usr/lib/qubes/qubesdb-hotplug-watcher.sh
%{_unitdir}/qubes-vhost-bridge.service
%{_unitdir}/qubes-kvm-hotplug-watcher.service

%changelog
* Wed Feb 18 2026 Qubes KVM Contributors - 4.3.0-1
- Initial KVM agent components for Qubes OS 4.3
