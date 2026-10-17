# Changelog

All notable changes to GhostChat will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-16

### Added

- **End-to-end encryption** (AES-GCM 256) between chat participants
- **Key derivation** via PBKDF2-SHA256 (250k iterations) from shared passphrase
- **Forward secrecy** per message via HKDF-SHA256 with per-message counter
- **Message signatures** with ECDSA P-256 (prevents spoofing)
- **Message padding** to 256-byte blocks (hides length)
- **Replay protection** via monotonic per-sender counter
- **Handshake protocol** (`__hello__` / `hello_ok`) to confirm passphrase
- **Embedded Cloudflare Quick Tunnel** in Rust (no cloudflared subprocess)
- **DoH resolver** via hickory-resolver (bypasses OEM DNS filtering)
- **HTTP/WebSocket server** in Dart (shelf + shelf_web_socket)
- **Web client** with vanilla JS + WebCrypto API
- **Multi-language UI**: Italiano, English, Español
- **Anonymous nicknames** generated client-side (`Ghost-XXXX`)
- **Session invites** with `GHST-XXXX-XXXX` codes
- **Reconnect** with token and 2-minute grace period
- **Foreground Service** (Android) to keep the tunnel alive
- **FLAG_SECURE** on Android (blocks screenshots)
- **Ghost emoji reactions** (10 custom emojis)
- **HTTP security headers** (CSP, X-Frame-Options, Referrer-Policy, etc.)
- **Blind relay server** (no persistence, no decryption)

### Security

- Server never sees plaintext messages
- Server never stores messages
- Server never logs message content, passphrase, or nicknames
- All cryptographic operations happen client-side
- Zero metadata persistence beyond the session lifetime

### Known limitations

- Metadata (IP, timestamp, URL) visible to Cloudflare
- No full forward secrecy (no DH ratchet, not Signal protocol)
- Compromised client browser can read messages
- 48-bit passphrase entropy (6 words × 8 bits)
- No rate limiting on join
- No file attachments
- No push notifications

### Technical details

- **Flutter**: 3.27+
- **Rust**: 1.86+
- **Android NDK**: 27.0.12077973
- **minSdkVersion**: Flutter default (Android 5.0+)
- **targetSdkVersion**: 33 (Android 13)
- **compileSdkVersion**: 35 (Android 15)
- **Package**: `com.aitechdb.ghostchat`
