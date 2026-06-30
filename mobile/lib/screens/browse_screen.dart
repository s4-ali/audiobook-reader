import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/library_store.dart';
import '../services/settings_store.dart';
import '../services/transfer.dart';
import '../theme.dart';
import '../util.dart';

/// Connect to the desktop server over the LAN, list its library, and download books
/// (the `.abk` package) straight onto the device.
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
  List<RemoteBook>? _remote;
  final Set<String> _installed = {};
  final Map<String, double> _progress = {};
  String? _error;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsStore>();
    _transfer = context.read<Transfer>();
    _library = context.read<LibraryStore>();
    _url.text = _settings.serverUrl ?? '';
    _refreshInstalled();
    if (_url.text.isNotEmpty) _connect();
  }

  @override
  void dispose() {
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
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
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
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: const TextStyle(color: cRed)),
            ),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _list() {
    final remote = _remote;
    if (remote == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Run the player on your computer with\nHOST=0.0.0.0 ./scripts/run.sh\nthen enter its address above.',
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
        '${b.author.isEmpty ? 'Unknown' : b.author} · ${b.nChapters} ch · ${fmtMinutes(b.duration)}'
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
