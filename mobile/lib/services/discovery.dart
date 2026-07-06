import 'dart:io';

import 'package:nsd/nsd.dart';

/// A desktop server found on the local network by mDNS/Bonjour.
class DiscoveredServer {
  final String name; // friendly computer name from the mDNS instance
  final String host; // IPv4 (preferred) or hostname the phone can reach
  final int port;
  const DiscoveredServer(this.name, this.host, this.port);

  String get url {
    final h = host.contains(':') ? '[$host]' : host; // bracket a bare IPv6 literal
    return 'http://$h:$port';
  }
}

/// Auto-discovers desktop servers advertising `_audiobook._tcp` on the LAN, so the user can
/// tap one instead of typing the computer's IP address.
///
/// Best-effort by design: if discovery is unsupported, unpermitted, or the network blocks mDNS
/// (guest / corporate / AP-isolated Wi-Fi), it simply reports nothing and the QR-scan and
/// manual-entry paths still work. It never throws to the caller.
class DiscoveryService {
  static const _serviceType = '_audiobook._tcp';
  Discovery? _discovery;
  void Function()? _listener;

  /// Begin discovery. [onUpdate] fires with the current server list whenever it changes.
  Future<void> start(void Function(List<DiscoveredServer>) onUpdate) async {
    try {
      // Resolve to IPv4 so we get a concrete address the phone can dial, not just a .local name.
      final d = await startDiscovery(_serviceType, ipLookupType: IpLookupType.v4);
      _discovery = d;
      void handler() => onUpdate(_collect(d));
      _listener = handler;
      d.addListener(handler);
      handler(); // emit anything already present
    } catch (_) {
      // Discovery unavailable on this device/network — leave the list empty.
    }
  }

  List<DiscoveredServer> _collect(Discovery d) {
    final out = <DiscoveredServer>[];
    for (final s in d.services) {
      final port = s.port;
      final host = _bestHost(s);
      if (port == null || host == null) continue; // not fully resolved yet
      out.add(DiscoveredServer(_label(s), host, port));
    }
    return out;
  }

  // Prefer a concrete IPv4 address over the (sometimes unresolvable) .local hostname.
  String? _bestHost(Service s) {
    final addrs = s.addresses;
    if (addrs != null && addrs.isNotEmpty) {
      final v4 = addrs.where((a) => a.type == InternetAddressType.IPv4);
      return (v4.isNotEmpty ? v4.first : addrs.first).address;
    }
    return s.host;
  }

  String _label(Service s) {
    final n = (s.name ?? '').trim();
    return n.isEmpty ? 'Computer' : n;
  }

  /// Stop discovery and free its native resources (it's an expensive OS operation).
  Future<void> stop() async {
    final d = _discovery;
    final l = _listener;
    _discovery = null;
    _listener = null;
    if (d != null) {
      if (l != null) d.removeListener(l);
      try {
        await stopDiscovery(d);
      } catch (_) {}
    }
  }
}
