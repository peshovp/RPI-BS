# RTCM Message Presets - Technical Documentation

## Обща Информация

RTCM (Radio Technical Commission for Maritime Services) съобщенията са стандартен формат за предаване на GNSS корекции от базова станция към rover приемници.

## Налични Presets

### 1. **MSM4 - Multi-Signal Messages Level 4 (Compact)**

**Описание:** Компактен формат с по-малък bandwidth, подходящ за бързи актуализации и нестабилни връзки.

**RTCM Съобщения:**
- `1005(10)` - Станционни координати (интервал 10 сек)
- `1006` - Станция + височина на антената
- `1033(10)` - Информация за приемника (интервал 10 сек)
- `1074` - GPS MSM4 (Multi-Signal Message Level 4)
- `1084` - GLONASS MSM4
- `1094` - Galileo MSM4
- `1124` - BeiDou MSM4
- `1230` - GLONASS code-phase biases

**Предимства:**
- Нисък bandwidth (~300-500 bytes/sec)
- Бързи актуализации (1 Hz)
- Подходящ за 4G/LTE връзки

**Недостатъци:**
- По-ниска точност (~2-3 cm RTK Fix)

---

### 2. **MSM5 - Multi-Signal Messages Level 5 (Full Precision)**

**Описание:** Пълна прецизност с балансиран bandwidth, препоръчван за повечето приложения.

**RTCM Съобщения:**
- `1005(10)` - Станционни координати
- `1006` - Станция + височина на антената
- `1033(10)` - Информация за приемника
- `1075` - GPS MSM5
- `1085` - GLONASS MSM5
- `1095` - Galileo MSM5
- `1125` - BeiDou MSM5
- `1230` - GLONASS code-phase biases

**Предимства:**
- Отлична точност (~1-2 cm RTK Fix)
- Среден bandwidth (~500-800 bytes/sec)
- **ПРЕПОРЪЧАН** за повечето базови станции

**Недостатъци:**
- Малко по-висок bandwidth от MSM4

---

### 3. **MSM7 - Multi-Signal Messages Level 7 (High Resolution)**

**Описание:** Най-висока резолюция и точност, за професионални приложения.

**RTCM Съобщения:**
- `1005(10)` - Станционни координати
- `1006` - Станция + височина на антената
- `1033(10)` - Информация за приемника
- `1077` - GPS MSM7
- `1087` - GLONASS MSM7
- `1097` - Galileo MSM7
- `1127` - BeiDou MSM7
- `1230` - GLONASS code-phase biases

**Предимства:**
- Максимална точност (~0.5-1 cm RTK Fix)
- Най-добра multi-frequency поддръжка

**Недостатъци:**
- Висок bandwidth (~800-1200 bytes/sec)
- Изисква стабилна мрежа

---

### 4. **MSM4 + CMR** (Compact Measurement Record)

**Описание:** MSM4 + допълнителни ephemeris съобщения за съвместимост със стари приемници.

**Допълнителни Съобщения:**
- `1019` - GPS ephemeris data
- `1020` - GLONASS ephemeris data
- `1042` - BeiDou ephemeris data (D1 NAV)
- `1045` - Galileo F/NAV ephemeris data
- `1046` - Galileo I/NAV ephemeris data

**Използвай когато:**
- Rover приемникът е legacy (по-стар модел)
- Нужна е backwards compatibility
- Използваш смесени rover приемници (нови + стари)

---

### 5. **MSM5 + CMR**

**Описание:** MSM5 + CMR за балансирана точност и съвместимост.

**Препоръчва се за:**
- Базови станции обслужващи различни типове приемници
- Centipede network nodes
- RTK2GO mountpoints

---

### 6. **MSM7 + CMR**

**Описание:** Пълен пакет за максимална съвместимост и точност.

**Използвай когато:**
- Критична е максималната точност
- Bandwidth не е проблем (стабилна мрежа)
- Professional surveying applications

---

## Технически Детайли

### Bandwidth Comparison

| Preset | Approx. Bandwidth | Update Rate | RTK Fix Accuracy |
|--------|-------------------|-------------|------------------|
| MSM4 | 300-500 bytes/s | 1 Hz | 2-3 cm |
| MSM5 | 500-800 bytes/s | 1 Hz | 1-2 cm |
| MSM7 | 800-1200 bytes/s | 1 Hz | 0.5-1 cm |
| MSM4 + CMR | 400-600 bytes/s | 1 Hz | 2-3 cm |
| MSM5 + CMR | 600-900 bytes/s | 1 Hz | 1-2 cm |
| MSM7 + CMR | 900-1400 bytes/s | 1 Hz | 0.5-1 cm |

### Интервали на Съобщенията

- `(10)` - Изпраща се на всеки 10 секунди
- Без скоби - Изпраща се на всяка секунда (1 Hz)

**Пример:** `1005(10)` означава станционните координати се изпращат веднъж на 10 секунди.

---

## Препоръки

### За Centipede Network:
```
Използвай: MSM5 или MSM5 + CMR
```

### За RTK2GO:
```
Използвай: MSM4 или MSM5 (за по-малък bandwidth)
```

### За Локална Мрежа (LAN):
```
Използвай: MSM7 (максимална точност)
```

### За 4G/LTE Връзка:
```
Използвай: MSM4 (минимален bandwidth)
```

---

## Тестване

След промяна на RTCM съобщенията:

1. **Провери връзката:**
   ```bash
   sudo systemctl status str2str_ntrip_A
   ```

2. **Виж реалния bandwidth:**
   - Отвори RTKBase Status page
   - Провери "Output (bps)" за текущия service

3. **Тествай с Rover:**
   - Свържи rover приемник
   - Провери дали постига RTK Fix
   - Измери времето за Fix (Time to Fix)

---

## Troubleshooting

### Проблем: Rover не постига RTK Fix

**Решение:**
1. Провери дали rover поддържа избрания MSM level
2. Превключи на MSM4 + CMR за съвместимост
3. Виж логовете на rover-а

### Проблем: Висок latency / connection timeout

**Решение:**
1. Превключи от MSM7 на MSM5 или MSM4
2. Провери network bandwidth
3. Увеличи интервалите: `1005(30)` вместо `1005(10)`

### Проблем: Legacy receiver не работи

**Решение:**
1. Задължително използвай "+ CMR" preset
2. Добави ephemeris съобщения ръчно ако е нужно

---

## Custom Configuration

Ако нито един preset не отговаря на нуждите ти:

1. Избери **"Custom (Manual Entry)"** от dropdown
2. Въведи собствена комбинация от съобщения
3. Формат: `msg1,msg2(interval),msg3,...`

**Пример:**
```
1005(30),1077,1087,1097,1127
```

Това изпраща станционни координати на всеки 30 сек и MSM7 съобщения за всички констелации на всяка секунда.

---

## Източници

- RTCM Standard 10403.3
- U-Blox ZED-F9P Integration Manual
- RTKLIB Documentation
- Centipede RTK Network Guidelines
