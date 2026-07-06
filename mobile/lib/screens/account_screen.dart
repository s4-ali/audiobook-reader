import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/sync_store.dart';
import '../theme.dart';

/// Email + password **sign-in** for optional cloud sync (Cloud Firestore). Reached from the
/// library's account button. New accounts are created on the web player — the mobile app
/// intentionally exposes sign-in only. When Firebase isn't configured it just explains that.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _obscure = true;

  AppPalette get _pal => AppPalette.of(context);

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = _pretty(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit(SyncStore sync) {
    final email = _email.text.trim();
    final pw = _password.text;
    if (email.isEmpty || pw.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    _run(() => sync.signIn(email, pw));
  }

  String _pretty(Object e) {
    final s = e.toString();
    if (s.contains('invalid-credential') ||
        s.contains('wrong-password') ||
        s.contains('user-not-found')) {
      return 'Wrong email or password.';
    }
    if (s.contains('invalid-email')) return "That doesn't look like a valid email.";
    if (s.contains('too-many-requests')) {
      return 'Too many attempts — wait a moment and try again.';
    }
    if (s.contains('network')) return 'Network error — check your connection.';
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud sync')),
      body: SafeArea(
        child: !sync.enabled
            ? _disabled()
            : sync.signedInWithAccount
                ? _signedIn(sync)
                : _signedOut(sync),
      ),
    );
  }

  Widget _disabled() => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          "Cloud sync isn't configured in this build. See the README "
          '("Optional cloud sync") to add your own Firebase project.',
          style: TextStyle(color: _pal.subtext0, height: 1.5),
        ),
      );

  Widget _badge(IconData icon, Color color) => Container(
        width: 66,
        height: 66,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 32),
      );

  InputDecoration _decoration(String label, {Widget? suffixIcon}) => InputDecoration(
        labelText: label,
        filled: true,
        fillColor: _pal.surface0,
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: _pal.accent, width: 1.5),
        ),
      );

  Widget _signedOut(SyncStore sync) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        children: [
          Center(
            child: Column(
              children: [
                _badge(Icons.cloud_outlined, _pal.accent),
                const SizedBox(height: 18),
                Text(
                  'Welcome back',
                  style: TextStyle(
                      fontSize: 23, fontWeight: FontWeight.w700, color: _pal.text),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sign in to sync your reading progress and notes with the web '
                  'player and your other devices.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _pal.subtext0, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            enabled: !_busy,
            decoration: _decoration('Email'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _password,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            enabled: !_busy,
            onSubmitted: (_) => _submit(sync),
            decoration: _decoration(
              'Password',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: _pal.subtext0,
                  size: 20,
                ),
                tooltip: _obscure ? 'Show password' : 'Hide password',
                onPressed: _busy ? null : () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            _errorBox(_error!),
          ],
          const SizedBox(height: 22),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: _busy ? null : () => _submit(sync),
              child: _busy
                  ? SizedBox(
                      height: 20,
                      width: 20,
                      child:
                          CircularProgressIndicator(strokeWidth: 2, color: _pal.crust),
                    )
                  : const Text('Sign in',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'New here? Signing in with a fresh email creates your account and keeps the '
            "reading progress you've already made on this device.",
            textAlign: TextAlign.center,
            style: TextStyle(color: _pal.subtext0, fontSize: 12.5, height: 1.4),
          ),
        ],
      );

  Widget _errorBox(String msg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: cRed.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: cRed, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(msg, style: const TextStyle(color: cRed, fontSize: 13)),
            ),
          ],
        ),
      );

  Widget _signedIn(SyncStore sync) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
        children: [
          Center(
            child: Column(
              children: [
                _badge(Icons.check_rounded, cGreen),
                const SizedBox(height: 18),
                Text(
                  "You're all set",
                  style: TextStyle(
                      fontSize: 23, fontWeight: FontWeight.w700, color: _pal.text),
                ),
                const SizedBox(height: 8),
                Text(
                  'Signed in as ${sync.email ?? ''}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _pal.subtext0),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _pal.surface0,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration:
                      const BoxDecoration(color: cGreen, shape: BoxShape.circle),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Reading progress and notes sync automatically across your '
                    'devices.',
                    style: TextStyle(color: _pal.subtext0, fontSize: 13, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          SizedBox(
            height: 50,
            child: OutlinedButton(
              onPressed: _busy ? null : () => _run(sync.signOut),
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Sign out'),
            ),
          ),
        ],
      );
}
