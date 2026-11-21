// Content Script for farsi.khamenei.ir
// Priority: main speech text (div.Content) + page URL + links/metadata

const BACKEND = 'https://corpus.ai.ismc.ir';
let lastUrl = '';
let extracting = false;

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.action === 'extractCurrentPage') {
    extractAndSubmit().then((result) => sendResponse(result || { ok: true }));
    return true;
  }
  if (msg.action === 'discoverSpeechIds') {
    discoverIds().then((result) => sendResponse(result || { ok: true }));
    return true;
  }
  if (msg.action === 'ping') {
    sendResponse({ ok: true, url: location.href });
    return true;
  }
  return false;
});

setInterval(() => {
  if (window.location.href !== lastUrl && !extracting) {
    lastUrl = window.location.href;
    setTimeout(() => extractAndSubmit(), 1200);
  }
}, 1500);

function xpathFirst(expr) {
  try {
    const r = document.evaluate(expr, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
    return r.singleNodeValue;
  } catch (_) {
    return null;
  }
}

function textOf(el) {
  if (!el) return '';
  return (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
}

/** Convert Persian/Arabic-Indic digits → ASCII so ۱۴۰۴/۰۱/۰۱ → 1404/01/01 */
function toAsciiDigits(s) {
  const map = {
    '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4',
    '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9',
    '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4',
    '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9',
  };
  return String(s || '').replace(/[۰-۹٠-٩]/g, (d) => map[d] || d);
}

/** Prefer span.oliveDate (Jalali), then meta block */
function extractJalaliDate(metaText) {
  const olive = document.querySelector('span.oliveDate, .oliveDate');
  if (olive) {
    const m = toAsciiDigits(textOf(olive)).match(/(\d{4}\/\d{2}\/\d{2})/);
    if (m) return m[1];
  }
  const raw = toAsciiDigits(metaText || document.body.innerText || '');
  const m2 = raw.match(/(\d{4}\/\d{2}\/\d{2})/);
  return m2 ? m2[1] : '';
}

// Main-list item: anchor to speech-content whose FIRST inner element is a
// date span (class skyText, "YYYY/MM/DD" — Persian digits possible).
// Sidebar widgets ("پیشنهاد ما", li.hpList) link to speeches WITHOUT a date
// span — they must NOT be seeded (they belong to other years).
function datedSpeechLinks() {
  const out = [];
  document.querySelectorAll('a[href*="speech-content"]').forEach((link) => {
    const href = link.getAttribute('href') || '';
    const match = href.match(/speech-content\?id=(\d+)/);
    if (!match) return;
    const span = link.firstElementChild;
    if (!span || !/skyText/i.test(span.className || '')) return;
    const date = toAsciiDigits(textOf(span)).match(/(\d{4})\/(\d{2})\/(\d{2})/);
    if (!date) return;
    out.push({ id: match[1], date: `${date[1]}/${date[2]}/${date[3]}`, link });
  });
  return out;
}

function allSpeechLinks() {
  const ids = new Set();
  document.querySelectorAll('a[href*="speech-content"]').forEach((link) => {
    const href = link.getAttribute('href') || '';
    const match = href.match(/speech-content\?id=(\d+)/);
    if (match) ids.add(match[1]);
  });
  return [...ids];
}

function maxYearOf(dates) {
  let max = 0;
  for (const d of dates) {
    const m = d.match(/(\d{4})/);
    if (m && parseInt(m[1], 10) > max) max = parseInt(m[1], 10);
  }
  return max || null;
}

async function discoverIds() {
  console.log('[Khamenei] Discovering speech IDs...');

  // Primary: dated main-list items only (one year = one complete list page).
  const dated = datedSpeechLinks();
  let idList;
  let titles = {};
  if (dated.length > 0) {
    idList = [...new Set(dated.map((d) => d.id))];
    for (const d of dated) titles[d.id] = textOf(d.link).slice(0, 200);
  } else {
    // Fallback (layout change / unrelated page): every speech-content anchor.
    idList = allSpeechLinks();
  }

  // maxYear: from item dates, else the year= param of the current URL.
  const dates = dated.map((d) => d.date);
  const urlYear = (location.href.match(/[?&]year=(\d{4})/) || [])[1] || null;
  const maxYear = maxYearOf(dates) || urlYear || null;

  if (idList.length === 0) {
    console.warn('[Khamenei] No speech IDs found on page');
    chrome.runtime.sendMessage({
      action: 'khameneiListScanned',
      seeded: 0,
      duplicates: 0,
      total: 0,
      maxYear: maxYear,
    });
    return { ok: false, message: 'هیچ لینک بیانی در این صفحه پیدا نشد', seeded: 0 };
  }

  console.log(`[Khamenei] Found ${idList.length} IDs (maxYear=${maxYear || '-'})`);
  try {
    const items = idList.map((id) => ({
      url: `https://farsi.khamenei.ir/speech-content?id=${id}`,
      item_id: id,
      page_type: 'khamenei_speech',
      title: titles[id] || `Speech #${id}`,
      source_page: location.href,
    }));
    const r = await fetch(`${BACKEND}/api/phase1/seed-batch`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ site: 'khamenei', items }),
    });
    const result = await r.json();
    console.log(`[Khamenei] Phase1 seeded ${result.added} (dup ${result.duplicates})`);
    chrome.runtime.sendMessage({
      action: 'khameneiListScanned',
      seeded: result.added,
      duplicates: result.duplicates,
      total: idList.length,
      maxYear: maxYear,
    });
    return { ok: true, seeded: result.added, duplicates: result.duplicates, total: idList.length, maxYear };
  } catch (e) {
    console.error('[Khamenei] Seed error:', e);
    return { ok: false, message: String(e) };
  }
}

async function extractAndSubmit() {
  if (extracting) return { ok: false, message: 'busy' };
  extracting = true;

  try {
    const url = window.location.href;

    if (url.includes('speech-content')) {
      const speech = extractSpeechDetail();
      if (!speech || !speech.content) {
        console.warn('[Khamenei] Empty content — possible block or layout change');
        chrome.runtime.sendMessage({
          action: 'khameneiExtractResult',
          status: 'empty',
          speech_id: speech?.speech_id || null,
          url
        });
        return { ok: false, status: 'empty', message: 'متن بیان خالی بود' };
      }

      console.log(`[Khamenei] Extracted #${speech.speech_id}: ${speech.title} (${speech.char_count} chars)`);
      const r = await fetch(`${BACKEND}/api/phase2/complete`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ site: 'khamenei', ...speech })
      });
      const result = await r.json();
      console.log(`[Khamenei] ✅ ${result.status}: ${speech.title}`);
      chrome.runtime.sendMessage({
        action: 'khameneiExtractResult',
        status: result.status,
        speech_id: speech.speech_id,
        title: speech.title,
        char_count: speech.char_count,
        url
      });
      return { ok: true, status: result.status, speech };
    }

    if (url.match(/\/speech(\?|$|#)/) || url.includes('/speech?')) {
      const disc = await discoverIds();
      return disc;
    }

    return { ok: false, message: 'این صفحه بیان نیست' };
  } catch (e) {
    console.error('[Khamenei] Error:', e);
    chrome.runtime.sendMessage({ action: 'khameneiExtractResult', status: 'error', error: String(e) });
    return { ok: false, message: String(e) };
  } finally {
    extracting = false;
  }
}

function extractSpeechDetail() {
  const idMatch = window.location.href.match(/[?&]id=(\d+)/);
  if (!idMatch) return null;
  const speechId = idMatch[1];
  const pageUrl = window.location.href.split('#')[0];

  let title = '';
  const titleTag = document.querySelector('title');
  if (titleTag) {
    title = titleTag.textContent.trim();
    title = title.replace(/\s*[-–|]\s*KHAMENEI\.IR.*$/i, '').trim();
    title = title.replace(/\s*[-–|]\s*پایگاه.*$/i, '').trim();
    title = title.replace(/\s*[-–|]\s*farsi\.khamenei\.ir.*$/i, '').trim();
  }
  if (!title) {
    const h1 = document.querySelector('h1, .title, .speech-title');
    if (h1) title = textOf(h1);
  }

  // Metadata block: //*[@id="newsContentInnerSide"]/div[2]/div[1]/div
  const metaNode =
    xpathFirst('//*[@id="newsContentInnerSide"]/div[2]/div[1]/div') ||
    xpathFirst('//*[@id="newsContentInnerSide"]//div[contains(@class,"")][1]');
  const metaText = textOf(metaNode);
  const date = extractJalaliDate(metaText);
  const year = date ? date.slice(0, 4) : '';

  // Priority: class="Content" main body
  let content = '';
  const contentEl =
    document.querySelector('#newsContentInnerSide div.Content') ||
    document.querySelector('div.Content') ||
    xpathFirst('//*[@id="newsContentInnerSide"]//div[@class="Content"]');

  if (contentEl) {
    content = textOf(contentEl);
  }
  if (!content) {
    const newsDiv = document.getElementById('newsContentInnerSide');
    if (newsDiv) content = textOf(newsDiv);
  }

  // Strip leading date (ASCII or Persian digits) from content body
  if (date) {
    const asciiContent = toAsciiDigits(content);
    if (asciiContent.startsWith(date)) {
      // remove same length prefix from original (digits are 1:1)
      content = content.substring(date.length).trim();
    }
  }

  let audioUrl = '';
  const audioLink = document.querySelector('a[href*="audio-content"], a[href*="sound"], audio source');
  if (audioLink) {
    const href = audioLink.getAttribute('href') || audioLink.getAttribute('src') || '';
    if (href) audioUrl = href.startsWith('http') ? href : `https://farsi.khamenei.ir${href}`;
  }

  let videoUrl = '';
  const videoLink = document.querySelector('a[href*="video-content"], a[href*="film"]');
  if (videoLink) {
    const href = videoLink.getAttribute('href') || '';
    if (href) videoUrl = href.startsWith('http') ? href : `https://farsi.khamenei.ir${href}`;
  }

  const tags = [];
  document.querySelectorAll('.topmenu-tag, a[title]').forEach((el) => {
    const t = el.getAttribute('title');
    if (t && t !== 'کلیدواژه' && t.length > 2 && t.length < 80) tags.push(t);
  });

  // Outgoing speech links on page (for graph / discovery)
  const relatedLinks = [];
  document.querySelectorAll('a[href*="speech-content?id="]').forEach((a) => {
    const href = a.getAttribute('href') || '';
    const m = href.match(/id=(\d+)/);
    if (!m) return;
    const abs = href.startsWith('http') ? href : `https://farsi.khamenei.ir${href.startsWith('/') ? '' : '/'}${href}`;
    relatedLinks.push({ speech_id: m[1], url: abs, title: textOf(a).slice(0, 200) });
  });

  // Other download / media links near content
  const extraLinks = [];
  document.querySelectorAll('#newsContentInnerSide a[href]').forEach((a) => {
    const href = a.getAttribute('href') || '';
    if (!href || href.startsWith('#') || href.startsWith('javascript:')) return;
    const abs = href.startsWith('http') ? href : `https://farsi.khamenei.ir${href.startsWith('/') ? '' : '/'}${href}`;
    extraLinks.push({ url: abs, text: textOf(a).slice(0, 120) });
  });

  return {
    speech_id: speechId,
    url: pageUrl,
    title,
    date,
    year,
    content,
    meta_text: metaText,
    audio_url: audioUrl,
    video_url: videoUrl,
    tags: [...new Set(tags)],
    related_links: relatedLinks,
    extra_links: extraLinks.slice(0, 50),
    char_count: content.length,
  };
}

console.log('[Khamenei Content] Ready on', window.location.href);
