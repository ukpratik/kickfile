// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

enum LinkKind { wifi, ethernet, other, none }

class LocalAddress {
  const LocalAddress(this.ip, this.interface, this.kind);
  final String ip;
  final String interface;
  final LinkKind kind;
}

class NetworkState {
  const NetworkState({required this.addresses, required this.vpnActive});
  final List<LocalAddress> addresses;
  final bool vpnActive;

  LinkKind get kind => addresses.isEmpty ? LinkKind.none : addresses.first.kind;
  String? get primaryIp => addresses.isEmpty ? null : addresses.first.ip;
}

final _virtual = RegExp(
  r'^(lo|utun|tun|tap|ppp|ipsec|wg|docker|br-|veth|virbr|vmnet|vboxnet|vEthernet|awdl|llw|bridge|anpi|ap\d|gif|stf|zt|tailscale|nordlynx)',
  caseSensitive: false,
);
final _vpn = RegExp(r'^(utun|tun|tap|ppp|ipsec|wg|tailscale|nordlynx|zt)|vpn|wireguard|openvpn|cisco|anyconnect|fortinet|globalprotect', caseSensitive: false);

Map<String, LinkKind>? _macPorts;

/// Our usable IPv4 addresses, best first (Wi-Fi/Ethernet; never VPN or virtual adapters).
Future<NetworkState> readNetwork() async {
  final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
  var vpn = false;
  final out = <LocalAddress>[];
  for (final i in ifs) {
    final hasV4 = i.addresses.any((a) => !a.isLoopback);
    if (hasV4 && _vpn.hasMatch(i.name)) vpn = true;
    if (_virtual.hasMatch(i.name)) continue;
    for (final a in i.addresses) {
      if (a.isLoopback || a.isLinkLocal || a.address.startsWith('169.254.')) continue;
      out.add(LocalAddress(a.address, i.name, await _kindOf(i.name)));
    }
  }
  int rank(LocalAddress a) => switch (a.kind) {
    LinkKind.wifi => 0,
    LinkKind.ethernet => 1,
    _ => 2,
  };
  out.sort((a, b) => rank(a).compareTo(rank(b)));
  return NetworkState(addresses: out, vpnActive: vpn);
}

Future<LinkKind> _kindOf(String name) async {
  final n = name.toLowerCase();
  if (Platform.isMacOS) {
    _macPorts ??= await _readMacPorts();
    return _macPorts![name] ?? (n.startsWith('en') ? LinkKind.ethernet : LinkKind.other);
  }
  if (n.startsWith('wl') || n.contains('wi-fi') || n.contains('wifi') || n.contains('wlan') || n.contains('wireless')) {
    return LinkKind.wifi;
  }
  if (n.startsWith('en') || n.startsWith('eth') || n.contains('ethernet')) return LinkKind.ethernet;
  if (n.startsWith('ap') || n.startsWith('swlan')) return LinkKind.wifi; // Android hotspot side
  return LinkKind.other;
}

/// macOS: map `en0` etc. to Wi-Fi or Ethernet using `networksetup`.
Future<Map<String, LinkKind>> _readMacPorts() async {
  final map = <String, LinkKind>{};
  try {
    final r = await Process.run('networksetup', ['-listallhardwareports']);
    String? port;
    for (final line in (r.stdout as String).split('\n')) {
      if (line.startsWith('Hardware Port:')) port = line.substring(14).trim();
      if (line.startsWith('Device:') && port != null) {
        final dev = line.substring(7).trim();
        map[dev] = port.contains('Wi-Fi') ? LinkKind.wifi : (port.contains('Ethernet') || port.contains('LAN') ? LinkKind.ethernet : LinkKind.other);
      }
    }
  } catch (_) {}
  return map;
}
