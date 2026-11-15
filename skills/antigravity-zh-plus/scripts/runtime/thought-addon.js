/* === AGY_THOUGHT_TRANSLATOR_ADDON_START === */
(() => {
  'use strict';
  if (typeof window === 'undefined' || window !== window.top) return;

  const nativeFetch = typeof window.fetch === 'function' ? window.fetch.bind(window) : null;
  if (!nativeFetch) return;

  const loc = window.location;
  if (!loc) return;
  const proto = String(loc.protocol || '').toLowerCase();
  const host = String(loc.hostname || '').toLowerCase();
  const path = String(loc.pathname || '');
  const isAllowedAppOrigin =
    ((proto === 'https:' || proto === 'http:') && (host === '127.0.0.1' || host === 'localhost')) ||
    proto === 'vscode-file:' ||
    (proto === 'file:' && /workbench\.html$/i.test(path));
  if (!isAllowedAppOrigin) return;

  const CONFIG = Object.assign({
    enabled: true,
    provider: 'auto',
    bridgePort: 47831,
    bridgeToken: '',
    hasLlmKey: false,
    llmModel: 'glm-4-flash',
    geminiApiKey: '',
    geminiModel: 'gemini-3.5-flash-lite',
    _buildId: 'dev'
  }, /*__AGY_THOUGHT_CONFIG_JSON__*/ {});

  const normalizedProvider = String(CONFIG.provider || 'auto').trim().toLowerCase();
  const ADDON_FINGERPRINT =
    String(window.__antigravityZhPatchRequestedFingerprint || 'ext') +
    '|thought-v8|' +
    String(CONFIG._buildId || '') +
    '|' +
    String(Boolean(CONFIG.enabled)) +
    '|' +
    normalizedProvider;

  if (
    CONFIG.enabled &&
    window.__agyThoughtAddonInstalled === true &&
    window.__agyThoughtObservedDoc === document &&
    window.__agyThoughtAddonFingerprint === ADDON_FINGERPRINT
  ) {
    return;
  }

  if (typeof window.__agyThoughtAddonCleanup === 'function') {
    try { window.__agyThoughtAddonCleanup(!CONFIG.enabled); } catch (_e) {}
  }

  if (!CONFIG.enabled) {
    window.__agyThoughtAddonInstalled = false;
    return;
  }

  window.__agyThoughtAddonInstalled = true;
  window.__agyThoughtObservedDoc = document;
  window.__agyThoughtAddonFingerprint = ADDON_FINGERPRINT;

  // One-time cleanup of any legacy DOM pending attributes from older versions
  try {
    for (const el of document.querySelectorAll('[data-agy-zh-pending]')) {
      el.removeAttribute('data-agy-zh-pending');
    }
  } catch (_e) {}

  const LANG_STORAGE_KEY = 'antigravityHansLang';
  const CACHE_STORAGE_KEY = 'agyZhThoughtCacheV3';
  const STYLE_ID = 'agy-zh-thought-addon-style';
  const MAX_CACHE_ENTRIES = 320;
  const MAX_CACHE_ITEM_CHARS = 4000;
  const MAX_CONCURRENCY = 2;
  const MAX_QUEUE_LENGTH = 64;
  const STREAM_DEBOUNCE_MS = 480;
  const STREAM_MAX_WAIT_MS = 1400;

  let disposed = false;
  let activeRequests = 0;
  const requestQueue = [];
  const inflightMap = new Map();
  const memoryCache = new Map();
  const activeAbortControllers = new Set();
  const pendingBlockMap = new WeakMap();
  const trackedTextNodes = new Set();
  const trackedScrollPanels = new Map();
  const mdDebounceStates = new Map();

  function pruneDisconnectedTracking() {
    for (const node of Array.from(trackedTextNodes)) {
      if (!node.isConnected) trackedTextNodes.delete(node);
    }
    for (const [panel] of Array.from(trackedScrollPanels.entries())) {
      if (!panel.isConnected) trackedScrollPanels.delete(panel);
    }
  }

  function loadSessionCache() {
    try {
      const raw = window.sessionStorage ? window.sessionStorage.getItem(CACHE_STORAGE_KEY) : null;
      if (!raw || raw.length > 524288) return;
      const arr = JSON.parse(raw);
      if (!Array.isArray(arr)) return;
      const slice = arr.slice(-MAX_CACHE_ENTRIES);
      for (const item of slice) {
        if (
          Array.isArray(item) &&
          typeof item[0] === 'string' &&
          typeof item[1] === 'string' &&
          item[0].length <= MAX_CACHE_ITEM_CHARS &&
          item[1].length <= MAX_CACHE_ITEM_CHARS
        ) {
          memoryCache.set(item[0], item[1]);
        }
      }
    } catch (_e) {}
  }

  let saveCacheTimer = null;
  function scheduleSaveSessionCache() {
    if (saveCacheTimer !== null || disposed) return;
    saveCacheTimer = window.setTimeout(() => {
      saveCacheTimer = null;
      if (disposed) return;
      try {
        if (!window.sessionStorage) return;
        const entries = Array.from(memoryCache.entries()).slice(-MAX_CACHE_ENTRIES);
        window.sessionStorage.setItem(CACHE_STORAGE_KEY, JSON.stringify(entries));
      } catch (_e) {}
    }, 1000);
  }

  function cacheGet(key) {
    if (!memoryCache.has(key)) return null;
    const val = memoryCache.get(key);
    memoryCache.delete(key);
    memoryCache.set(key, val);
    return val;
  }

  function cacheSet(key, val) {
    if (!key || !val || key.length > MAX_CACHE_ITEM_CHARS || val.length > MAX_CACHE_ITEM_CHARS) return;
    if (memoryCache.has(key)) memoryCache.delete(key);
    memoryCache.set(key, val);
    while (memoryCache.size > MAX_CACHE_ENTRIES) {
      const oldestKey = memoryCache.keys().next().value;
      memoryCache.delete(oldestKey);
    }
    scheduleSaveSessionCache();
  }

  function getLang() {
    try {
      return window.localStorage && window.localStorage.getItem(LANG_STORAGE_KEY) === 'en' ? 'en' : 'zh';
    } catch (_e) {
      return 'zh';
    }
  }

  let currentLang = getLang();

  function ensureStyleMounted() {
    let styleEl = document.getElementById(STYLE_ID);
    if (!styleEl) {
      styleEl = document.createElement('style');
      styleEl.id = STYLE_ID;
      styleEl.setAttribute('data-agy-hans-ui', 'thought-style');
      styleEl.textContent = [
        '.agy-zh-thought-line {',
        '  display: block;',
        '  margin-top: 4px;',
        '  margin-bottom: 2px;',
        '  padding-left: 8px;',
        '  border-left: 2px solid rgba(125, 162, 255, 0.45);',
        '  color: var(--color-foreground, rgba(235, 238, 245, 0.92));',
        '  font-size: 0.94em;',
        '  line-height: 1.55;',
        '  opacity: 0.94;',
        '  word-break: break-word;',
        '}',
        '.agy-zh-thought-notice {',
        '  display: flex;',
        '  flex-wrap: wrap;',
        '  align-items: center;',
        '  gap: 6px 10px;',
        '  margin-top: 8px;',
        '  padding: 6px 10px;',
        '  border-radius: 6px;',
        '  border: 1px solid rgba(245, 158, 11, 0.35);',
        '  background: rgba(245, 158, 11, 0.08);',
        '  color: var(--color-foreground, rgba(245, 240, 230, 0.92));',
        '  font-size: 0.85em;',
        '  line-height: 1.5;',
        '}',
        '.agy-zh-thought-retry-btn {',
        '  padding: 1px 8px;',
        '  border-radius: 4px;',
        '  border: 1px solid rgba(125, 162, 255, 0.5);',
        '  background: rgba(125, 162, 255, 0.14);',
        '  color: inherit;',
        '  font-size: 0.92em;',
        '  cursor: pointer;',
        '  white-space: nowrap;',
        '}',
        '.agy-zh-thought-retry-btn:hover {',
        '  background: rgba(125, 162, 255, 0.26);',
        '}',
        '@media (prefers-color-scheme: light) {',
        '  .agy-zh-thought-line {',
        '    border-left-color: rgba(31, 111, 235, 0.45);',
        '    color: rgba(28, 33, 40, 0.92);',
        '  }',
        '  .agy-zh-thought-notice {',
        '    border-color: rgba(217, 119, 6, 0.4);',
        '    background: rgba(254, 243, 199, 0.55);',
        '    color: rgba(31, 41, 55, 0.95);',
        '  }',
        '}',
        'html[data-agy-thought-lang="en"] .agy-zh-thought-line,',
        'html[data-agy-thought-lang="en"] .agy-zh-thought-notice {',
        '  display: none !important;',
        '}'
      ].join('\n');
      (document.head || document.documentElement).appendChild(styleEl);
    }
    document.documentElement.setAttribute('data-agy-thought-lang', currentLang);
  }

  function formatDurationZh(raw) {
    const s = String(raw || '').trim();
    if (/^<\s*1\s*s$/i.test(s)) return '< 1 秒';
    return s
      .replace(/(\d+(?:\.\d+)?)\s*d\b/gi, '$1 天 ')
      .replace(/(\d+(?:\.\d+)?)\s*h\b/gi, '$1 小时 ')
      .replace(/(\d+(?:\.\d+)?)\s*m\b/gi, '$1 分 ')
      .replace(/(\d+(?:\.\d+)?)\s*s\b/gi, '$1 秒')
      .replace(/\s+/g, ' ')
      .trim();
  }

  const EXACT_ACTION_LABELS = new Map([
    ['Edited', '已编辑'],
    ['Editing', '正在编辑'],
    ['Analyzed', '已分析'],
    ['Analyzing', '正在分析'],
    ['Created', '已创建'],
    ['Creating', '正在创建'],
    ['Deleted', '已删除'],
    ['Deleting', '正在删除'],
    ['Read', '已读取'],
    ['Reading', '正在读取'],
    ['Wrote', '已写入'],
    ['Writing', '正在写入'],
    ['Searched', '已搜索'],
    ['Searching', '正在搜索'],
    ['Ran', '已运行'],
    ['Running', '正在运行'],
    ['Executed', '已执行'],
    ['Executing', '正在执行'],
    ['Listed', '已列出'],
    ['Listing', '正在列出'],
    ['Viewed', '已查看'],
    ['Viewing', '正在查看'],
    ['Fetched', '已获取'],
    ['Fetching', '正在获取'],
    ['Updated', '已更新'],
    ['Updating', '正在更新'],
    ['Checked', '已检查'],
    ['Checking', '正在检查'],
    ['Explored', '已探索'],
    ['Exploring', '正在探索'],
    ['Modified', '已修改'],
    ['Modifying', '正在修改'],
    ['Renamed', '已重命名'],
    ['Moved', '已移动'],
    ['Copied', '已复制'],
    ['Called', '已调用'],
    ['Calling', '正在调用'],
    ['Backgrounded', '已转入后台'],
    ['Canceled', '已取消'],
    ['Cancelled', '已取消'],
    ['Failed', '失败'],
    ['Just now', '刚刚'],
    ['Hide earlier steps', '隐藏更早的步骤'],
    ['Thought', '思考过程'],
    ['Thinking', '思考中'],
    ['Thinking...', '思考中...'],
    ['Thinking…', '思考中…']
  ]);

  const REL_UNIT_ZH = {
    s: '秒',
    m: '分钟',
    h: '小时',
    d: '天',
    w: '周',
    mo: '个月',
    y: '年'
  };

  function translateStepLabelString(str) {
    const trimmed = str.trim();
    if (!trimmed) return null;

    if (EXACT_ACTION_LABELS.has(trimmed)) {
      return str.replace(trimmed, EXACT_ACTION_LABELS.get(trimmed));
    }

    let m = trimmed.match(/^Thought for (<\s*1\s*s|(?:\d+(?:\.\d+)?\s*[dhms]\b\s*)+)$/i);
    if (m) return str.replace(trimmed, '已思考 ' + formatDurationZh(m[1]));

    m = trimmed.match(/^Thinking for (<\s*1\s*s|(?:\d+(?:\.\d+)?\s*[dhms]\b\s*)+)$/i);
    if (m) return str.replace(trimmed, '思考中 ' + formatDurationZh(m[1]));

    m = trimmed.match(/^Worked for (<\s*1\s*s|(?:\d+(?:\.\d+)?\s*[dhms]\b\s*)+)$/i);
    if (m) return str.replace(trimmed, '已工作 ' + formatDurationZh(m[1]));

    m = trimmed.match(/^Stopped after (<\s*1\s*s|(?:\d+(?:\.\d+)?\s*[dhms]\b\s*)+)$/i);
    if (m) return str.replace(trimmed, '工作 ' + formatDurationZh(m[1]) + '后停止');

    m = trimmed.match(/^(\d+)\s*(mo|[smhdwy])\s*ago$/i);
    if (m) {
      const unit = REL_UNIT_ZH[m[2].toLowerCase()];
      if (unit) return str.replace(trimmed, m[1] + ' ' + unit + '前');
    }

    m = trimmed.match(/^Show (\d+) earlier steps?$/i);
    if (m) return str.replace(trimmed, '显示更早的 ' + m[1] + ' 个步骤');

    return null;
  }

  const EXCLUDED_ACTION_SUBTREE_SEL =
    '[data-testid="planner-response-text"], [data-testid="user-input-step"], [data-markdown-root], code, pre, script, style, textarea, input, [contenteditable="true"], button[data-uri], [data-quotable-inline], [data-agy-hans-ui], [data-agy-zh-thought]';

  const ALLOWED_ACTION_CONTAINER_SEL =
    '[data-testid="thinking-collapsible-trigger"], [data-testid="worked-for-collapsible"], [data-testid="tool-group-collapsible"], [data-testid="agent-response"], [aria-label="Agent response"], [aria-label="智能体回复"], [data-testid="conversation-row-sidebar"]';

  function isEligibleActionTextNode(textNode) {
    const el = textNode.parentElement;
    if (!el) return false;
    if (el.closest(EXCLUDED_ACTION_SUBTREE_SEL)) return false;
    return Boolean(el.closest(ALLOWED_ACTION_CONTAINER_SEL));
  }

  function applyActionTextNode(textNode) {
    if (!textNode || textNode.nodeType !== Node.TEXT_NODE) return;
    if (!isEligibleActionTextNode(textNode)) return;

    const currentVal = textNode.nodeValue || '';
    if (!currentVal.trim()) return;

    if (currentLang === 'en') {
      if (textNode.__agyLastZh === currentVal && typeof textNode.__agyOrigEn === 'string') {
        textNode.nodeValue = textNode.__agyOrigEn;
      }
      return;
    }

    if (textNode.__agyLastZh === currentVal) {
      return;
    }

    const sourceEn = currentVal;
    const zh = translateStepLabelString(sourceEn);
    if (zh && zh !== sourceEn) {
      textNode.__agyOrigEn = sourceEn;
      textNode.__agyLastZh = zh;
      textNode.nodeValue = zh;
      trackedTextNodes.add(textNode);
      if (trackedTextNodes.size > 300) pruneDisconnectedTracking();
    }
  }

  function restoreAllActionLabels(removeThoughtSpans) {
    for (const node of Array.from(trackedTextNodes)) {
      if (!node.isConnected) {
        trackedTextNodes.delete(node);
        continue;
      }
      if (node.nodeValue === node.__agyLastZh && typeof node.__agyOrigEn === 'string') {
        node.nodeValue = node.__agyOrigEn;
      }
    }
    for (const [panel, saved] of Array.from(trackedScrollPanels.entries())) {
      if (!panel.isConnected) {
        trackedScrollPanels.delete(panel);
        continue;
      }
      if (panel.style.maxHeight === '360px') {
        panel.style.setProperty('max-height', saved.value, saved.priority);
      }
      trackedScrollPanels.delete(panel);
    }
    if (removeThoughtSpans) {
      for (const sp of Array.from(document.querySelectorAll('[data-agy-zh-thought]'))) {
        const parent = sp.parentElement;
        sp.remove();
        if (parent) {
          parent.removeAttribute('data-agy-zh-rendered');
        }
      }
      for (const nt of Array.from(document.querySelectorAll('[data-agy-zh-notice]'))) {
        nt.remove();
      }
    }
  }

  // --- Thinking Block Inline Code & Identifier Masking ---
  const INLINE_TOKEN_RE = /(\$[A-Za-z_][\w:.-]*|--[A-Za-z0-9][\w-]*|(?:[A-Za-z]:\\|\\\\)[\w.\\/-]+|\b[\w.-]+\.(?:ps1|psm1|psd1|vbs|cmd|bat|exe|dll|asar|lnk|js|mjs|cjs|ts|tsx|jsx|py|go|rs|java|kt|cs|cpp|c|h|json|ya?ml|md|toml|ini|xml|html|css|scss|sh|sql)(?:#L\d+(?:-\d+)?)?\b|\b[A-Za-z]+_[A-Za-z0-9_]+\b|\b[a-z]+[A-Z][A-Za-z0-9]*\b|\b[A-Z][a-z]+-[A-Z][a-z]+[A-Z][A-Za-z0-9]*\b|\b[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\b)/g;

  function chooseCollisionFreePrefix(rawText) {
    const candidates = ['C', 'K', 'Q', 'V', 'X', 'Z'];
    for (const c of candidates) {
      const re = new RegExp('[_\\uFF3F]{2}\\s*' + c + '\\s*\\d+\\s*[_\\uFF3F]{2}', 'i');
      if (!re.test(rawText)) return c;
    }
    let salt = 1;
    while (new RegExp('[_\\uFF3F]{2}\\s*T' + salt + 'N\\s*\\d+\\s*[_\\uFF3F]{2}', 'i').test(rawText)) {
      salt++;
    }
    return 'T' + salt + 'N';
  }

  function buildTokenRegex(prefix) {
    return new RegExp('[_\\uFF3F]{2}\\s*' + prefix + '\\s*(\\d+)\\s*[_\\uFF3F]{2}', 'gi');
  }

  function extractBlockMaskedPayload(blockEl) {
    const rawPreview = blockEl.textContent || '';
    const prefix = chooseCollisionFreePrefix(rawPreview);
    const tokens = [];
    const parts = [];

    function pushToken(text, isCode) {
      const id = tokens.length;
      tokens.push({ text, isCode });
      return `__${prefix}${id}__`;
    }

    function walk(node) {
      if (!node) return;
      if (node.nodeType === Node.TEXT_NODE) {
        const raw = node.nodeValue || '';
        if (!raw) return;
        let lastIdx = 0;
        INLINE_TOKEN_RE.lastIndex = 0;
        let m;
        while ((m = INLINE_TOKEN_RE.exec(raw)) !== null) {
          if (m.index > lastIdx) {
            parts.push(raw.slice(lastIdx, m.index));
          }
          parts.push(pushToken(m[0], false));
          lastIdx = m.index + m[0].length;
        }
        if (lastIdx < raw.length) {
          parts.push(raw.slice(lastIdx));
        }
        return;
      }

      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const el = node;
      if (el.hasAttribute('data-agy-zh-thought') || el.hasAttribute('data-agy-hans-ui')) return;
      const tag = el.tagName;
      if (/^(?:UL|OL|PRE|STYLE|SCRIPT|TABLE|P|H[1-6]|BLOCKQUOTE)$/.test(tag)) {
        return;
      }
      if (tag === 'CODE' || tag === 'KBD' || tag === 'SAMP') {
        const codeTxt = el.textContent || '';
        if (codeTxt) {
          parts.push(pushToken(codeTxt, true));
        }
        return;
      }
      if (el.matches('button[data-uri], [data-quotable-inline], a[href^="file:"]')) {
        const pillTxt = (el.textContent || '').trim();
        if (pillTxt) {
          parts.push(pushToken(pillTxt, true));
        }
        return;
      }
      if (tag === 'BR') {
        parts.push(' ');
        return;
      }
      for (let child = el.firstChild; child; child = child.nextSibling) {
        walk(child);
      }
    }

    for (let child = blockEl.firstChild; child; child = child.nextSibling) {
      walk(child);
    }

    const masked = parts.join('').replace(/\s+/g, ' ').trim();
    const stripRe = buildTokenRegex(prefix);
    const stripped = masked.replace(stripRe, '').trim();
    const alphaMatches = stripped.match(/[A-Za-z]/g);
    const cjkMatches = stripped.match(/[\u4E00-\u9FFF]/g);
    const alphaCount = alphaMatches ? alphaMatches.length : 0;
    const cjkCount = cjkMatches ? cjkMatches.length : 0;

    const shouldTranslate = alphaCount >= 6 && (cjkCount / (cjkCount + alphaCount)) < 0.35 && masked.length <= 3600;
    return { prefix, masked, tokens, shouldTranslate };
  }

  function validatePlaceholders(translatedText, prefix, tokenCount, strictAllPresent) {
    if (!translatedText) return false;
    if (tokenCount === 0) return true;
    const re = buildTokenRegex(prefix);
    const counts = new Map();
    let m;
    while ((m = re.exec(translatedText)) !== null) {
      const idx = parseInt(m[1], 10);
      if (Number.isNaN(idx) || idx < 0 || idx >= tokenCount) {
        return false;
      }
      counts.set(idx, (counts.get(idx) || 0) + 1);
    }
    if (strictAllPresent) {
      if (counts.size !== tokenCount) return false;
      for (let i = 0; i < tokenCount; i++) {
        if (counts.get(i) !== 1) return false;
      }
    }
    return true;
  }

  // --- Full-Lifecycle Bounded-Timeout Zero-Risk Translation Providers ---
  async function fetchJsonWithTimeout(url, init, timeoutMs) {
    const ctrl = typeof AbortController === 'function' ? new AbortController() : null;
    if (ctrl) activeAbortControllers.add(ctrl);
    const timer = ctrl ? window.setTimeout(() => { try { ctrl.abort(); } catch (_e) {} }, timeoutMs) : null;
    try {
      const opts = ctrl ? Object.assign({}, init, { signal: ctrl.signal }) : init;
      const resp = await nativeFetch(url, opts);
      if (!resp.ok) {
        let detail = '';
        try {
          const errTxt = await resp.text();
          if (errTxt && errTxt.length <= 1024) detail = ': ' + errTxt.slice(0, 180);
        } catch (_e) {}
        const httpErr = new Error('HTTP ' + resp.status + detail);
        httpErr.status = resp.status;
        throw httpErr;
      }
      const rawText = await resp.text();
      if (rawText.length > 131072) {
        throw new Error('Response too large');
      }
      return JSON.parse(rawText);
    } finally {
      if (timer !== null) clearTimeout(timer);
      if (ctrl) activeAbortControllers.delete(ctrl);
    }
  }

  const FREE_PROVIDER_COOLDOWN_MS = 180000;
  const ALL_COOLDOWN_PROBE_INTERVAL_MS = 15000;
  const providerCooldownUntil = { gtx: 0, mymemory: 0, transmart: 0 };
  let lastAllCooldownProbeAt = 0;
  const utf8Encoder = typeof TextEncoder === 'function' ? new TextEncoder() : null;

  function getUtf8ByteLength(str) {
    return utf8Encoder ? utf8Encoder.encode(str).length : str.length * 3;
  }

  const NAMED_ENTITIES = {
    quot: '"',
    apos: "'",
    lt: '<',
    gt: '>',
    amp: '&'
  };

  function decodeSafeHtmlEntities(str) {
    if (!str || str.indexOf('&') === -1) return str;
    return str.replace(/&(?:#(\d{1,7})|#x([0-9a-fA-F]{1,6})|(quot|apos|lt|gt|amp));/gi, (full, dec, hex, named) => {
      if (dec !== undefined) {
        const cp = parseInt(dec, 10);
        return (cp === 0x27 || (cp >= 0x20 && cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF))) ? String.fromCodePoint(cp) : full;
      }
      if (hex !== undefined) {
        const cp = parseInt(hex, 16);
        return (cp >= 0x20 && cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF)) ? String.fromCodePoint(cp) : full;
      }
      if (named !== undefined) {
        const key = named.toLowerCase();
        return Object.prototype.hasOwnProperty.call(NAMED_ENTITIES, key) ? NAMED_ENTITIES[key] : full;
      }
      return full;
    });
  }

  function splitOversizedAtomSafe(tokenStr, maxBytes, prefix) {
    const atomRe = new RegExp('(__' + prefix + '\\d+__)', 'g');
    const pieces = tokenStr.split(atomRe).filter(Boolean);
    const subChunks = [];
    let buf = '';
    let bufBytes = 0;

    const flushBuf = () => {
      const t = buf.trim();
      if (t) subChunks.push(t);
      buf = '';
      bufBytes = 0;
    };

    for (const piece of pieces) {
      if (atomRe.test(piece)) {
        atomRe.lastIndex = 0;
        const pBytes = getUtf8ByteLength(piece);
        if (bufBytes + pBytes > maxBytes && buf) flushBuf();
        buf += piece;
        bufBytes += pBytes;
        if (bufBytes >= maxBytes) flushBuf();
      } else {
        atomRe.lastIndex = 0;
        for (const ch of Array.from(piece)) {
          const cBytes = getUtf8ByteLength(ch);
          if (bufBytes + cBytes > maxBytes && buf) flushBuf();
          buf += ch;
          bufBytes += cBytes;
        }
      }
    }
    flushBuf();
    return subChunks;
  }

  function splitMaskedTextByBytes(text, maxBytes, prefix) {
    if (getUtf8ByteLength(text) <= maxBytes) return [text];
    const sentences = text.match(/[^.!?;]+[.!?;]*\s*/g) || [text];
    const chunks = [];
    let current = '';

    const flushCurrent = () => {
      const trimmed = current.trim();
      if (trimmed) chunks.push(trimmed);
      current = '';
    };

    for (const seg of sentences) {
      if (getUtf8ByteLength(current + seg) <= maxBytes) {
        current += seg;
        continue;
      }
      flushCurrent();
      if (getUtf8ByteLength(seg) <= maxBytes) {
        current = seg;
        continue;
      }
      const parts = seg.split(/(\s+)/);
      for (const part of parts) {
        if (!part) continue;
        if (getUtf8ByteLength(current + part) <= maxBytes) {
          current += part;
        } else {
          flushCurrent();
          if (getUtf8ByteLength(part) <= maxBytes) {
            current = part;
          } else {
            const safeSubs = splitOversizedAtomSafe(part, maxBytes, prefix);
            for (let i = 0; i < safeSubs.length; i++) {
              if (i < safeSubs.length - 1) {
                chunks.push(safeSubs[i]);
              } else {
                current = safeSubs[i];
              }
            }
          }
        }
      }
    }
    flushCurrent();
    return chunks;
  }

  async function translateViaGoogleGtx(maskedText) {
    const url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=zh-CN&dt=t';
    const data = await fetchJsonWithTimeout(url, {
      method: 'POST',
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: 'q=' + encodeURIComponent(maskedText)
    }, 6500);
    if (!Array.isArray(data) || !Array.isArray(data[0])) {
      throw new Error('Unexpected Google Translate payload');
    }
    const out = data[0].map(seg => (Array.isArray(seg) && typeof seg[0] === 'string' ? seg[0] : '')).join('').trim();
    if (!out) throw new Error('Empty Google Translate output');
    return out;
  }

  async function translateViaMyMemory(maskedText, prefix) {
    const chunks = splitMaskedTextByBytes(maskedText, 420, prefix);
    if (chunks.length === 0 || chunks.length > 10) {
      throw new Error('Unsupported MyMemory chunk count');
    }
    const outParts = [];
    for (const ch of chunks) {
      if (disposed) throw new Error('Disposed');
      const data = await fetchJsonWithTimeout('https://api.mymemory.translated.net/get', {
        method: 'POST',
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
        body: 'langpair=en%7Czh-CN&q=' + encodeURIComponent(ch)
      }, 10000);
      if (!data || data.quotaFinished === true || (data.responseStatus && Number(data.responseStatus) !== 200)) {
        throw new Error('MyMemory status/quota failure');
      }
      const rawTr = data.responseData && typeof data.responseData.translatedText === 'string'
        ? data.responseData.translatedText.trim()
        : '';
      if (!rawTr || /^(?:MAX ALLOWED QUERY|MYMEMORY WARNING|QUERY LENGTH LIMIT)/i.test(rawTr)) {
        throw new Error('MyMemory rejected query');
      }
      outParts.push(decodeSafeHtmlEntities(rawTr));
    }
    const joined = outParts.join(' ').replace(/\s+/g, ' ').trim();
    if (!joined) throw new Error('Empty MyMemory output');
    return joined;
  }

  async function translateViaTranSmart(maskedText) {
    const clientKey = 'browser-chrome-120.0.0-Windows_10-agy-' + Math.random().toString(36).slice(2, 10);
    const data = await fetchJsonWithTimeout('https://transmart.qq.com/api/imt', {
      method: 'POST',
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      headers: { 'Content-Type': 'text/plain;charset=UTF-8' },
      body: JSON.stringify({
        header: { fn: 'auto_translation', client_key: clientKey },
        type: 'plain',
        model_category: 'normal',
        source: { lang: 'en', text_list: [maskedText] },
        target: { lang: 'zh' }
      })
    }, 6500);
    if (!data || !data.header || data.header.ret_code !== 'succ' || !Array.isArray(data.auto_translation)) {
      throw new Error('Unexpected TranSmart payload');
    }
    const out = data.auto_translation.map(s => (typeof s === 'string' ? s : '')).join('').trim();
    if (!out) throw new Error('Empty TranSmart output');
    return out;
  }

  async function translateViaFreeCascade(maskedText, prefix, tokenCount) {
    const chain = [
      { key: 'gtx', fn: () => translateViaGoogleGtx(maskedText) },
      { key: 'mymemory', fn: () => translateViaMyMemory(maskedText, prefix) },
      { key: 'transmart', fn: () => translateViaTranSmart(maskedText) }
    ];

    const now = Date.now();
    const allCooling = chain.every(it => now < providerCooldownUntil[it.key]);
    let singleProbeKey = null;
    if (allCooling) {
      if ((now - lastAllCooldownProbeAt) < ALL_COOLDOWN_PROBE_INTERVAL_MS) {
        throw new Error('All free translation providers are cooling down');
      }
      lastAllCooldownProbeAt = now;
      // Probe only the earliest-expiring provider instead of resetting all cooldowns
      singleProbeKey = chain.reduce((best, cur) =>
        providerCooldownUntil[cur.key] < providerCooldownUntil[best.key] ? cur : best
      ).key;
    }

    let lastErr = null;
    for (const item of chain) {
      if (disposed) return '';
      if (singleProbeKey !== null) {
        if (item.key !== singleProbeKey) continue;
      } else if (Date.now() < providerCooldownUntil[item.key]) {
        continue;
      }
      try {
        const cand = await item.fn();
        if (validatePlaceholders(cand, prefix, tokenCount, false)) {
          providerCooldownUntil[item.key] = 0;
          return cand;
        }
        throw new Error(item.key + ' placeholder validation failed');
      } catch (err) {
        lastErr = err;
        providerCooldownUntil[item.key] = Date.now() + FREE_PROVIDER_COOLDOWN_MS;
      }
    }
    throw lastErr || new Error('All free translation providers failed');
  }

  function isVerifiedAgAppSurface() {
    if (proto === 'vscode-file:' || (proto === 'file:' && /workbench\.html$/i.test(path))) return true;
    if (proto === 'https:' && host === '127.0.0.1' && /^\/c\//.test(path)) return true;
    return (
      proto === 'https:' &&
      host === '127.0.0.1' &&
      document.querySelector('[data-testid="agent-response"], [data-testid="conversation-row-sidebar"]') !== null
    );
  }

  async function translateViaOfficialGeminiApi(maskedText, prefix, tokenCount) {
    const apiKey = String(CONFIG.geminiApiKey || '').trim();
    if (!apiKey || !isVerifiedAgAppSurface()) {
      return translateViaFreeCascade(maskedText, prefix, tokenCount);
    }
    const model = String(CONFIG.geminiModel || 'gemini-3.5-flash-lite').trim() || 'gemini-3.5-flash-lite';
    const ex0 = `__${prefix}0__`;
    const ex1 = `__${prefix}1__`;
    const data = await fetchJsonWithTimeout('https://generativelanguage.googleapis.com/v1beta/interactions', {
      method: 'POST',
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
        'Api-Revision': '2026-05-20'
      },
      body: JSON.stringify({
        model: model,
        store: false,
        generation_config: { thinking_level: 'minimal' },
        system_instruction: `将输入的英文AI思考摘要准确、自然、简练地译为简体中文。必须原封不动保留所有形如 ${ex0}、${ex1} 的占位标记（切勿修改字母、编号或下划线），只输出中文译文正文，不要附加任何解释。`,
        input: maskedText
      })
    }, 18000);
    const steps = Array.isArray(data && data.steps) ? data.steps : [];
    const out = steps
      .filter(s => s && s.type === 'model_output' && Array.isArray(s.content))
      .flatMap(s => s.content)
      .map(c => (c && typeof c.text === 'string' ? c.text : ''))
      .join('')
      .trim();
    if (!out) {
      throw new Error('Empty Gemini model_output');
    }
    return out;
  }

  let bridgeCooldownUntil = 0;
  const BRIDGE_RETRY_COOLDOWN_MS = 8000;

  async function translateBatchViaLocalBridge(maskedTexts) {
    const token = String(CONFIG.bridgeToken || '').trim();
    const port = Number(CONFIG.bridgePort) || 47831;
    if (!token || port < 1024 || port > 65535 || !isVerifiedAgAppSurface()) {
      throw new Error('Local bridge not configured');
    }
    if (Date.now() < bridgeCooldownUntil) {
      throw new Error('Local bridge cooling down');
    }
    try {
      const timeoutMs = normalizedProvider === 'local-llm' ? 28000 : 24000;
      const data = await fetchJsonWithTimeout('http://127.0.0.1:' + port + '/translate', {
        method: 'POST',
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
        headers: { 'Content-Type': 'text/plain;charset=UTF-8' },
        body: JSON.stringify({
          token: token,
          texts: maskedTexts
        })
      }, timeoutMs);
      if (!data || data.ok !== true || !Array.isArray(data.translations) || data.translations.length !== maskedTexts.length) {
        throw new Error((data && data.error) ? String(data.error) : 'Invalid bridge payload');
      }
      bridgeCooldownUntil = 0;
      return {
        engine: typeof data.engine === 'string' ? data.engine : 'transmart-direct',
        translations: data.translations.map(s => (typeof s === 'string' ? s.trim() : ''))
      };
    } catch (err) {
      bridgeCooldownUntil = Date.now() + BRIDGE_RETRY_COOLDOWN_MS;
      throw err;
    }
  }

  function getActiveProviderTag() {
    const buildVer = String(CONFIG._buildId || 'dev').slice(0, 8);
    if (normalizedProvider === 'local-llm') {
      return 'local-llm:' + (String(CONFIG.llmModel || 'qwen2.5:3b').trim() || 'qwen2.5:3b') + ':' + buildVer;
    }
    if (Boolean(CONFIG.hasLlmKey) && (normalizedProvider === 'auto' || normalizedProvider === 'zhipu' || normalizedProvider === 'openai-compat')) {
      return 'llm:' + normalizedProvider + ':' + (String(CONFIG.llmModel || 'glm-4-flash').trim() || 'glm-4-flash') + ':' + buildVer;
    }
    const hasGemKey = Boolean(String(CONFIG.geminiApiKey || '').trim());
    if (hasGemKey && (normalizedProvider === 'auto' || normalizedProvider === 'gemini') && isVerifiedAgAppSurface()) {
      return 'gemini:' + (String(CONFIG.geminiModel || 'gemini-3.5-flash-lite').trim() || 'gemini-3.5-flash-lite') + ':' + buildVer;
    }
    return 'direct:' + buildVer;
  }

  function pumpQueue() {
    while (!disposed && activeRequests < MAX_CONCURRENCY && requestQueue.length > 0) {
      const job = requestQueue.shift();
      if (!job.hasLiveSubscriber()) {
        job.resolve('');
        continue;
      }
      activeRequests++;
      Promise.resolve()
        .then(() => job.fn())
        .then(job.resolve, job.reject)
        .finally(() => {
          activeRequests--;
          pumpQueue();
        });
    }
  }

  async function translateSingleItemDirect(payload, providerTag) {
    const { prefix, masked, tokens } = payload;
    const tokenCount = tokens.length;
    const useGemini = providerTag.startsWith('gemini:');
    const cacheKey = providerTag + '|' + prefix + '|' + masked;

    const hit = cacheGet(cacheKey);
    if (hit !== null && validatePlaceholders(hit, prefix, tokenCount, false)) {
      return hit;
    }

    if (inflightMap.has(cacheKey)) {
      return inflightMap.get(cacheKey);
    }

    const workPromise = (async () => {
      if (disposed) return '';
      if (useGemini) {
        try {
          const cand = await translateViaOfficialGeminiApi(masked, prefix, tokenCount);
          if (validatePlaceholders(cand, prefix, tokenCount, true)) {
            cacheSet(cacheKey, cand);
            return cand;
          }
          throw new Error('Gemini placeholder mismatch');
        } catch (_err) {
          const fb = await translateViaFreeCascade(masked, prefix, tokenCount);
          if (validatePlaceholders(fb, prefix, tokenCount, false)) {
            cacheSet('direct|' + prefix + '|' + masked, fb);
            return fb;
          }
          return '';
        }
      } else {
        const fb = await translateViaFreeCascade(masked, prefix, tokenCount);
        if (validatePlaceholders(fb, prefix, tokenCount, false)) {
          cacheSet(cacheKey, fb);
          return fb;
        }
        return '';
      }
    })().finally(() => {
      inflightMap.delete(cacheKey);
    });

    inflightMap.set(cacheKey, workPromise);
    return workPromise;
  }

  function removeDirectThoughtSpan(blockEl) {
    if (!blockEl) return;
    for (let child = blockEl.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === Node.ELEMENT_NODE && child.hasAttribute('data-agy-zh-thought')) {
        child.remove();
        break;
      }
    }
    blockEl.removeAttribute('data-agy-zh-rendered');
  }

  function renderBilingualSpan(blockEl, translatedText, prefix, tokens, renderSig) {
    if (!blockEl || !blockEl.isConnected) return;

    let span = null;
    for (let child = blockEl.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === Node.ELEMENT_NODE && child.hasAttribute('data-agy-zh-thought')) {
        span = child;
        break;
      }
    }
    if (!span) {
      span = document.createElement('span');
      span.className = 'agy-zh-thought-line';
      span.setAttribute('data-agy-zh-thought', '1');
      span.setAttribute('data-agy-hans-ui', 'thought');
    } else {
      while (span.firstChild) span.removeChild(span.firstChild);
    }

    const tokenRe = buildTokenRegex(prefix);
    let lastIdx = 0;
    let m;
    while ((m = tokenRe.exec(translatedText)) !== null) {
      if (m.index > lastIdx) {
        span.appendChild(document.createTextNode(translatedText.slice(lastIdx, m.index)));
      }
      const tokenIdx = parseInt(m[1], 10);
      const tokenInfo = (tokenIdx >= 0 && tokenIdx < tokens.length) ? tokens[tokenIdx] : null;
      if (tokenInfo) {
        if (tokenInfo.isCode) {
          const codeEl = document.createElement('code');
          codeEl.className = 'whitespace-pre-wrap bg-muted text-code rounded px-1 py-0.5 text-[0.9em]';
          codeEl.textContent = tokenInfo.text;
          span.appendChild(codeEl);
        } else {
          span.appendChild(document.createTextNode(tokenInfo.text));
        }
      } else {
        span.appendChild(document.createTextNode(m[0]));
      }
      lastIdx = m.index + m[0].length;
    }
    if (lastIdx < translatedText.length) {
      span.appendChild(document.createTextNode(translatedText.slice(lastIdx)));
    }

    let insertBeforeNode = null;
    if (blockEl.tagName === 'LI') {
      for (let child = blockEl.firstChild; child; child = child.nextSibling) {
        if (child.nodeType === Node.ELEMENT_NODE && /^(?:UL|OL|PRE|P|H[1-6]|BLOCKQUOTE)$/.test(child.tagName)) {
          insertBeforeNode = child;
          break;
        }
      }
    }

    if (insertBeforeNode) {
      if (span.parentNode !== blockEl || span.nextSibling !== insertBeforeNode) {
        blockEl.insertBefore(span, insertBeforeNode);
      }
    } else if (span.parentNode !== blockEl || span.nextSibling !== null) {
      blockEl.appendChild(span);
    }

    blockEl.setAttribute('data-agy-zh-rendered', renderSig);
  }

  let nextJobSeq = 1;
  const MAX_BATCH_PARAGRAPHS = 8;
  const MAX_BATCH_TOTAL_CHARS = 9000;

  function applyResolvedTranslationToItem(item, zhText, providerTag) {
    if (disposed || !zhText || !item.block.isConnected || currentLang !== 'zh') return;
    const active = pendingBlockMap.get(item.block);
    if (!active || active.jobId !== item.jobId) return;
    const latest = extractBlockMaskedPayload(item.block);
    if (!latest.shouldTranslate || latest.masked !== item.payload.masked || latest.prefix !== item.payload.prefix) return;
    const latestSig = providerTag + '|' + latest.prefix + '|' + latest.masked + '|' + JSON.stringify(latest.tokens);
    renderBilingualSpan(item.block, zhText, latest.prefix, latest.tokens, latestSig);
  }

  function isRateLimitError(err) {
    if (!err) return false;
    if (err.status === 429) return true;
    const msg = String(err.message || err || '');
    return /\b429\b|too many requests|rate.?limit|quota|cooling down|bridge busy/i.test(msg);
  }

  function removeFailureNotice(mdRoot) {
    if (!mdRoot) return;
    const existing = mdRoot.querySelector(':scope > [data-agy-zh-notice]');
    if (existing) existing.remove();
  }

  function renderFailureNotice(mdRoot, err) {
    if (disposed || currentLang !== 'zh' || !mdRoot || !mdRoot.isConnected) return;
    const rateLimited = isRateLimitError(err);
    const kind = rateLimited ? 'rate-limit' : 'error';

    let bar = mdRoot.querySelector(':scope > [data-agy-zh-notice]');
    if (!bar) {
      bar = document.createElement('div');
      bar.className = 'agy-zh-thought-notice';
      bar.setAttribute('data-agy-zh-notice', '1');
      bar.setAttribute('data-agy-hans-ui', 'thought-notice');
    } else {
      while (bar.firstChild) bar.removeChild(bar.firstChild);
    }
    bar.setAttribute('data-agy-notice-kind', kind);

    const textSpan = document.createElement('span');
    const prefixTitle = rateLimited
      ? '⚠️ 思考翻译触发并发限流，部分内容暂未译出 — '
      : '⚠️ 思考实时翻译暂时失败 — ';
    textSpan.textContent =
      prefixTitle +
      '可选择：① 接入个人免费 API（打开「管理自动汉化守护.cmd」→ [4] 配智谱免费 GLM-4-Flash / 硅基流动 / Gemini） ' +
      '② 本地部署离线翻译模型（菜单 [4] → [5] 连接本机 Ollama 如 qwen2.5:3b） ' +
      '③ 更新 Skill / 插件（对 AI 说「更新 antigravity-zh-plus」获取最新源）。';
    bar.appendChild(textSpan);

    const retryBtn = document.createElement('button');
    retryBtn.type = 'button';
    retryBtn.className = 'agy-zh-thought-retry-btn';
    retryBtn.textContent = '立即重试';
    retryBtn.addEventListener('click', (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      bridgeCooldownUntil = 0;
      providerCooldownUntil.gtx = 0;
      providerCooldownUntil.mymemory = 0;
      providerCooldownUntil.transmart = 0;
      lastAllCooldownProbeAt = 0;
      removeFailureNotice(mdRoot);
      processThinkingMarkdownRoot(mdRoot);
    });
    bar.appendChild(retryBtn);

    if (bar.parentNode !== mdRoot) {
      mdRoot.appendChild(bar);
    }
  }

  function enqueueParagraphBatch(mdRoot, batchItems, providerTag) {
    if (!batchItems || batchItems.length === 0) return;

    const hasLiveSubscriber = () => {
      if (disposed || currentLang !== 'zh') return false;
      for (const it of batchItems) {
        if (!it.block.isConnected) continue;
        const st = pendingBlockMap.get(it.block);
        if (st && st.jobId === it.jobId) return true;
      }
      return false;
    };

    while (requestQueue.length >= MAX_QUEUE_LENGTH) {
      const dropped = requestQueue.shift();
      if (dropped) dropped.resolve('');
    }

    new Promise((resolve, reject) => {
      requestQueue.push({
        hasLiveSubscriber,
        resolve,
        reject,
        fn: async () => {
          if (disposed || !hasLiveSubscriber()) return '';

          const liveItems = [];
          for (const it of batchItems) {
            if (!it.block.isConnected) continue;
            const st = pendingBlockMap.get(it.block);
            if (!st || st.jobId !== it.jobId) continue;
            const cached = cacheGet(it.cacheKey);
            if (cached !== null && validatePlaceholders(cached, it.payload.prefix, it.payload.tokens.length, false)) {
              applyResolvedTranslationToItem(it, cached, providerTag);
              continue;
            }
            liveItems.push(it);
          }

          if (liveItems.length === 0) return '';

          let fallbackItems = [];
          let lastErr = null;
          try {
            const bridgeRes = await translateBatchViaLocalBridge(liveItems.map(x => x.payload.masked));
            const bridgeEngine = bridgeRes.engine || 'transmart-direct';
            const bridgeTranslations = bridgeRes.translations;
            const expectsConfiguredModel = providerTag.startsWith('llm:') || providerTag.startsWith('local-llm:') || providerTag.startsWith('gemini:');
            const usedFreeFallbackOnBridge = expectsConfiguredModel && bridgeEngine === 'transmart-direct';

            for (let i = 0; i < liveItems.length; i++) {
              const it = liveItems[i];
              const tr = bridgeTranslations[i] || '';
              if (tr && validatePlaceholders(tr, it.payload.prefix, it.payload.tokens.length, true)) {
                if (!usedFreeFallbackOnBridge) {
                  cacheSet(it.cacheKey, tr);
                }
                applyResolvedTranslationToItem(it, tr, providerTag);
              } else {
                fallbackItems.push(it);
              }
            }
          } catch (bridgeErr) {
            lastErr = bridgeErr;
            fallbackItems = liveItems;
          }

          let unresolvedCount = 0;
          for (const it of fallbackItems) {
            if (disposed) break;
            const st = pendingBlockMap.get(it.block);
            if (!it.block.isConnected || !st || st.jobId !== it.jobId) continue;
            try {
              const tr = await translateSingleItemDirect(it.payload, providerTag);
              if (tr) {
                applyResolvedTranslationToItem(it, tr, providerTag);
              } else {
                unresolvedCount++;
              }
            } catch (singleErr) {
              lastErr = singleErr;
              unresolvedCount++;
            }
          }

          if (!disposed && mdRoot && mdRoot.isConnected) {
            if (unresolvedCount > 0) {
              renderFailureNotice(mdRoot, lastErr);
            } else {
              removeFailureNotice(mdRoot);
            }
          }
          return 'ok';
        }
      });
      pumpQueue();
    })
      .catch(() => {})
      .finally(() => {
        for (const it of batchItems) {
          const active = pendingBlockMap.get(it.block);
          if (active && active.jobId === it.jobId) {
            pendingBlockMap.delete(it.block);
          }
        }
      });
  }

  function processThinkingMarkdownRoot(mdRoot) {
    if (disposed || currentLang !== 'zh' || !mdRoot || !mdRoot.isConnected) return;

    const providerTag = getActiveProviderTag();
    const blocks = mdRoot.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6');
    const uncachedItems = [];

    for (const block of blocks) {
      if (block.closest('pre, code, table, [data-agy-zh-thought], [data-agy-zh-notice]')) continue;
      if (block.tagName === 'LI' && block.querySelector('p, h1, h2, h3, h4, h5, h6')) continue;

      const payload = extractBlockMaskedPayload(block);
      if (!payload.shouldTranslate || !payload.masked) {
        pendingBlockMap.delete(block);
        removeDirectThoughtSpan(block);
        continue;
      }

      const cacheKey = providerTag + '|' + payload.prefix + '|' + payload.masked;
      const renderSig = cacheKey + '|' + JSON.stringify(payload.tokens);

      if (block.getAttribute('data-agy-zh-rendered') === renderSig && block.querySelector(':scope > [data-agy-zh-thought]')) {
        continue;
      }

      // Instant 0ms synchronous cache hit before queueing any network job
      const memHit = cacheGet(cacheKey);
      if (memHit !== null && validatePlaceholders(memHit, payload.prefix, payload.tokens.length, false)) {
        pendingBlockMap.delete(block);
        renderBilingualSpan(block, memHit, payload.prefix, payload.tokens, renderSig);
        continue;
      }

      const curPending = pendingBlockMap.get(block);
      if (curPending && curPending.renderSig === renderSig) {
        continue;
      }

      const jobId = nextJobSeq++;
      pendingBlockMap.set(block, { jobId, cacheKey, renderSig });
      uncachedItems.push({ block, payload, cacheKey, renderSig, jobId });
    }

    if (uncachedItems.length === 0) return;

    // Group uncached paragraphs into bounded multi-paragraph batches (cuts HTTP calls by ~75%)
    let curBatch = [];
    let curChars = 0;
    for (const item of uncachedItems) {
      const len = item.payload.masked.length;
      if (curBatch.length >= MAX_BATCH_PARAGRAPHS || (curBatch.length > 0 && (curChars + len) > MAX_BATCH_TOTAL_CHARS)) {
        enqueueParagraphBatch(mdRoot, curBatch, providerTag);
        curBatch = [];
        curChars = 0;
      }
      curBatch.push(item);
      curChars += len;
    }
    if (curBatch.length > 0) {
      enqueueParagraphBatch(mdRoot, curBatch, providerTag);
    }
  }

  function scheduleThinkingScanForTrigger(btn) {
    if (disposed || currentLang !== 'zh' || !btn || !btn.isConnected) return;
    if (btn.getAttribute('aria-expanded') !== 'true') {
      const wrapper = btn.parentElement;
      const panel = wrapper ? (wrapper.querySelector('[role="group"]') || btn.nextElementSibling) : null;
      const mdRoot = panel ? panel.querySelector('[data-markdown-root]') : null;
      if (mdRoot && mdDebounceStates.has(mdRoot)) {
        clearTimeout(mdDebounceStates.get(mdRoot).timer);
        mdDebounceStates.delete(mdRoot);
      }
      return;
    }

    const wrapper = btn.parentElement;
    if (!wrapper) return;
    const panel = wrapper.querySelector('[role="group"]') || btn.nextElementSibling;
    if (!panel) return;

    if (panel.style.maxHeight === '200px') {
      if (!trackedScrollPanels.has(panel)) {
        trackedScrollPanels.set(panel, {
          value: panel.style.getPropertyValue('max-height') || '200px',
          priority: panel.style.getPropertyPriority('max-height') || ''
        });
      }
      panel.style.maxHeight = '360px';
    }

    const mdRoot = panel.querySelector('[data-markdown-root]');
    if (!mdRoot) return;

    const btnTxt = (btn.textContent || '').trim();
    const isStreaming = /^(?:Thinking|思考中)/i.test(btnTxt);
    const now = Date.now();
    const prev = mdDebounceStates.get(mdRoot);
    const firstQueuedAt = prev ? prev.firstQueuedAt : now;
    if (prev) clearTimeout(prev.timer);

    let delayMs = isStreaming ? STREAM_DEBOUNCE_MS : 50;
    if (isStreaming && (now - firstQueuedAt) >= STREAM_MAX_WAIT_MS) {
      delayMs = 80;
    }

    const timer = window.setTimeout(() => {
      mdDebounceStates.delete(mdRoot);
      processThinkingMarkdownRoot(mdRoot);
    }, delayMs);
    mdDebounceStates.set(mdRoot, { timer, firstQueuedAt });
  }

  function scheduleAllOpenThinkingScans() {
    if (disposed || currentLang !== 'zh') return;
    const openTriggers = document.querySelectorAll('button[data-testid="thinking-collapsible-trigger"][aria-expanded="true"]');
    for (const btn of openTriggers) {
      scheduleThinkingScanForTrigger(btn);
    }
  }

  const actionWalkerFilter = {
    acceptNode(node) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.matches && node.matches(EXCLUDED_ACTION_SUBTREE_SEL)) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_SKIP;
      }
      if (node.nodeType === Node.TEXT_NODE) {
        return NodeFilter.FILTER_ACCEPT;
      }
      return NodeFilter.FILTER_SKIP;
    }
  };

  function scanSubtreeForActionLabels(root) {
    if (!root || currentLang !== 'zh' || !root.isConnected) return;
    if (root.nodeType === Node.TEXT_NODE) {
      applyActionTextNode(root);
      return;
    }
    if (root.nodeType !== Node.ELEMENT_NODE && root.nodeType !== Node.DOCUMENT_NODE) return;
    if (root.nodeType === Node.ELEMENT_NODE && root.matches(EXCLUDED_ACTION_SUBTREE_SEL)) return;

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, actionWalkerFilter);
    let n;
    while ((n = walker.nextNode())) {
      applyActionTextNode(n);
    }
  }

  let scanScheduled = false;
  let scanAllOpenThinking = false;
  const pendingRoots = new Set();
  const pendingTriggers = new Set();

  function requestBatchScan(targetNode, scanAllThinking) {
    if (disposed) return;
    if (targetNode) pendingRoots.add(targetNode);
    if (scanAllThinking) scanAllOpenThinking = true;
    if (scanScheduled) return;
    scanScheduled = true;
    window.requestAnimationFrame(() => {
      scanScheduled = false;
      if (disposed) return;
      ensureStyleMounted();
      if (currentLang !== 'zh') {
        pendingRoots.clear();
        pendingTriggers.clear();
        scanAllOpenThinking = false;
        return;
      }

      const roots = Array.from(pendingRoots);
      pendingRoots.clear();
      if (roots.includes(document) || roots.includes(document.body) || roots.includes(document.documentElement)) {
        scanSubtreeForActionLabels(document.body || document);
      } else {
        for (const r of roots) {
          scanSubtreeForActionLabels(r);
        }
      }

      if (scanAllOpenThinking) {
        scanAllOpenThinking = false;
        pendingTriggers.clear();
        scheduleAllOpenThinkingScans();
      } else if (pendingTriggers.size > 0) {
        const triggers = Array.from(pendingTriggers);
        pendingTriggers.clear();
        for (const t of triggers) {
          scheduleThinkingScanForTrigger(t);
        }
      }
    });
  }

  function syncLanguageState() {
    if (disposed) return;
    const nextLang = getLang();
    if (nextLang === currentLang) return;
    currentLang = nextLang;
    ensureStyleMounted();
    if (currentLang === 'en') {
      restoreAllActionLabels(false);
    } else {
      requestBatchScan(document.body || document, true);
    }
  }

  let origSetLang = null;
  let installedWrapper = null;
  function wrapSetLang() {
    if (typeof window.__antigravityZhSetLang === 'function' && window.__antigravityZhSetLang !== installedWrapper && !window.__antigravityZhSetLang.__agyWrapped) {
      const fn = window.__antigravityZhSetLang;
      const wrapped = function () {
        const r = fn.apply(this, arguments);
        syncLanguageState();
        return r;
      };
      wrapped.__agyWrapped = true;
      origSetLang = fn;
      installedWrapper = wrapped;
      window.__antigravityZhSetLang = wrapped;
    }
  }

  function findEnclosingThinkingTrigger(node) {
    const el = node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
    if (!el) return null;
    if (el.matches && el.matches('button[data-testid="thinking-collapsible-trigger"]')) {
      return el;
    }
    const group = el.closest('[role="group"]');
    if (!group) return null;
    const prev = group.previousElementSibling;
    if (prev && prev.matches && prev.matches('button[data-testid="thinking-collapsible-trigger"]')) {
      return prev;
    }
    const parent = group.parentElement;
    return parent ? parent.querySelector('button[data-testid="thinking-collapsible-trigger"]') : null;
  }

  loadSessionCache();
  ensureStyleMounted();
  wrapSetLang();

  const observer = new MutationObserver((mutations) => {
    if (disposed) return;
    wrapSetLang();
    syncLanguageState();
    if (currentLang !== 'zh') return;

    for (const m of mutations) {
      const targetEl = m.target.nodeType === Node.ELEMENT_NODE ? m.target : m.target.parentElement;
      if (targetEl && targetEl.closest('[data-agy-zh-thought], [data-agy-hans-ui]')) {
        continue;
      }

      if (m.type === 'characterData') {
        pendingRoots.add(m.target);
        if (targetEl && targetEl.closest('[role="group"] [data-markdown-root]')) {
          const trig = findEnclosingThinkingTrigger(targetEl);
          if (trig) pendingTriggers.add(trig);
        }
      } else if (m.type === 'attributes') {
        if (m.attributeName === 'aria-expanded' && m.target.nodeType === Node.ELEMENT_NODE && m.target.getAttribute('data-testid') === 'thinking-collapsible-trigger') {
          pendingTriggers.add(m.target);
        }
      } else if (m.type === 'childList') {
        for (const added of m.addedNodes) {
          if (added.nodeType === Node.ELEMENT_NODE && added.matches && added.matches('[data-agy-zh-thought], [data-agy-hans-ui]')) {
            continue;
          }
          pendingRoots.add(added);
          if (added.nodeType === Node.ELEMENT_NODE && added.querySelector) {
            const innerOpen = added.querySelectorAll('button[data-testid="thinking-collapsible-trigger"][aria-expanded="true"]');
            for (const b of innerOpen) pendingTriggers.add(b);
          }
          const enclosingTrig = findEnclosingThinkingTrigger(added);
          if (enclosingTrig) pendingTriggers.add(enclosingTrig);
        }
        // If our bilingual span was removed while block stays connected, re-check its enclosing trigger
        for (const removed of m.removedNodes) {
          if (removed.nodeType === Node.ELEMENT_NODE && removed.hasAttribute && removed.hasAttribute('data-agy-zh-thought')) {
            const enclosingTrig = findEnclosingThinkingTrigger(m.target);
            if (enclosingTrig) pendingTriggers.add(enclosingTrig);
          }
        }
      }
    }

    if (pendingRoots.size > 0 || pendingTriggers.size > 0) {
      requestBatchScan(null, false);
    }
  });

  function start() {
    if (disposed) return;
    ensureStyleMounted();
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
      attributeFilter: ['aria-expanded']
    });
    requestBatchScan(document.body || document, true);
  }

  const onClickSync = () => {
    window.setTimeout(syncLanguageState, 30);
  };
  document.addEventListener('click', onClickSync, true);

  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }

  window.__agyThoughtAddonCleanup = (removeThoughtSpans) => {
    disposed = true;
    observer.disconnect();
    document.removeEventListener('click', onClickSync, true);
    if (saveCacheTimer !== null) {
      clearTimeout(saveCacheTimer);
      saveCacheTimer = null;
    }
    for (const st of mdDebounceStates.values()) {
      clearTimeout(st.timer);
    }
    mdDebounceStates.clear();
    while (requestQueue.length > 0) {
      const j = requestQueue.shift();
      if (j) j.resolve('');
    }
    for (const ctrl of Array.from(activeAbortControllers)) {
      try { ctrl.abort(); } catch (_e) {}
    }
    activeAbortControllers.clear();
    restoreAllActionLabels(Boolean(removeThoughtSpans));
    if (installedWrapper && window.__antigravityZhSetLang === installedWrapper && typeof origSetLang === 'function') {
      window.__antigravityZhSetLang = origSetLang;
    }
    if (removeThoughtSpans) {
      const st = document.getElementById(STYLE_ID);
      if (st) st.remove();
    }
    window.__agyThoughtAddonInstalled = false;
  };
})();
/* === AGY_THOUGHT_TRANSLATOR_ADDON_END === */
