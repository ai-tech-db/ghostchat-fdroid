import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models/session.dart';
import 'token.dart';

/// Server GhostChat embedded: HTTP + WebSocket.
///
/// Relay puro e cieco. Nessuna persistenza dei messaggi, nessuna
/// decifratura. Il server vede solo ciphertext e metadati.
class SessionServer {
  SessionServer({required this.port, AssetBundle? bundle})
      : _bundle = bundle ?? rootBundle;

  final int port;
  final AssetBundle _bundle;
  HttpServer? _http;

  final Map<String, Session> _sessions = {};
  final Map<String, String> _inviteToSession = {};
  final Map<String, SessionParticipant> _reconnectIndex = {};

  /// Lingua corrente dell'interfaccia (propagata al client web)
  String _language = 'it';

  /// Imposta la lingua per il client web
  void setLanguage(String lang) {
    _language = lang;
  }

  static const Duration _reconnectGrace = Duration(minutes: 2);

  bool get isRunning => _http != null;
  int get boundPort => _http?.port ?? port;
  Iterable<Session> get sessions => _sessions.values;

  ({Session session, String passphrase}) createSession({
    String? creatorNickname,
    int inviteCount = 3,
  }) {
    if (inviteCount < 1 || inviteCount > 3) {
      throw ArgumentError('inviteCount deve essere 1..3');
    }

    final id = SecureToken.random(12);
    final creator = creatorNickname ?? SecureToken.ghostNickname();

    final session = Session(
      id: id,
      creatorNickname: creator,
      createdAt: DateTime.now(),
    );

    for (var i = 0; i < inviteCount; i++) {
      final token = SecureToken.random(32);
      final code = SecureToken.shortCode();
      final invite = SessionInvite(
        token: token,
        code: code,
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 2)),
      );
      session.invites.add(invite);
      _inviteToSession[token] = id;
      _inviteToSession[code] = id;
    }

    // Il creator NON viene aggiunto ai participants.
    // Non chatta, non ha WebSocket, non deve apparire nella lista.
    // Resta solo come metadato in Session.creatorNickname.

    _sessions[id] = session;

    final passphrase = SecureToken.passphrase6Words();
    return (session: session, passphrase: passphrase);
  }

  Session? getSession(String id) => _sessions[id];

  static String _normalizeJoinToken(String raw) {
    final t = raw.trim();
    if (t.toUpperCase().startsWith('GHST-')) {
      return t.toUpperCase();
    }
    return t;
  }

  Session? sessionFromInvite(String tokenOrCode) {
    final normalized = _normalizeJoinToken(tokenOrCode);
    final sessionId = _inviteToSession[normalized];
    if (sessionId == null) return null;
    return _sessions[sessionId];
  }

  void _expireReconnect(SessionParticipant p) {
    final rt = p.reconnectToken;
    if (rt != null) {
      _reconnectIndex.remove(rt);
      p.reconnectToken = null;
    }
  }

  Future<bool> closeSession(String id,
      {String reason = 'creator_ended'}) async {
    final session = _sessions[id];
    if (session == null || session.closed) return false;

    session.closed = true;

    for (final p in session.participants) {
      final ws = p.wsConnection;
      if (ws is WebSocketChannel) {
        try {
          ws.sink.add(jsonEncode({
            'type': 'session_ended',
            'reason': reason,
          }));
          await ws.sink.close();
        } catch (_) {}
      }
    }

    for (final inv in session.invites) {
      _inviteToSession.remove(inv.token);
      _inviteToSession.remove(inv.code);
    }

    for (final p in session.participants) {
      _expireReconnect(p);
    }

    _sessions.remove(id);
    return true;
  }

  Future<void> start() async {
    if (_http != null) return;

    final handler = const shelf.Pipeline()
        .addMiddleware(_securityHeaders)
        .addHandler(_router);

    _http = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      port,
    );
  }

  shelf.Handler _securityHeaders(shelf.Handler inner) {
    return (shelf.Request req) async {
      final res = await inner(req);
      return res.change(headers: {
        'Content-Security-Policy':
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "connect-src 'self' wss:; img-src 'self' data:; frame-ancestors 'none'; "
            "base-uri 'none'; form-action 'none'",
        'X-Frame-Options': 'DENY',
        'Referrer-Policy': 'no-referrer',
        'X-Content-Type-Options': 'nosniff',
        'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
      });
    };
  }

  Future<void> stop() async {
    for (final id in _sessions.keys.toList()) {
      await closeSession(id, reason: 'server_shutdown');
    }
    await _http?.close(force: true);
    _http = null;
  }

  Future<shelf.Response> _router(shelf.Request req) async {
    final path = req.url.path;

    if (path == 'ws') {
      final token = req.url.queryParameters['token'] ?? '';
      final handler = webSocketHandler((WebSocketChannel ws, _) {
        _handleWsConnection(ws, token);
      });
      return await handler(req);
    }

    if (path == 'api/session/create' && req.method == 'POST') {
      return _handleCreateSession(req);
    }

    if (path.startsWith('api/session/') && path.endsWith('/info')) {
      final id = path.substring(
        'api/session/'.length,
        path.length - '/info'.length,
      );
      return _handleSessionInfo(id);
    }

    if (path == 'api/stickers') {
      return shelf.Response.ok(
        jsonEncode({'packs': []}),
        headers: {'content-type': 'application/json'},
      );
    }

    if (path.isEmpty || path == '/' || path == 'index.html') {
      return _serveAsset('index.html', 'text/html; charset=utf-8');
    }
    if (path == 'style.css') {
      return _serveAsset('style.css', 'text/css; charset=utf-8');
    }
    if (path == 'app.js') {
      return _serveAsset('app.js', 'application/javascript; charset=utf-8');
    }

    if (path == 'strings_web.js') {
      return _serveAsset('strings_web.js', 'application/javascript; charset=utf-8');
    }

    return shelf.Response.notFound('not found');
  }

  Future<shelf.Response> _serveAsset(String name, String contentType) async {
    try {
      var data = await _bundle.loadString('assets/web_client/$name');
      if (name == 'index.html') {
        data = data.replaceFirst(
          '<head>',
          '<head><meta name="ghostchat-lang" content="$_language">',
        );
      }
      return shelf.Response.ok(
        data,
        headers: {'content-type': contentType},
      );
    } catch (e) {
      return shelf.Response.notFound(
          'asset non trovato: assets/web_client/$name');
    }
  }

  Future<shelf.Response> _handleCreateSession(shelf.Request req) async {
    try {
      final body = await req.readAsString();
      final data = body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(body) as Map<String, dynamic>;
      final inviteCount = (data['inviteCount'] as int?) ?? 3;
      final creatorNickname = data['creatorNickname'] as String?;

      final result = createSession(
        creatorNickname: creatorNickname,
        inviteCount: inviteCount,
      );
      final session = result.session;
      final passphrase = result.passphrase;

      return shelf.Response.ok(
        jsonEncode({
          'sessionId': session.id,
          'creatorNickname': session.creatorNickname,
          'passphrase': passphrase,
          'invites': session.invites
              .map((i) => {
                    'token': i.token,
                    'code': i.code,
                    'expiresAt': i.expiresAt.toIso8601String(),
                  })
              .toList(),
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return shelf.Response.badRequest(body: 'errore: $e');
    }
  }

  shelf.Response _handleSessionInfo(String id) {
    final s = _sessions[id];
    if (s == null) {
      return shelf.Response.notFound('sessione non trovata');
    }
    return shelf.Response.ok(
      jsonEncode({
        'id': s.id,
        'creator': s.creatorNickname,
        'createdAt': s.createdAt.toIso8601String(),
        'participants': s.participants.length,
        'maxParticipants': s.maxParticipants,
        'invitesRemaining': s.activeInvites,
        'closed': s.closed,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  // ── WebSocket ──────────────────────────────────────────────────────────

  void _handleWsConnection(WebSocketChannel ws, String rawToken) {
    if (rawToken.isEmpty) {
      _send(ws, {'type': 'error', 'code': 'missing_token'});
      ws.sink.close();
      return;
    }

    if (rawToken.startsWith('reconnect:')) {
      final rt = rawToken.substring('reconnect:'.length);
      final participant = _reconnectIndex[rt];

      if (participant == null) {
        _send(ws, {'type': 'error', 'code': 'reconnect_invalid'});
        ws.sink.close();
        return;
      }

      Session? maybeSession;
      for (final s in _sessions.values) {
        if (s.participants.contains(participant)) {
          maybeSession = s;
          break;
        }
      }

      if (maybeSession == null || maybeSession.closed) {
        _send(ws, {'type': 'error', 'code': 'session_closed'});
        ws.sink.close();
        return;
      }

      final disconnectedAt = participant.disconnectedAt;
      if (disconnectedAt != null &&
          DateTime.now().difference(disconnectedAt) > _reconnectGrace) {
        _expireReconnect(participant);
        _send(ws, {'type': 'error', 'code': 'reconnect_expired'});
        ws.sink.close();
        return;
      }

      final session = maybeSession;
      participant.wsConnection = ws;
      participant.disconnectedAt = null;

      _send(ws, {
        'type': 'welcome',
        'sessionId': session.id,
        'nickname': participant.nickname,
        'reconnectToken': participant.reconnectToken,
        'participants': session.participants
            .map((p) => {'nickname': p.nickname, 'isCreator': p.isCreator})
            .toList(),
      });

      _broadcast(session, {
        'type': 'participant_joined',
        'nickname': participant.nickname,
      }, exclude: ws);

      ws.stream.listen(
        (data) => _handleClientMessage(session, participant, ws, data),
        onDone: () => _handleDisconnect(session, participant),
        onError: (_) => _handleDisconnect(session, participant),
        cancelOnError: true,
      );
      return;
    }

    final token = _normalizeJoinToken(rawToken);
    final session = sessionFromInvite(token);
    if (session == null) {
      _send(ws, {'type': 'error', 'code': 'invalid_token'});
      ws.sink.close();
      return;
    }

    if (session.closed) {
      _send(ws, {'type': 'error', 'code': 'session_closed'});
      ws.sink.close();
      return;
    }

    if (!session.canAcceptParticipant) {
      _send(ws, {'type': 'error', 'code': 'session_full'});
      ws.sink.close();
      return;
    }

    SessionInvite? invite;
    for (final i in session.invites) {
      if (i.token == token || i.code == token) {
        invite = i;
        break;
      }
    }

    if (invite == null) {
      _send(ws, {'type': 'error', 'code': 'invalid_invite'});
      ws.sink.close();
      return;
    }

    if (invite.isUsed) {
      _send(ws, {'type': 'error', 'code': 'invite_already_used'});
      ws.sink.close();
      return;
    }

    if (invite.isExpired) {
      _send(ws, {'type': 'error', 'code': 'invite_expired'});
      ws.sink.close();
      return;
    }

    final nickname = SecureToken.ghostNickname();
    invite.usedAt = DateTime.now();
    invite.usedByNickname = nickname;

    final reconnectToken = SecureToken.random(32);

    final participant = SessionParticipant(
      nickname: nickname,
      joinedAt: DateTime.now(),
      isCreator: false,
    )
      ..wsConnection = ws
      ..reconnectToken = reconnectToken;

    session.participants.add(participant);
    _reconnectIndex[reconnectToken] = participant;

    _send(ws, {
      'type': 'welcome',
      'sessionId': session.id,
      'nickname': nickname,
      'reconnectToken': reconnectToken,
      'participants': session.participants
          .map((p) => {'nickname': p.nickname, 'isCreator': p.isCreator})
          .toList(),
    });

    _broadcast(session, {
      'type': 'participant_joined',
      'nickname': nickname,
    }, exclude: ws);

    ws.stream.listen(
      (data) => _handleClientMessage(session, participant, ws, data),
      onDone: () => _handleDisconnect(session, participant),
      onError: (_) => _handleDisconnect(session, participant),
      cancelOnError: true,
    );
  }

  void _handleClientMessage(
    Session session,
    SessionParticipant participant,
    WebSocketChannel ws,
    dynamic data,
  ) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      _send(ws, {'type': 'error', 'code': 'invalid_json'});
      return;
    }

    final type = msg['type'] as String?;
    switch (type) {
      case 'pubkey':
        final pk = msg['pubkey'] as String?;
        if (pk == null || pk.isEmpty || pk.length > 256) return;
        _broadcast(session, {
          'type': 'pubkey',
          'from': participant.nickname,
          'pubkey': pk,
        }, exclude: ws);
        break;

      case 'pubkey_request':
        _broadcast(session, {
          'type': 'pubkey_request',
          'from': participant.nickname,
        }, exclude: ws);
        break;

      case 'hello_ok':
        // Inoltro mirato al destinatario.
        final to = msg['to'] as String?;
        if (to == null || to.isEmpty || to.length > 32) return;
        for (final p in session.participants) {
          if (p.nickname == to) {
            final targetWs = p.wsConnection;
            if (targetWs is WebSocketChannel && targetWs != ws) {
              try {
                targetWs.sink.add(jsonEncode({
                  'type': 'hello_ok',
                  'from': participant.nickname,
                  'to': to,
                }));
              } catch (_) {}
            }
            break;
          }
        }
        break;

      case 'message':
        final iv = msg['iv'] as String?;
        final ct = msg['ct'] as String?;
        final sig = msg['sig'] as String?;
        final counter = msg['counter'];
        if (iv == null || ct == null || sig == null) return;
        if (iv.isEmpty || ct.isEmpty || sig.isEmpty) return;
        if (ct.length > 16384 || iv.length > 64 || sig.length > 256) return;
        if (counter is! int || counter < 0) return;
        _broadcast(session, {
          'type': 'message',
          'from': participant.nickname,
          'counter': counter,
          'iv': iv,
          'ct': ct,
          'sig': sig,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }, exclude: ws);
        break;

      case 'sticker':
        final stickerId = msg['stickerId'] as String? ?? '';
        if (stickerId.isEmpty || stickerId.length > 64) return;
        _broadcast(session, {
          'type': 'sticker',
          'from': participant.nickname,
          'stickerId': stickerId,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }, exclude: ws);
        break;

      case 'typing':
        final active = msg['active'] as bool? ?? false;
        _broadcast(session, {
          'type': 'typing',
          'from': participant.nickname,
          'active': active,
        }, exclude: ws);
        break;

      case 'ping':
        _send(ws, {'type': 'pong'});
        break;

      default:
        _send(ws, {'type': 'error', 'code': 'unknown_type'});
    }
  }

  void _handleDisconnect(Session session, SessionParticipant participant) {
    participant.wsConnection = null;
    participant.disconnectedAt = DateTime.now();

    _broadcast(session, {
      'type': 'participant_left',
      'nickname': participant.nickname,
    });

    final rt = participant.reconnectToken;
    if (rt != null) {
      Timer(_reconnectGrace, () {
        final stillThere = _reconnectIndex[rt];
        if (stillThere == participant && participant.wsConnection == null) {
          _reconnectIndex.remove(rt);
          participant.reconnectToken = null;
          session.participants.remove(participant);
        }
      });
    } else {
      session.participants.remove(participant);
    }
  }

  void _send(WebSocketChannel ws, Map<String, dynamic> msg) {
    try {
      ws.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  void _broadcast(
    Session session,
    Map<String, dynamic> msg, {
    WebSocketChannel? exclude,
  }) {
    final data = jsonEncode(msg);
    for (final p in session.participants) {
      final ws = p.wsConnection;
      if (ws is WebSocketChannel && ws != exclude) {
        try {
          ws.sink.add(data);
        } catch (_) {}
      }
    }
  }
}
