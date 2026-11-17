# گزارش PCM-EXT-03 — قفل یک-run بین‌مرورگری (cross-browser single-run lock)

**تاریخ:** ۲۰۲۶-۱۱-۱۷ · **نسخه‌ی اکستنشن:** 3.8 · **branch:** `pcm-20.9-knowledge-studio-factory`

## ۱. وضعیت قبل

اکستنشن «Persian Corpus Crawler» تمام وضعیت اجرای خودش را در
`chrome.storage.local` نگه می‌دارد (100% مخصوص همان پروفایل مرورگر؛ بدون
`storage.sync`/`storage.session`). اگر **همان پروژه** در دو مرورگر/پروفایل
اجرا شود:

- وضعیت backend (ستون تکی `projects.status`) بین `running`/`paused`
  «پینگ‌پونگ» می‌کند (همان علامتی که کاربر دید).
- هر دو مرورگر cursor را جلو می‌برند (دوباره‌خواندن/ازدوباره‌ذخیره — صفحه‌ی
  ذخیره idempotent است، پس داده‌ای گم/خراب نمی‌شود، ولی کار تکراری و گزارش‌ها
  کثیف می‌شود).
- نگهبان یک-runی محلی v3.7 (token + `pctRun`) از مرورگر دیگر **دیده نمی‌شود**.

پروژه‌های **متفاوت** همزمان امن بودند و می‌مانند (ذخیره‌ی صفحه با
`UNIQUE(project_id,url)` idempotent است و API نوشتاری اکستنشن
throttle ندارد).

## ۲. طراحی

backend «حقیقت»ِ یک-run-در-هر-زمان برای هر پروژه می‌شود — **اجاره‌ی run
(lease) با TTL**:

- هر پروفایل مرورگر یک `owner` پایدار دارد (`pctOwner` در storage.local،
  ساختار `b<time36>-<rand8>`).
- **claim**: `POST /api/projects/<id>/run` با `{owner, token}` — یک UPDATE
  شرطی **اتمی** روی یک ردیف:
  `WHERE id=? AND (run_token='' OR COALESCE(run_heartbeat,0) < stale OR run_owner=?)`
  یعنی: بی‌قفل / قفل منقضی / owner همان → 200 claim؛ در غیر این صورت 409
  با `locked_by` و پیام فارسی.
- **heartbeat**: `POST /run/heartbeat` — فقط owner+token دارنده تمدید می‌کند؛
  409 = دیگر مالک نیستیم → اکستنشن run را تمیز می‌بندد.
- **release**: `POST /run/release` — owner+token دارنده (یا هر کسی روی قفل
  **منقضی**)؛ status روی `paused` می‌نشیند.
- **TTL = 180 ثانیه (۳ دقیقه)**: مرورگر مرده که release نداده، بعد از ۳ دقیقه
  خودکار آزاد می‌شود (self-heal).
- اکستنشن: claim **قبل از** ساخت تب؛ heartbeat **دو بار در هر صفحه** (بالای
  حلقه + بعد از extract) تا با سرعت پایین صفحه/دقیقه TTL نشکند؛ خطای شبکه‌ی
  گذرا روی heartbeat run را **نمی‌کشد** (heartbeat بعدی حقیقت را می‌گوید)؛
  release در stop/endRun/بسته‌شدن تب (best-effort).
- سازگاری رو به عقب: اگر backend قدیمی باشد (route نباشد → 404)، اکستنشن
  با رفتار v3.7 محلی ادامه می‌دهد (`console.warn`).
- پنل: هر ۴ ثانیه پروژه را refresh می‌کند؛ اگر `run_owner` غیرخالی +
  `run_heartbeat` تازه باشد → دکمه «در حال خواندن (دستگاه دیگر)» و شروع
  امتیاز داده نمی‌شود (بررسی نهایی همان claim اتمیک سرور است).

## ۳. مهاجرت

افزایشی (additive) در `ensure_projects_schema` (همان الگوی khamenei_speeches):

```sql
ALTER TABLE projects ADD COLUMN run_owner TEXT DEFAULT '';
ALTER TABLE projects ADD COLUMN run_token TEXT DEFAULT '';
ALTER TABLE projects ADD COLUMN run_heartbeat REAL DEFAULT 0;
```

- اجرا **lazy** است: اولین request به هر سه route جدید (و routeهای
  موجودی که `ensure_projects_schema` را صدا می‌زنند) ستون‌ها را اضافه می‌کند.
- ردیف‌های قدیمی بی‌تغییر می‌مانند (default = بدون قفل).
- هیچ DROP/RENAME/تغییر نوعی نیست.

## ۴. فایل‌ها / API

| فایل | تغییر |
|---|---|
| `backend/projects.py` | +133 خط: `import time`، `RUN_LOCK_TTL=180`، 3 ستون افزایشی، 3 route جدید (`claim_run`/`heartbeat_run`/`release_run`) |
| `backend/test_run_lock.py` | **جدید**: 14 تست RL-01..RL-14 |
| `extension/background.js` | `getOwnerId`/`claimRun`/`heartbeatRun`/`releaseRun`؛ claim در `startReading` قبل از تب؛ heartbeat×2 در `runMinute`؛ release در `stopReading`/`endRun`/`tabs.onRemoved` |
| `extension/content_picker.js` | `lockLiveByOther()` + حالت «در حال خواندن (دستگاه دیگر)» + پیش‌بررسی `testAndStart` + poll async |
| `extension/manifest.json` | version 3.7 → **3.8** |
| `docs/EXT-NEXT-PAGE-METHODS.md` | بخش «قفل cross-browser روی پروژه (v3.8 / PCM-EXT-03)» |
| `deploy/pcm_ext_03_deploy.sh` | **جدید**: اسکریپت دپلوی کنترل‌شده (الگوی pcm208) |

APIهای جدید (همه open مثل بقیه‌ی `/api/projects*`، طبق AGENTS.md §2.6):

- `POST /api/projects/<id>/run` → 200 `{ok, claimed, project}` / 409 `{ok, message, locked_by}` / 400 / 404
- `POST /api/projects/<id>/run/heartbeat` → 200 `{ok, heartbeat}` / 409 / 400 / 404
- `POST /api/projects/<id>/run/release` → 200 `{ok, released, project}` / 409 / 400 / 404

## ۵. تست‌ها

- `python -m unittest test_run_lock -v` → **14 passed** (RL-01 claim آزاد،
  RL-02 owner دوم 409 + `locked_by`، RL-03 reclaim همان owner، RL-04/05
  heartbeat، RL-06/07 release، RL-08/09 قفل منقضی claimable/releasable،
  RL-10 404 پروژه‌ی ناموجود، RL-11 exposure ستون‌ها در GET، RL-12 ذخیره‌ی
  صفحه قفل را حفظ می‌کند، RL-13 400 بدون owner/token، RL-14 مهاجرت
  schema legacy + idempotent).
- رگرسیون کامل: `test_api test_projects test_dashboard test_knowledge_api
  test_word_factory test_dump test_work_registry test_queue
  test_corpus_builder test_studio_api test_api_contract test_run_lock` →
  **214 tests, OK** (10 skip = base-line موجود).
- اکستنشن: `node --check` هر سه JS + `node extension/test_next.js` →
  **35 passed** + `node extension/test_popup.js` → **8 passed**.
- `git hash-object` blob‌های کلیدی با commit e38f914 تطبیق دارد (چک داخل
  اسکریپت دپلوی).

## ۶. نتیجه‌ی production

**اجرای deploy روی s52 هنوز انجام نشده** — در زمان این گزارش
`ssh -p 22 saber@172.20.1.52` و ping هر دو **unreachable** بودند
(«Destination host unreachable» از gateway؛ همان وضعیت PCM-18). کد + تست +
اسکریپت دپلوی آماده است (بخش ۱۰). تا قبل از deploy، اکستنشن 3.8 روی
backend قدیمی رفتار v3.7 را نگه می‌دارد (404 fallback) — هیچ breakage‌ای
ایجاد نمی‌شود.

## ۷. SHA + لینک

- commit: `e38f914` — «PCM-EXT-03 (v3.8): cross-browser single-run lock for parallel crawls»
- push: `57b8327..e38f914` → branch `pcm-20.9-knowledge-studio-factory`
- blobهای کلیدی (برای اسکریپت دپلوی):
  - `backend/projects.py` = `b0411c05788cbba18f8e5c6a0f245360466894d0`
  - `backend/server.py` = `b0cfa21357928aa125f70f7e47a647f087fc8b78`
  - `backend/Dockerfile` = `0d211b9b1cb4f02a229189ed8d516c7ea7262032`
  - `docker-compose.yml` = `fc05c99800a3c70d7516ee4aa3b1332ddd2df2ec`
  - `dashboard/index.html` = `e548c3ac068faf17d3e6ed8ac35a2984eef38e08`
  - `extension/manifest.json` = `68a963f8d39684b7ba365873628b9093f25e0c7e`

## ۸. git status

پس از commit: clean جزو دو مورد خارج از محدوده (untracked، دست‌نخورده):
`docs/reports/E8.0-G-MASTER-REPORT.md` (مربوط به جریان کاری دیگر).
اسکریپت one-shot `backend/_pcm_ext_03_apply.js` حذف شد (commit نشد).
در حین کار، drift خط CRLF روی working-copy محلی `backend/projects.py`
(میراث autocrlf از clone قدیمی، در برابر `eol=lf` در .gitattributes) با
تبدیل به LF رفع شد؛ diff نهایی **خالص افزایشی** (+133 خط).

## ۹. بکاپ / rollback

- بکاپ‌ها در زمان deploy (اسکریپت): `/home/saber/backups/thesaurus-<TS>.db`
  (online backup + integrity_check) + `/home/saber/backups/pct-deploy-<TS>.tar.gz`
  (اسنپ‌شات کل deploy dir بدون DB).
- rollback کد: extract اسنپ‌شات + `docker compose build backend && docker
  compose up -d backend`. ستون‌های افزایشی توسط کد قدیمی **ignore**
  می‌شوند — rollback DB لازم نیست.
- rollback DB (فقط در صورت خرابی داده): `.restore` از بکاپ (برای این تغییر
  انتظار نمی‌رود).

## ۱۰. موارد باقی‌مانده

1. **اجرای deploy روی s52** (مسدود: host unreachable). وقتی شبکه در دسترس
   شد:
   ```bat
   git archive --format=tar.gz --prefix=persian-corpus-toolkit/ e38f914 -o pct-code-ext03.tgz
   scp -P 22 pct-code-ext03.tgz saber@172.20.1.52:/tmp/
   scp -P 22 deploy\pcm_ext_03_deploy.sh saber@172.20.1.52:/tmp/
   ssh -p 22 saber@172.20.1.52 "bash /tmp/pcm_ext_03_deploy.sh"
   ```
2. reload اکستنشن به 3.8 در هر مرورگر (`chrome://extensions` → Reload).
3. (اختیاری، بعد از deploy) یک smoke دستی دو-مرورگری طبق بخش ۱۱.

## ۱۱. روش تست دستی (دو مرورگر)

1. deploy بخش ۱۰ روی s52 اجرا شود؛ هر دو مرورگر اکستنشن 3.8 داشته باشند.
2. مرورگر A: پروژه‌ی X را «آزمایش و شروع» → شروع می‌شود.
3. مرورگر B (پروفایل/اکانت دیگر): همان پروژه‌ی X را باز کنید → پنل دکمه
   «در حال خواندن (دستگاه دیگر)» نشان می‌دهد و «آزمایش و شروع» پیام
   «این پروژه همین حالا توسط نشست دیگری در حال خواندن است» می‌دهد.
4. در مرورگر A «توقف» بزنید → در B دکمه باز می‌گردد «آزمایش و شروع».
5. تست TTL: در A شروع کنید، مرورگر A را **کاملا** ببندید (بدون توقف) →
   بعد از ۳ دقیقه (TTL=180s) در B باید claim شود.
6. پروژه‌های **متفاوت** در A و B همزمان → هر دو باید بی‌دردسر کار کنند.
