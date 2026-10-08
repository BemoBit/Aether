<p align="center">
  <strong>Aether</strong><br>
  One uplink. Three ways to use it on Linux.<br>
  یک لینک. سه حالت استفاده روی لینوکس.
</p>

<p align="center">
  <a href="#english">English</a> · <a href="#فارسی">فارسی</a>
</p>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-111111">
  <img alt="Platform" src="https://img.shields.io/badge/platform-Linux%20%2B%20systemd-111111">
  <img alt="Engine" src="https://img.shields.io/badge/engine-sing--box%201.14.2-111111">
</p>

Aether takes a proxy or share link you already have and puts it to work on a Linux server. It does not sell access and it does not run a VPN panel of its own. The engine is [sing-box](https://github.com/SagerNet/sing-box), bound to `127.0.0.1`. You get a terminal menu for the jobs that stall when GitHub, Docker Hub, or the Ubuntu archive is hard to reach: package installs, image pulls, file downloads, and the official 3x-ui installer.

---

## English

### Traffic scope

| Scope | Command | What crosses the uplink |
| --- | --- | --- |
| Application | `aether scope tool` | Only programs Aether launches, and `aether exec`. Everything else stays as it was. This is the default. |
| System proxy | `aether scope system` | The application scope, plus a published system proxy. Programs that honor `http_proxy`, `https_proxy`, and `all_proxy` use the uplink. apt is included. |
| Full tunnel | `aether scope tunnel` | All outbound traffic, including programs that ignore proxy settings. |

Full tunnel keeps a direct route for the current SSH client when `SSH_CONNECTION` is set. If the server stops answering, open the console and run:

```bash
sudo aether scope tool
```

### Supported uplinks

| Link | What Aether accepts |
| --- | --- |
| HTTP / HTTPS | `http://host:port`, optional username and password |
| SOCKS | `socks5://`, `socks4://`, `socks4a://` |
| VLESS | TCP, WebSocket, gRPC, HTTP, HTTPUpgrade, QUIC. TLS and Reality, including `xtls-rprx-vision` on TCP |
| VMess | Standard `vmess://` links |
| Trojan | `trojan://` |
| Shadowsocks | SIP002 and the legacy base64 form |

Paste the link, or enter an HTTP or SOCKS proxy as host, port, and an optional login. XHTTP, SplitHTTP, and mKCP are refused up front. The bundled sing-box build does not implement them.

### Install

```bash
curl -fsSL https://raw.githubusercontent.com/BemoBit/Aether/main/install.sh | sudo bash
sudo aether
```

`ae` is a shortcut for `aether` when that command name is free.

From a checkout of this repository:

```bash
sudo bash install.sh
sudo aether
```

The installer downloads sing-box 1.14.2 for `amd64` or `arm64`. If GitHub is unreachable, copy a sing-box binary to `/usr/local/lib/aether/sing-box` and run `sudo aether` again.

Package commands and the Docker apt repository need Debian or Ubuntu. The uplink service needs systemd. The proxy and the full tunnel are the parts that matter on any other systemd distribution. Aether will say so when a menu action needs apt.

### Menu

| | Action |
| --- | --- |
| 1 | Check GitHub, the Ubuntu archive, and the Docker registry |
| 2 | Update package lists, upgrade, or install one package |
| 3 | Install Docker, pull an image, or toggle the daemon proxy |
| 4 | Download a file through the uplink |
| 5 | Install 3x-ui (Sanaei) from the official installer |
| 6 | Choose application, system proxy, or full tunnel |
| 7 | Status, change the uplink, enable, disable, uninstall |
| 8 | Update Aether from GitHub |
| 0 | Exit |

The first run asks for an uplink before the menu. Settings can replace it later.

### Commands

```bash
sudo aether
sudo aether status
sudo aether check
sudo aether on
sudo aether off
sudo aether scope tool
sudo aether scope system
sudo aether scope tunnel
sudo aether set 'vless://...'
sudo aether parse 'vless://...'
sudo aether exec -- curl -I https://example.com
sudo aether version
```

`aether parse` prints the server, port, security, and transport. It does not print passwords, UUIDs, or keys.

Enabling the full tunnel from a script needs an explicit confirmation:

```bash
sudo AETHER_ASSUME_YES=1 aether scope tunnel
```

### What each scope writes

Application mode starts the local sing-box service and nothing else.

System proxy also writes:

- `/etc/profile.d/aether.sh`
- `/etc/apt/apt.conf.d/80aether`
- a marked block in `/etc/environment`

Open a new login shell before expecting every program to see the new variables. Services that are already running do not pick them up. Docker has its own switch in the Docker menu, because the daemon ignores a user's environment.

Full tunnel adds an `aether0` interface and routes outbound traffic through it. Private destinations stay direct. sing-box resolves the uplink host with the system resolver and resolves other destinations through the uplink. When `nft` is installed, `auto_redirect` is turned on so forwarded traffic, including Docker, follows the tunnel. If that start fails, Aether retries once without it.

### Paths

| Path | Role |
| --- | --- |
| `/usr/local/bin/aether` | Command |
| `/usr/local/bin/ae` | Shortcut |
| `/usr/local/lib/aether/` | Program, libraries, sing-box binary |
| `/etc/aether/config.env` | Saved uplink, mode 600 |
| `/etc/aether/sing-box.json` | Generated engine config, mode 600 |
| `/var/lib/aether/` | Baseline of Docker settings, taken before Aether changes them |
| `/var/log/aether.log` | Short action log |

### Uninstall

From Settings, or:

```bash
sudo bash /usr/local/lib/aether/uninstall.sh
sudo bash /usr/local/lib/aether/uninstall.sh --purge
sudo bash /usr/local/lib/aether/uninstall.sh --no-restore
```

`--purge` also removes the saved uplink, the Docker baseline, and the log. `--no-restore` leaves Docker's daemon settings and the system proxy files where they are.

### Development

```bash
python3 -m unittest tests/test_link.py
```

The parser tests need no root access and no network. `sudo ./aether` from a checkout uses that checkout's code and the system paths under `/etc/aether`.

### Limits

- The share link is stored on disk. The config directory is mode 700 and the file is mode 600.
- The local proxy binds to `127.0.0.1` only. If it ever listens on a public address, Aether stops it.
- The first package install, and only that install, can temporarily point DNS at Shecan (`178.22.122.100`, `185.51.200.2`) and an ArvanCloud mirror when apt cannot be reached directly. The previous resolver and apt sources are put back afterwards.
- 3x-ui is installed by the upstream project's own installer. Aether downloads it and passes a release tag.

---

## فارسی

Aether ابزار خط فرمان برای سرور لینوکس است. پروکسی نمی‌فروشد و پنل VPN هم بالا نمی‌آورد. یک لینک یا پروکسی را که خودتان دارید می‌گیرد و روی سیستم قابل استفاده می‌کند. موتور sing-box است و فقط روی `127.0.0.1` گوش می‌دهد.

به درد سروری می‌خورد که گرفتن بسته، ایمیج Docker، یا فایل از GitHub گیر می‌کند. از داخل منو می‌شود لیست بسته‌ها را به‌روز کرد، Docker نصب کرد، فایل دانلود کرد، و نصب‌کنندهٔ رسمی 3x-ui را اجرا کرد.

### سه حالت ترافیک

| حالت | دستور | چه ترافیکی از لینک رد می‌شود |
| --- | --- | --- |
| برنامه | `aether scope tool` | فقط برنامه‌هایی که خود Aether اجرا می‌کند، و `aether exec`. بقیهٔ سیستم دست نمی‌خورد. این حالت پیش‌فرض است. |
| پروکسی سیستم | `aether scope system` | حالت برنامه، به‌علاوهٔ پروکسی منتشرشده در سیستم‌عامل. هر برنامه‌ای که `http_proxy` و `https_proxy` و `all_proxy` را بخواند از همین لینک استفاده می‌کند. apt هم شامل می‌شود. |
| تونل کامل | `aether scope tunnel` | کل ترافیک خروجی سرور، حتی برنامه‌هایی که تنظیم پروکسی را نادیده می‌گیرند. |

در تونل کامل، اگر متغیر `SSH_CONNECTION` پر باشد، مسیر مستقیم برای همان کلاینت SSH حفظ می‌شود. اگر سرور دیگر جواب نداد، از کنسول این را بزنید:

```bash
sudo aether scope tool
```

### لینک‌های قابل قبول

| نوع | شکل ورودی |
| --- | --- |
| HTTP / HTTPS | `http://host:port`، با نام کاربری و رمز اختیاری |
| SOCKS | `socks5://` و `socks4://` و `socks4a://` |
| VLESS | TCP، وب‌سوکت، gRPC، HTTP، HTTPUpgrade، QUIC. TLS و Reality، از جمله `xtls-rprx-vision` روی TCP |
| VMess | لینک استاندارد `vmess://` |
| Trojan | `trojan://` |
| Shadowsocks | هر دو شکل SIP002 و base64 قدیمی |

لینک را می‌شود چسباند، یا برای HTTP و SOCKS میزبان و پورت و در صورت نیاز اطلاعات ورود را جدا نوشت. XHTTP و SplitHTTP و mKCP همان اول رد می‌شوند. نسخهٔ sing-box که همراه برنامه می‌آید این‌ها را ندارد.

### نصب

```bash
curl -fsSL https://raw.githubusercontent.com/BemoBit/Aether/main/install.sh | sudo bash
sudo aether
```

اگر دستور `ae` روی سیستم اشغال نشده باشد، میانبر `aether` است.

از روی کلون همین مخزن:

```bash
sudo bash install.sh
sudo aether
```

نصب‌کننده sing-box نسخهٔ 1.14.2 را برای `amd64` یا `arm64` می‌گیرد. اگر سرور به GitHub نمی‌رسد، فایل اجرایی sing-box را در `/usr/local/lib/aether/sing-box` بگذارید و دوباره `sudo aether` را اجرا کنید.

دستورهای بسته و مخزن apt داکر به دبیان یا اوبونتو نیاز دارند. خود سرویس لینک به systemd نیاز دارد. روی توزیع دیگری که systemd دارد، پروکسی و تونل کامل کار می‌کنند. هر جا منو به apt نیاز داشته باشد، خودش می‌گوید.

### منو

| | کار |
| --- | --- |
| ۱ | تست GitHub، آرشیو اوبونتو، و رجیستری Docker |
| ۲ | به‌روزرسانی لیست بسته‌ها، ارتقا، یا نصب یک بسته |
| ۳ | نصب Docker، دریافت ایمیج، یا روشن و خاموش کردن پروکسی دیمون |
| ۴ | دانلود فایل از طریق لینک |
| ۵ | نصب 3x-ui سنایی با نصب‌کنندهٔ رسمی |
| ۶ | انتخاب حالت برنامه، پروکسی سیستم، یا تونل کامل |
| ۷ | وضعیت، تعویض لینک، فعال‌سازی، غیرفعال‌سازی، حذف |
| ۸ | به‌روزرسانی خود Aether از GitHub |
| ۰ | خروج |

اجرای اول، پیش از منو، لینک را می‌پرسد. بعداً از تنظیمات عوض می‌شود.

### دستورها

```bash
sudo aether
sudo aether status
sudo aether check
sudo aether on
sudo aether off
sudo aether scope tool
sudo aether scope system
sudo aether scope tunnel
sudo aether set 'vless://...'
sudo aether parse 'vless://...'
sudo aether exec -- curl -I https://example.com
sudo aether version
```

`aether parse` سرور، پورت، نوع امنیت و انتقال را نشان می‌دهد. رمز، UUID و کلید را چاپ نمی‌کند.

فعال کردن تونل کامل از داخل اسکریپت تأیید صریح می‌خواهد:

```bash
sudo AETHER_ASSUME_YES=1 aether scope tunnel
```

### هر حالت چه فایلی می‌نویسد

حالت برنامه فقط سرویس محلی sing-box را بالا می‌آورد.

پروکسی سیستم این‌ها را هم می‌نویسد:

- `/etc/profile.d/aether.sh`
- `/etc/apt/apt.conf.d/80aether`
- یک بلوک علامت‌گذاری‌شده در `/etc/environment`

برای دیدن متغیرهای تازه، یک پوستهٔ ورود جدید باز کنید. سرویسی که از قبل در حال اجراست آن‌ها را نمی‌بیند. Docker متغیر محیط کاربر را نادیده می‌گیرد، برای همین پروکسی دیمون کلید جداگانه‌ای در منوی Docker دارد.

تونل کامل رابط `aether0` را می‌سازد و ترافیک خروجی را از آن رد می‌کند. مقصدهای خصوصی مستقیم می‌مانند. نام میزبان خود لینک با DNS سیستم حل می‌شود و بقیهٔ مقصدها از داخل لینک. اگر `nft` نصب باشد، `auto_redirect` روشن می‌شود تا ترافیک فورواردشده، از جمله Docker، هم از تونل رد شود. اگر این حالت بالا نیاید، Aether یک بار بدون آن دوباره تلاش می‌کند.

### مسیرها

| مسیر | نقش |
| --- | --- |
| `/usr/local/bin/aether` | دستور اصلی |
| `/usr/local/bin/ae` | میانبر |
| `/usr/local/lib/aether/` | برنامه، کتابخانه‌ها، فایل sing-box |
| `/etc/aether/config.env` | لینک ذخیره‌شده، مجوز ۶۰۰ |
| `/etc/aether/sing-box.json` | پیکربندی ساخته‌شدهٔ موتور، مجوز ۶۰۰ |
| `/var/lib/aether/` | نسخهٔ قبلی تنظیم Docker، پیش از دستکاری Aether |
| `/var/log/aether.log` | گزارش کوتاه کارها |

### حذف

از منوی تنظیمات، یا:

```bash
sudo bash /usr/local/lib/aether/uninstall.sh
sudo bash /usr/local/lib/aether/uninstall.sh --purge
sudo bash /usr/local/lib/aether/uninstall.sh --no-restore
```

`--purge` لینک ذخیره‌شده، نسخهٔ پشتیبان تنظیم Docker، و لاگ را هم پاک می‌کند. `--no-restore` تنظیم دیمون Docker و فایل‌های پروکسی سیستم را سر جایشان می‌گذارد.

### آزمون

```bash
python3 -m unittest tests/test_link.py
```

آزمون پارسر به ریشه و شبکه نیاز ندارد. `sudo ./aether` از داخل کلون، کد همان پوشه را با مسیرهای سیستمی زیر `/etc/aether` اجرا می‌کند.

### حد کار

- لینک روی دیسک ذخیره می‌شود. پوشهٔ تنظیم حالت ۷۰۰ دارد و خود فایل حالت ۶۰۰.
- پروکسی محلی فقط به `127.0.0.1` وصل می‌شود. اگر روی آدرس عمومی گوش بدهد، Aether متوقفش می‌کند.
- فقط همان نصب اول بسته‌ها، اگر apt مستقیم در دسترس نباشد، موقتاً DNS را روی شکن (`178.22.122.100` و `185.51.200.2`) و مخزن آروان‌کلاد می‌گذارد. بعد از کار، resolver و سورس‌های apt به حالت قبل برمی‌گردند.
- 3x-ui با نصب‌کنندهٔ خود پروژهٔ بالادست نصب می‌شود. Aether آن را دانلود می‌کند و شمارهٔ نسخه را به آن می‌دهد.
