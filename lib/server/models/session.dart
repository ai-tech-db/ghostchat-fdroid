/// Modello dati per una sessione GhostChat.
///
/// Tutto in memoria volatile. Nessuna persistenza su disco.
library;

class SessionInvite {
  SessionInvite({
    required this.token,
    required this.code,
    required this.createdAt,
    required this.expiresAt,
    this.usedAt,
    this.usedByNickname,
  });

  final String token;
  final String code;
  final DateTime createdAt;
  final DateTime expiresAt;
  DateTime? usedAt;
  String? usedByNickname;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get isUsed => usedAt != null;
  bool get isValid => !isExpired && !isUsed;
}

class SessionParticipant {
  SessionParticipant({
    required this.nickname,
    required this.joinedAt,
    required this.isCreator,
  });

  final String nickname;
  final DateTime joinedAt;
  final bool isCreator;
  Object? wsConnection;

  /// Token opaco per riconnettersi dopo una caduta di rete.
  /// Generato al primo join, valido finché il participant resta
  /// nella grace period di riconnessione.
  String? reconnectToken;

  /// Timestamp dell'ultima disconnessione. `null` se connesso.
  DateTime? disconnectedAt;
}

class SessionMessage {
  SessionMessage({
    required this.id,
    required this.from,
    required this.ts,
    required this.kind,
    this.text,
    this.stickerId,
  });

  final String id;
  final String from;
  final DateTime ts;
  final String kind; // 'text' | 'sticker'
  final String? text;
  final String? stickerId;
}

class Session {
  Session({
    required this.id,
    required this.creatorNickname,
    required this.createdAt,
    this.maxParticipants = 4,
  })  : participants = [],
        invites = [],
        messages = [];

  final String id;
  final String creatorNickname;
  final DateTime createdAt;
  final int maxParticipants;

  final List<SessionParticipant> participants;
  final List<SessionInvite> invites;
  final List<SessionMessage> messages;

  bool closed = false;

  int get maxInvitees => maxParticipants - 1;
  int get activeInvites => invites.where((i) => i.isValid).length;
  bool get canAcceptParticipant =>
      !closed && participants.length < maxParticipants;
}
