import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/discovery.dart';
import '../services/library_store.dart';
import '../services/settings_store.dart';
import '../services/transfer.dart';
import '../theme.dart';
import '../util.dart';
import 'scan_screen.dart';

/// Connect to the desktop server over the LAN, list its library, and download books
/// (the `.abk` package) straight onto the device.
///
/// Three ways to connect, easiest first: tap a server auto-discovered on the Wi-Fi (mDNS),
/// scan the QR code the desktop shows, or type the address by hand.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  late final SettingsStore _settings;
  late final Transfer _transfer;
  late final LibraryStore _library;

  final TextEditingController _url = TextEditingController();
  final DiscoveryService _discovery = DiscoveryService();
  List<DiscoveredServer> _found = [];
  List<RemoteBook>? _remote;
  final Set<String> _installed = {};
  final Map<String, double> _progress = {};
  String? _error;
  bool _connecting = false;
  bool _scanning = false;

  AppPalette get _pal => AppPalette.of(context);

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsStore>();
    _transfer = context.read<Transfer>();
    _library = context.read<LibraryStore>();
    _url.text = _settings.serverUrl ?? '';
    _refreshInstalled();
    _discovery.start((servers) {
      if (mounted) setState(() => _found = servers);
    });
    if (_url.text.isNotEmpty) _connect();
  }

  @override
  void dispose() {
    _discovery.stop();
    _url.dispose();
    super.dispose();
  }

  Future<void> _refreshInstalled() async {
    final books = await _library.list();
    if (mounted) {
      setState(() => _installed
        ..clear()
        ..addAll(books.map((b) => b.book.id)));
    }
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final base = Transfer.normalizeUrl(_url.text);
      final books = await _transfer.fetchLibrary(base);
      _settings.serverUrl = base;
      if (mounted) {
        setState(() {
          _remote = books;
          _connecting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not reach the server.\n$e';
          _connecting = false;
        });
      }
    }
  }

  /// Fill the address field from a discovered server or a scanned QR, then connect.
  void _connectTo(String url) {
    _url.text = url;
    _connect();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final result = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const ScanScreen()),
      );
      if (result != null && result.trim().isNotEmpty) _connectTo(result.trim());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _download(RemoteBook b) async {
    final messenger = ScaffoldMessenger.of(context);
    final base = Transfer.normalizeUrl(_url.text);
    setState(() => _progress[b.id] = 0);
    try {
      await _transfer.downloadAndInstall(
        base,
        b.id,
        onProgress: (p) {
          if (mounted) setState(() => _progress[b.id] = p);
        },
      );
      if (mounted) {
        setState(() {
          _progress.remove(b.id);
          _installed.add(b.id);
        });
      }
      messenger
          .showSnackBar(SnackBar(content: Text('Downloaded “${b.title}”')));
    } catch (e) {
      if (mounted) setState(() => _progress.remove(b.id));
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to computer')),
      body: Column(
        children: [
          _connectHeader(),
          const Divider(height: 1),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  /// Discovery list + Scan button + manual address field, in a scrollable header so it never
  /// overflows when the keyboard opens.
  Widget _connectHeader() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_found.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 2),
              child: Text('On your Wi-Fi',
                  style: TextStyle(
                      color: _pal.subtext0,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
            ..._found.map(_discoveredTile),
            _orDivider(),
          ],
          OutlinedButton.icon(
            onPressed: _scanning ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR code'),
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Server address',
                    hintText: '192.168.1.20:8000',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _connect(),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _connecting ? null : _connect,
                child: _connecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Connect'),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: const TextStyle(color: cRed)),
            ),
        ],
      ),
    );
  }

  Widget _discoveredTile(DiscoveredServer s) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(Icons.wifi, color: _pal.accent),
        title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${s.host}:${s.port}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: _connecting ? null : () => _connectTo(s.url),
      ),
    );
  }

  Widget _orDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(child: Divider(color: _pal.surface1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('or', style: TextStyle(color: _pal.subtext0, fontSize: 12)),
        ),
        Expanded(child: Divider(color: _pal.surface1)),
      ]),
    );
  }

  Widget _list() {
    final remote = _remote;
    if (remote == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'On the same Wi-Fi, this computer appears above automatically.\n\n'
            'Otherwise tap “Scan QR code”, or type the address.\n\n'
            'On the computer, run:  HOST=0.0.0.0 ./scripts/run.sh',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (remote.isEmpty) {
      return const Center(child: Text('No books on the server yet.'));
    }
    return ListView.separated(
      itemCount: remote.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => _row(remote[i]),
    );
  }

  Widget _row(RemoteBook b) {
    return ListTile(
      leading: const Icon(Icons.menu_book),
      title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${b.author.isEmpty ? 'Unknown' : b.author} · ${b.nChapters} ch · ${fmtHm(b.duration)}'
        '${b.isReady ? '' : ' · ${b.status}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _trailing(b),
    );
  }

  Widget _trailing(RemoteBook b) {
    final p = _progress[b.id];
    if (p != null) {
      return SizedBox(
        width: 38,
        height: 38,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(value: p > 0 ? p : null, strokeWidth: 3),
            Text('${(p * 100).round()}', style: const TextStyle(fontSize: 9)),
          ],
        ),
      );
    }
    if (_installed.contains(b.id)) {
      return IconButton(
        icon: const Icon(Icons.check_circle, color: cGreen),
        tooltip: 'Downloaded — tap to re-download',
        onPressed: b.isReady ? () => _download(b) : null,
      );
    }
    if (b.isReady) {
      return IconButton(
        icon: const Icon(Icons.download),
        tooltip: 'Download',
        onPressed: () => _download(b),
      );
    }
    return const SizedBox.shrink();
  }
}
