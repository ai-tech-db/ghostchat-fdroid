/// Stringhe tradotte per l'app GhostChat (lato Flutter).
///
/// 3 lingue supportate: Italiano, Inglese, Spagnolo.
/// Fallback: inglese.
library;

class GhostStrings {
  final String appTitle;
  final String howItWorks;
  final String step1;
  final String step2;
  final String step3;
  final String step4;
  final String step5;
  final String language;
  final String startTunnel;
  final String starting;
  final String stopTunnel;
  final String publicUrl;
  final String copyUrl;
  final String passphraseTitle;
  final String passphraseHint;
  final String copyPassphrase;
  final String session;
  final String sessionId;
  final String creator;
  final String invites;
  final String copyCode;
  final String copyLink;
  final String openInBrowser;
  final String log;
  final String brandTag;
  final String langItalian;
  final String langEnglish;
  final String langSpanish;

  const GhostStrings({
    required this.appTitle,
    required this.howItWorks,
    required this.step1,
    required this.step2,
    required this.step3,
    required this.step4,
    required this.step5,
    required this.language,
    required this.startTunnel,
    required this.starting,
    required this.stopTunnel,
    required this.publicUrl,
    required this.copyUrl,
    required this.passphraseTitle,
    required this.passphraseHint,
    required this.copyPassphrase,
    required this.session,
    required this.sessionId,
    required this.creator,
    required this.invites,
    required this.copyCode,
    required this.copyLink,
    required this.openInBrowser,
    required this.log,
    required this.brandTag,
    required this.langItalian,
    required this.langEnglish,
    required this.langSpanish,
  });

  static const Map<String, GhostStrings> _all = {
    'it': GhostStrings(
      appTitle: 'GhostChat',
      howItWorks: 'COME FUNZIONA',
      step1: '1. Premi "Avvia Quick Tunnel"',
      step2: '2. Attendi l\'URL pubblico (15-20 secondi)',
      step3: '3. Copia il link e la passphrase',
      step4: '4. Inviali su canali diversi (link su WhatsApp, passphrase a voce)',
      step5: '5. I partecipanti aprono il link nel browser',
      language: 'LINGUA',
      startTunnel: 'Avvia Quick Tunnel',
      starting: 'Avvio...',
      stopTunnel: 'Ferma tunnel',
      publicUrl: 'URL PUBBLICO',
      copyUrl: 'Copia URL',
      passphraseTitle: 'PASSPHRASE E2EE',
      passphraseHint:
          'Comunica questa passphrase ai partecipanti su un canale DIVERSO dal link (a voce, Signal, di persona). Senza di essa i messaggi sono incomprensibili.',
      copyPassphrase: 'Copia passphrase',
      session: 'SESSIONE',
      sessionId: 'ID',
      creator: 'Creator',
      invites: 'INVITI (link + codice)',
      copyCode: 'Copia codice',
      copyLink: 'Copia link',
      openInBrowser: 'Apri nel browser',
      log: 'LOG',
      brandTag: 'by AI-Tech-DB',
      langItalian: 'Italiano',
      langEnglish: 'English',
      langSpanish: 'Español',
    ),
    'en': GhostStrings(
      appTitle: 'GhostChat',
      howItWorks: 'HOW IT WORKS',
      step1: '1. Tap "Start Quick Tunnel"',
      step2: '2. Wait for the public URL (15-20 seconds)',
      step3: '3. Copy the link and the passphrase',
      step4: '4. Send them on different channels (link via WhatsApp, passphrase by voice)',
      step5: '5. Participants open the link in their browser',
      language: 'LANGUAGE',
      startTunnel: 'Start Quick Tunnel',
      starting: 'Starting...',
      stopTunnel: 'Stop tunnel',
      publicUrl: 'PUBLIC URL',
      copyUrl: 'Copy URL',
      passphraseTitle: 'E2EE PASSPHRASE',
      passphraseHint:
          'Share this passphrase with participants on a DIFFERENT channel than the link (by voice, Signal, in person). Without it, messages are unreadable.',
      copyPassphrase: 'Copy passphrase',
      session: 'SESSION',
      sessionId: 'ID',
      creator: 'Creator',
      invites: 'INVITES (link + code)',
      copyCode: 'Copy code',
      copyLink: 'Copy link',
      openInBrowser: 'Open in browser',
      log: 'LOG',
      brandTag: 'by AI-Tech-DB',
      langItalian: 'Italiano',
      langEnglish: 'English',
      langSpanish: 'Español',
    ),
    'es': GhostStrings(
      appTitle: 'GhostChat',
      howItWorks: 'CÓMO FUNCIONA',
      step1: '1. Pulsa "Iniciar Quick Tunnel"',
      step2: '2. Espera la URL pública (15-20 segundos)',
      step3: '3. Copia el enlace y la frase de paso',
      step4: '4. Envíalos por canales distintos (enlace por WhatsApp, frase de paso por voz)',
      step5: '5. Los participantes abren el enlace en su navegador',
      language: 'IDIOMA',
      startTunnel: 'Iniciar Quick Tunnel',
      starting: 'Iniciando...',
      stopTunnel: 'Detener túnel',
      publicUrl: 'URL PÚBLICA',
      copyUrl: 'Copiar URL',
      passphraseTitle: 'FRASE DE PASO E2EE',
      passphraseHint:
          'Comparte esta frase de paso con los participantes en un canal DISTINTO al del enlace (por voz, Signal, en persona). Sin ella, los mensajes son ilegibles.',
      copyPassphrase: 'Copiar frase',
      session: 'SESIÓN',
      sessionId: 'ID',
      creator: 'Creador',
      invites: 'INVITACIONES (enlace + código)',
      copyCode: 'Copiar código',
      copyLink: 'Copiar enlace',
      openInBrowser: 'Abrir en el navegador',
      log: 'REGISTRO',
      brandTag: 'by AI-Tech-DB',
      langItalian: 'Italiano',
      langEnglish: 'English',
      langSpanish: 'Español',
    ),
  };

  /// Ritorna le stringhe per la lingua data, con fallback all'inglese.
  static GhostStrings of(String langCode) {
    final key = langCode.toLowerCase().split('-').first;
    return _all[key] ?? _all['en']!;
  }

  /// Codici lingua supportati.
  static const List<String> supported = ['it', 'en', 'es'];
}
