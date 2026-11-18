# گزارش PCM-20.10 — حد عددی توقف کراول + ممیزی کامل‌بودن (گپ‌ها)

تاریخ: 2026-11-18 · branch: `pcm-20.9-knowledge-studio-factory` · deploy: **بدون deploy** (s52 SSH در دسترس نبود — همان وضعیت PCM-20.8)

## ۱. وضعیت قبل (مشکلات گزارش‌شده)

کراول زنده‌ی «تفسیر تسنیم همتا» (پروژهٔ 2، `tasnim.hamtaa.org`) در لحظهٔ بررسی:
- status `running`، cursor روی `item_index=69677`، 109,877 ذخیره / 52 تکراری-رد / 148,935 خطا
- بار اول از 45,000 تا آخر رفته بود؛ بار دوم از صفحهٔ 1 دوباره شروع شده (در حال طی مسیر)
- کراولر **هیچ حد توقفی نداشت**: تنها توقف‌ها دکمهٔ «توقف» (token) و «دو صفحهٔ متوالی خالی» بودند؛ کراول تا آخرِ سایت (یا تا قفل/خطا) جلو می‌رفت
- تکرار صرفاً در لحظهٔ ذخیره (hash مقایسه → `skipped`)؛ ولی «رد» شدن باز هم یک fetch کامل می‌خواست → بار دوم وقت می‌گرفت
- ابزار «کجاها گپ دارد؟» فقط `pcm20_tasnim_export.py` (روی DB مستقیم s52) بود؛ چون SSH قطع است، از این ویندوز قابل اجرا نبود

## ۲. طراحی

### A) حد عددی توقف (`stop_number`) — «تا فلان عدد برو و ایست کن»

- ستون جدید `projects.stop_number TEXT DEFAULT ''` — **مهاجرت افزایشی** (additive migration مثل PCM-EXT-03؛ خالی = بدون حد)
- UI: فیلد «حد عددی توقف (صفحهٔ آخر؛ خالی = بدون حد)» کنار «در هر دقیقه چند صفحه»؛ با `saveRule` ذخیره می‌شود
- API: create + update پروژه `stop_number` را می‌گیرند (اعتبارسنجی: عدد صحیح مثبت یا خالی؛ وگرنه 400)
- crawl loop (`background.js`): **قبل از باز کردن هر صفحه** `checkStopUrl(target, project)` اجرا می‌شود:
  - شماره‌ی صفحه از URL با **همان روشی** که `advanceUrl` جلو می‌رود استخراج می‌شود (param از query، `url-number`/next-link از آخرین عدد مسیر، regex از گروه عددی)
  - `n > stop` → «حد … از عدد … عبور کرد» · `n === stop` → «به حد … رسید (آخرین صفحه)»
  - پایان تمیز: `endRun` → وضعیت `paused` + پیام + release قفل run (PCM-EXT-03)
- مثال خواسته‌شده: `https://ganjoor.net/hafez/ghazal/sh150` با قانون `url-number` + حد 495 → sh150..sh495 خوانده می‌شوند، sh496 باز **نمی‌شود** و run با `paused` می‌ایستد
- حد عددی مستقل از دکمهٔ توقف است: هر دو باید برقرار باشند تا run زنده بماند

### B) ممیزی کامل‌بودن (gap/quality/duplicate audit) — اسکریپت read-only

`deploy/pcm2010_crawl_gap_audit.py` (stdlib فقط؛ از هر دستگاهی با HTTPS قابل اجرا؛ login یک‌بار با `PCT_PASSWORD`):

1. **گپ‌ها**: همه‌ی صفحات پروژه از `GET /api/dashboard/projects/<id>/pages` (مورب، max 100) می‌آیند؛ شمارهٔ صفحه از URL استخراج می‌شود؛ اعداد غایب بین min..max → **بازه‌های پیوسته** (`chunks`) + فهرست کامل در JSON
2. **کیفیت داده**: صفحاتی که یک یا چند نقطه (point) خالی یا < `--min-len` (default 20 کاراکتر) است → کاندیدای «ناقص» (همان چیزی که باید دوباره کراول شود)
3. **تکرار**: payloadهای values یکسان روی چند رکورد + رکوردهای هم‌شماره
4. **وضعیت کراول فعلی**: قفل run زنده است یا نه (heartbeat < 180 ثانیه) + cursor
5. **اثبات کامل بودن**: `--expect-max N` → اگر همهٔ `1..N` موجود باشند و هیچ صفحهٔ ناقص/تکراری نباشد: `COMPLETENESS PROOF: PASS`، وگرنه `FAIL` با جزئیات
6. خروجی: کنسول + فایل JSON کامل (پیش‌فرض در `evidence/crawl-gap-audit-project<id>-<TS>.json`)

برای تسنیم (پروژهٔ 2): `--project 2` کافی است (پارامتر عددی پیش‌فرض `item_index` است).
برای گنجور (پروژهٔ 9، `url-number`): `--project 9 --path-number`.

### C) رفتار تکراری (پاسخ به «اگر قبلاً همین مقادیر را گرفتیم، تکرار نکند مگر ناقص/خطا داشته باشد»)

مکانیسم فعلی همین است و حفظ شد: `save_page` در بک‌اند hash مقایسه می‌کند → identical = `skipped` (بازنویسی نمی‌کند، `skipped_count+1`)، متفاوت = `updated`. یعنی **دادهٔ تکراری دوباره ذخیره نمی‌شود**؛ هزینهٔ بار دوم یک fetch است. با F.1 (حذف `section` از URL — بعدی) fetchهای تکراری بین دو crawl با sectionهای متفاوت هم یک record می‌شوند و بار دوم واقعاً cheap می‌شود.

## ۳. مهاجرت

افزایشی: `ALTER TABLE projects ADD COLUMN stop_number TEXT DEFAULT ''` در `ensure_projects_schema` (lazy، همان pattern PCM-EXT-03). بدون DROP/RENAME/تغییر نوع. روی DB production s52 در اولین request بعد از deploy اعمال می‌شود.

## ۴. فایل‌ها / API

| فایل | تغییر |
|---|---|
| `extension/background.js` | `parseStopSpec` / `pageNumberOf` / `checkStopUrl` + چک قبل از هر صفحه در `runMinute` |
| `extension/content_picker.js` | فیلد UI `stopNum` + خواندن/ذخیرهٔ `stop_number` |
| `extension/test_next.js` | +12 تست stop-rule (47 total) |
| `backend/projects.py` | `_clean_stop_number` + ستون in schema/migration + create/update |
| `backend/test_projects.py` | +6 تست `StopNumberTests` (SN-01..06) |
| `deploy/pcm2010_crawl_gap_audit.py` | **جدید** — ممیزی read-only |
| `AGENTS.md` | خط PCM-20.10 در نقشهٔ راه |

## ۵. تست

- `node extension/test_next.js` → **47 passed, 0 failed** (35 قبلی + 12 جدید: parse/عدد-صفحه/اتراف حد/overshoot با step>1/عدم‌اعمال‌پذیری حد)
- رگرسیون کامل بک‌اند: `python -m unittest test_api test_projects test_dashboard test_knowledge_api test_word_factory test_dump test_work_registry test_queue test_corpus_builder test_studio_api test_api_contract` → **206 tests OK (skipped=10 — همهٔ skip‌ها قبلی هستند: 10× CT-06 «PyYAML not installed» روی این ویندوز)**

## ۶. نتیجه production

بدون deploy (s52: 172.20.1.52 port 22 timeout — بازبینی‌شده در این مأموریت). پس از deploy استاندارد (PCM-EXT-03 pattern): `docker compose build backend && docker compose up -d backend` + reload اکستنشن.

## ۷. SHA + لینک

- commit بعد از بازبینی (این گزارش + کد) — SHA در commit message ثبت می‌شود
- اسکریپت: [deploy/pcm2010_crawl_gap_audit.py](deploy/pcm2010_crawl_gap_audit.py)

## ۸. git status

فایل‌های این مأموریت: `backend/projects.py`, `backend/test_projects.py`, `extension/background.js`, `extension/content_picker.js`, `extension/test_next.js`, `deploy/pcm2010_crawl_gap_audit.py`, `AGENTS.md`, `گزارش-PCM-20.10.md`
(علاوه بر فایل‌های uncommitted موجود از قبل: گزارش‌های E8.0-H* و evidence/E8.0-H)

## ۹. بکاپ / rollback

بدون تغییر schema مخرب؛ rollback = revert commit + (اختیاری) `stop_number` ستونی بدون reference باقی می‌ماند — حذف‌پذیر بعداً.

## ۱۰. موارد باقی‌مانده (برای مأموریت بعدی / با دسترسی s52)

1. **F.1 (مهم — تکرار تسنیم)**: `section` از URL صفحه‌های تسنیم حذف شود (کماکنندگی URL در `save_page` یا حذف query‌های غیر-`item_index`). دلیلی که بار دوم 148k خطا/52 تکرار می‌گیرد احتمالاً همین است: URL با sectionهای مختلف برای همان `item_index` recordهای متفاوت می‌سازد / یا `section` در URL cursor نمی‌آید و `parse_qs` آن را گم می‌کند. نیاز به inspect recordهای واقعی (از این ویندوز با `pcm2010_crawl_gap_audit.py --out` و بعد بررسی JSON).
2. **F.2**: retry خودکار گپ‌ها — بعد از ممیزی، اسکریپت می‌تواند فهرست `missing` را به cursor کراولر تبدیل کند (حالت «فقط گپ‌ها»).
3. **F.3**: توقف بر اساس **الگوریتم** (مثلاً «N صفحهٔ متوالی بدون داده‌ی جدید») — الان فقط «دو صفحهٔ متوالی خالی» و «حد عددی» وجود دارد.
4. deploy به s52 + smoke test + اجرای واقعی `pcm2010_crawl_gap_audit.py` روی پروژهٔ 2 (تسنیم) و پروژهٔ 9 (حافظ) و ثبت خروجی در `evidence/`.

## ۱۱. روش تست دستی

```bash
# از این ویندوز:
cd persian-corpus-toolkit
node extension/test_next.js                      # 47 تست
cd backend && python -m unittest test_projects -v   # SN-01..06

# بعد از deploy به s52:
# 1) پنل اکستنشن روی صفحه‌ای از سایت → فیلد «حد عددی توقف» = مثلاً 495 → «آزمایش و شروع»
# 2) کراول تا sh495 می‌رود، sh496 باز نمی‌شود، وضعیت paused + پیام «به حد عددی 495 رسید»
# 3) ممیزی:
set PCT_PASSWORD=...
python deploy\pcm2010_crawl_gap_audit.py --project 2
python deploy\pcm2010_crawl_gap_audit.py --project 9 --path-number
python deploy\pcm2010_crawl_gap_audit.py --project 9 --path-number --expect-max 2961
# 4) خروجی: گپ‌ها به‌صورت بازه، صفحات ناقص، تکرارها، COMPLETENESS PROOF: PASS/FAIL
```
