// Ghaemiyeh Book Collector — content script (PCM-EXT-05)
// Runs on ghaemiyeh.ir pages. Extracts the LIVE DOM (covers pages that the
// service worker's fetch cannot see, e.g. dynamic content) and answers the
// popup's `ghExtractCurrentPage` request.

(function () {
  'use strict';

  function textOf(el) {
    return (el && (el.innerText || el.textContent) || '').replace(/\s+/g, ' ').trim();
  }

  function cleanTitle(s) {
    return String(s || '')
      .replace(/\s+/g, ' ')
      .replace(/\b(download|دانلود)\b[\s.]*$/i, '')
      .replace(/^[\s.·•|-]+|[\s.·•|-]+$/g, '')
      .trim();
  }

  function bookIdFromHref(href) {
    const m = String(href || '').match(/show-book\/(\d+)/);
    return m ? m[1] : null;
  }

  function downloadIdFromHref(href) {
    const m = String(href || '').match(/library\/download\/(\d+)/);
    return m ? m[1] : null;
  }

  function absUrl(href) {
    try {
      return new URL(href, window.location.href).href;
    } catch (_) {
      return null;
    }
  }

  function ownerBookId(a, books) {
    let card = a.closest ? a.closest('li,tr,article,div,td') : a.parentElement;
    let depth = 0;
    while (card && depth < 8) {
      const links = card.querySelectorAll ? card.querySelectorAll('a[href]') : [];
      for (const b of links) {
        const bid = bookIdFromHref(b.getAttribute ? b.getAttribute('href') : '');
        if (bid && books.has(bid)) return bid;
      }
      card = card.parentElement || null;
      depth += 1;
    }
    return null;
  }

  function extract() {
    const books = new Map();
    const orphans = [];
    const anchors = document.querySelectorAll('a[href]');

    for (const a of anchors) {
      const href = a.getAttribute('href') || '';
      const bid = bookIdFromHref(href);
      if (!bid) continue;
      const url = absUrl(href);
      if (!url) continue;
      const title = cleanTitle(textOf(a));
      const prev = books.get(bid);
      if (!prev) {
        books.set(bid, {
          book_id: bid,
          title: title || 'کتاب ' + bid,
          url,
          download_url: null,
        });
      } else if (!prev.title && title) {
        prev.title = title;
      }
    }

    for (const a of anchors) {
      const href = a.getAttribute('href') || '';
      const did = downloadIdFromHref(href);
      if (!did) continue;
      const url = absUrl(href);
      if (!url) continue;
      const bid = ownerBookId(a, books);
      if (bid) {
        const bk = books.get(bid);
        if (bk && !bk.download_url) bk.download_url = url;
      } else {
        orphans.push({ download_id: did, url });
      }
    }

    // Page context (category pages) — title of the page itself
    let page = '';
    const h1 = document.querySelector('h1, .category-title, .page-title');
    if (h1) page = textOf(h1);
    const t = document.querySelector('title');
    if (!page && t) page = textOf(t);

    return {
      page_url: window.location.href,
      page_title: page,
      books: [...books.values()],
      orphans,
    };
  }

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg && msg.action === 'ghExtract') {
      try {
        sendResponse({ ok: true, data: extract() });
      } catch (e) {
        sendResponse({ ok: false, message: String(e) });
      }
      return true;
    }
    if (msg && msg.action === 'ping') {
      sendResponse({ ok: true, url: window.location.href });
      return true;
    }
    return false;
  });
})();
