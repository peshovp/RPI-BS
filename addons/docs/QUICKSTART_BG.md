# 🎯 GeoMaxima - Quick Start Guide

**Версия:** 1.3.1 | **Дата:** Декември 2025

## ⚡ Най-Важното (TL;DR)

**НОВА критична функция в v1.3.1:**
- ✅ **Автоматично спиране на логване след survey** - Предотвратява пълнене на диска!
- ✅ Ръчни контроли за start/stop logging в UI
- ✅ API endpoints за logging управление

**ЗАДЪЛЖИТЕЛНА актуализация за production станции!**

## Какво е GeoMaxima?

GeoMaxima е модулна разширителна система за RTKBase, която ви позволява да добавяте собствени функционалности, докато RTKBase се обновява независимо.

## 🚀 Първи стъпки

### Инсталация

#### Метод 1: Локална инсталация (Офлайн - Препоръчително за Private Repos)

**За private repositories или инсталации без интернет:**

1. **Създайте релийз архив** (на development машина):
   ```bash
   # Linux/Mac
   ./build_release.sh
   
   # Windows
   .\build_release.ps1
   ```
   Това създава `Output/GeoMaxima-vX.X.X.zip`

2. **Прехвърлете ZIP на RTKBase станцията** (USB, SCP, и т.н.)

3. **Разархивирайте и инсталирайте**:
   ```bash
   unzip GeoMaxima-vX.X.X.zip
   cd GeoMaxima
   sudo ./install_local.sh
   ```

**Какво прави:**
- ✅ Проверява за RTKBase инсталация
- ✅ Backup на съществуващ GeoMaxima
- ✅ Инсталира от локални файлове (без интернет)
- ✅ Автоматична интеграция с RTKBase
- ✅ Рестарт на услугите

**Изисквания:**
- RTKBase вече инсталиран
- Root достъп (sudo)

---

#### Метод 2: Онлайн инсталация (За публични repos)

Инсталаторът автоматично проверява дали RTKBase е инсталиран и действа съответно:

```bash
wget -O - https://raw.githubusercontent.com/peshovp/GeoMaxima-BS/master/install.sh | sudo bash
```

**Какво прави:**
- ✅ **RTKBase намерен?** → Инсталира само GeoMaxima
- ✅ **RTKBase липсва?** → Инсталира RTKBase + GeoMaxima
- ✅ Автоматична интеграция
- ✅ Backup на съществуващи файлове
- ✅ Рестарт на услугите

**Изисквання:**
- Debian 12+ или Ubuntu 24.04+
- Root достъп (sudo)
- Интернет връзка
- Repository трябва да е публично

### Ръчна инсталация (за разработчици)

#### 1. Създайте Git Repository

Ако искате да модифицирате или да използвате собствено repository:

```bash
cd /path/to/rtkbase
cd geomaxima
git init
git add .
git commit -m "Initial GeoMaxima setup"
```

Качете го на GitHub/GitLab:
```bash
git remote add origin https://github.com/yourusername/geomaxima-extensions.git
git push -u origin main
```

#### 2. Конфигурирайте Repository URL

Редактирайте `geomaxima/config.py`:

```python
GEOMAXIMA_REPO = "https://github.com/yourusername/geomaxima-extensions.git"
GEOMAXIMA_BRANCH = "main"
```

### 3. Направете скрипта изпълним

```bash
sudo chmod +x geomaxima/geomaxima_update.sh
```

## 📝 Добавяне на нова функционалност

### Стъпка 1: Създайте Feature модул

Създайте нов файл в `geomaxima/features/my_feature.py`:

```python
from flask import jsonify, request
import logging

logger = logging.getLogger(__name__)

def register_routes(app, gm_blueprint):
    """Register routes for this feature"""
    
    @gm_blueprint.route('/api/my-feature')
    def my_feature():
        return jsonify({
            "status": "success",
            "message": "My feature works!",
            "data": {"example": "value"}
        })
    
    @gm_blueprint.route('/api/my-feature/data', methods=['POST'])
    def process_data():
        data = request.get_json()
        # Process your data here
        return jsonify({
            "status": "success",
            "processed": data
        })
    
    logger.info("My feature routes registered")
```

### Стъпка 2: Активирайте Feature-а

Редактирайте `geomaxima/config.py`:

```python
FEATURES = {
    "example_feature": True,
    "my_feature": True,  # Добавете това
}
```

### Стъпка 3: Рестартирайте Web Service

```bash
sudo systemctl restart rtkbase_web
```

### Стъпка 4: Тествайте

Отворете браузър: `http://your-rtkbase-ip/geomaxima`

API endpoint: `http://your-rtkbase-ip/geomaxima/api/my-feature`

## 🔄 Обновяване на GeoMaxima

### Ръчно обновяване

```bash
cd /path/to/rtkbase
sudo ./geomaxima/geomaxima_update.sh
```

### Автоматично обновяване (препоръчително)

Създайте systemd timer:

```bash
# Създайте /etc/systemd/system/geomaxima_update.service
[Unit]
Description=GeoMaxima Update Service
After=network-online.target

[Service]
Type=oneshot
ExecStart=/path/to/rtkbase/geomaxima/geomaxima_update.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
# Създайте /etc/systemd/system/geomaxima_update.timer
[Unit]
Description=GeoMaxima Update Timer
Requires=geomaxima_update.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

Активирайте timer-а:
```bash
sudo systemctl daemon-reload
sudo systemctl enable geomaxima_update.timer
sudo systemctl start geomaxima_update.timer
```

## 📚 Структура на проекта

```
geomaxima/
├── README.md                    # Документация
├── QUICKSTART_BG.md            # Този файл
├── VERSION                      # Версия
├── config.py                   # Конфигурация
├── controller.py               # Основен контролер
├── __init__.py                 # Python package
├── geomaxima_update.sh         # Update скрипт
├── requirements-geomaxima.txt  # Python зависимости
└── features/                   # Функционалности
    ├── __init__.py
    ├── example_feature.py
    └── my_feature.py           # Вашите features
```

## 🎨 Добавяне на UI компоненти

### Създайте HTML template

`web_app/templates/geomaxima/my_feature.html`:

```html
{% extends 'base.html' %}

{% block content %}
<div class="container">
    <h2>My Feature</h2>
    <button onclick="callMyAPI()">Test Feature</button>
    <div id="result"></div>
</div>

<script>
function callMyAPI() {
    fetch('/geomaxima/api/my-feature')
        .then(response => response.json())
        .then(data => {
            document.getElementById('result').textContent = 
                JSON.stringify(data, null, 2);
        });
}
</script>
{% endblock %}
```

### Добавете route за UI

В `geomaxima/features/my_feature.py`:

```python
@gm_blueprint.route('/my-feature-ui')
def my_feature_ui():
    return render_template('geomaxima/my_feature.html')
```

## 🔐 Сигурност

- Използвайте Flask-Login за authentication (вече е интегриран)
- Валидирайте входните данни
- Използвайте HTTPS в продукция
- Ограничете API rate limiting при нужда

## 📊 Логване

```python
import logging
logger = logging.getLogger(__name__)

logger.info("Information message")
logger.warning("Warning message")
logger.error("Error message")
```

## 🐛 Debugging

Проверете логовете:
```bash
sudo journalctl -u rtkbase_web.service -f
```

Тествайте API с curl:
```bash
curl http://localhost/geomaxima/api/info
```

## 💡 Примери за Features

### 1. Auto Survey-In (Вградено)
```bash
# Стартиране на 24-часов автоматичен survey
# UI: GEOMAXIMA → Auto Survey → Start Survey

# Ръчно управление на logging (НОВО в v1.3.1)
# UI: Auto Survey → Manual Controls → Start/Stop Logging

# API endpoints:
curl -X POST http://localhost/geomaxima/api/survey/start \
  -H "Content-Type: application/json" \
  -d '{"target_hours": 24}'

curl -X POST http://localhost/geomaxima/api/survey/logging/stop
```

**Критично в v1.3.1:**
- File logging **автоматично спира** след survey completion
- Предотвратява пълнене на диска (75MB/час × 24ч = 1.8GB)
- Ръчни контроли за start/stop logging в UI

### 2. Data Export Feature
```python
@gm_blueprint.route('/api/export/<format>')
def export_data(format):
    # Export GNSS data to custom format
    pass
```

### 3. Custom Analytics
```python
@gm_blueprint.route('/api/analytics/summary')
def get_analytics():
    # Calculate custom statistics
    pass
```

### 4. External Integration
```python
@gm_blueprint.route('/api/webhook', methods=['POST'])
def handle_webhook():
    # Integrate with external services
    pass
```

## 🛠️ Troubleshooting v1.3.1

### Проблем: Диска се пълни с .ubx файлове

**Решение:**
1. **Спрете логването веднага:**
   ```bash
   sudo systemctl stop str2str_file.service
   ```

2. **Актуализирайте до v1.3.1:**
   ```bash
   cd ~/GeoMaxima
   git pull origin master
   sudo ./install_local.sh
   ```

3. **Проверете че survey автоматично спира логването:**
   ```bash
   sudo journalctl -u rtkbase_web -f | grep -i "stopping file logging"
   ```

### Проблем: Survey не стартира

**Проверки:**
```bash
# 1. RTKBase работи ли?
sudo systemctl status rtkbase_web.service

# 2. File logging стартира ли?
sudo systemctl status str2str_file.service

# 3. Проверка на логове
sudo journalctl -u rtkbase_web -f | grep -i survey
```

### Проблем: Ръчните logging контроли не работят

**Решение:**
```bash
# Провери API endpoints
curl -X POST http://localhost/geomaxima/api/survey/logging/start
curl -X POST http://localhost/geomaxima/api/survey/logging/stop

# Ако връща 404, рестартирай web service
sudo systemctl restart rtkbase_web.service
```

## 🔄 Workflow

1. **Разработка локално** → Тествай на dev машината
2. **Commit & Push** → `git push origin main`
3. **Update на базата** → `sudo ./geomaxima/geomaxima_update.sh`
4. **Провери** → Отвори `/geomaxima` в браузър

## ⚠️ Важно!

- **Винаги правете backup** преди обновяване
- **Тествайте локално** преди push в production
- **Update скриптът автоматично прави backup** във `/var/tmp/geomaxima_backup_*`
- **RTKBase се обновява независимо** от GeoMaxima

## 🆘 Помощ

Ако нещо се обърка при обновяване, скриптът автоматично прави rollback.

Ръчен rollback:
```bash
sudo systemctl stop rtkbase_web
cd /path/to/rtkbase
sudo rm -rf geomaxima
sudo cp -r /var/tmp/geomaxima_backup_LATEST/* geomaxima/
sudo systemctl start rtkbase_web
```

## 📞 Поддръжка

- GitHub Issues: https://github.com/yourusername/geomaxima-extensions/issues
- RTKBase Docs: https://github.com/Stefal/rtkbase

---

**Готово!** Сега имате пълна контрола над разширенията, докато RTKBase си остава независим и се обновява нормално! 🚀
