/* ═══════════════════════════════════════════════════════════════════════
   GHOSTCHAT — Client web con E2EE e forward secrecy

   v5:
   - Fix 1: validazione formato passphrase (6 parole minuscole)
   - Fix 2: handshake __hello__ / hello_ok per confermare la passphrase
   ═══════════════════════════════════════════════════════════════════════ */

(() => {
  'use strict';

  const PBKDF2_ITERATIONS = 250000;

  // ---- i18n --------------------------------------------------------

  const STRINGS = window.GHOSTCHAT_STRINGS || {};
  const LANG = (() => {
    const metaLang = document.querySelector('meta[name="ghostchat-lang"]');
    const fromServer = metaLang ? metaLang.content : null;
    const fromBrowser = (navigator.language || 'en').toLowerCase().split('-')[0];
    const candidate = fromServer || fromBrowser;
    return STRINGS[candidate] ? candidate : 'en';
  })();

  const t = (key) => {
    const s = STRINGS[LANG];
    if (s && s[key] !== undefined) return s[key];
    const fb = STRINGS.en;
    if (fb && fb[key] !== undefined) return fb[key];
    return key;
  };

  const applyTranslations = () => {
    document.querySelectorAll('[data-i18n]').forEach((el) => {
      const k = el.getAttribute('data-i18n');
      if (k) el.textContent = t(k);
    });
    document.querySelectorAll('[data-i18n-placeholder]').forEach((el) => {
      const k = el.getAttribute('data-i18n-placeholder');
      if (k) el.setAttribute('placeholder', t(k));
    });
    document.querySelectorAll('[data-i18n-title]').forEach((el) => {
      const k = el.getAttribute('data-i18n-title');
      if (k) el.setAttribute('title', t(k));
    });
    document.documentElement.lang = LANG;
    document.body.classList.add('i18n-ready');
  };

  // ---- fine i18n ---------------------------------------------------

  const AES_KEY_BITS = 256;
  const IV_BYTES = 12;
  const PAD_BLOCK = 256;
  const HKDF_INFO_PREFIX = 'ghostchat-msg-v1:';
  const PBKDF2_SALT_PREFIX = 'ghostchat-e2ee-v1|';
  const HELLO_MARKER = '__hello__';

  const GHOST_EMOJIS = [
    { glyph: '👻❤️', label: 'cuoricino' },
    { glyph: '👻🔥', label: 'fuoco' },
    { glyph: '👻💀', label: 'teschio' },
    { glyph: '👻🎉', label: 'festa' },
    { glyph: '👻😴', label: 'dorme' },
    { glyph: '👻🤔', label: 'pensieroso' },
    { glyph: '👻😡', label: 'arrabbiato' },
    { glyph: '👻😢', label: 'lacrima' },
    { glyph: '👻💰', label: 'dollari' },
    { glyph: '👻✨', label: 'scintille' },
  ];

  const state = {
    ws: null,
    connected: false,
    myNickname: null,
    sessionId: null,
    participants: [],
    typingTimer: null,
    typingUsers: new Set(),
    reconnectAttempts: 0,
    reconnectTimer: null,
    pingTimer: null,
    reconnectToken: null,
    lastJoinToken: null,
    lastPassphrase: null,

    rootKey: null,
    mySignKey: null,
    myVerifyKey: null,
    peerKeys: new Map(),
    pendingMessages: new Map(),
    sendCounters: new Map(),
    lastSeen: new Map(),

    pubkeySent: false,
    helloConfirmed: false,
    helloSent: false,
    helloWarningTimer: null,
    helloBannerTimer: null,
  };

  const RECONNECT_STORAGE_KEY = 'ghostchat_reconnect_token';

  // ── Base64url ──────────────────────────────────────────────────────────

  const b64uEncode = (buf) => {
    const bytes = new Uint8Array(buf);
    let s = '';
    for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };

  const b64uDecode = (str) => {
    const pad = str.length % 4 === 0 ? '' : '='.repeat(4 - (str.length % 4));
    const s = str.replace(/-/g, '+').replace(/_/g, '/') + pad;
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  };

  const utf8 = (s) => new TextEncoder().encode(s);
  const fromUtf8 = (b) => new TextDecoder().decode(b);

  const pad = (data) => {
    const len = data.length;
    const padded = Math.ceil((len + 2) / PAD_BLOCK) * PAD_BLOCK;
    const out = new Uint8Array(padded);
    out[0] = (len >> 8) & 0xff;
    out[1] = len & 0xff;
    out.set(data, 2);
    return out;
  };

  const unpad = (data) => {
    if (data.length < 2) throw new Error('padding too short');
    const len = (data[0] << 8) | data[1];
    if (len > data.length - 2) throw new Error('padding invalid');
    return data.slice(2, 2 + len);
  };

  // ── Fix 1: validazione passphrase ─────────────────────────────────────

  const isValidPassphrase = (p) => {
    if (typeof p !== 'string') return false;
    const trimmed = p.trim();
    if (trimmed.length < 10 || trimmed.length > 200) return false;
    const parts = trimmed.split('-');
    if (parts.length !== 6) return false;
    return parts.every(w => /^[a-z]{2,}$/.test(w));
  };

  // ── Crypto ─────────────────────────────────────────────────────────────

  const deriveRootKey = async (passphrase, sessionId) => {
    const saltInput = utf8(PBKDF2_SALT_PREFIX + sessionId);
    const saltHash = await crypto.subtle.digest('SHA-256', saltInput);
    const baseKey = await crypto.subtle.importKey(
      'raw', utf8(passphrase), { name: 'PBKDF2' }, false, ['deriveBits']
    );
    const bits = await crypto.subtle.deriveBits(
      { name: 'PBKDF2', salt: saltHash, iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
      baseKey, AES_KEY_BITS
    );
    return crypto.subtle.importKey(
      'raw', bits, { name: 'HKDF' }, false, ['deriveKey']
    );
  };

  const deriveMsgKey = async (from, counter) => {
    const info = utf8(HKDF_INFO_PREFIX + from + ':' + counter);
    return crypto.subtle.deriveKey(
      { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info },
      state.rootKey,
      { name: 'AES-GCM', length: AES_KEY_BITS },
      false,
      ['encrypt', 'decrypt']
    );
  };

  const generateSignKeys = async () => {
    const pair = await crypto.subtle.generateKey(
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['sign', 'verify']
    );
    state.mySignKey = pair.privateKey;
    state.myVerifyKey = pair.publicKey;
    return pair;
  };

  const exportPubKeyRaw = async (key) => {
    const raw = await crypto.subtle.exportKey('raw', key);
    return b64uEncode(raw);
  };

  const importPubKeyRaw = async (b64) => {
    const raw = b64uDecode(b64);
    return crypto.subtle.importKey(
      'raw', raw,
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['verify']
    );
  };

  const signMessage = async (from, counter, ivB64, ctB64) => {
    const data = utf8(from + '|' + counter + '|' + ivB64 + '|' + ctB64);
    const sig = await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      state.mySignKey,
      data
    );
    return b64uEncode(sig);
  };

  const verifyMessage = async (pubKey, from, counter, ivB64, ctB64, sigB64) => {
    const data = utf8(from + '|' + counter + '|' + ivB64 + '|' + ctB64);
    const sig = b64uDecode(sigB64);
    try {
      return await crypto.subtle.verify(
        { name: 'ECDSA', hash: 'SHA-256' },
        pubKey,
        sig,
        data
      );
    } catch (_) {
      return false;
    }
  };

  const encryptMessage = async (from, counter, plaintext) => {
    const key = await deriveMsgKey(from, counter);
    const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
    const padded = pad(utf8(plaintext));
    const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, padded);
    return { iv: b64uEncode(iv), ct: b64uEncode(ct) };
  };

  const decryptMessage = async (from, counter, ivB64, ctB64) => {
    const key = await deriveMsgKey(from, counter);
    const iv = b64uDecode(ivB64);
    const ct = b64uDecode(ctB64);
    const padded = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, ct);
    return fromUtf8(unpad(new Uint8Array(padded)));
  };

  // ── DOM ────────────────────────────────────────────────────────────────

  const $ = (id) => document.getElementById(id);
  const screenJoin = $('screen-join');
  const screenChat = $('screen-chat');
  const screenEnded = $('screen-ended');
  const inputToken = $('input-token');
  const inputPassphrase = $('input-passphrase');
  const btnTogglePass = $('btn-toggle-pass');
  const btnJoin = $('btn-join');
  const joinError = $('join-error');
  const messagesEl = $('messages');
  const inputMessage = $('input-message');
  const btnSend = $('btn-send');
  const btnLeave = $('btn-leave');
  const connStatus = $('conn-status');
  const participantsCount = $('participants-count');
  const participantsStrip = $('participants-strip');
  const typingIndicator = $('typing-indicator');
  const typingLabel = $('typing-label');
  const endedReason = $('ended-reason');
  const btnStickers = $('btn-stickers');
  const stickerPanel = $('sticker-panel');
  const btnStickersClose = $('btn-stickers-close');
  const stickerGrid = $('sticker-grid');

  const show = (screen) => {
    document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
    screen.classList.add('active');
  };

  const setConnected = (ok) => {
    connStatus.classList.toggle('connected', ok);
    connStatus.classList.toggle('disconnected', !ok);
  };

  const setComposerEnabled = (enabled) => {
    inputMessage.disabled = !enabled;
    btnSend.disabled = !enabled;
  };

  const tsFormat = (ts) => {
    const d = new Date(ts);
    return d.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' });
  };

  const escapeHtml = (s) => String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');

  const addMessage = ({ from, text, ts, self }) => {
    const div = document.createElement('div');
    div.className = 'msg ' + (self ? 'msg-self' : 'msg-other');
    let html = '';
    if (!self && from) html += `<div class="msg-author">${escapeHtml(from)}</div>`;
    const isEmojiOnly = /^[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}\s]+$/u.test(text) && text.trim().length <= 8;
    const textClass = isEmojiOnly ? 'msg-emoji-big' : '';
    html += `<div class="${textClass}">${escapeHtml(text)}</div>`;
    if (ts) {
      html += `<div style="font-size:9px;opacity:0.5;margin-top:4px;text-align:right">${tsFormat(ts)}</div>`;
    }
    div.innerHTML = html;
    messagesEl.appendChild(div);
    messagesEl.scrollTop = messagesEl.scrollHeight;
  };

  const addSystem = (text) => {
    const div = document.createElement('div');
    div.className = 'msg-system';
    div.textContent = text;
    messagesEl.appendChild(div);
    messagesEl.scrollTop = messagesEl.scrollHeight;
  };

  // ── Fix 2: banner handshake ───────────────────────────────────────────

  const removeExistingBanner = () => {
    const old = document.getElementById('passphrase-banner');
    if (old) old.remove();
  };

  const showBanner = (text, kind) => {
    removeExistingBanner();
    const div = document.createElement('div');
    div.id = 'passphrase-banner';
    div.className = `passphrase-banner passphrase-banner-${kind}`;
    div.textContent = text;
    const composer = document.querySelector('.composer');
    if (composer && composer.parentNode) {
      composer.parentNode.insertBefore(div, composer);
    }
    return div;
  };

  const showBannerTemp = (text, kind, ms) => {
    const el = showBanner(text, kind);
    if (state.helloBannerTimer) clearTimeout(state.helloBannerTimer);
    state.helloBannerTimer = setTimeout(() => {
      if (el.parentNode) el.remove();
    }, ms);
  };

  const handleHelloOk = () => {
    if (state.helloConfirmed) return;
    state.helloConfirmed = true;
    if (state.helloWarningTimer) {
      clearTimeout(state.helloWarningTimer);
      state.helloWarningTimer = null;
    }
    showBannerTemp(t('helloConfirmed'), 'ok', 3500);
  };

  // ── Participants ──────────────────────────────────────────────────────

  const renderParticipants = () => {
    participantsStrip.innerHTML = '';
    const n = state.participants.length;
    const label = n === 1 ? t('participant') : t('participants');
    participantsCount.textContent = `${n} ${label}`;
    for (const p of state.participants) {
      const chip = document.createElement('span');
      chip.className = 'participant-chip';
      if (p.isCreator) chip.classList.add('creator');
      if (p.nickname === state.myNickname) chip.classList.add('self');
      chip.textContent = p.nickname + (p.isCreator ? ' ★' : '');
      participantsStrip.appendChild(chip);
    }
  };

  const showTyping = (nickname, active) => {
    if (active) state.typingUsers.add(nickname);
    else state.typingUsers.delete(nickname);
    if (state.typingUsers.size === 0) {
      typingIndicator.classList.add('hidden');
    } else {
      typingIndicator.classList.remove('hidden');
      const names = Array.from(state.typingUsers).join(', ');
      typingLabel.textContent = `${names} sta${state.typingUsers.size > 1 ? 'nno' : ''} scrivendo…`;
    }
  };

  // ── Sticker / Emoji ───────────────────────────────────────────────────

  const renderStickerPanel = () => {
    if (!stickerGrid) return;
    stickerGrid.innerHTML = '';
    for (const e of GHOST_EMOJIS) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'sticker-item';
      btn.title = `Ghost ${e.label}`;

      const glyph = document.createElement('span');
      glyph.className = 'sticker-glyph';
      glyph.textContent = e.glyph;

      const label = document.createElement('span');
      label.className = 'sticker-label';
      label.textContent = e.label;

      btn.appendChild(glyph);
      btn.appendChild(label);
      btn.addEventListener('click', () => handleEmojiClick(e.glyph));
      stickerGrid.appendChild(btn);
    }
  };

  const handleEmojiClick = async (glyph) => {
    if (!state.rootKey || !state.mySignKey) return;
    stickerPanel.classList.add('hidden');
    await sendEncrypted(glyph);
  };

  // ── Ping ───────────────────────────────────────────────────────────────

  const PING_INTERVAL_MS = 20000;

  const startPing = () => {
    stopPing();
    state.pingTimer = setInterval(() => send({ type: 'ping' }), PING_INTERVAL_MS);
  };

  const stopPing = () => {
    if (state.pingTimer) { clearInterval(state.pingTimer); state.pingTimer = null; }
  };

  // ── WebSocket ──────────────────────────────────────────────────────────

  const buildWsUrl = (joinToken) => {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const rt = state.reconnectToken;
    const wireToken = rt ? `reconnect:${rt}` : joinToken;
    return `${proto}://${location.host}/ws?token=${encodeURIComponent(wireToken)}`;
  };

  const connect = (joinToken) => {
    state.lastJoinToken = joinToken;
    const url = buildWsUrl(joinToken);
    state.ws = new WebSocket(url);

    state.ws.onopen = () => {
      state.connected = true;
      state.reconnectAttempts = 0;
      setConnected(true);
      startPing();
    };

    state.ws.onmessage = (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      handleMessage(msg);
    };

    state.ws.onclose = () => {
      state.connected = false;
      setConnected(false);
      stopPing();
      if (!screenChat.classList.contains('active')) return;

      state.reconnectAttempts++;
      if (state.reconnectAttempts > 8) {
        addSystem(t('connFailed'));
        return;
      }
      const base = Math.min(1000 * Math.pow(1.7, state.reconnectAttempts - 1), 30000);
      const jitter = Math.floor(Math.random() * 800) - 400;
      const delay = Math.max(500, base + jitter);
      const secs = Math.round(delay / 1000);
      addSystem(`${t('connLost')} ${secs}${t('connLostSuffix')}`);
      state.reconnectTimer = setTimeout(() => connect(state.lastJoinToken), delay);
    };

    state.ws.onerror = () => setConnected(false);
  };

  // ── Pubkey ─────────────────────────────────────────────────────────────

  const publishPubKey = async () => {
    const pub = await exportPubKeyRaw(state.myVerifyKey);
    send({ type: 'pubkey', pubkey: pub });
    state.pubkeySent = true;
  };

  const requestPeerPubKeys = () => {
    send({ type: 'pubkey_request' });
  };

  // ── Handshake ─────────────────────────────────────────────────────────

  const sendHello = async () => {
    if (state.helloSent) return;
    state.helloSent = true;
    await sendEncrypted(HELLO_MARKER, { silent: true });
    if (state.helloWarningTimer) clearTimeout(state.helloWarningTimer);
    state.helloWarningTimer = setTimeout(() => {
      if (!state.helloConfirmed) {
        showBanner(
          t('helloWarning') +
          'Se sei da solo nella stanza, ignora questo avviso. ' +
          'Altrimenti, ricontrolla di aver copiato la passphrase corretta.',
          'warn'
        );
      }
    }, 6000);
  };

  // ── handleMessage ──────────────────────────────────────────────────────

  const handleMessage = async (msg) => {
    switch (msg.type) {
      case 'welcome': {
        state.myNickname = msg.nickname;
        state.sessionId = msg.sessionId;
        state.participants = msg.participants || [];
        if (msg.reconnectToken) {
          state.reconnectToken = msg.reconnectToken;
          try { sessionStorage.setItem(RECONNECT_STORAGE_KEY, msg.reconnectToken); } catch (_) {}
        }
        renderParticipants();
        show(screenChat);
        addSystem(`${t('joinedAs')} ${state.myNickname}`);

        if (!state.rootKey) {
          try {
            state.rootKey = await deriveRootKey(
              state.lastPassphrase, state.sessionId
            );
          } catch (e) {
            addSystem('Errore derivazione chiave: ' + e.message);
            return;
          }
        }

        if (!state.mySignKey) {
          await generateSignKeys();
        }

        await publishPubKey();
        requestPeerPubKeys();

        // Handshake: invia __hello__ cifrato con la mia chiave
        await sendHello();

        setComposerEnabled(true);
        break;
      }

      case 'hello_ok': {
        if (msg.to && msg.to !== state.myNickname) return;
        handleHelloOk();
        break;
      }

      case 'pubkey_request': {
        if (msg.from === state.myNickname) return;
        if (state.myVerifyKey) {
          await publishPubKey();
        }
        break;
      }

      case 'pubkey': {
        const { from, pubkey } = msg;
        if (!from || !pubkey) return;
        if (from === state.myNickname) return;
        try {
          const key = await importPubKeyRaw(pubkey);
          state.peerKeys.set(from, key);
        } catch (e) {
          console.warn('pubkey import failed', from, e);
          return;
        }
        const pending = state.pendingMessages.get(from);
        if (pending && pending.length) {
          state.pendingMessages.delete(from);
          for (const p of pending) {
            await processIncomingMessage(p);
          }
        }
        break;
      }

      case 'message': {
        await processIncomingMessage(msg);
        break;
      }

      case 'participant_joined':
        if (!state.participants.some(p => p.nickname === msg.nickname)) {
          state.participants.push({ nickname: msg.nickname, isCreator: false });
          renderParticipants();
          addSystem(`${msg.nickname} ${t('userJoined')}`);
        }
        break;

      case 'participant_left':
        state.participants = state.participants.filter(p => p.nickname !== msg.nickname);
        renderParticipants();
        addSystem(`${msg.nickname} ${t('userLeft')}`);
        break;

      case 'typing':
        showTyping(msg.from, msg.active);
        break;

      case 'session_ended':
        state.connected = false;
        setConnected(false);
        clearTimeout(state.reconnectTimer);
        stopPing();
        setComposerEnabled(false);
        endedReason.textContent = msg.reason === 'creator_ended'
          ? t('endedReason')
          : t('endedReasonGeneric');
        show(screenEnded);
        break;

      case 'error':
        console.warn('Server error:', msg);
        if (msg.code === 'reconnect_invalid' || msg.code === 'reconnect_expired') {
          state.reconnectToken = null;
          try { sessionStorage.removeItem(RECONNECT_STORAGE_KEY); } catch (_) {}
        }
        if (['invalid_token','invalid_invite','invite_already_used','invite_expired','session_full'].includes(msg.code)) {
          const textMap = {
            invalid_token: t('invalidToken'),
            invalid_invite: t('invalidInvite'),
            invite_already_used: t('inviteUsed'),
            invite_expired: t('inviteExpired'),
            session_full: t('sessionFull'),
          };
          joinError.textContent = textMap[msg.code] || t('genericError');
          joinError.classList.remove('hidden');
          btnJoin.disabled = false;
          setComposerEnabled(false);
        }
        break;

      case 'pong':
        break;
    }
  };

  // ── Processo messaggi ──────────────────────────────────────────────────

  const processIncomingMessage = async (msg) => {
    const { from, counter, iv, ct, sig, ts } = msg;
    if (!from || counter == null || !iv || !ct || !sig) return;
    if (from === state.myNickname) return;

    const last = state.lastSeen.get(from) ?? -1;
    if (counter <= last) return;

    const pub = state.peerKeys.get(from);
    if (!pub) {
      const buf = state.pendingMessages.get(from) || [];
      buf.push(msg);
      state.pendingMessages.set(from, buf);
      send({ type: 'pubkey_request' });
      setTimeout(() => {
        const still = state.pendingMessages.get(from);
        if (still && still.includes(msg)) {
          state.pendingMessages.set(from, still.filter(m => m !== msg));
          addSystem(`[messaggio da ${from} non verificabile]`);
        }
      }, 8000);
      return;
    }

    const ok = await verifyMessage(pub, from, counter, iv, ct, sig);
    if (!ok) {
      addSystem(`[firma non valida da ${from}]`);
      return;
    }

    let text;
    try {
      text = await decryptMessage(from, counter, iv, ct);
    } catch (e) {
      console.error('decrypt failed', e, msg);
      addSystem(`[decifratura fallita da ${from}]`);
      return;
    }

    state.lastSeen.set(from, counter);

    // Handshake marker?
    if (text === HELLO_MARKER) {
      send({ type: 'hello_ok', to: from });
      return;
    }

    // Imposta conferma se non ancora confermato
    if (!state.helloConfirmed) {
      state.helloConfirmed = true;
      if (state.helloWarningTimer) {
        clearTimeout(state.helloWarningTimer);
        state.helloWarningTimer = null;
      }
      removeExistingBanner();
    }

    addMessage({
      from,
      text,
      ts: ts || Date.now(),
      self: false,
    });
    showTyping(from, false);
  };

  // ── Invio ──────────────────────────────────────────────────────────────

  const sendEncrypted = async (plaintext, opts = {}) => {
    if (!state.rootKey || !state.mySignKey) return;
    const from = state.myNickname;
    const counter = state.sendCounters.get(from) ?? 0;

    let enc;
    try {
      enc = await encryptMessage(from, counter, plaintext);
    } catch (e) {
      if (!opts.silent) addSystem('Errore cifratura: ' + e.message);
      return;
    }

    let sig;
    try {
      sig = await signMessage(from, counter, enc.iv, enc.ct);
    } catch (e) {
      if (!opts.silent) addSystem('Errore firma: ' + e.message);
      return;
    }

    send({
      type: 'message',
      counter,
      iv: enc.iv,
      ct: enc.ct,
      sig,
    });

    state.sendCounters.set(from, counter + 1);

    if (!opts.silent) {
      addMessage({ from, text: plaintext, ts: Date.now(), self: true });
    }
  };

  const send = (obj) => {
    if (state.ws && state.ws.readyState === WebSocket.OPEN) {
      state.ws.send(JSON.stringify(obj));
    }
  };

  // ── UI wiring ──────────────────────────────────────────────────────────

  const urlParams = new URLSearchParams(location.search);
  const urlToken = urlParams.get('code') || urlParams.get('token');
  if (urlToken) inputToken.value = urlToken;

  try {
    const saved = sessionStorage.getItem(RECONNECT_STORAGE_KEY);
    if (saved) state.reconnectToken = saved;
  } catch (_) {}

  btnTogglePass.addEventListener('click', () => {
    const isPass = inputPassphrase.type === 'password';
    inputPassphrase.type = isPass ? 'text' : 'password';
    btnTogglePass.textContent = isPass ? '🙈' : '👁';
  });

  btnJoin.addEventListener('click', () => {
    const token = inputToken.value.trim();
    const pass = inputPassphrase.value.trim();

    if (!token) {
      joinError.textContent = t('codeRequired');
      joinError.classList.remove('hidden');
      return;
    }

    if (!pass) {
      joinError.textContent = t('passRequired');
      joinError.classList.remove('hidden');
      return;
    }

    // Fix 1: validazione formato passphrase
    if (!isValidPassphrase(pass)) {
      joinError.innerHTML =
        'La passphrase deve essere <strong>6 parole minuscole</strong> separate da trattino.<br>' +
        'Esempio: <code>cavallo-batteria-luna-sole-mare-topo</code><br>' +
        'Non è il codice invito. È la stringa che ti è stata comunicata separatamente.';
      joinError.classList.remove('hidden');
      return;
    }

    joinError.classList.add('hidden');
    btnJoin.disabled = true;
    state.lastPassphrase = pass;
    connect(token);
  });

  inputPassphrase.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') btnJoin.click();
  });
  inputToken.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') inputPassphrase.focus();
  });

  const doSend = async () => {
    const text = inputMessage.value.trim();
    if (!text) return;
    inputMessage.value = '';
    send({ type: 'typing', active: false });
    await sendEncrypted(text);
  };

  btnSend.addEventListener('click', doSend);
  inputMessage.addEventListener('keypress', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      doSend();
    }
  });

  let typingSent = false;
  inputMessage.addEventListener('input', () => {
    if (!typingSent) {
      send({ type: 'typing', active: true });
      typingSent = true;
    }
    clearTimeout(state.typingTimer);
    state.typingTimer = setTimeout(() => {
      send({ type: 'typing', active: false });
      typingSent = false;
    }, 1500);
  });

  btnLeave.addEventListener('click', () => {
    stopPing();
    clearTimeout(state.reconnectTimer);
    state.reconnectToken = null;
    try { sessionStorage.removeItem(RECONNECT_STORAGE_KEY); } catch (_) {}
    if (state.ws) state.ws.close();
    state.rootKey = null;
    state.mySignKey = null;
    state.myVerifyKey = null;
    state.peerKeys.clear();
    state.pendingMessages.clear();
    state.sendCounters.clear();
    state.lastSeen.clear();
    state.pubkeySent = false;
    state.helloSent = false;
    state.helloConfirmed = false;
    if (state.helloWarningTimer) clearTimeout(state.helloWarningTimer);
    if (state.helloBannerTimer) clearTimeout(state.helloBannerTimer);
    removeExistingBanner();
    state.participants = [];
    state.myNickname = null;
    messagesEl.innerHTML = '';
    setComposerEnabled(false);
    show(screenJoin);
  });

  btnStickers.addEventListener('click', () => stickerPanel.classList.toggle('hidden'));
  btnStickersClose.addEventListener('click', () => stickerPanel.classList.add('hidden'));

  renderStickerPanel();
  applyTranslations();

})();
