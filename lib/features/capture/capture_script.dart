/// 注入到每个页面的抓取脚本。设计文档第 6 节。
///
/// 三路并行汇入同一个聚合器：
/// 1. PerformanceObserver（resource）→ 覆盖 JS 动态加载的图片；
/// 2. MutationObserver（childList / src / srcset / style / class）→ 覆盖懒加载与背景图；
/// 3. 全量 DOM 扫描 → img.currentSrc、srcset 最大候选、CSS 背景图、picture>source、svg>image。
///
/// 只上报 http/https URL；data: 与 blob: 不上报（不可下载）。
const String kCaptureScript = r'''
(function () {
  if (window.__imgcat) return;

  var SOURCE_RANK = { dynamic: 0, cssBackground: 1, srcset: 2, img: 3 };
  var IMG_EXT = /\.(jpe?g|png|gif|webp|svg|avif|bmp|ico)(\?|#|$)/i;
  var HANDLER = 'imgcat';

  var seen = Object.create(null);
  var pending = Object.create(null);
  var pendingCount = 0;
  var cssPassNeeded = true;
  var rescanTimer = null;
  var running = false;
  var aborted = false;

  // ---------- 桥就绪管理：AT_DOCUMENT_START 注入时 bridge 还没好，先排队 ----------
  var ready = false;
  var outbox = [];

  function bridgeAvailable() {
    return !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler);
  }

  function post(payload) {
    if (!ready) { outbox.push(payload); return; }
    try {
      window.flutter_inappwebview.callHandler(HANDLER, JSON.stringify(payload));
    } catch (e) { /* 桥断了就丢弃这一批，不阻塞页面 */ }
  }

  function markReady() {
    if (ready || !bridgeAvailable()) return;
    while (outbox.length) {
      try {
        window.flutter_inappwebview.callHandler(HANDLER, JSON.stringify(outbox[0]));
      } catch (e) { return; } // 发送失败就把队首留在队列里，下个 tick 再试
      outbox.shift();
    }
    ready = true;
  }

  window.addEventListener('flutterInAppWebViewPlatformReady', markReady);
  // 轮询必须持续到 ready 为真：仅凭「桥对象存在」就停表，会在
  // 「对象存在但 callHandler 尚不可用、且就绪事件被错过」时让 outbox 永久卡死。
  var readyTimer = setInterval(function () {
    if (ready) { clearInterval(readyTimer); return; }
    markReady();
  }, 100);
  setTimeout(function () { clearInterval(readyTimer); }, 10000);

  function waitForBridge(timeoutMs) {
    return new Promise(function (resolve, reject) {
      var start = Date.now();
      (function tick() {
        if (ready) return resolve();
        if (Date.now() - start > timeoutMs) return reject(new Error('bridge-timeout'));
        setTimeout(tick, 100);
      })();
    });
  }

  // ---------- URL 归一化 ----------
  function normalize(u) {
    if (!u) return null;
    var s = String(u).trim();
    if (!s || s.indexOf('data:') === 0 || s.indexOf('blob:') === 0) return null;
    try {
      var abs = new URL(s, location.href).href;
      if (abs.indexOf('http://') !== 0 && abs.indexOf('https://') !== 0) return null;
      return abs;
    } catch (e) { return null; }
  }

  // ---------- 聚合 ----------
  function collect(u, source, w, h, size, mime) {
    var url = normalize(u);
    if (!url) return;
    var entry = seen[url];
    if (entry) {
      // 只有信息真的变了才重新入 pending；否则每轮扫描都会把全量快照重推一遍桥。
      var changed = false;
      if (SOURCE_RANK[source] > SOURCE_RANK[entry.source]) { entry.source = source; changed = true; }
      if (w != null && h != null && (entry.w == null || entry.w < w)) { entry.w = w; entry.h = h; changed = true; }
      if (size != null && entry.size == null) { entry.size = size; changed = true; }
      if (mime != null && entry.mime == null) { entry.mime = mime; changed = true; }
      if (!changed) return;
    } else {
      seen[url] = { url: url, source: source, w: w, h: h, size: size, mime: mime };
    }
    if (!pending[url]) { pending[url] = true; pendingCount++; }
  }

  function countAssets() {
    var n = 0;
    for (var k in seen) n++;
    return n;
  }

  function flush() {
    if (pendingCount === 0) return;
    var assets = [];
    for (var url in pending) {
      delete pending[url];
      var e = seen[url];
      assets.push({ url: e.url, w: e.w, h: e.h, size: e.size, mime: e.mime, source: e.source });
    }
    pendingCount = 0;
    post({ type: 'batch', pageUrl: location.href, assets: assets });
  }

  // ---------- 三路采集源 ----------
  function urlsInBackgroundImage(value) {
    var out = [];
    if (!value || value === 'none') return out;
    var re = /url\((['"]?)([^'")]+)\1\)/g;
    var m;
    while ((m = re.exec(value)) !== null) { if (m[2]) out.push(m[2]); }
    return out;
  }

  function pickFromSrcset(srcset) {
    if (!srcset) return null;
    var parts = String(srcset).split(',');
    var best = null;
    var bestW = -1;
    for (var i = 0; i < parts.length; i++) {
      var fields = parts[i].trim().split(/\s+/);
      if (!fields[0]) continue;
      var w = -1;
      if (fields.length > 1) {
        var d = fields[1].toLowerCase();
        var body = d.substring(0, d.length - 1);
        if (d.charAt(d.length - 1) === 'w') w = parseInt(body, 10);
        else if (d.charAt(d.length - 1) === 'x') w = Math.round(parseFloat(body) * 1000);
      }
      if (isNaN(w)) w = -1;
      // 并列时取先出现的，与 lib/features/capture/srcset.dart 的 pickLargest 保持一致。
      if (best === null || w > bestW) {
        bestW = w;
        best = { url: fields[0], width: w < 0 ? null : w };
      }
    }
    return best;
  }

  /// includeCssPass 为 false 时跳过 CSS 背景图全量遍历（代价高，只在必要时跑）。
  function scanImages(includeCssPass) {
    var imgs = document.images;
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      var best = pickFromSrcset(img.getAttribute('srcset'));
      if (best) {
        collect(best.url, 'srcset', best.width, null, null, null);
      } else {
        collect(img.currentSrc || img.src, 'img', img.naturalWidth || null, img.naturalHeight || null, null, null);
      }
    }
    var media = document.querySelectorAll('picture source, svg image');
    for (var s = 0; s < media.length; s++) {
      var el = media[s];
      var best2 = pickFromSrcset(el.getAttribute('srcset'));
      if (best2) collect(best2.url, 'srcset', best2.width, null, null, null);
      var href = el.getAttribute('href') || el.getAttribute('xlink:href');
      if (href) collect(href, 'img', el.naturalWidth || null, el.naturalHeight || null, null, null);
    }
    if (!includeCssPass) return;
    var all = document.querySelectorAll('*');
    for (var j = 0; j < all.length; j++) {
      var bg = getComputedStyle(all[j]).backgroundImage;
      if (!bg || bg === 'none') continue;
      var urls = urlsInBackgroundImage(bg);
      for (var k = 0; k < urls.length; k++) collect(urls[k], 'cssBackground', null, null, null, null);
    }
  }

  function scheduleRescan(includeCssPass) {
    if (includeCssPass) cssPassNeeded = true;
    if (rescanTimer) return;
    rescanTimer = setTimeout(function () {
      rescanTimer = null;
      var withCss = cssPassNeeded;
      cssPassNeeded = false;
      scanImages(withCss);
      flush();
    }, 300);
  }

  // 1) PerformanceObserver：覆盖 JS 动态加载的图片
  try {
    var po = new PerformanceObserver(function (list) {
      var entries = list.getEntries();
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var isImageRequest = e.initiatorType === 'img' || IMG_EXT.test(e.name);
        if (!isImageRequest) continue;
        collect(e.name, 'dynamic', null, null, e.transferSize || e.decodedBodySize || null, null);
      }
      scheduleRescan(false);
    });
    try {
      po.observe({ type: 'resource', buffered: true });
    } catch (e) {
      // Chrome 52~65 只认 entryTypes（单 type + buffered 的形态要 Chrome 66+），
      // 不退回这一形态的话整个 PO 路径会被外层 catch 静默吞掉。
      // 拿不到 buffered 回放，但脚本在文档开始注入，后续动态请求仍能覆盖。
      po.observe({ entryTypes: ['resource'] });
    }
  } catch (e) { /* 引擎完全没有 PerformanceObserver 时降级为纯 DOM 扫描 */ }

  // 2) MutationObserver：覆盖懒加载与背景图切换
  try {
    var mo = new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var m = mutations[i];
        if (m.type === 'attributes' || (m.addedNodes && m.addedNodes.length)) {
          scheduleRescan(true);
          return;
        }
      }
    });
    mo.observe(document.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['src', 'srcset', 'style', 'class', 'data-src']
    });
  } catch (e) { /* 忽略 */ }

  // ---------- 自动扫整页 ----------
  function waitForImages(timeoutMs) {
    return new Promise(function (resolve) {
      var start = Date.now();
      (function tick() {
        var pendingImgs = 0;
        for (var i = 0; i < document.images.length; i++) {
          if (!document.images[i].complete) pendingImgs++;
        }
        if (pendingImgs === 0 || Date.now() - start > timeoutMs) return resolve();
        setTimeout(tick, 50);
      })();
    });
  }

  function isAtBottom() {
    var doc = document.documentElement;
    return window.scrollY + window.innerHeight >= doc.scrollHeight - 4;
  }

  async function scan(opts) {
    opts = opts || {};
    if (running) return { ok: false, reason: 'already-running' };
    running = true;
    aborted = false;
    var maxScreens = opts.maxScreens || 40;
    var timeoutMs = opts.timeoutMs || 60000;
    var deadline = Date.now() + timeoutMs;
    var pageUrl = location.href;
    var startY = window.scrollY;
    var screen = 0;
    var limited = false;

    post({ type: 'scan', state: 'start', pageUrl: pageUrl, screen: 0, maxScreens: maxScreens, found: countAssets() });
    scanImages(true);
    flush();

    try {
      for (screen = 1; screen <= maxScreens; screen++) {
        if (aborted) {
          post({ type: 'scan', state: 'aborted', pageUrl: pageUrl, screen: screen - 1, maxScreens: maxScreens, found: countAssets() });
          return { ok: true, aborted: true };
        }
        window.scrollBy(0, Math.max(1, Math.floor(window.innerHeight * 0.9)));
        await waitForImages(600);
        scanImages(screen === 1);
        flush();
        post({ type: 'scan', state: 'progress', pageUrl: pageUrl, screen: screen, maxScreens: maxScreens, found: countAssets() });
        if (Date.now() >= deadline) { limited = true; break; }
        if (isAtBottom()) break;
      }
      if (screen > maxScreens) limited = true;
    } finally {
      aborted = false;
      running = false;
      window.scrollTo(0, startY);
    }

    scanImages(true);
    flush();
    post({
      type: 'scan',
      state: limited ? 'limit' : 'done',
      pageUrl: pageUrl,
      screen: Math.min(screen, maxScreens),
      maxScreens: maxScreens,
      found: countAssets()
    });
    return { ok: true, limited: limited };
  }

  // ---------- 下载：页面内 fetch 取 blob，512KB 分块回传 ----------
  function bytesToBase64(bytes) {
    var step = 0x8000;
    var out = '';
    for (var i = 0; i < bytes.length; i += step) {
      out += String.fromCharCode.apply(null, bytes.subarray(i, i + step));
    }
    return btoa(out);
  }

  async function fetchAsBase64(opts) {
    opts = opts || {};
    var id = opts.id;
    var chunkSize = opts.chunkSize || 524288;
    try {
      await waitForBridge(5000);
      var res = await fetch(opts.url, { credentials: 'include', referrer: location.href });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      var bytes = new Uint8Array(await res.arrayBuffer());
      var mime = res.headers.get('content-type') || null;
      if (bytes.length === 0) {
        await window.flutter_inappwebview.callHandler(HANDLER, JSON.stringify({
          type: 'blob', id: id, seq: 0, data: '', last: true, mime: mime
        }));
        return { ok: true, length: 0 };
      }
      var seq = 0;
      for (var off = 0; off < bytes.length; off += chunkSize) {
        var slice = bytes.subarray(off, Math.min(off + chunkSize, bytes.length));
        var isLast = off + chunkSize >= bytes.length;
        await window.flutter_inappwebview.callHandler(HANDLER, JSON.stringify({
          type: 'blob', id: id, seq: seq++, data: bytesToBase64(slice), last: isLast, mime: mime
        }));
      }
      return { ok: true, length: bytes.length };
    } catch (e) {
      post({ type: 'blob', id: id, seq: 0, data: '', last: true, error: String((e && e.message) || e) });
      return { ok: false };
    }
  }

  window.__imgcat = {
    scan: scan,
    abort: function () { aborted = true; return { ok: true }; },
    fetchAsBase64: fetchAsBase64,
    rescan: function () { scanImages(true); flush(); return { ok: true, count: countAssets() }; },
    assets: function () { var out = []; for (var k in seen) out.push(k); return out; }
  };

  scheduleRescan(true);
})();
''';
