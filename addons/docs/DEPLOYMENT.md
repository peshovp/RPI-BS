# 🚀 Production Deployment Guide

## Инсталация на GeoMaxima на RTKBase станция

### Предпоставки

- RTKBase 2.7.0+ инсталиран и работещ
- SSH достъп до базата
- Sudo/root привилегии
- Internet свързаност

### Стъпка 1: Clone на GeoMaxima

```bash
# SSH в базата
ssh user@your-rtkbase-ip

# Backup на евентуален стар geomaxima (ако има)
cd /home/user/rtkbase
sudo mv geomaxima geomaxima.old.$(date +%Y%m%d) 2>/dev/null || true

# Clone на GeoMaxima repo
sudo git clone https://github.com/peshovp/GeoMaxima-BS.git geomaxima

# Влез в директорията
cd geomaxima
```

### Стъпка 2: Конфигуриране на Authentication

За да може базата да тегли updates, трябва да конфигурираш git credentials.

#### Опция А: Personal Access Token (препоръчително)

```bash
# Създай read-only token в GitHub:
# Settings → Developer Settings → Personal Access Tokens
# Repository access: Only select peshovp/GeoMaxima-BS
# Permissions: Contents (Read-only)

# Конфигурирай git
sudo git config credential.helper store

# При първия pull ще те попита за credentials
# Username: peshovp
# Password: [paste your read-only token]
```

#### Опция Б: Deploy Key (по-сигурно)

```bash
# Генерирай SSH ключ на базата
ssh-keygen -t ed25519 -C "rtkbase-station" -f ~/.ssh/geomaxima_deploy

# Копирай public key
cat ~/.ssh/geomaxima_deploy.pub

# Добави като Deploy Key в GitHub:
# Repository Settings → Deploy keys → Add deploy key
# Title: "RTKBase Station"
# Key: [paste public key]
# ✓ Allow read access

# Конфигурирай SSH
cat >> ~/.ssh/config << EOF
Host github.com-geomaxima
    HostName github.com
    User git
    IdentityFile ~/.ssh/geomaxima_deploy
EOF

# Смени remote на SSH
cd /home/user/rtkbase/geomaxima
sudo git remote set-url origin git@github.com-geomaxima:peshovp/GeoMaxima-BS.git
```

### Стъпка 3: Настройка на Permissions

```bash
# Увери се, че web server има достъп
cd /home/user/rtkbase
sudo chown -R $(stat -c '%U' .) geomaxima
sudo chmod -R 755 geomaxima
sudo chmod +x geomaxima/geomaxima_update.sh
```

### Стъпка 4: Рестартиране на RTKBase Web Service

```bash
# Рестартирай за да зареди GeoMaxima
sudo systemctl restart rtkbase_web

# Провери статус
sudo systemctl status rtkbase_web

# Провери логовете
sudo journalctl -u rtkbase_web -f
```

Трябва да видиш:
```
GeoMaxima v1.0.0 loaded successfully
```

### Стъпка 5: Проверка на Инсталацията

```bash
# Отвори в браузър
http://your-rtkbase-ip/geomaxima

# Или с curl
curl http://localhost/geomaxima/api/info
```

Очакван резултат:
```json
{
  "name": "GeoMaxima",
  "version": "1.0.0",
  "enabled": true,
  "features": {
    "wireguard_client": true
  }
}
```

### Стъпка 6: Тест на WireGuard Feature

```bash
# Отвори WireGuard UI
http://your-rtkbase-ip/geomaxima/wireguard

# Ако WireGuard не е инсталиран, кликни "Install WireGuard"
# Или инсталирай ръчно:
sudo apt-get update
sudo apt-get install -y wireguard wireguard-tools
```

## 🔄 Настройка на Auto-Update

### Вариант 1: Manual Updates

```bash
# Просто изпълни update скрипта когато има нов release
cd /home/user/rtkbase/geomaxima
sudo ./geomaxima_update.sh
```

### Вариант 2: Systemd Timer (препоръчително)

```bash
# Създай systemd service
sudo tee /etc/systemd/system/geomaxima_update.service << 'EOF'
[Unit]
Description=GeoMaxima Update Service
After=network-online.target

[Service]
Type=oneshot
ExecStart=/home/user/rtkbase/geomaxima/geomaxima_update.sh
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Създай systemd timer (daily at 3AM)
sudo tee /etc/systemd/system/geomaxima_update.timer << 'EOF'
[Unit]
Description=GeoMaxima Daily Update Timer
Requires=geomaxima_update.service

[Timer]
OnCalendar=daily
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Reload и enable
sudo systemctl daemon-reload
sudo systemctl enable geomaxima_update.timer
sudo systemctl start geomaxima_update.timer

# Провери timer
sudo systemctl list-timers geomaxima_update.timer
```

### Вариант 3: Cron Job

```bash
# Добави в crontab
sudo crontab -e

# Добави ред (update всеки ден в 3:00 сутринта)
0 3 * * * /home/user/rtkbase/geomaxima/geomaxima_update.sh >> /var/log/geomaxima_update.log 2>&1
```

## 🛠️ Troubleshooting

### GeoMaxima не се показва в менюто

```bash
# Провери дали се зарежда
sudo journalctl -u rtkbase_web | grep -i geomaxima

# Ако вид "GeoMaxima not found", провери path
ls -la /home/user/rtkbase/geomaxima

# Рестартирай web service
sudo systemctl restart rtkbase_web
```

### Update скриптът не работи

```bash
# Провери git credentials
cd /home/user/rtkbase/geomaxima
sudo git pull

# Ако има authentication error, конфигурирай отново credentials
```

### Permission Denied при WireGuard config

```bash
# Web service трябва да работи като root за достъп до /etc/wireguard
sudo systemctl cat rtkbase_web.service | grep User

# Ако не е root, редактирай service file
sudo systemctl edit rtkbase_web.service

# Добави:
[Service]
User=root
```

### Python Import Errors

```bash
# Провери Python path
cd /home/user/rtkbase
python3 -c "import sys; sys.path.insert(0, '.'); from geomaxima import config; print(config.VERSION)"

# Инсталирай допълнителни dependencies ако има
cd geomaxima
sudo pip3 install -r requirements-geomaxima.txt
```

## 📊 Мониторинг

### Проверка на статус

```bash
# Web service status
sudo systemctl status rtkbase_web

# GeoMaxima API check
curl http://localhost/geomaxima/api/info | jq

# WireGuard status (ако е инсталиран)
curl http://localhost/geomaxima/api/wireguard/status | jq
```

### Логове

```bash
# RTKBase web service logs
sudo journalctl -u rtkbase_web -f

# WireGuard service logs
sudo journalctl -u wg-quick@wg0 -f

# Update logs (ако използваш systemd timer)
sudo journalctl -u geomaxima_update.service -n 50
```

## 🔐 Security Best Practices

1. **Използвай read-only token** за production базите
2. **Rotate tokens** на всеки 90 дни
3. **SSH keys** > Tokens за по-добра сигурност
4. **Firewall rules** - ограничи достъпа до web interface
5. **HTTPS** - използвай reverse proxy с SSL

### Reverse Proxy с Nginx + SSL

```bash
# Инсталирай Nginx и Certbot
sudo apt-get install -y nginx certbot python3-certbot-nginx

# Конфигурирай nginx за RTKBase
sudo tee /etc/nginx/sites-available/rtkbase << 'EOF'
server {
    listen 80;
    server_name your-domain.com;
    
    location / {
        proxy_pass http://localhost:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

# Enable site
sudo ln -s /etc/nginx/sites-available/rtkbase /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# Get SSL certificate
sudo certbot --nginx -d your-domain.com
```

## 📞 Support

- GitHub Issues: https://github.com/peshovp/GeoMaxima-BS/issues
- RTKBase Docs: https://github.com/Stefal/rtkbase

---

**Успешна инсталация!** 🎉

След като следваш тези стъпки, GeoMaxima ще работи на production базата и ще се обновява автоматично от GitHub repo.
