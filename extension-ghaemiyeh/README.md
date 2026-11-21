# Ghaemiyeh Book Collector (PCM-EXT-05)

اکستنشن جداگانهٔ Chrome (MV3) برای سایت غایمیه: مجموعهٔ کتب یک فرد را «تریس» می‌کند
(همهٔ صفحه‌های فهرست یک دسته)، کتاب‌ها و لینک مستقیم دانلود هرکدام را استخراج می‌کند،
و تک‌تک فایل‌های DOCX را دانلود و به یک **کالکشن استودیوی دانش** اضافه می‌کند.

سند کامل: `docs/گزارش-PCM-EXT-05.md`

## چرا جدا از اکستنشن اصلی؟

- سایت غایمیه TLS کلاینت‌های غیرمرورگر را می‌ریزد (schannel/curl/python — همه)؛
  تنها مرورگر کاربر دسترسی دارد. بنابراین **کل کار شبکه داخل مرورگر کاربر**
  (service worker با `credentials: 'include'`) انجام می‌شود.
- احراز هویت corpus.ai.ismc.ir با همان کوکی `pct_session` داشبورد است —
  رمز در کد نیست.
- ریسک صفر برای اکستنشن زندهٔ کراول v3.9 (`extension/`).

## نصب (load unpacked)

1. `chrome://extensions` → Developer mode ON.
2. **Load unpacked** → پوشهٔ `extension-ghaemiyeh/`.
3. پیش‌نیاز: یک تب با `https://corpus.ai.ismc.ir/dashboard` **واردشده** باشد
   (چراکه کالکشن‌ها auth می‌خواهند؛ popup گزینه‌ی «401 — وارد داشبورد شوید» را نشان می‌دهد).

## استفاده (۵ مرحله)

1. آیکون اکستنشن → در بخش «کالکشن مقصد» کالکشن انتخاب کن (یا با نام+slug بساز).
2. در «آغاز تریس» آدرس فهرست دسته را بگذار
   (مثل `https://www.ghaemiyeh.ir/category-page?category=51636`) → **تریس شروع**.
   (یا تب غایمیه را باز نگه‌دار و **تریس همین صفحه** را بزن.)
3. جدول کتاب‌ها پر می‌شود: هرکدام با «دانلود ✓/—» و وضعیت.
   تیک‌ها را تنظیم کن (حالا همه انتخاب‌اند).
4. **اجرا** — یک‌به‌یک دانلود → آپلود. هر کتاب: `queued → downloading → uploading → done`.
   **توقف** در میانه کار؛ `done/duplicate` دست‌نخورده می‌مانند.
5. خطاها: **retry failed** (فقط items ناکام/need-manual/unsupported به queued برمی‌گردند).
   برای `need-manual` صفحهٔ کتاب همزمان باز شده — فایل DOCX را از کامپیوتر با دکمهٔ
   «آپلود» همان ردیف انتخاب کن.

## کدهای وضعیت

| وضعیت | معنا |
|-------|------|
| `queued` | در صف |
| `downloading` / `uploading` | در حال پردازش |
| `done` | 201 — در کالکشن ثبت شد |
| `duplicate` | 409 — sha256 تکراری (قبلاً آپلود شده) |
| `auth-error` | 401 — جلسهٔ داشبورد منقضی؛ وارد شو و retry کن |
| `unsupported` | فرمت نه DOCX (بازگشت از آپلود) |
| `failed` | خطای دانلود/آپلود (جزئیات در title سلول) |
| `need-manual` | لینک دانلود خودکار نیافت — تب کتاب باز شد |

## محدودیت‌ها (مستند در سند)

- فقط `.docx` و ≤ ۵۰MB (حد backend) — بقیه `unsupported`.
- حداکثر ۲۰۰ صفحه در هر تریس (`MAX_TRACE_PAGES`) + توقف چرخهٔ صفحه‌ها.
- دال‌ی «delay» بین کتاب‌ها ذخیره می‌شود؛ اجرای SW دلی‌ف‌کارت را از استوریژ می‌خواند.
- اگر دانلودها فقط از صفحهٔ show-book دستی قابل‌دریافت باشند، G7-fallback (fetch صفحه
  + استخراج لینک) پوشش می‌دهد؛ در غیر این‌صورت `need-manual`.

## تست

```bat
cd extension-ghaemiyeh
node test_ghaemiyeh.js
:: G1..G8 — 8 PASS / 0 FAIL
node --check background.js && node --check content.js && node --check popup.js
```

تست‌ها پاپایپلین خالص (injectable deps) را بدون مرورگر/شبکه می‌سنجند:
استخراج+dedup، تریس صفحه‌بندی (jump-to-max / loop / cap)، نگاشت 201/401/409/500،
stop/resume، parsing RFC5987، fallback show-book، need-manual.

## فایل‌ها

| فایل | نقش |
|------|-----|
| `background.js` | لایهٔ خالص (extract/trace/processBook/runQueue) + SW wiring (11 action) |
| `content.js` | استخراج زنده از DOM تب غایمیه (`ghExtract`) |
| `popup.html/js` | رابط RTL: کالکشن، تریس، جدول کتاب‌ها، اجرا/توقف/retry/آپلود دستی |
| `test_ghaemiyeh.js` | G1-G8 (node، بدون مرورگر) |
| `manifest.json` | MV3؛ host_permissions: ghaemiyeh ×2 + corpus.ai.ismc.ir |
