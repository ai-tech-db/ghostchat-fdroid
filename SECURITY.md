# GhostChat — Sicurezza e Privacy

Documento di sicurezza di GhostChat. Descrive le protezioni
crittografiche, le proprietà di privacy, e le best practice per l'uso
ottimale.

---

## 1. Sintesi

GhostChat è una chat anonima, end-to-end encrypted, effimera. È
progettata per conversazioni brevi, private e riservate tra poche
persone che si conoscono.

Perché è sicura:

- End-to-End Encryption con AES-GCM 256 bit
- Forward secrecy per ogni messaggio (chiavi dedicate)
- Firma crittografica di ogni messaggio (ECDSA P-256)
- Server cieco: non vede il contenuto, non vede la passphrase
- Zero persistenza: nessun messaggio salvato
- Nickname anonimi generati lato client
- Padding dei messaggi: la lunghezza non è deducibile
- Replay protection: i messaggi non possono essere riprodotti
- Header di sicurezza HTTP (CSP, X-Frame-Options, no-referrer)
- Blocco screenshot su Android (FLAG_SECURE)
- Sessione effimera: vive pochi minuti, poi svanisce

Raccomandazione: usa GhostChat con una VPN attiva sul dispositivo.
La VPN non è obbligatoria (la crittografia E2EE è già robusta), ma
aggiunge uno strato di protezione sui metadati di rete.

---

## 2. Modello di minaccia

GhostChat è progettata per conversazioni brevi e private. Non è
progettata per resistere a sorveglianza di massa a lungo termine o
attacchi mirati da parte di attori statali.

GhostChat protegge da:

- Intercettazione passiva del traffico (E2EE)
- Server compromesso (non può decifrare)
- Cloudflare (non vede il contenuto)
- Carrier / ISP (non vede il contenuto)
- MITM passivo (TLS + E2EE)
- MITM attivo (firma ECDSA + AES-GCM autenticata)
- Spoofing del mittente (firma crittografica)
- Manomissione dei messaggi (AES-GCM autentica)
- Replay di messaggi (counter monotono)
- Bruteforce del codice invito (32^8 combinazioni)
- Bruteforce offline della passphrase (PBKDF2 250k iterazioni)

GhostChat non protegge da:

- Compromissione del browser del client (malware, estensioni malevole)
- Chi conosce la passphrase (chat di gruppo, non E2EE per-coppia)
- Attacco mirato con risorse illimitate
- Condivisione della passphrase sullo stesso canale del link
