# GitHub Setup за GeoMaxima-BS

## 🔐 Private Repository Configuration

Repository: `https://github.com/peshovp/GeoMaxima-BS` (Private)

## 📝 Първоначална настройка

### 1. Създай GitHub Personal Access Token

1. Отиди на: https://github.com/settings/tokens?type=beta
2. Кликни **"Generate new token"** → **"Fine-grained token"**
3. Име: `GeoMaxima-BS-Token`
4. Expiration: Избери срок (препоръчвам 90 days или 1 year)
5. Repository access: **Only select repositories** → Избери `peshovp/GeoMaxima-BS`
6. Permissions:
   - **Contents**: Read and write
   - **Metadata**: Read-only (автоматично)
   - **Pull requests**: Read and write (optional)
7. **Generate token** и запази токена на сигурно място!

### 2. Конфигурирай Git Authentication

#### Опция А: HTTPS с Token (препоръчително за development)

```bash
cd e:\Projects\rtkbase-2.7.0\geomaxima

# Initialize git repo
git init
git branch -M main

# Add remote с token (замени YOUR_TOKEN)
git remote add origin https://YOUR_TOKEN@github.com/peshovp/GeoMaxima-BS.git

# Първи commit
git add .
git commit -m "Initial GeoMaxima setup for RTKBase"
git push -u origin main
```

#### Опция Б: Credential Helper (по-сигурно)

```bash
cd e:\Projects\rtkbase-2.7.0\geomaxima

git init
git branch -M main
git remote add origin https://github.com/peshovp/GeoMaxima-BS.git

# Използвай credential helper
git config credential.helper store

# При първия push ще те попита:
# Username: peshovp
# Password: [paste your token here]
git push -u origin main
```

#### Опция В: SSH (най-сигурно за production)

```bash
# Генерирай SSH ключ (ако нямаш)
ssh-keygen -t ed25519 -C "your_email@example.com"

# Добави public key в GitHub:
# Settings → SSH and GPG keys → New SSH key

# Clone с SSH
cd e:\Projects\rtkbase-2.7.0
rm -rf geomaxima  # Backup first!
git clone git@github.com:peshovp/GeoMaxima-BS.git geomaxima
```

### 3. Конфигурирай Production Base Stations

На всяка RTKBase станция, която ще тегли updates:

```bash
# SSH в базата
ssh user@rtkbase-station

cd /path/to/rtkbase/geomaxima

# Клонирай repo (за първи път)
sudo rm -rf /path/to/rtkbase/geomaxima
cd /path/to/rtkbase
sudo git clone https://github.com/peshovp/GeoMaxima-BS.git geomaxima

# Конфигурирай authentication за updates
cd geomaxima
sudo git config credential.helper store

# При първия update ще трябва да въведеш token
sudo ./geomaxima_update.sh
# Username: peshovp
# Password: [deploy token with read-only access]
```

### 4. Създай Deploy Token (за production базите)

За production, създай отделен **read-only** token:

1. GitHub → Repository Settings → Security → Deploy keys
2. Или създай друг Fine-grained token само с **Contents: Read-only**
3. Използвай този token на production базите за updates

## 🔄 Workflow за Development

### Local Development (на твоя компютър)

```bash
cd e:\Projects\rtkbase-2.7.0\geomaxima

# Направи промени
nano features/my_feature.py

# Commit & Push
git add .
git commit -m "Add new feature"
git push origin main
```

### Testing на локална RTKBase инсталация

```bash
# Рестартирай web service
sudo systemctl restart rtkbase_web

# Провери
curl http://localhost/geomaxima/api/info
```

### Deploy на Production

```bash
# SSH в production base
ssh user@production-base

# Update GeoMaxima
sudo /path/to/rtkbase/geomaxima/geomaxima_update.sh

# Проверка
curl http://localhost/geomaxima/api/info
```

## 📦 Release Process

### Създаване на Release (за версиониране)

```bash
# Update VERSION file
echo "1.1.0" > VERSION

# Commit
git add VERSION
git commit -m "Release v1.1.0"
git tag -a v1.1.0 -m "Release version 1.1.0"
git push origin main --tags
```

### GitHub Release (optional, за по-прегледна история)

1. GitHub → Releases → Create new release
2. Tag: `v1.1.0`
3. Title: `GeoMaxima v1.1.0`
4. Description: Описание на промените
5. Publish release

## 🔒 Security Best Practices

### Token Security

1. **Никога не commit-вай токени** в кода
2. **Използвай различни токени** за dev и production
3. **Read-only токени** за production базите
4. **Rotation**: Сменяй токените периодично (90 дни)

### Git Ignore

Проверка че `.gitignore` е правилен:

```bash
cat .gitignore
# Трябва да има:
# config.local.py
# *.log
# __pycache__/
```

### Environment Variables (за по-добра сигурност)

Вместо hardcode на token в URL, използвай:

```bash
# Set environment variable
export GITHUB_TOKEN="your_token_here"

# Use in scripts
git remote set-url origin https://${GITHUB_TOKEN}@github.com/peshovp/GeoMaxima-BS.git
```

## 🆘 Troubleshooting

### Problem: Authentication failed

**Solution:**
```bash
# Изтрий stored credentials
git config --unset credential.helper

# Опитай отново
git push

# Или използвай token директно в URL
git remote set-url origin https://TOKEN@github.com/peshovp/GeoMaxima-BS.git
```

### Problem: Permission denied (publickey)

**Solution:**
```bash
# Провери SSH ключовете
ssh -T git@github.com

# Ако не работи, използвай HTTPS вместо SSH
git remote set-url origin https://github.com/peshovp/GeoMaxima-BS.git
```

### Problem: Repository not found

**Solution:**
- Провери че токена има достъп до repo
- Провери че repo URL е правилен
- Провери че токена не е изтекъл

## 📞 Support

При проблеми с GitHub setup:
- GitHub Docs: https://docs.github.com/en/authentication
- Contact: peshovp

---

**Готово!** След като конфигурираш authentication, GeoMaxima ще се обновява автоматично от private repo! 🔐
