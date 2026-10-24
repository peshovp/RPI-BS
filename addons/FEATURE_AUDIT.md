# Одит на addons/ (GeoMaxima extension) — RPI-BS

**Дата:** 2026-07-02
**Метод:** Само четене на кода в работното дърво (read-only). Няма извършени промени, commit-и или git add.
**Обхват:** `addons/` (controller.py, config.py, features/*, templates/geomaxima/*, requirements*.txt) + кръстосана проверка с `tools/bin/RTKLIB-2.5.0/`.

---

## 0. Статус на интеграцията (общ контекст)

Потвърдено: `addons/` **не е** wire-нат към `web_app/server.py` — никъде в `web_app/server.py` не се извиква `init_geomaxima`. Това е самостоятелен, готов-за-монтиране пакет.

### Интеграционен контракт, очакван от `addons/controller.py`

- Публичната входна точка е `init_geomaxima(app)` (модул-ниво функция) → създава `GeoMaximaController`, вика `controller.register_routes(app)`.
- `register_routes(app)`:
  - Проверява дали Blueprint `geomaxima` вече е регистриран (idempotent guard).
  - Регистрира core routes (`/`, `/rtcm-info`, `/api/info`, `/api/status`, `/api/features`) директно върху модул-ниво `geomaxima_bp = Blueprint('geomaxima', __name__, url_prefix='/geomaxima', template_folder='templates', static_folder='static', static_url_path='/static/geomaxima')` — **точно съвпада** с познатия по-рано патърн (`init_geomaxima(app)` + `Blueprint(..., template_folder='templates')`).
  - Динамично сканира `addons/features/*.py` (без `__`-префикс файлове) и за всеки файл, чието име (без `.py`) е `True` в `config.FEATURES`, прави `__import__("geomaxima.features.<name>")` и вика `feature_module.register_routes(self.app, geomaxima_bp)`.
  - **Важно:** очаква модулният път `geomaxima.features.<feature>` да е импортируем — т.е. `addons/` трябва да е монтиран/наличен под Python пакет с име `geomaxima` (виж `from geomaxima import config` в началото на файла). В момента `addons/__init__.py` не съдържа алиас/preinstall стъпка за това — интеграцията ще изисква или symlink/copy на `addons/` като `geomaxima` пакет в `web_app/`, или `sys.path` магия, направена от `server.py` при истинска инсталация (коментарът "sys.path is already configured by server.py" го потвърждава — т.е. server.py трябва да добави пътя, но в момента не го прави).
  - Допълнително регистрира `rtcm_dropdown_injector.register_rtcm_injector(app)` и `rtkbase_proxy.register_rtkbase_proxy(app)` безусловно (независимо от `FEATURES` флаговете).

### Feature флагове в `addons/config.py`

```
FEATURES = {
    "wireguard_client": True,
    "auto_survey_feature": True,
    "ota_update_feature": True,
    "watchdog_feature": True,
    "gnss_config_feature": True,
    "external_integration_feature": True,
    "system_settings_feature": True,
}
```

**Находка:** `custom_analytics_feature` **липсва** от `FEATURES` речника → дори ако `addons/` бъде wire-нат утре, `custom_analytics_feature.py` **няма да се зареди**, защото `config.is_feature_enabled("custom_analytics_feature")` връща `False` по подразбиране (fallback в `is_feature_enabled`). Това е активен пропуск, не просто "неактивирано по избор".

### rnx2rtkp срещу `tools/bin/RTKLIB-2.5.0/` — КЛЮЧОВА НАХОДКА

Проверени са и трите архитектурни поддиректории:
- `tools/bin/RTKLIB-2.5.0/aarch64/` → съдържа само `convbin`, `rtkrcv`, `str2str` (+ файл `compiled_with_bookworm`, маркер, не directory).
- `tools/bin/RTKLIB-2.5.0/armv7l/` → същото: `convbin`, `rtkrcv`, `str2str`.
- `tools/bin/RTKLIB-2.5.0/armv6l/` → същото: `convbin`, `rtkrcv`, `str2str`.

**`rnx2rtkp` липсва във всички архитектури.** А `addons/features/auto_survey/spp_processor.py` (класът `SPPProcessor`) очаква точно този бинарник и го търси чрез `find_rtklib_tool("rnx2rtkp")`, който проверява (в ред):
1. `shutil.which("rnx2rtkp")` (системен PATH)
2. `/usr/local/bin/rnx2rtkp`, `/usr/bin/rnx2rtkp`
3. `~/RTKLIB/rnx2rtkp`
4. `~/rtkbase/tools/bin/RTKLIB-2.5.0/<arch>/rnx2rtkp`, ...`/armv7l/...`, ...`/aarch64/...`

Тъй като нито един от търсените пътища реално съдържа `rnx2rtkp` в това repo, при първо инстанциране на `SPPProcessor()` (случва се безусловно в конструктора на `SurveyController.__init__`) ще бъде хвърлено `FileNotFoundError("rnx2rtkp not found. Please install RTKLIB.")`. **Auto Survey модулът НЕ може да проработи "както е", докато `rnx2rtkp` не бъде компилиран/добавен отделно** (или инсталиран системно през `apt`/сорс билд на RTKLIB, което съдържа `rnx2rtkp` в `app/consapp/rnx2rtkp/`).

`convbin` (за `RINEXConverter`) е наличен коректно и ще бъде намерен чрез автодетекция.

---

## 1. Одит по фийчър

### 1.1 `auto_survey` (файл: `auto_survey_feature.py` + пакет `auto_survey/`)

- **Функция:** 24-часово автоматично survey-in на базовата станция — четене на `rover.pos`, статистическо оценяване на позицията (MAD outlier rejection, тегловно осредняване), геоид корекция, обновяване на `settings.conf`, персистиране на състояние за recovery.
- **Статус:** Най-зрелият модул в addons — версия `1.3.1`, богат README, ясна архитектура (`survey_controller.py`, `gnss_parser.py`, `position_estimator.py`, `geoid_corrector.py`, `config_manager.py`, `state_manager.py`, `rinex_converter.py`, `spp_processor.py`). Няма открити `TODO`/placeholder маркери в grep. Реализацията изглежда завършена откъм логика.
- **Външни зависимости:**
  - Системни: `convbin` (намира се в `tools/bin/RTKLIB-2.5.0/<arch>/`), `rnx2rtkp` (**липсва**, виж по-горе), `systemctl` (проверка на `str2str_file.service`).
  - Python: `numpy>=1.19.0`, `scipy>=1.5.0` — присъстват в `addons/requirements.txt`.
  - Хардуер: GNSS приемник, пишещ в `rover.pos`.
- **Routes/Templates:** `/geomaxima/survey` (page), `/geomaxima/api/survey/status`, `/start`, `/stop`, `/reset`, `/config`, `/geoid`, `/geoid/upload` — всички с `@login_required`. Template: `addons/templates/geomaxima/auto_survey.html` ✅ присъства.
- **Известни рискове:**
  - **Hardcoded path:** `settings_file="/home/peshovp/rtkbase/settings.conf"` — потребителско-специфичен home directory (`peshovp`), не е портируем към друга инсталация с различен Linux user. Същото в `auto_survey_feature.py::get_survey_controller()`.
  - Липсващ `rnx2rtkp` бинарник (виж по-горе) — блокиращ проблем при реална употреба.
  - `geoid_upload` endpoint приема качване на файлове (`.bin`/`.ggf`) — има базова валидация на разширение, MIME тип и размер (5 MiB лимит), което е добра практика, но липсва проверка за съдържание/magic bytes.
- **Готовност за активиране:** **Готов с малка поправка** — трябва (а) да се добави `rnx2rtkp` бинарник (компилиран за aarch64/armv7l/armv6l или инсталиран системно), и (б) hardcoded `/home/peshovp/...` пътища да се параметризират спрямо реалния инсталационен home directory.

### 1.2 `custom_analytics` (файл: `custom_analytics_feature.py` + пакет `custom_analytics/`)

- **Функция:** Реално-времеви анализи на GNSS данни — sat tracking с елевация/азимут (чрез `satinfo` команда към RTKLIB процеса), история на SNR, fix history, CSV/JSON export.
- **Статус:** Работещ код, но **не е регистриран** в `config.FEATURES` (виж по-горе) — де факто "мъртъв" докато не се добави флаг `"custom_analytics_feature": True`. Кодът директно достъпва вътрешности на RTKLIB контролера (`rtkbase_instance.rtkc.child`, `.semaphore`, `.obs_rover`, `.status`) — плътно свързан с вътрешния API на `web_app/RTKLIB.py`, което е крехка интеграционна точка.
- **Външни зависимости:** Python: няма нови извън стандартните (`json`, `csv`, `threading`); разчита на `app.config['RTKBASE_INSTANCE']` да е сетнат от `server.py` (не е гарантирано в момента, тъй като addons не е wire-нат).
- **Routes/Templates:** `/geomaxima/analytics`, `/api/analytics/satellite-data`, `/position-stats`, `/history`, `/fix-history`, `/export`. Template: `addons/templates/geomaxima/custom_analytics.html` ✅ (плюс `.backup` копие, не се използва).
- **Известни рискове:**
  - Директен достъп до частни атрибути на RTKLIB контролера (`rtkc.child`, `rtkc.semaphore`) — ако `web_app/RTKLIB.py` промени вътрешната си структура, тук ще счупи тихо (има try/except обвивки, но само логват грешката).
  - Разчита на `app.config.get('RTKBASE_INSTANCE')`, който трябва изрично да се подаде при `server.py` инициализация — не е документирано другаде в `addons/`.
- **Готовност за активиране:** **Готов с малка поправка** — добавяне на `"custom_analytics_feature": True` в `FEATURES`, и осигуряване на `app.config['RTKBASE_INSTANCE']` от страна на `server.py` при истинско wiring.

### 1.3 `external_integration` (файл: `external_integration_feature.py`, без под-пакет)

- **Функция:** Интеграция с "GNSS.NET" централен caster — регистрация на станцията, периодично изпращане на статус/health метрики, четене на позиция от `settings.conf`.
- **Статус:** Частично завършен. Съдържа единствения открит `TODO` в целия `addons/features/` grep: `# TODO: Get real metrics from system monitoring` (health метриките — `cpu_usage`, `memory_usage`, `disk_usage`, `rtcm_rate` — са **hardcoded на 0**, не се четат реално).
- **Външни зависимости:** Python: `requests` (присъства в `requirements.txt`, макар и под коментар "Watchdog monitoring notifications" — споделена зависимост). Мрежа: изходящ HTTPS към конфигурируем caster URL. Конфигурация: очаква секция `[caster_api]` в `settings.conf` — **потвърдено липсваща** в `settings.conf.default` на репото (grep за `caster_api` не намери нищо) → при първо стартиране ще ползва fallback стойности (`enabled=False`, празни url/api_key), което е безопасно по подразбиране, но означава, че фийчърът е неактивен "из кутията".
- **Routes/Templates:** Route регистрацията не се вижда напълно в прочетения откъс (стигнахме до `load_caster_config()` и старт на update thread), но template `addons/templates/geomaxima/external_integration.html` ✅ присъства, предполагащ UI за конфигурация на caster връзка.
- **Известни рискове:**
  - `api_key` се чете/пише в plaintext в `settings.conf` (`configparser`) — няма encryption/keyring. При споделяне на `settings.conf` (напр. в support tickets) ключът изтича.
  - Background thread (`update_loop`) стартира автоматично при `register_routes()` ако `enabled=True` в конфигурацията — не се спира изрично при shutdown/reload на Flask (само `daemon=True`), възможен лек risk при hot-reload на dev сървър (дублирани threads), но не е фатално.
  - Health метриките са фиктивни (0) — TODO не е разрешен, изпраща подвеждаща информация към централния caster.
- **Готовност за активиране:** **Готов с малка поправка** за самата свързаност (config/route/UI изглеждат налични), но **health метриките изискват доработка** (реално CPU/memory/disk/rtcm rate вместо hardcoded нули) преди да се разчита на мониторинга от страна на caster-а.

### 1.4 `gnss_config` (файл: `gnss_config_feature.py` + пакет `gnss_config/`)

- **Функция:** Уеб конфигурация на GNSS приемници (ZED-F9P, Mosaic-X5, UM980/UM982) — сканиране на серийни портове, детекция на тип приемник, спиране/стартиране на RTKBase услуги около сканирането.
- **Статус:** Работещ код, ясно структуриран (`config_manager.py` с `ReceiverDetector`/`GNSSConfigManager`, отделни конфигуратори за всеки чипсет). Няма открити TODO/placeholder-и.
- **Външни зависимости:**
  - Python: `pyserial` (`import serial` в `config_manager.py`, `mosaic_config.py`, `unicore_config.py`, `zedf9p_config.py`) — **липсва в `addons/requirements.txt` и `requirements-geomaxima.txt`**. Това е пропусната зависимост — `pip install -r requirements.txt` няма да инсталира `pyserial`, а модулът ще падне при import, освен ако `pyserial` вече е инсталиран транзитивно чрез основния `web_app/requirements.txt` (не е потвърдено в текущия одит — извън обхвата на `addons/`, но си струва проверка при wiring).
  - Системни: `systemctl` (`sudo systemctl stop/start` на `str2str_*` и `rtkbase_raw2nmea` услуги), нужни `sudo` права.
  - Хардуер: физически серийни портове на GNSS приемника.
- **Routes/Templates:** Регистрира собствен `Blueprint('gnss_config', ..., url_prefix='/gnss-config')` **вложен** в `gm_blueprint` чрез `gm_blueprint.register_blueprint(gnss_config_bp)` (Flask nested blueprints, изисква Flask ≥2.0) — крайният path е `/geomaxima/gnss-config/...` (различна конвенция спрямо повечето други фийчъри, които ползват `@gm_blueprint.route(...)` директно). Routes: `/`, `/api/scan`, `/api/restart-services`, `/api/info/<port>`. Template: `addons/templates/geomaxima/gnss_config.html` ✅.
- **Известни рискове:**
  - Изисква `sudo` за `systemctl stop/start` на системни услуги — предполага passwordless sudo за web процеса или ще fail-ва тихо (само warning в log, `except Exception` поглъща грешката).
  - Ако сканирането хвърли грешка, `finally` блокът винаги рестартира спрените услуги — добра практика (fail-safe), но ако `stop_rtkbase_services()` частично успее и после process се убие (SIGKILL), услугите могат да останат спрени.
- **Готовност за активиране:** **Готов с малка поправка** — добавяне на `pyserial` в `requirements.txt`/`requirements-geomaxima.txt` и потвърждение на sudo/polkit права за `systemctl` (в repo-то вече има `tools/polkit/` и `install_polkit_rules.sh`, което предполага, че такъв механизъм може вече да съществува за основния RTKBase — трябва да се провери съвместимост).

### 1.5 `ota_update` (файл: `ota_update_feature.py` + пакет `ota_update/`)

- **Функция:** Git-базирано OTA обновяване на GeoMaxima — проверка на текуща версия, git log, проверка за нови commit-и, изпълнение на update в background thread, персистиране на статус (survives service restart).
- **Статус:** Работещ, доста зрял код — има stale-lock защита (`OTA_UPDATE_STALE_MINUTES`), idempotent повторни заявки, GitHub token поддръжка (`.github_token` файл), `.git_askpass.sh` helper.
- **Външни зависимости:** Системни: `git`, `bash`/shell (чрез `subprocess`), файлова система права за пренаписване на repo. Python: няма извън стандартна библиотека (`shlex`, `tempfile`, `glob`, `threading`, `json`).
- **Routes/Templates:** `/geomaxima/update` (page), `/api/update/version`, `/check`, `/perform`, `/status`. Template: `addons/templates/geomaxima/ota_update.html` ✅.
- **Известни рискове:**
  - **Hardcoded:** `git_user: str = 'peshovp'` по подразбиране в `UpdateController.__init__` — потребителско-специфично, трябва да се параметризира при различна инсталация.
  - Съхранение на GitHub token в локален файл (`.github_token`) в repo директорията — риск ако директорията някога бъде архивирана/споделена без изключване на този файл (проверете `.gitignore` дали го покрива).
  - `perform_update` тече в детачнат background thread/процес — грешки, случили се извън основния process (напр. ако демонът бъде убит по средата на git операция), могат да оставят repo-то в несъгласувано състояние (частичен `git pull`/checkout).
- **Готовност за активиране:** **Готов с малка поправка** — параметризиране на `git_user`, проверка на `.gitignore` за `.github_token`/`.update_status.json`, и потвърждение, че `sudo`/файлови права позволяват self-update на работещото приложение.

### 1.6 `system_settings` (файл: `system_settings_feature.py`, без под-пакет)

- **Функция:** Пълен `raspi-config` контрол през уеб — hostname, WiFi country, timezone/locale, интерфейси (SSH/VNC/SPI/I2C/Serial/Camera/1-Wire), performance/boot настройки.
- **Статус:** Работещ код за прочетените функции (`get/set_hostname`, `get/set_timezone`, `get_locale`, `get/set_wifi_country`, `get_interface_status`), но файлът е дълъг и не е прочетен целият — вероятно има допълнителни функции за overclock/display/boot, споменати в docstring-а, които не са верифицирани в тази сесия.
- **Външни зависимости:** Системни: `raspi-config` (специфично за Raspberry Pi OS — **environment-specific**, няма да работи на друг Linux дистрибутив/платформа), `hostnamectl`, `timedatectl`, `sed`, `sudo` права за почти всяка операция.
- **Routes/Templates:** Не са прочетени изрично route декораторите в тази сесия (файлът е по-дълъг от 160 реда), но template `addons/templates/geomaxima/system_settings.html` ✅ присъства, потвърждаващ съществуването на UI слой.
- **Известни рискове:**
  - **Shell injection повърхност:** `set_hostname` конструира shell команда с `f"echo '{new_hostname}' | sudo tee ..."` и `run_command(cmd, shell=True)` — има regex валидация (`^[a-zA-Z0-9-]+$`) **преди** използване, което е добра защита срещу инжекция в случая на hostname. Но общата хелпър функция `run_command(cmd, shell=True)` е generic и всяка бъдеща употреба с shell=True без стриктна санитизация на входа носи риск от command injection (OWASP A03).
  - Изисква passwordless `sudo` за много операции (`hostnamectl`, `timedatectl`, `raspi-config nonint ...`) — трябва изрична polkit/sudoers конфигурация; ако липсва, всички set-операции ще fail-ват тихо с `success: False`.
  - **Не е портируем извън Raspberry Pi OS** (buster/bullseye/bookworm) заради директна зависимост от `raspi-config`.
- **Готовност за активиране:** **Изисква съществена доработка преди производствена употреба** — не заради непълен код, а заради високия risk profile (root-ниво системни промени през уеб UI без видима политика за authorization/audit trail в прочетения код) и твърдата обвързаност с Raspberry Pi OS. Препоръчва се допълнителен security review на всички `subprocess` извиквания с `shell=True` преди активиране.

### 1.7 `watchdog` (файл: `watchdog_feature.py` + пакет `watchdog/`)

- **Функция:** Системен мониторинг и auto-recovery — под-монитори за CPU, памет, диск, температура, мрежа, GNSS приемник, RTKBase услуги (`monitors/service_monitor.py`, `network_monitor.py`, `disk_monitor.py`, `gnss_monitor.py`, `temperature_monitor.py`, `cpu_monitor.py`, `memory_monitor.py`).
- **Статус:** Работещ код, ясна модулна структура, lazy-loading на monitor инстанции, конфигурация с default fallback (`_load_config`), incident logging (`watchdog_incidents.json`).
- **Външни зависимости:** Python: `psutil>=5.9.0`, `requests>=2.28.0` (и двете присъстват в `requirements.txt`, коментирани изрично като "Watchdog monitoring/system resource").
- **Routes/Templates:** **Несъответствие с останалите фийчъри** — вместо да ползва подадения `gm_blueprint` параметър, `register_routes(app, gm_blueprint)` прави `app.register_blueprint(watchdog_bp)` директно върху `app`, където `watchdog_bp = Blueprint('watchdog', __name__, url_prefix='/geomaxima/watchdog')` вече съдържа пълния `/geomaxima/watchdog` префикс твърдо закодиран. Функционално резултатът е същият URL, но архитектурно е различен модел на регистрация от останалите (`gnss_config` използва nested blueprint, повечето други директно декорират `gm_blueprint`). Това не чупи нещо в момента, но е inconsistency, която може да създаде объркване при бъдещи промени на `url_prefix` на `geomaxima_bp` (watchdog няма да го наследи автоматично, защото има собствен hardcoded prefix). Template: `addons/templates/geomaxima/watchdog.html` ✅.
- **Известни рискове:**
  - Hardcoded системни пътища: `/var/lib/rtkbase/watchdog_config.json`, `/var/lib/rtkbase/watchdog_incidents.json` — приемливо (стандартна конвенция за state files), но изисква тези директории/права да съществуват при deploy.
  - Двойна регистрация на blueprint е потенциален риск ако в бъдеще някой добави `url_prefix` промяна на `geomaxima_bp` очаквайки watchdog да я наследи.
- **Готовност за активиране:** **Готов сега** функционално, но препоръчително се хармонизира начинът на регистрация на blueprint-а с останалите фийчъри за консистентност (козметична поправка, не блокираща).

### 1.8 `wireguard_client` (файл: `wireguard_client.py`, без под-пакет)

- **Функция:** Пълен уеб интерфейс за WireGuard VPN клиент конфигурация — статус, четене/запис на `/etc/wireguard/wg0.conf`, вероятно connect/disconnect operations (файлът продължава след прочетения откъс).
- **Статус:** Работещ код за прочетените функции (`get_wireguard_status`, `get_wireguard_config`, `save_wireguard_config` с базова валидация за наличие на `[Interface]` секция).
- **Външни зависимости:** Системни: `wg` CLI, `wg-quick@wg0` systemd service, файл `/etc/wireguard/wg0.conf`. Няма Python пакетни зависимости извън стандартни.
- **Routes/Templates:** `/geomaxima/wireguard` (UI), `/api/wireguard/status`, `/config` (GET/POST). Template: `addons/templates/geomaxima/wireguard.html` ✅. Има и допълнителна документация `addons/features/WIREGUARD.md`.
- **Известни рискове:**
  - `get_wireguard_config`/`save_wireguard_config` четат/пишат директно `/etc/wireguard/wg0.conf`, който съдържа **private keys** в plaintext — endpoint-ът връща целия конфигурационен файл (вкл. private key) като JSON през `/api/wireguard/config` GET заявка. Ако този endpoint не е защитен с автентикация (не се видя `@login_required` декоратор в прочетения откъс, за разлика от `auto_survey`, който explicit го ползва навсякъде), това е **потенциален risk за разкриване на VPN private key** през мрежата (OWASP A01 - Broken Access Control, ако липсва auth).
  - Записването изисква `sudo`/root права за писане в `/etc/wireguard/` — не е потвърдено как се управляват тези права в кода (по-нататък във файла, извън прочетения откъс).
- **Готовност за активиране:** **Готов с малка поправка** — трябва изрично да се потвърди/добави authentication guard (`@login_required` или еквивалент) на всички `/api/wireguard/*` routes преди активиране, заради чувствителността на private key материала.

---

## 2. Обобщаваща таблица

| Фийчър | Статус на завършеност | Ключови зависимости | Основен риск | Готовност | Препоръчан приоритет |
|---|---|---|---|---|---|
| `wireguard_client` | Работещ код | `wg`, `wg-quick@wg0`, `/etc/wireguard/` | Private key може да изтече през незащитен API endpoint (провери auth) | Готов с малка поправка | **1** |
| `watchdog` | Работещ код | `psutil`, `requests` (в requirements.txt) | Blueprint регистрация не следва общата конвенция (козметично) | Готов сега | **2** |
| `ota_update` | Работещ, зрял код | `git`, `bash`, файлови права | Hardcoded `git_user='peshovp'`, token файл в repo dir | Готов с малка поправка | **3** |
| `gnss_config` | Работещ код | `pyserial` (**липсва в requirements**), `systemctl`+sudo | Липсваща Python зависимост в requirements файловете | Готов с малка поправка | **4** |
| `auto_survey` | Най-зрелият модул, версия 1.3.1 | `convbin` (наличен), **`rnx2rtkp` (липсва в tools/bin/RTKLIB-2.5.0!)**, numpy, scipy | Блокиращо: `rnx2rtkp` не съществува в repo — SPPProcessor ще хвърли `FileNotFoundError` | Готов с малка поправка (но поправката е съществена — трябва бинарник) | **5** |
| `external_integration` | Частично готово (1 явен TODO) | `requests`, липсваща `[caster_api]` секция в settings.conf.default | Health метрики са hardcoded нули; API key в plaintext | Готов с малка поправка | **6** |
| `custom_analytics` | Работещ код, но **изключен** от `FEATURES` | вътрешен достъп до `RTKLIB.py` контролера, `app.config['RTKBASE_INSTANCE']` | Не е активиран изобщо в config.py; крехка зависимост от вътрешен RTKLIB API | Готов с малка поправка (добави флаг + `RTKBASE_INSTANCE`) | **7** |
| `system_settings` | Работещ код (частично прегледан) | `raspi-config`, `hostnamectl`, `timedatectl`, sudo навсякъде | Root-ниво системни промени през web UI, `shell=True` subprocess извиквания, обвързан само с Raspberry Pi OS | Изисква съществена доработка (security review) | **8** |

---

## 3. Изводи

1. **Интеграционният контракт е стабилен и последователен** (`init_geomaxima(app)`, `Blueprint(template_folder='templates')`) — самият `controller.py` е готов да зареди всички features динамично, стига `geomaxima` пакетът да е достъпен в Python path на `web_app` (нужна е изрична crossdependency стъпка в `server.py`, която в момента липсва).
2. **Най-сериозната блокираща находка:** `addons/features/auto_survey/` очаква `rnx2rtkp` от `tools/bin/RTKLIB-2.5.0/<arch>/`, но там присъстват само `convbin`, `rtkrcv`, `str2str` — `rnx2rtkp` липсва във всички архитектури (aarch64, armv7l, armv6l). Auto Survey е фактически неработоспособен без допълнителна стъпка за доставяне на този бинарник.
3. **`custom_analytics_feature` не е регистриран в `config.FEATURES`** — работещ код, но напълно неактивен дори след wiring, докато не се добави ред във feature флаговете.
4. **Пропусната зависимост:** `pyserial`, използвана в четири файла на `gnss_config/`, липсва в `addons/requirements.txt` и `requirements-geomaxima.txt`.
5. **Hardcoded, потребителско-специфични пътища** се повтарят в няколко фийчъра (`/home/peshovp/rtkbase/...`, `git_user='peshovp'`) — ще пречат на инсталация под различен системен потребител.
6. **Security точки за преглед преди активиране:** незащитен (вероятно) `/api/wireguard/config` GET endpoint, връщащ private key material; `shell=True` subprocess извиквания в `system_settings_feature.py`; plaintext съхранение на caster API key.

Отчетът е записан в `addons/FEATURE_AUDIT.md`. Не са правени промени по никой друг файл в репото.
