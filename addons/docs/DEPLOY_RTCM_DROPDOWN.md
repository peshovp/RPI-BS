# Manual Deployment Guide - RTCM Dropdown Menu

## Quick Deploy (Via Browser)

Понеже settings.html е част от RTKBase (не GeoMaxima), трябва да го deploy-неш ръчно.

### Стъпки:

1. **Копирай settings.html на BS-Aheloy**
   
   От Windows PowerShell:
   ```powershell
   scp E:\Projects\rtkbase-2.7.0\web_app\templates\settings.html basegnss@192.168.1.14:/tmp/settings_new.html
   ```

2. **SSH на сървъра**
   ```powershell
   ssh basegnss@192.168.1.14
   ```

3. **Backup на текущия файл**
   ```bash
   sudo cp /var/www/html/web_app/templates/settings.html /var/www/html/web_app/templates/settings.html.backup_$(date +%Y%m%d)
   ```

4. **Move новия файл**
   ```bash
   sudo mv /tmp/settings_new.html /var/www/html/web_app/templates/settings.html
   sudo chown www-data:www-data /var/www/html/web_app/templates/settings.html
   sudo chmod 644 /var/www/html/web_app/templates/settings.html
   ```

5. **Restart web service**
   ```bash
   sudo systemctl restart rtkbase_web
   ```

6. **Test**
   Отвори: http://192.168.1.14/settings.html
   
   Scroll down до **Ntrip A service** → **Rtcm messages**
   
   Трябва да видиш dropdown menu с 7 опции:
   - -- Select Preset --
   - MSM4
   - MSM5
   - MSM7
   - MSM4 + CMR
   - MSM5 + CMR
   - MSM7 + CMR
   - Custom

---

## Тестване на Dropdown

1. Избери **MSM5** от dropdown
2. Input полето трябва да се попълни автоматично с:
   ```
   1005(10),1006,1033(10),1075,1085,1095,1125,1230
   ```
3. Полето става read-only (сиво background)
4. Избери **Custom** за да направиш ръчна промяна

---

## Rollback (ако нещо не работи)

```bash
ssh basegnss@192.168.1.14
sudo cp /var/www/html/web_app/templates/settings.html.backup_YYYYMMDD /var/www/html/web_app/templates/settings.html
sudo systemctl restart rtkbase_web
```

---

## Често Задавани Въпроси

### Кой preset да използвам?

- **Centipede Network:** MSM5 или MSM5 + CMR
- **RTK2GO:** MSM4 (за по-малък bandwidth)
- **Локална мрежа:** MSM7 (максимална точност)
- **4G/LTE:** MSM4 (минимален bandwidth)

### Какво правят CMR вариантите?

CMR (+ ephemeris) добавя съобщения 1019, 1020, 1042, 1045, 1046 за съвместимост със стари GNSS приемници.

### Мога ли да направя custom комбинация?

Да! Избери "Custom" от dropdown и въведи ръчно желаните RTCM съобщения.

---

## Проверка на Bandwidth

След промяна на preset, виж реалния bandwidth:

1. Отвори http://192.168.1.14/status.html
2. Виж "Output (bps)" за Ntrip A/B service
3. Сравни с очаквания bandwidth от документацията

**Expected Bandwidth:**
- MSM4: 300-500 bytes/s
- MSM5: 500-800 bytes/s
- MSM7: 800-1200 bytes/s
- + CMR adds ~100-200 bytes/s

---

## Automated Deployment (Advanced)

Ако имаш SSH key authentication setup:

```powershell
.\geomaxima\tools\deploy_rtcm_dropdown.ps1
```

Скриптът автоматично:
- Прави backup
- Upload-ва нов settings.html
- Restart-ва service
- Проверява status
