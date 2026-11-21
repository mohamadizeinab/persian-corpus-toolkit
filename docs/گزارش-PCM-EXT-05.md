# گزارش PCM-EXT-05 — اکستنشن جمع‌آوری کتب غایمیه (تریس، دانلود، کالکشن)

تاریخ: ۱۴۰۵/09/30 (2026-11-21) · شاخه: `pcm-20.9-knowledge-studio-factory`
Commit کد: `2ca1e3f204354b9cdca828c0e23f265635ed5f8c` · نسخه اکستنشن جدید: **Ghaemiyeh Book Collector 1.0**

## ۱. وضعیت قبل و درخواست

درخواست:
> «اگر بتونیم اکشنشن دیگری بنویسیم روی کروم که مخصوص سایت غایمیه باشه که لینک
> اصلی کتاب رو بگیره و مجموعه کتب یک فرد رو تریس کنه و همه کتاب‌ها رو دانلود
> کنه و به یک کالکشن اضافه کنه خیلی خوبه»

با URLهای نمونه:
- فهرست کتب یک نفر: `https://www.ghaemiyeh.ir/category-page?category=51636`
- صفحهٔ اصلی کتاب: `https://www.ghaemiyeh.ir/show-book/349117`
- لینک دانلود: `https://www.ghaemiyeh.ir/library/download/5970520`
- خوانندهٔ کتاب: `https://www.ghaemiyeh.ir/ebook-reader/349117`
- deep-link صفحه/بخش: `ebook-reader/349117?page=42&sectionId=5188&section=0`

**نتیجه‌ی ممیزی قبل از شروع:**
1. هیچ سند یا کد قبلی برای غایمیه در ریپازیتوری نبود (0 hit). تنها ردپاها:
   - `.recon/shim/book_titles.json`: `book_349117_vUkPFY.docx` = «درس‌های پیامبر اعظم (صلی الله علیه و آله)» — یعنی کتاب نمونهٔ 349117 همین عنوان است.
   - `.recon/pcm23_s53_wire.sh`: کورپس RAG خامنه‌ای = «13 کتاب (ghaemiyeh)» — یعنی غایمیه همان منبع بالادستی پیکرهٔ خامنه‌ای است.
2. **پیدا بودن سایت از سرورها:** edge غایمیه TLS کلاینت‌های غیرمرورگری را رد
   می‌کند (سایز کوچک ClientHello / fingerprint): از s52 (curl 7.64 + OpenSSL 3.0 +
   python urllib) و از operator box (curl WinHTTP/schannel + PowerShell) همه
   `UNEXPECTED_EOF_WHILE_READING` — در حالی که مرورگر کاربر کار می‌کند.
   **نتیجهٔ طراحی:** کل شبکه (دریافت HTML، دانلود فایل، آپلود) باید داخل
   مرورگر کاربر انجام شود — یعنی service worker اکستنشن (TLS همان مرورگر).
   هیچ fetch سمت سرور امکان‌پذیر نیست (مگر با proxy مرورگری؛ خارج از scope).
3. APIهای مقصد (همان backend زندهٔ `corpus.ai.ismc.ir`):
   - `POST /api/knowledge/collections` — ساخت کالکشن (name+slug؛ auth)
   - `POST /api/knowledge/collections/<id>/documents` — آپلود DOCX (multipart
     `file`، ≤50MB، auth؛ 409 برای SHA تکراری)
   - `GET /api/knowledge/collections` — فهرست (auth)
   - auth = کوکی `pct_session` (HttpOnly, Secure, SameSite=Lax) روی
     `corpus.ai.ismc.ir`؛ SW با `host_permissions` + `credentials:'include'`
     همان کوکی کاربر را می‌فرستد → بدون فرم ورود جداگانه.
   - `CORS(app)` (flask-cors) در server.py باز است.

## ۲. تحلیل

### ۲.۱. مدل دادهٔ سایت (از الگوهای URL + شواهد موجود)
- شناسهٔ کتاب (`book_id`) در مسیرها: `show-book/<id>`, `ebook-reader/<id>`.
- شناسهٔ فایل/دانلود (`file_id`) در `library/download/<id>` — **فضای شناسهٔ
  جدا** است (5970520 ≠ 349117)؛ یعنی لینک دانلود نمی‌تواند از book_id ساخته
  شود و حتماً باید از HTML صفحه **کشف** شود.
- فهرست کتب یک شخص: `category-page?category=<id>` (احتمالاً pagination با پارامتر صفحه).
- خروجی فایل‌ها DOCX است (تأییدشده از نام فایل‌های راجع‌شده در p105/p117:
  `book_349117_vUkPFY.docx`).

### ۲.۲. چرخهٔ کار (workflow)
```
[کاربر: URL دسته/نفر را می‌چسباند] (یا همین تب اگر غایمیه است)
   → SW: دریافت HEADless صفحه‌ها (fetch + DOMParser، با کوکی‌های کاربر)
   → استخراج: همهٔ a[href*="show-book/"]  ← «لینک اصلی کتاب»
   → استخراج: همهٔ a[href*="library/download/"] + نسبت‌سازی هرکدام به کارت کتابش
   → pagination: دنبال‌کردن صفحه‌های بعد تا آخرین (حد امن 200 صفحه)
   → جدول کتاب‌ها در پنل (title / book_id / download_url / وضعیت)
   → [کاربر: انتخاب کتاب‌ها + انتخاب/ساخت کالکشن]
   → صف دانلود+آپلود (یکی‌در-یک، تأخیر 3s، قابل توقف/ادامه):
       1) download_url مستقیم → fetch → Blob → FormData → POST documents
       2) نبود لینک مستقیم → fetch show-book/<id> → استخراج → همان 1
       3) باز هم نبود → open tab show-book + وضعیت need-manual
       4) fallback نهایی: کاربر دستی دانلود کند → «آپلود فایل دانلودشده» در پنل
   → 409 (SHA تکراری) = «قبلا در کالکشن بود» (نه خطا)
   → 401 = «اول وارد داشبورد شوید» (queue تمیز stop)
```

### ۲.۳. چرا «پکیج جدا» (extension-ghaemiyeh) و نه ماژولِ اکستنشن فعلی؟
1. درخواست کاربر صریح بود: **اکستنشن دیگری** مخصوص غایمیه.
2. اکستنشن فعلی (v3.9) در production روی s52 کراول زنده دارد؛ ریسک صفر برای آن
   اولویت است (قاعدهٔ AGENTS: APIهای نوشتاری اکستنشن باید باز/ثابت بمانند).
3. workflow متفاوت است: bulk download+upload، نه crawl صفحه‌به‌صفحه با points.
4. کوکی‌های auth به‌ازای هر *host* در مرورگر است؛ هر دو اکستنشن همان
   `pct_session` را با `credentials:'include'` می‌فرستند — ورود دوباره لازم نیست.

## ۳. طراحی

### ۳.۱. فایل‌ها
```
extension-ghaemiyeh/
  manifest.json        MV3، host_permissions: ghaemiyeh.ir (+www) و corpus.ai.ismc.ir
  background.js        SW: کشف headless (fetch+DOMParser) + صف دانلود/آپلود
  content.js           روی صفحات غایمیه: استخراج زنده (fallback برای صفحاتی که
                       fetch از SW کامل نمی‌دهد) + پاسخ به درخواست popup
  popup.html / popup.js UI: کالکشن، تریس، جدول کتاب‌ها، دانلود همه، توقف/ادامه،
                       آپلود دستی، لاگ زنده
  test_ghaemiyeh.js    تست‌های G1..G8 با stub (node vm، الگوی test_popup.js)
  icons/               همان آیکون‌ها (کپی از extension/icons)
  README.md            راه‌اندازی + روش استفاده
```

### ۳.۲. seam تست‌پذیر (background.js)
`createPipeline(deps)` — تابع خالص که با injection می‌سازد:
`deps = { fetchFn, storageGet, storageSet, openTab, sleep, now, log }`.
SW واقعی deps واقعی (chrome.*) می‌گذارد؛ تست‌ها stub. هیچ منطق شبکه/صف داخل
scope global نمی‌ماند → قابل آزمون بدون مرورگر.

### ۳.۳. قواعد استخراج
- `bookIdOf(href)`: `/show-book\/(\d+)/`
- `downloadIdOf(href)`: `/library\/download\/(\d+)/`
- نسبت‌سازی دانلود→کتاب: از anchor دانلود به بالا `closest('li,tr,.book,.item,div')`
  و جستجوی `a[href*="show-book/"]` در همان کارت. بدون کارت مشخص → دانلود
  «بی‌صاحب» (در حالت «دانلود همهٔ لینک‌های یافته» استفاده می‌شود).
- title: متن anchor، تمیز‌شده (whitespace collapse؛ حذف «دانلود» و مشابه).
- pagination: روی صفحهٔ category، لینک‌هایی که pathname همان صفحه است و
  `page=\d+` دارند → max(page) → walk ترتیبی؛ visited-set + حد 200 صفحه.

### ۳.۴. قواعد صف
- **یکی‌در-یک**؛ تأخیر پیش‌فرض 3000ms (در popup قابل تنظیم 0–30s).
- statusها: `queued | downloading | uploading | done | duplicate |
  unsupported | failed | need-manual | skipped`
- توقف: flag در storage (`ghStop`)؛ هر حلقه قبل از کتاب بعد چک می‌کند.
- resume: کل state صف (`ghQueue`) در `chrome.storage.local` mirror می‌شود؛
  بعد از close مرورگر، «ادامه» از اولین `queued` شروع می‌کند.
- 401 در هر مرحله = `auth-error` + stop (پیام «وارد داشبورد شوید»).
- نام فایل: از `Content-Disposition` (filename*= یا filename=)؛ نبود →
  `book_<book_id>.docx`. اگر پسوند ≠ `.docx` → `unsupported` (API فقط DOCX
  می‌پذیرد؛ ساختگی نمی‌سازیم).

### ۳.۵. امنیتی
- هیچ رمز/توکن در کد یا لاگ. auth فقط با کوکی مرورگر کاربر.
- خروجی DOM popup از `esc()` (الگوی موجود در dashboard).
- محدودیت‌های واقعی API (50MB، فقط .docx) به‌جای اعداد ساختگی به کاربر
  گزارش می‌شود.

## ۴. مهاجرت
**هیچ** — هیچ schema/DB سمت backend تغییر نکرده؛ همه endpointهای موجود و
ثابت استفاده می‌شوند. (قاعدهٔ 2 AGENTS: فقط افزایشی — اینجا صفر.)

## ۵. فایل/API

| فایل | وضعیت | نقش |
|---|---|---|
| `extension-ghaemiyeh/manifest.json` | جدید | MV3 v1.0 |
| `extension-ghaemiyeh/background.js` | جدید | pipeline خالص + SW wiring |
| `extension-ghaemiyeh/content.js` | جدید | استخراج زنده صفحه |
| `extension-ghaemiyeh/popup.html` | جدید | UI فارسی RTL |
| `extension-ghaemiyeh/popup.js` | جدید | منطق UI + آپلود دستی مستقیم |
| `extension-ghaemiyeh/test_ghaemiyeh.js` | جدید | G1..G8 |
| `extension-ghaemiyeh/icons/` | کپی | همان آیکون‌ها |
| `docs/گزارش-PCM-EXT-05.md` | جدید | همین سند |

APIهای مصرف‌شده (همه موجود، بدون تغییر):
`POST/GET /api/knowledge/collections`،
`POST /api/knowledge/collections/<id>/documents`،
`GET /api/knowledge/collections/<id>` (نمایش جزئیات).

## ۶. تست

```bash
cd extension-ghaemiyeh && node test_ghaemiyeh.js
```
- **G1** استخراج کتاب از stub-HTML (dedup، title، نسبت‌سازی دانلود)
- **G2** pagination: walk تا max-page + stop با visited/حد
- **G3** صف: 201 / 409 / 401 / 500 / فایل غیر-DOCX → وضعیت‌های درست
- **G4** توقف با flag وسط صف (کتاب بعدی اجرا نمی‌شود)
- **G5** resume: state از storage بازیابی، فقط `queued` باقی می‌مانند
- **G6** نام‌گذاری: Content-Disposition (filename* unicode) + fallback
- **G7** fallback show-book: نبود لینک مستقیم → fetch صفحهٔ کتاب → استخراج
- **G8** need-manual: هیچ لینکی نبود → open tab + وضعیت

تست‌های رگرسیون backend (228+) دست‌نخورده — این مأموریت backend را
لمس نکرده است.

## ۷. نتیجه production / deploy
- **بدون deploy backend** (هیچ تغییر سمت سرور نیست).
- اکستنشن: `chrome://extensions` → Developer mode → **Load unpacked** →
  پوشهٔ `extension-ghaemiyeh` (دوبار نصب شدن با اکستنشن فعلی بی‌ضرر است).
- تأیید زنده: فقط با مرورگر کاربر (edge سایت سرورها را می‌بندد — بند ۱).

## ۸. SHA + لینک
- commit: `2ca1e3f204354b9cdca828c0e23f265635ed5f8c` (branch `pcm-20.9-knowledge-studio-factory`)
- ریپازیتوری: GitLab `saberprojects/persian-corpus-toolkit`
- شاخه: `pcm-20.9-knowledge-studio-factory`

## ۹. git status
فقط فایل‌های `extension-ghaemiyeh/*` + همین سند + (در commit نهایی) پاک‌سازی
فایل‌های موقت `.recon` و scrub توکن‌ها.

## ۱۰. بکاپ / rollback
- rollback اکستنشن = حذف از `chrome://extensions` (هیچ state سمت سرور ندارد).
- state کلاینتی (`chrome.storage.local`) با prefix `gh` — حذف extension آن را پاک می‌کند.
- DB production: دست‌نخورده (read + document-insert فقط؛ backup دوره‌ای照常).

## ۱۱. موارد باقی‌مانده + روش تست دستی
باقي‌مانده:
- اگر سایت از `category-page` فقط «عنوان‌ها» بدهد و لینک‌های دانلود فقط روی
  `show-book` باشد → fallback G7 خودکار پوشش می‌دهد (fetch هر show-book).
- اگر برخی کتاب‌ها login در غایمیه لازم داشته باشند برای دانلود → کوکی‌های
  کاربر با `credentials:'include'` می‌روند؛ اگر باز هم نبود → need-manual.
- (اختیاری، بعدی) ثبت auto در Work Registry (work/edition) بعد از آپلود.

**روش تست دستی (مرورگر کاربر):**
1. `chrome://extensions` → Load unpacked → `extension-ghaemiyeh`.
2. وارد داشبورد شوید: `https://corpus.ai.ismc.ir/dashboard` (کوکی لازم است).
3. آیکون اکستنشن → بخش «کالکشن»: یا یکی را انتخاب کنید یا بسازید
   (مثلاً name=«کتب شخص X (غایمیه)»، slug=`ghaemiyeh-<slug>`).
4. URL صفحهٔ دسته را در باکس «آغاز تریس» بچسبانید (یا همان تب غایمیه باز باشد)
   → «🔎 تریس کتب نفر».
5. جدول کتاب‌ها → انتخاب → «⬇ دانلود و افزودن همه» → لاگ زنده.
6. خطاها: 401 → پیام ورود؛ `unsupported` → فایل غیر-DOCX (دستی بررسی)؛
   `need-manual` → تب show-book باز شده، دانلود دستی + «آپلود فایل دانلودشده».
7. «ادامه» بعد از close مرورگر باید از همان کتاب توقف‌شده شروع کند.
