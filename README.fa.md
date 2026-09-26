# راه — تونل چندمسیرهٔ ایران ↔ خارج/مقصد

**[English](README.md)** · **فارسی** · [LICENSE](LICENSE) · [CHANGELOG](CHANGELOG.md) · [معماری](docs/ARCHITECTURE.md) · [پروتکل‌ها](docs/PROTOCOLS.md)

[![CI](https://github.com/qasamij/raah-tunnel/actions/workflows/python-package.yml/badge.svg)](https://github.com/qasamij/raah-tunnel/actions/workflows/python-package.yml)
[![Python 3.9+](https://img.shields.io/badge/python-3.9%2B-blue.svg)](https://www.python.org/downloads/)
[![sing-box 1.14+](https://img.shields.io/badge/sing--box-1.14%2B-blue.svg)](https://sing-box.sagernet.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Ubuntu 22.04+](https://img.shields.io/badge/server-Ubuntu%2022.04%2B-orange.svg)](https://ubuntu.com/)

اگر `git clone` در شبکهٔ شما کند یا مسدود بود، نصب‌کننده خودش به‌صورت خودکار همان نسخه را با یک درخواست HTTPS از `codeload.github.com` می‌گیرد. برای تغییر رفتار:

```bash
sudo RAAH_TARBALL_TIMEOUT=180 bash /tmp/raah-install.sh --menu   # مهلت بیشتر برای شبکهٔ کند
sudo RAAH_REF=main bash /tmp/raah-install.sh --menu              # نصب آخرین کد روی شاخهٔ main
```

**راه** لایهٔ انتقال بین دو سرور ایران و خارج/مقصد است. کاربران، UUID، رمز، تاریخ انقضا، سهمیه و پنل باید در `x-ui`/`3x-ui` بمانند؛ Raah نباید مالک کاربرهای نهایی باشد. مسیر QUIC برای ترافیک TCP/UDP و مسیر TCP/REALITY به‌عنوان جایگزین قرار می‌گیرد.

> این نسخهٔ اولیه است. هیچ پروتکلی تضمین نمی‌کند که شناسایی یا مسدود نشود. قطع برق، مسیر بین‌الملل، فیلتر ارائه‌دهنده یا خاموش‌شدن کامل سرور را هم نرم‌افزار نمی‌تواند جبران کند.

## در این نسخه

- تولید کانفیگ جدا برای سرور خارج/مقصد، ایران و کلاینت لینوکس در حالت مستقیم، ریورس یا هر دو.
- Hysteria 2 روی QUIC برای TCP و UDP، و VLESS/REALITY روی TCP به‌عنوان مسیر جایگزین.
- اسکن SNI برای REALITY و ساخت چند مسیر fallback؛ هر SNI روی پورت TCP جدا ساخته می‌شود و `urltest` خودش مسیر سالم‌تر را انتخاب می‌کند.
- انتخاب خودکار مسیر سالم خارج/مقصد و ورودی کم‌تأخیر ایران با آزمون URL؛ این نسخه ترافیک چند کاربر را هم‌زمان بین سرورها پخش نمی‌کند.
- امکان انتخاب پورت؛ هیچ پورتی را در UFW یا فایروال پنل VPS باز نمی‌کند. هنگام فعال‌بودن port hopping فقط جدول DNAT مجزای خود Raah را مدیریت می‌کند.
- کانفیگ مستقل زیر مسیر `/etc/raah`؛ فایل‌ها و سرویس x-ui دست‌کاری نمی‌شوند.
- ابزارهای عملیاتی برای تولید برنامهٔ UFW، چک سلامت نصب، چک سقف مصرف host/interface و گزارش متادیتای لاگ Xray/x-ui.
- نمایش مجموع حجم ورودی/خروجی کارت شبکه، load و memory، بررسی سلامت سرویس TCP با اعلان تلگرام، و probe ساده برای latency/jitter اتصال TCP.
- تست end-to-end با کانفیگ واقعی کلاینت از مسیر ایران، خارج و مقصد HTTP/HTTPS.

این طراحی یک VPN کامل لایهٔ ۳ نیست؛ TCP و UDP را از طریق پراکسی عبور می‌دهد، اما ICMP و همهٔ پروتکل‌های IP را منتقل نمی‌کند. برای استفاده، کلاینت سازگار با sing-box و پشتیبانی TUN لازم است.

## راه‌اندازی

پیش‌نیاز: Ubuntu 22.04/24.04 یا جدیدتر، دسترسی root و sing-box نسخهٔ 1.14 یا جدیدتر. نصب‌کنندهٔ خودکار، Git، Python، ابزارهای لازم، مخزن Raah و نسخهٔ رسمی `sing-box` را از مخزن APT امضاشده نصب می‌کند. برای Hysteria 2 همچنان گواهی معتبر TLS لازم است.

```bash
git clone https://github.com/qasamij/raah-tunnel.git
cd raah-tunnel
python3 raahctl.py generate --out ./private-bundle
```

### نصب سریع روی VPS

روی سرور اول این دستور را اجرا کن. اسکریپت همهٔ وابستگی‌ها و مخزن را دانلود می‌کند و سپس ویزارد ساخت bundle مشترک را باز می‌کند:

```bash
curl -fsSL https://raw.githubusercontent.com/qasamij/raah-tunnel/main/one-click-install.sh -o /tmp/raah-install.sh && \
sudo bash /tmp/raah-install.sh --menu
```

در منوی انگلیسی گزینهٔ ساخت کانفیگ را انتخاب کن. bundle را فقط **یک بار** بساز تا کلیدهای دو سمت مشترک باشند؛ برای حالت مستقیم فایل‌ها در `/root/raah-private-bundle/` قرار می‌گیرند. `outside.json` را فقط روی سرور خارج و `iran-01.json` را فقط روی سرور ایران بگذار.

### پاسخ به پرسش‌ها برای دو سرور (یک ایران و یک خارج)

در منو گزینهٔ `1` را انتخاب کن. برای پرسش «Outside server PUBLIC IP» نشانی عمومی سرور **خارج** را بده؛ برای «Iran server PUBLIC IP» نشانی عمومی سرور **ایران** را بده. اگر فقط یک سرور ایران داری، همان یک IP را وارد کن؛ نشانی خارج را دوباره وارد نکن. نام دامنهٔ گواهی TLS خارج باید به IP خارج و نام دامنهٔ گواهی TLS ایران باید به IP ایران اشاره کند. این دو دامنه باید گواهی معتبر متناظر داشته باشند. نام `REALITY SNI` یک دامنهٔ عمومی در دسترس است، مثل نمونهٔ پیشنهادی ویزارد؛ IP سرور خودت نیست. برای تنظیمات پیشنهادی داخل `[ ]` فقط Enter بزن؛ پورت TCP خارج پیش‌فرض `7788` و ایران `8877` است و UDP هر دو `8443` است.

ویزارد به‌طور پیش‌فرض با HTTPS و به‌ترتیب از `api4.ipify.org`، `ifconfig.me` و `icanhazip.com` تلاش می‌کند IP عمومی **همین سرور** را پیدا کند؛ کشور آن و کشور IPهای واردشده را با `ipwho.is` تقریب می‌زند. با اولین پاسخ معتبر، درخواست‌های بعدی اجرا نمی‌شوند. این درخواست‌ها IP سرورها را در اختیار سرویس مربوط قرار می‌دهند. پیش از قبول IP پیشنهادی، نقش همین سرور (`Iran` یا `Outside`) را بررسی کن و اطلاعات را با پنل VPS تطبیق بده؛ اگر ویزارد از پشت پراکسی اجرا شود IP تشخیص‌داده‌شده می‌تواند اشتباه باشد. اگر همهٔ سرویس‌ها در دسترس نباشند، آدرس‌ها را دستی وارد کن. برای صرف‌نظر از درخواست‌های آنلاین، `sudo bash /tmp/raah-install.sh --generate --no-discovery` را اجرا کن.

اگر پوشهٔ `/opt/raah-tunnel` تغییر محلی داشته باشد، نصب‌کننده آن را حذف یا بازنویسی نمی‌کند؛ فهرست فایل‌های تغییرکرده را نشان می‌دهد و عملیات همان اجرا را از یک کپی تمیز موقت انجام می‌دهد.

**قبل از `--start`:** روی *هر دو سرور* گواهی معتبر Hysteria 2 و کلید خصوصی متناظر را به‌ترتیب در `/etc/raah/tls/fullchain.pem` و `/etc/raah/tls/privkey.pem` قرار بده، یا موقع ساخت از `generate --advanced` برای تعیین مسیرهای متفاوت استفاده کن. نصب‌کننده برایت دامنه یا گواهی صادر نمی‌کند؛ با صرف داشتن IP عمومی نمی‌توان مرحلهٔ گواهی را به‌درستی تکمیل کرد. فایل `DEPLOY.txt` پورت‌هایی را نشان می‌دهد که باید در فایروال سیستم و ارائه‌دهنده باز کنی. اگر دامنه و گواهی هنوز نداری، قبل از شروع سرویس آن‌ها را فراهم کن.

خروجی ویزارد بعد از ساخت، دستورهای انتقال `iran-01.json` با `scp` و نصب جداگانه روی هر دو سرور را چاپ می‌کند. محل فایل انتقال‌داده‌شده را در دستور نصب ایران دقیقاً مطابق محل واقعی فایل بنویس. فایل‌ها را در مخزن عمومی قرار نده.

**سرور خارج:**

```bash
sudo bash /tmp/raah-install.sh --config /root/raah-private-bundle/outside.json --start
```

**سرور ایران:**

```bash
scp root@OUTSIDE_IP:/root/raah-private-bundle/iran-01.json /root/iran-01.json
curl -fsSL https://raw.githubusercontent.com/qasamij/raah-tunnel/main/one-click-install.sh -o /tmp/raah-install.sh
sudo bash /tmp/raah-install.sh --config /root/iran-01.json --start
```

فایل JSON همان سرور را با `scp` در مسیر گفته‌شده قرار بده؛ اگر جای دیگری کپی کردی، مسیر همان فایل را در دستور بنویس. هرگز bundle محرمانه را روی GitHub نگذار. نصب‌کننده وابستگی‌ها را دریافت می‌کند و سرویس مستقل `raah-sing-box` می‌سازد. گواهی TLS معتبر و بازکردن دستی پورت‌های `DEPLOY.txt` هنوز لازم است. **Raah به‌تنهایی کاربران و inboundهای x-ui را به این تونل متصل نمی‌کند؛ مسیر خروجی پنل را جداگانه تنظیم کن.**

برای ساخت مستقیم، ریورس یا هر دو:

```bash
python3 raahctl.py generate --mode direct --out ./private-bundle
python3 raahctl.py generate --mode reverse --out ./private-reverse
python3 raahctl.py generate --mode both --out ./private-both
```

اگر خواستی REALITY SNI را خودش پیشنهاد بدهد و چند fallback بسازد:

```bash
python3 raahctl.py sni-scan
python3 raahctl.py generate --auto-sni --sni-pool-size 3 --out ./private-bundle
```

### ویرایش امن و خودکار

از منوی نصب گزینهٔ `8` را انتخاب کن، یا دستور زیر را اجرا کن:

```bash
python3 raahctl.py edit-bundle /root/raah-private-bundle
```

می‌توانی IP/دامنهٔ خارج، IP/دامنهٔ هر سرور ایران، پورت‌های Hysteria 2 و REALITY، فهرست SNI و Health URL هر سمت را انتخاب و ویرایش کنی. ابزار پیش از تغییر، یک بکاپ زمان‌دار با مجوز `700/600` کنار bundle می‌سازد، کلیدها و UUIDها را نگه می‌دارد و همهٔ فایل‌های سرور و کلاینت را هماهنگ بازسازی می‌کند. بعد از تغییر، فایل JSON متناظر را دوباره روی هر سرور نصب و پروفایل کلاینت به‌روز را توزیع کن.

نمونهٔ غیرتعاملی برای تعویض سریع IP خارج:

```bash
python3 raahctl.py edit-bundle /root/raah-private-bundle \
  --outside-address NEW_OUTSIDE_IP
```

نمونهٔ تعویض IP سرور ایران اول:

```bash
python3 raahctl.py edit-bundle /root/raah-private-bundle \
  --iran-address 1=NEW_IRAN_IP
```

بعد از تغییر IP خارج، `outside.json` را روی سرور خارج جدید و `iran-01.json` را روی سرور ایران دوباره نصب کن. بعد از تغییر IP ایران، `iran-01.json` را روی همان سرور و `client-linux.json` را برای کلاینت‌ها به‌روز کن. ویرایشگر bundle سرویس‌های دو سرور را از راه دور restart نمی‌کند.

پس از اولین نصب، منو را با `sudo raah-install --menu` باز کن. گزینهٔ `9` آخرین تگ پایدار منتشرشده را نصب می‌کند. گزینهٔ `10` پس از نوشتن عبارت `UNINSTALL` سرویس و فایل‌های نصب Raah را حذف می‌کند؛ حذف bundle محرمانه یک تأیید جدا دارد. بستهٔ مشترک `sing-box` عمداً پاک نمی‌شود.

ویزارد ساده آدرس سرور خارج/مقصد، یک یا چند IP/دامنهٔ ورودی ایران، دامنه‌های گواهی TLS، SNI و پورت‌ها را می‌پرسد. در حالت مستقیم این فایل‌ها را می‌سازد:

برای پرسش‌های بیشتر مثل مسیر اختصاصی گواهی و SNI مجزای ایران، از `python3 raahctl.py generate --advanced --out ./private-bundle` استفاده کن. در حالت ساده مسیر گواهی هر دو سرور ثابت است و تعداد پرسش‌ها کمتر است.

- `outside.json`
- `outside.install.json` برای تنظیم امن DNAT و port hopping همان سرور
- `iran-01.json`، `iran-02.json` و ... (هر فایل مخصوص یک ورودی ایران است)
- `iran-01.install.json`، `iran-02.install.json` و ...
- `client-linux.json`
- `DEPLOY.txt`

در حالت ریورس، فایل‌های `reverse-outside-entry.json`، `reverse-iran-exit-01.json`، فایل‌های `.install.json` متناظر و `reverse-client-linux.json` ساخته می‌شوند. در حالت `both` دو پوشهٔ جدا به نام‌های `direct` و `reverse` ساخته می‌شود. هنگام انتقال، JSON هر سرور و فایل `.install.json` هم‌نام آن را کنار هم نگه دار.

فایل‌ها محرمانه‌اند و با مجوز محدود ساخته می‌شوند. آن‌ها را در GitHub قرار نده؛ از SSH/SCP برای انتقال استفاده کن و پس از نصب نسخهٔ خصوصی را پاک کن. سرویس راه روی پورت‌های خودش اجرا می‌شود و x-ui را تغییر نمی‌دهد.

برای نصب دستی نیز دستورها را **روی دو سرور جداگانه** اجرا کن. اسکریپت و کانفیگ مربوطه باید از قبل در همان سرور موجود باشد.

**سرور خارج:**

```bash
cd /opt/raah-tunnel
sudo bash scripts/install-unit.sh /root/raah-private-bundle/outside.json
sudo systemctl enable --now raah-sing-box
```

**سرور ایران:**

```bash
cd /opt/raah-tunnel
sudo bash scripts/install-unit.sh /root/raah-private-bundle/iran-01.json
sudo systemctl enable --now raah-sing-box
```

برای سرور ایران دوم از `iran-02.json` همان سرور استفاده کن. اگر بعداً کانفیگ را عوض کردی، `sudo systemctl restart raah-sing-box` را اجرا کن.

اسکریپت، کانفیگ را پیش از نصب اعتبارسنجی می‌کند؛ پورت فایروال را باز نمی‌کند و x-ui را ریستارت نمی‌کند. برای port hopping فقط جدول DNAT مجزای `raah_porthop` را می‌سازد؛ بازکردن کل بازهٔ UDP در UFW و فایروال پنل VPS با شماست.

پورت پایهٔ پیش‌فرض REALITY خارج/مقصد TCP/7788 و ایران TCP/8877 است تا دو سمت با هم قاطی نشوند. اگر چند SNI وارد کنی، پورت‌های بعدی خودکار مصرف می‌شوند؛ مثلا خارج/مقصد `7788, 7789, 7790` و ایران `8877, 8878, 8879`.

حالت پیشرفته Health URL جدا برای مسیر خارج و ایران و زمان‌بندی `urltest` را می‌پرسد. مقدار پیش‌فرض `https://cp.cloudflare.com/generate_204` است؛ اگر روی مسیر واقعی قابل دسترس نبود از گزینهٔ 8 منو آن را تغییر بده. برای failover سریع‌تر می‌توانی `10s` بدهی؛ مقدار آرام‌تر و پیش‌فرض `15s` است.

## نکته‌های عملی

- Hysteria 2 برای کار به UDP نیاز دارد. Salamander/Gecko یا جابه‌جایی پورت ممکن است در بعضی مسیرها کمک کند، اما UDP مسدودشده را تضمینی باز نمی‌کند.
- کلاینت sing-box 1.14 از DNS رمزگذاری‌شدهٔ DoH داخل مسیر انتخاب‌شده و حالت `dns_mode: hijack` استفاده می‌کند. قالب قدیمی FakeIP در 1.14 حذف شده و عمداً تولید نمی‌شود.
- port hopping هایستریا اکنون هماهنگ پیاده شده است: کلاینت `server_ports` و `hop_interval` می‌گیرد و فایل `.install.json` متناظر یک سرویس مستقل nftables برای DNAT می‌سازد. بازهٔ کامل UDP نوشته‌شده در `DEPLOY.txt` را همچنان باید در فایروال پنل VPS باز کنی.
- REALITY روی TCP مسیر جایگزین است؛ ارسال UDP از داخل پراکسی TCP ممکن است با تأخیر و jitter بیشتری همراه شود. برای بازی، مسیر UDP سالم کیفیت بهتری می‌دهد.
- SNI اسکن‌شده فقط از دید همان ماشین تست معتبر است. بهتر است `sni-scan` را از ایران و خارج/مقصد جداگانه اجرا کنی. در حالت چند SNI، اگر یکی از مسیرهای REALITY مشکل پیدا کند، sing-box با `urltest` مسیرهای دیگر را انتخاب می‌کند.
- نام دامنهٔ Hysteria باید گواهی منطبق داشته باشد. دامنه را در Arvan یا Cloudflare به‌صورت DNS-only تنظیم کن؛ CDN معمولی QUIC تونل را عبور نمی‌دهد.
- حالت direct یعنی کلاینت به ایران وصل می‌شود و خارج/مقصد خروجی اینترنت است. حالت reverse یعنی کلاینت به خارج/مقصد وصل می‌شود و یکی از سرورهای ایران خروجی می‌شود. اگر هر دو حالت را روی یک میزبان هم‌زمان می‌خواهی، پورت‌های یکی را تغییر بده تا تداخل نکنند.
- انتخاب ورودی این نسخه در سمت کلاینت است: sing-box ورودی‌های ایران را آزمایش می‌کند و یکی را برمی‌گزیند؛ این توزیع هم‌زمان بار بین چند سرور نیست. DNS فقط نام را به IP تبدیل می‌کند و اتصال جاری را هنگام قطعی حفظ نمی‌کند.
- مدیریت اصلی کاربر باید در x-ui/3x-ui انجام شود. دستورهای `add-user`، `revoke-user` و `enforce-users` فقط برای سازگاری با bundleهای قدیمی باقی مانده‌اند و نباید برای کاربران x-ui استفاده شوند.
- `audit-report` لاگ دسترسی Xray/x-ui را بر اساس کاربر، مقصد، پروتکل، زمان اتصال و حجم جمع‌بندی می‌کند. برای HTTPS معمولاً دامنه/SNI دیده می‌شود، نه مسیر کامل URL یا محتوای صفحه.
- `stats` و `quota-check` مجموع ترافیک کارت شبکه از زمان روشن‌شدن سرور را نشان می‌دهند؛ سهمیهٔ کاربر به کاربر هنوز enforce نمی‌شود.
- هشدار TCP را روی یک سرور مستقل اجرا کن تا خاموش‌شدن خود سرور مانیتورشونده را هم متوجه شود. ابزار داخلی فعلی UDP/Hysteria را به‌صورت end-to-end probe نمی‌کند و مانیتور داخل همان سرور نمی‌تواند قطعی برق یا اینترنت خودش را گزارش کند.

```bash
python3 raahctl.py stats --interface eth0
python3 raahctl.py quota-check --interface eth0 --limit-gb 500
python3 raahctl.py status --interface eth0
python3 raahctl.py doctor ./private-bundle
python3 raahctl.py audit-report /var/log/xray/access.log --user ali
python3 raahctl.py firewall-plan ./private-bundle --ssh-port 22
python3 raahctl.py probe --host ir-entry.example.net --port 8877 --count 20
python3 raahctl.py e2e-probe ./private-bundle/client-linux.json --count 5
python3 raahctl.py watch --host ir-entry.example.net --port 8877 --interval 30 --telegram-env
```

دستور `e2e-probe` یک ورودی SOCKS فقط روی `127.0.0.1` و در یک پوشهٔ موقت با مجوز محدود می‌سازد، کانفیگ را با `sing-box check` اعتبارسنجی می‌کند و درخواست HTTP/HTTPS را با `curl` از کل مسیر عبور می‌دهد. برای آزمایش یک مسیر مشخص، تگ آن را با `--outbound TAG` بده؛ بدون این گزینه همان `urltest` نهایی کانفیگ آزمایش می‌شود. این تست باید از دستگاه یا شبکه‌ای اجرا شود که نقش کلاینت واقعی را دارد.

برای اعلان، متغیرهای `TELEGRAM_BOT_TOKEN` و `TELEGRAM_CHAT_ID` را فقط روی ماشین مانیتور تنظیم کن.

### لاگ و حریم خصوصی

لاگ فعالیت باید در x-ui/Xray و با اطلاع کاربران فعال شود. فقط متادیتای لازم مانند زمان، کاربر، دامنه/مقصد، پروتکل و حجم را نگه‌دار؛ بدنهٔ ترافیک، رمزها و مسیر کامل HTTPS قابل ثبت امن نیستند. فایل لاگ را با دسترسی `600`، چرخش روزانه و نگهداری محدود (مثلاً ۷ یا ۳۰ روز) ذخیره کن. Raah این لاگ را تولید یا به تلگرام ارسال نمی‌کند.

جزئیات طراحی و مقایسهٔ پروتکل‌ها: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) و [docs/PROTOCOLS.md](docs/PROTOCOLS.md). تغییرات نسخه‌ها در [CHANGELOG.md](CHANGELOG.md) آمده است.
