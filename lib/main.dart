import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'l10n/strings.dart';
import 'server/session_server.dart';

void main() {
  runZonedGuarded(
    () => runApp(const MyApp()),
    (error, stack) {
      debugPrint('ZONE ERROR: $error');
      debugPrint('$stack');
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'GhostChat',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF22D3EE),
            brightness: Brightness.dark,
          ),
        ),
        home: const TunnelPage(),
      );
}

class TunnelPage extends StatefulWidget {
  const TunnelPage({super.key});

  @override
  State<TunnelPage> createState() => _TunnelPageState();
}

class _TunnelPageState extends State<TunnelPage> {
  static const _channel = MethodChannel('com.aitechdb.ghostchat/native');
  static const _prefsLangKey = 'ghostchat_lang';

  final _log = StringBuffer();
  String? _publicUrl;
  bool _running = false;
  bool _starting = false;

  SessionServer? _server;
  String? _sessionId;
  String? _creatorNickname;
  String? _passphrase;
  List<Map<String, String>> _invites = [];

  String _lang = 'en';
  bool _langLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsLangKey);
      if (saved != null && GhostStrings.supported.contains(saved)) {
        setState(() {
          _lang = saved;
          _langLoaded = true;
        });
        return;
      }
      final deviceLang = ui.PlatformDispatcher.instance.locale.languageCode;
      final detected =
          GhostStrings.supported.contains(deviceLang) ? deviceLang : 'en';
      setState(() {
        _lang = detected;
        _langLoaded = true;
      });
      await prefs.setString(_prefsLangKey, detected);
    } catch (_) {
      setState(() {
        _lang = 'en';
        _langLoaded = true;
      });
    }
  }

  Future<void> _setLanguage(String lang) async {
    setState(() => _lang = lang);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsLangKey, lang);
    } catch (_) {}
    _server?.setLanguage(lang);
  }

  GhostStrings get _t => GhostStrings.of(_lang);

  void _append(String s) {
    setState(() => _log.writeln(s));
    debugPrint(s);
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      _server = SessionServer(port: 8080);
      _server!.setLanguage(_lang);
      await _server!.start();
      _append('SessionServer avviato su 127.0.0.1:8080');

      final result = _server!.createSession(inviteCount: 3);
      final session = result.session;
      _sessionId = session.id;
      _creatorNickname = session.creatorNickname;
      _passphrase = result.passphrase;
      _invites = session.invites
          .map((i) => {'token': i.token, 'code': i.code})
          .toList();
      _append('Sessione creata: ${session.id}');
      _append('Creatore: ${session.creatorNickname}');
      _append('Passphrase generata (mostrata in UI)');

      _append('Avvio tunnel Cloudflare (Rust FFI)...');
      final url = await _channel.invokeMethod<String>('startTunnel', {
        'port': 8080,
      });

      if (url != null && url.isNotEmpty) {
        setState(() {
          _publicUrl = url;
          _running = true;
        });
        _append('URL pubblico: $url');

        try {
          await _channel.invokeMethod<bool>('startForegroundService', {
            'url': url,
          });
          _append('Foreground Service avviato');
        } catch (e) {
          _append('ATTENZIONE: Foreground Service non avviato: $e');
        }
      } else {
        _append('ERRORE: URL nullo');
      }
    } catch (e, st) {
      _append('ERRORE: $e\n$st');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    try {
      await _channel.invokeMethod<bool>('stopForegroundService');
    } catch (_) {}
    try {
      await _channel.invokeMethod<bool>('stopTunnel');
    } catch (_) {}
    await _server?.stop();
    _server = null;
    setState(() {
      _running = false;
      _publicUrl = null;
      _sessionId = null;
      _creatorNickname = null;
      _passphrase = null;
      _invites = [];
    });
    _append('Arrestato');
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    _append('$label copiato negli appunti');
  }

  Future<void> _openInBrowser(String url) async {
    try {
      final uri = Uri.parse(url);
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launched) {
        _append("Browser aperto: $url");
      } else {
        _append("Impossibile aprire il browser");
      }
    } catch (e) {
      _append("Errore apertura browser: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_langLoaded) {
      return const Scaffold(
        backgroundColor: Color(0xFF090D16),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF22D3EE)),
        ),
      );
    }

    final t = _t;
    final busy = _running || _starting;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF090D16),
        elevation: 0,
        centerTitle: true,
        title: _GradientTitle(text: t.appTitle),
      ),
      backgroundColor: const Color(0xFF090D16),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(child: _GhostLogo()),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  t.brandTag,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    color: Color(0xFFFF6B00),
                    shadows: [
                      Shadow(color: Color(0xAAFF6B00), blurRadius: 6),
                      Shadow(color: Color(0x55FF6B00), blurRadius: 12),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),
              _box(
                color: const Color(0xFF22D3EE),
                title: t.howItWorks,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _guideLine(t.step1),
                    _guideLine(t.step2),
                    _guideLine(t.step3),
                    _guideLine(t.step4),
                    _guideLine(t.step5),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              _languageSelector(t),

              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: busy ? null : _start,
                child: Text(_starting ? t.starting : t.startTunnel),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _running ? _stop : null,
                child: Text(t.stopTunnel),
              ),

              if (_publicUrl != null) ...[
                const SizedBox(height: 12),
                _box(
                  color: const Color(0xFF22D3EE),
                  title: t.publicUrl,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        _publicUrl!,
                        style: const TextStyle(
                            color: Color(0xFFF0F4FF), fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: () => _copy('URL', _publicUrl!),
                        icon: const Icon(Icons.copy, size: 16),
                        label: Text(t.copyUrl),
                      ),
                    ],
                  ),
                ),
              ],

              if (_passphrase != null) ...[
                const SizedBox(height: 12),
                _box(
                  color: const Color(0xFFEF4444),
                  title: t.passphraseTitle,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.passphraseHint,
                        style: const TextStyle(
                            color: Color(0xFFFCA5A5), fontSize: 11),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        _passphrase!,
                        style: const TextStyle(
                            color: Color(0xFFF0F4FF),
                            fontSize: 16,
                            fontFamily: 'monospace',
                            letterSpacing: 1.2),
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: () =>
                            _copy(t.copyPassphrase, _passphrase!),
                        icon: const Icon(Icons.copy, size: 16),
                        label: Text(t.copyPassphrase),
                      ),
                    ],
                  ),
                ),
              ],

              if (_sessionId != null) ...[
                const SizedBox(height: 12),
                _box(
                  color: const Color(0xFFA78BFA),
                  title: t.session,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${t.sessionId}: $_sessionId',
                          style: const TextStyle(
                              color: Color(0xFFF0F4FF), fontSize: 12)),
                      Text('${t.creator}: $_creatorNickname',
                          style: const TextStyle(
                              color: Color(0xFFF0F4FF), fontSize: 12)),
                      const SizedBox(height: 8),
                      Text(t.invites,
                          style: const TextStyle(
                              color: Color(0xFFA78BFA),
                              fontSize: 12,
                              letterSpacing: 2)),
                      const SizedBox(height: 4),
                      ..._invites.asMap().entries.map((entry) {
                        final index = entry.key;
                        final inv = entry.value;
                        final code = inv['code']!;
                        final link = _publicUrl != null
                            ? '${_publicUrl!}/?code=$code'
                            : '(link disponibile dopo il tunnel)';
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                code,
                                style: const TextStyle(
                                    color: Color(0xFF4ADE80),
                                    fontSize: 14,
                                    fontFamily: 'monospace'),
                              ),
                              const SizedBox(height: 2),
                              SelectableText(
                                link,
                                style: const TextStyle(
                                    color: Color(0xFF8892B0),
                                    fontSize: 10,
                                    fontFamily: 'monospace'),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton.icon(
                                    onPressed: () =>
                                        _copy('${t.copyCode} $code', code),
                                    icon: const Icon(Icons.copy, size: 14),
                                    label: Text(t.copyCode,
                                        style: const TextStyle(fontSize: 11)),
                                  ),
                                  if (_publicUrl != null)
                                    TextButton.icon(
                                      onPressed: () =>
                                          _copy('${t.copyLink} $code', link),
                                      icon: const Icon(Icons.link, size: 14),
                                      label: Text(t.copyLink,
                                          style: const TextStyle(fontSize: 11)),
                                    ),
                                  if (index == 0 && _publicUrl != null)
                                    TextButton.icon(
                                      onPressed: () => _openInBrowser(link),
                                      icon: const Icon(Icons.open_in_browser,
                                          size: 14, color: Color(0xFF22D3EE)),
                                      label: Text(
                                        t.openInBrowser,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Color(0xFF22D3EE)),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 12),
              Container(
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF1A1F2E)),
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.all(8),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _log.toString(),
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFF8892B0)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _guideLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFF0F4FF),
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _languageSelector(GhostStrings t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF8892B0)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text(
            t.language,
            style: const TextStyle(
              color: Color(0xFF8892B0),
              fontSize: 11,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<String>(
              value: _lang,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              dropdownColor: const Color(0xFF090D16),
              iconEnabledColor: const Color(0xFF22D3EE),
              style: const TextStyle(
                color: Color(0xFFF0F4FF),
                fontSize: 14,
              ),
              items: [
                DropdownMenuItem(value: 'it', child: Text(t.langItalian)),
                DropdownMenuItem(value: 'en', child: Text(t.langEnglish)),
                DropdownMenuItem(value: 'es', child: Text(t.langSpanish)),
              ],
              onChanged: (v) {
                if (v != null) _setLanguage(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _box({
    required Color color,
    required String title,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: color, fontSize: 12, letterSpacing: 2)),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class _GradientTitle extends StatelessWidget {
  const _GradientTitle({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Color(0xFF22D3EE),
          Color(0xFFA78BFA),
        ],
      ).createShader(bounds),
      blendMode: BlendMode.srcIn,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          color: Colors.white,
          shadows: [
            Shadow(color: Color(0x8822D3EE), blurRadius: 12),
            Shadow(color: Color(0x44A78BFA), blurRadius: 20),
          ],
        ),
      ),
    );
  }
}

class _GhostLogo extends StatelessWidget {
  const _GhostLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF22D3EE).withValues(alpha: 0.35),
            blurRadius: 40,
            spreadRadius: 8,
          ),
          BoxShadow(
            color: const Color(0xFFA78BFA).withValues(alpha: 0.25),
            blurRadius: 60,
            spreadRadius: 12,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: const Text(
        '👻',
        style: TextStyle(fontSize: 64, height: 1),
      ),
    );
  }
}
