import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Genera token crittograficamente sicuri per inviti e sessioni.
///
/// Usa [Random.secure] di Dart che su Android si appoggia al CSPRNG del
/// sistema.
class SecureToken {
  static final Random _rng = Random.secure();

  /// Token URL-safe da [bytes] byte di entropia (base64url senza padding).
  static String random([int bytes = 32]) {
    final buf = Uint8List(bytes);
    for (var i = 0; i < bytes; i++) {
      buf[i] = _rng.nextInt(256);
    }
    return base64UrlEncode(buf).replaceAll('=', '');
  }

  /// Codice breve leggibile, tipo `GHST-4F2A-9C71`.
  static String shortCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final parts = <String>[];
    for (var p = 0; p < 2; p++) {
      final b = StringBuffer();
      for (var i = 0; i < 4; i++) {
        b.write(alphabet[_rng.nextInt(alphabet.length)]);
      }
      parts.add(b.toString());
    }
    return 'GHST-${parts.join('-')}';
  }

  /// Nickname temporaneo, tipo `Ghost-7F2A`.
  static String ghostNickname() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final b = StringBuffer('Ghost-');
    for (var i = 0; i < 4; i++) {
      b.write(alphabet[_rng.nextInt(alphabet.length)]);
    }
    return b.toString();
  }

  /// Passphrase di 6 parole italiane.
  ///
  /// Entropia: 6 * log2(256) = 48 bit. Con PBKDF2 250k iterazioni,
  /// resiste a bruteforce offline ragionevole.
  static String passphrase6Words() {
    final buf = StringBuffer();
    for (var i = 0; i < 6; i++) {
      if (i > 0) buf.write('-');
      buf.write(_words[_rng.nextInt(_words.length)]);
    }
    return buf.toString();
  }

  /// Lista di 256 parole italiane comuni, senza accenti, senza
  /// omofoni, facili da dettare a voce.
  static const List<String> _words = [
    'albero', 'ancora', 'anello', 'arco', 'argento', 'aria', 'armonia',
    'arte', 'asino', 'atlante', 'attico', 'aurora', 'avena', 'azzurro',
    'balcone', 'bambino', 'banana', 'barca', 'basilico', 'bastone',
    'battello', 'bellezza', 'bicicletta', 'bosco', 'bottiglia', 'braccio',
    'brezza', 'bronzo', 'bufera', 'cactus', 'calamaio', 'calcio',
    'calendario', 'cammello', 'campana', 'canale', 'candela', 'cane',
    'cannone', 'canoa', 'cantina', 'capra', 'carbone', 'cardellino',
    'carta', 'casa', 'cascata', 'castello', 'catena', 'cavallo',
    'caverna', 'cedro', 'cena', 'cervo', 'chiave', 'chiodo', 'cielo',
    'ciliegia', 'cinema', 'cintura', 'cioccolato', 'cipolla', 'citta',
    'clessidra', 'colore', 'colomba', 'coltello', 'cometa', 'conchiglia',
    'coniglio', 'corda', 'corona', 'corvo', 'cristallo', 'cucchiaio',
    'cuore', 'delfino', 'deserto', 'diamante', 'diga', 'dito', 'dolce',
    'drago', 'edera', 'elefante', 'erba', 'estate', 'fabbrica', 'faggio',
    'falco', 'faro', 'fata', 'felce', 'fenice', 'ferro', 'festa',
    'fiamma', 'fiasco', 'fieno', 'figura', 'fiume', 'foglia', 'fontana',
    'foresta', 'formica', 'forno', 'fortezza', 'fragola', 'freccia',
    'freddo', 'fulmine', 'fumo', 'fuoco', 'gabbiano', 'galassia',
    'gallina', 'gatto', 'gemma', 'ghiaccio', 'ghiro', 'giardino',
    'giglio', 'giornale', 'girasole', 'giungla', 'gnomo', 'gomito',
    'gonna', 'granchio', 'granello', 'grappolo', 'grembo', 'grotta',
    'guanto', 'guscio', 'idea', 'inchiostro', 'inverno', 'isola',
    'lago', 'lampada', 'lampo', 'lanterna', 'lattice', 'lava', 'lente',
    'leone', 'lepre', 'lettera', 'libro', 'limone', 'lingua', 'luna',
    'lupo', 'lucciola', 'macchina', 'maglione', 'mago', 'mais', 'mandorla',
    'mango', 'mano', 'mare', 'marmo', 'matita', 'mattone', 'melone',
    'mente', 'mercato', 'miele', 'mirtillo', 'monte', 'mosaico',
    'muro', 'musica', 'nebbia', 'neve', 'nido', 'noce', 'nodo', 'nuvola',
    'oceano', 'ombra', 'onda', 'orologio', 'orso', 'ortensia', 'osso',
    'ostrica', 'pagina', 'palazzo', 'panca', 'pane', 'pantofola',
    'paprika', 'parco', 'parete', 'pattino', 'pavone', 'pepe', 'pera',
    'pesca', 'pesce', 'pettine', 'piano', 'pietra', 'pigna', 'pinguino',
    'pinna', 'pioggia', 'pipa', 'piuma', 'platano', 'polvere', 'pomodoro',
    'ponte', 'porta', 'prato', 'prugna', 'pulce', 'quaderno', 'quercia',
    'raggio', 'ramo', 'rana', 'razzo', 'regina', 'remo', 'riccio',
    'riva', 'roccia', 'rosa', 'rospo', 'ruota', 'sabbia', 'sacco',
    'sale', 'salice', 'sasso', 'scala', 'scarpa', 'scatola', 'scoglio',
    'scudo', 'sedano', 'sella', 'serpente', 'sfera', 'sipario', 'sole',
    'sorbo', 'specchio', 'spiga', 'spiaggia', 'stella', 'stivale',
    'stoffa', 'suono', 'tabacco', 'tamburo', 'tappeto', 'tavolo',
    'teatro', 'tetto', 'tigre', 'timone', 'topo', 'torre', 'tramonto',
    'treno', 'tromba', 'trottola', 'tulipano', 'uva', 'vagone', 'valle',
    'vela', 'veleno', 'veliero', 'vento', 'vetro', 'viaggio', 'villaggio',
    'viola', 'volpe', 'vulcano', 'zaffiro', 'zaino', 'zanzara', 'zattera',
    'zebra', 'zenzero', 'zoccolo', 'zucca', 'zuppa'
  ];
}
