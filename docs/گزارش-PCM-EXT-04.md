# گزارش PCM-EXT-04 — توقف کراول: حد عددی + تکرار محتوا + فیلد مبنای محتوا

تاریخ: ۱۴۰۵/09/28 (2026-11-19) · شاخه: `pcm-20.9-knowledge-studio-factory`
Commit کد: `e86cd0d` · نسخه اکستنشن: **3.9** (قبلاً 3.8)

## ۱. وضعیت قبل و درخواست

درخواست:
1. کراولر کورپوس یک **حد بالا** داشته باشد: باکس «صفحه ماکزیمم» — خالی = بی‌نهایت،
   پر (مثلاً 500) = تا آن صفحه بخواند و بایستد.
2. اگر **ده صفحهٔ پشت‌سرهم محتوایشان مثل صفحه‌های قبلی** بود (یا خالی/مشکوک و عین
   هم)، خواندن متوقف شود.
3. یکی از فیلدهای استخراج‌شده بتواند به‌عنوان **«مبنای محتوای صفحه»** معیار این
   تشخیص باشد.

**نتیجه‌ی ممیزی قبل از شروع:** حد عددی (۱)**قبلاً پیاده بود** — PCM-20.10:
ستون `projects.stop_number` (TEXT؛ خالی = بدون حد) + باکس پنل «حد عددی توقف
(صفحهٔ آخر؛ خالی = بدون حد)» + چک `checkStopUrl()` در حلقه‌ی خواندن (قبل از باز
کردن صفحه‌ی بعدِ حد، run تمیز `paused` می‌شود). پس باکس جدیدی نیازی نبود؛
فقط مستند شد و در smoke دپلوی assert شد.

نقطه ۲ و ۳ در این مأموریت پیاده شد (PCM-EXT-04).

## ۲. طراحی

### توقف بر مبنای تکرار محتوا
- `SAME_PAGE_LIMIT = 10` — اگر امضای محتوایی ۱۰ صفحهٔ پشت‌سرهم یکسان باشد،
  run تمیز تمام می‌شود با پیام «ده صفحهٔ پشت‌سرهم محتوای یکسان (…) داشت —
  خواندن ایستاد.»
- **امضا** (`contentSignature`): اگر `stop_field` تنظیم باشد و در `values`
  صفحه موجود باشد → مقدار همان فیلد؛ در غیر این صورت (خودکار یا فیلد
  موجود نباشد) → ترکیب مرتب‌شده (بر اساس نام کلید) همه‌ی مقادیر با جداکننده
  `\u0001`.
- **حش** (`sigHash`): djb2 32-بیت — مقدار کوچک برای ذخیره در `pctRun`.
- **streak** (`updateSameStreak`): `{streak, stop}`؛ برابر = +۱، متفاوت =
  ۱؛ `stop` دقیقاً وقتی streak به ۱۰ برسد.
- حالت `sameStreak`/`lastSig` در `pctRun` **پایداری می‌کند** (هر دقیقه
  `runMinute` از storage می‌خواند و برمی‌نویسد) → زنجیره از دقیقه‌ای به
  دقیقه‌ی بعد قطع نمی‌شود و با reopen مرورگر هم حفظ می‌شود.
- فقط استخراج‌های **موفق** وارد شمارش می‌شوند. صفحات **خالی** قاعده‌ی جدا
  دارند: ۲ صفحهٔ خالی پشت‌سرهم = توقف (قاعده‌ی قدیمی `emptyStreak`).

### فیلد مبنای محتوا (`stop_field`)
- UI: select «مبنای تشخیص تکرار محتوا» در پنل، بلافاصله بعد از باکس حد
  عددی. گزینه‌ها: **خودکار (کل محتوا)** + یک گزینه برای هر نقطه (tag) پروژه؛
  گزینه‌ها هر بار `render()` از `project.points` ساخته می‌شود و انتخاب فعلی
  حفظ می‌شود.
- `saveRule()` مقدار select را در `POST /api/projects/<id>` می‌فرستد
  (`stop_field`؛ همان POST قبلی `stop_number` را هم می‌فرستد).
- backend: `_clean_stop_field` — trim + سقف ۶۴ کاراکتر؛ **هرگز reject نمی‌شود**
  (برخلاف `stop_number` که عدد نامعتبر 400 می‌دهد). در create و update
  پذیرفته می‌شود و از `GET` (و list) به‌صورت خودکار خارج می‌شود (`_project`).

## ۳. مهاجرت (فقط افزایشی)

```sql
ALTER TABLE projects ADD COLUMN stop_field TEXT DEFAULT ''
```
- در `ensure_projects_schema` اجرا می‌شود (lazy؛ اولین request روی پروژه‌ها).
- DBهای قدیمی: ستون در همان جای خود اضافه می‌شود، ردیف‌ها دست‌نخورده
  (`stop_field=''` = خودکار). کدِ backend قدیمی هم این ستون را ignore می‌کند
  → rollback کد بدون rollback DB.
- `stop_number` (PCM-20.10) و سه ستون lock (PCM-EXT-03) هم در همان مسیر lazy
  مهاجرت هستند و در smoke دپلوی assert می‌شوند.

## ۴. فایل‌ها / API

| فایل | تغییر |
|---|---|
| `extension/background.js` | +48: `SAME_PAGE_LIMIT`، `contentSignature`، `sigHash`، `updateSameStreak`؛ `sameStreak`/`lastSig` در `pctRun` (شروع + ذخیره‌ی پیشرفت)؛ چک streak در branch موفق `runMinute` + `endRun` |
| `extension/content_picker.js` | +25: select `#stopField` + `rebuildStopField()` در `render` + `stop_field` در body `saveRule` |
| `extension/manifest.json` | نسخه 3.8 → **3.9** |
| `extension/test_next.js` | +84: 14 تست جدید (امضا/حش/streak) — مجموع 61 |
| `backend/projects.py` | +24: `_clean_stop_field` + مهاجرت افزایشی + create/update |
| `backend/test_projects.py` | +134: کلاس `StopFieldTests` (SF-01..SF-08) |
| `docs/EXT-NEXT-PAGE-METHODS.md` | +38: بخش «قواعد توقف خواندن» (سه قاعده) + نسخه |
| `deploy/pcm_ext_03_deploy.sh` | commit → `e86cd0d`، EXPECT blobها به‌روزرسانی (+3 فیلد اکستنشن)، assert `stop_number`/`stop_field` در smoke |

**API جدید: ندارد.** فقط فیلد `stop_field` در payloadهای موجود
`POST /api/projects` (create) و `POST /api/projects/<id>` (update) و خروجی
`GET`. هیچ route جدیدی اضافه نشده.

## ۵. تست‌ها (همه سبز قبل از commit)

| مجموعه | نتیجه |
|---|---|
| `node extension/test_next.js` | **61 passed, 0 failed** (47 قبلی + 14 جدید: خودکار/فیلد/مرتب‌سازی، null→''، حش قطعی/متفاوت، streak reset، توقف دقیقاً در ۱۰، شبیه‌سازی ۱۲ صفحه) |
| `node extension/test_popup.js` | 8 passed, 0 failed |
| `python -m unittest test_projects -v` | **23 OK** (T01..T12 + SN-01..06 + SF-01..08) |
| رگرسیون کامل backend (12 ماژول شامل `test_run_lock`) | **228 tests OK (skipped=10)** — 10 skip همان baseline است |

تست‌های SF: پیش‌فرض خالی، create با tag، update/clear، سقف 64 (هرگز 400
نمی‌شود)، trim، list، مهاجرت افزایشی روی DB legacy (has `stop_number`، بدون
`stop_field`) با حفظ ردیف + idempotent.

## ۶. نتیجه‌ی production (s52)

**اجرا مسدود است** — s52 (172.20.1.52) در زمان این مأموریت reachable نبود
(همان وضعیت PCM-18/EXT-03): `ssh: connect to host 172.20.1.52 port 22:
Connection timed out`. دپلوی به‌صورت یک اسکریپت کنترل‌شده آماده است
(بکاپ → snapshot → extract → blob-verify → build فقط backend → health →
smoke → integrity → counters) و در بخش ۱۰ آمده است. تا اجرای دپلوی، backend
زنده هنوز `stop_field` را نمی‌شناسد؛ اکستنشن 3.9 روی backend قدیمی هم کار می‌کند
(فیلد در JSON بی‌درد می‌ماند چون backend کلیدهای ناشناخته را نادیده می‌گیرد —
ولی برای ذخیره‌ی واقعی `stop_field` باید دپلوی انجام شود).

## ۷. SHA + لینک

- Commit کد: `e86cd0d` — «PCM-EXT-04: content-based stop (10 identical pages)
  + stop_field content basis» (7 فایل، +347/−8)
- Blobs کلیدی:
  - `backend/projects.py` = `f484dd12c7e34ec3dfd4a156590eb17d7218d568`
  - `extension/manifest.json` = `202684cc5475daf92ac5f09fd659978edd907d37`
  - `extension/background.js` = `98b35eafcbc90a801e12740abf08dbbcc6c1d5cf`
  - `extension/content_picker.js` = `1536b7c689b22f26870c13df63742ae22934e511`
  - `extension/test_next.js` = `3631482fa846b929b60c4ef9706636f66adb9f3f`
- لینک commit: https://github.com/saber13812002/persian-corpus-toolkit/commit/e86cd0d

## ۸. git status (زمان commit)

```
M backend/projects.py            (+24)
M backend/test_projects.py       (+134)
M docs/EXT-NEXT-PAGE-METHODS.md  (+38)
M extension/background.js        (+48)
M extension/content_picker.js    (+25)
M extension/manifest.json        (1 خط: 3.8 → 3.9)
M extension/test_next.js         (+84)
```
فایل‌های untracked (`docs/reports/E8.0-*`، `evidence/E8.0-H/`) جزو این
مأموریت نیستند و commit نشدند.

## ۹. بکاپ / rollback

- بکاپ قبل از دپلوی توسط اسکریپت: `sqlite3 .backup` + `PRAGMA integrity_check`
  + snapshot tar کل deploy dir (بدون DB).
- Rollback کد: extract snapshot + `docker compose build backend && up -d
  backend`. ستون‌های افزایشی (`stop_field` و قبلی‌ها) توسط کدِ قدیمی نادیده
  گرفته می‌شوند → **rollback DB لازم نیست**.
- Rollback DB (فقط اگر ردیف خراب شود): `.restore` از بکاپ.

## ۱۰. موارد باقی‌مانده (دپلوی — وقتی s52 برگشت)

```bash
# روی Windows:
git archive --format=tar.gz --prefix=persian-corpus-toolkit/ e86cd0d -o pct-code-ext03.tgz
scp -P 22 pct-code-ext03.tgz saber@172.20.1.52:/tmp/
scp -P 22 deploy\pcm_ext_03_deploy.sh saber@172.20.1.52:/tmp/
ssh -p 22 saber@172.20.1.52 "bash /tmp/pcm_ext_03_deploy.sh"
```
این دپلوی **هر دو** PCM-EXT-03 (lock) + PCM-EXT-04 (stop_field) را با هم می‌رساند
(اسکریپت به‌روزرسانی شده: commit `e86cd0d` + 9 blob EXPECT + assert هر سه
ستون lock و `stop_number`/`stop_field` بعد از smoke probe).

## ۱۱. روش تست دستی

1. اکستنشن را روی v3.9 reload کن (`chrome://extensions` → Reload) — روی کارت
   باید `3.9` باشد.
2. پنل یک پروژه را باز کن → در بخش قواعد، بعد از باکس «حد عددی توقف»، select
   «مبنای تشخیص تکرار محتوا» را می‌بینی: گزینه‌ها = خودکار + tagهای نقاط.
3. **حد عددی**: مثلاً `5` بزن، «آزمایش و شروع» → بعد از صفحه ۵، run با پیام
   «به حد عددی رسید» می‌ایستد و `paused` می‌شود. خالی بماند = بی‌نهایت.
4. **تکرار محتوا**: روی سایتی که صفحات تکراری دارد (یا موقتاً با DevTools
   contents یک فیلد را ثابت کن) شروع کن؛ بعد از ۱۰ صفحهٔ یکسان:
   «ده صفحهٔ پشت‌سرهم محتوای یکسان (فیلد «…» / کل محتوا) داشت — خواندن ایستاد.»
   اگر select روی یک فیلد خاص باشد، فقط همان فیلد معیار است (مثلاً body ثابت
   ولی title عوض شود → نمی‌ایستد).
5. **صفحه خالی**: ۲ صفحهٔ خالی پشت‌سرهم → توقف «دو صفحه پشت‌سرهم متن نداشت».
6. resume: بعد از هر توقف، «آزمایش و شروع» از همان cursor ادامه می‌دهد
   (streak در storage ماندگار است).
7. **backend**: `POST /api/projects` با `stop_field:"body"` → `GET` باید همان را
   برگرداند؛ مقادیر بلندتر از 64 حرف truncate می‌شوند نه 400.
