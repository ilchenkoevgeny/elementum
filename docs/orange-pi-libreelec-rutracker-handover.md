# Orange Pi 3 + LibreELEC + Elementum: актуальный handover

> Обновлено 2026-08-09 по результатам работ до 2026-08-07. Этот файл является основной точкой продолжения работы в новом чате.

## 1. Главная цель

На Orange Pi 3 под LibreELEC должна работать связка Kodi + Elementum + Burst:

- обычные провайдеры ищутся напрямую;
- RuTracker проходит блокировку провайдера через `nfqws`, а Cloudflare — через полноценный GUI Chromium;
- результаты появляются прогрессивно, без ожидания самого медленного провайдера;
- `.torrent` разрешается в Elementum, результаты дедублицируются и сортируются;
- BitTorrent-трафик к пирам идёт напрямую, без WARP/VPN;
- Chromium не должен постоянно занимать память: он запускается только для RuTracker и выключается после простоя;
- RuTor должен оставаться обычным Burst-провайдером и не должен использовать Chromium.

## 2. Критически важное различие

**RuTracker и RuTor — разные провайдеры с разной схемой работы.**

### RuTracker

- домен: `rutracker.org`;
- требует `nfqws` из-за DPI;
- требует GUI Chromium из-за Cloudflare;
- запросы выполняются через локальный browser bridge `127.0.0.1:9911`.

### RuTor

- домены: `rutor.info`, возможное зеркало `rutor.is`;
- Chromium не нужен;
- должен работать через стандартный HTTP-клиент Burst;
- текущая нерешённая задача: RuTor включён, но результатов от него нет.

Нельзя направлять RuTor через Chromium и нельзя смешивать его диагностику с RuTracker.

## 3. Платформа

| Параметр | Значение |
|---|---|
| Плата | Orange Pi 3, не LTS |
| SoC | Allwinner H6 |
| Архитектура | `aarch64` |
| LibreELEC | `devel-20260802060809-f3fdd11` |
| Ядро | Linux `6.6.71` |
| Kodi | 21.x |
| Elementum | `0.1.114` |
| Burst | `0.0.99` |
| Адрес во время настройки | `192.168.31.235` |

Основные пути:

```text
Elementum addon:
/storage/.kodi/addons/plugin.video.elementum

Elementum binary:
/storage/.kodi/userdata/addon_data/plugin.video.elementum/bin/linux_arm64/elementum

Burst:
/storage/.kodi/addons/script.elementum.burst

Kodi log:
/storage/.kodi/temp/kodi.log
```

## 4. Сетевой слой

Кастомное ядро LibreELEC было собрано с NFQUEUE/nftables. Подтверждены модули:

```text
nfnetlink_queue.ko
xt_NFQUEUE.ko
nft_queue.ko
```

Установлен Zapret `v72.13`:

```text
/storage/zapret-v72.13
```

Сервис:

```text
nfqws-rutracker.service
```

Очередь NFQUEUE: `200`.

Рабочая стратегия была найдена как `general_alt11`. Она пропускает трафик RuTracker до Cloudflare. WARP удалён и в рабочей схеме не используется.

Домены RuTracker и RuTor добавлялись в список `nfqws`:

```text
/storage/zapret-v72.13/config/rutracker-hosts.txt
```

Ранее контрольный запрос к `https://rutor.info/` возвращал HTTP 200, поэтому отсутствие результатов RuTor не следует заранее списывать на отсутствие сетевого доступа. Это ещё нужно повторно подтвердить текущим тестом поиска.

Диагностика:

```sh
systemctl status nfqws-rutracker.service --no-pager
journalctl -u nfqws-rutracker.service -n 100 --no-pager
iptables -t mangle -L ZAPRET_NFQ_OUT -nvx
iptables -t mangle -L ZAPRET_NFQ_IN -nvx
```

## 5. Progressive search

Прогрессивный поиск доведён до рабочего состояния. Повторные поиски выполнялись без смешивания старых и новых результатов.

Важные исправления:

- standalone Kodi runner получил корректный addon context;
- убран лишний dispatcher;
- исправлены повторные поиски;
- добавлена изоляция поколений поиска;
- устаревшие результаты предыдущего поиска игнорируются;
- состояние Burst защищено lock;
- progressive timeout Burst установлен около 27 секунд;
- для HTTP-запросов добавлены реальные сетевые timeout;
- Kodi перезапускается установщиком после обновления Burst.

Ключевые commits:

| Назначение | Commit |
|---|---|
| Стабильный rollback Elementum | `8758ebec77369aea75a65fe50f069c47e8e49ad3` |
| No-op dispatcher | `9254001fe08ab2536d40b87a1a0d9646734513c4` |
| Standalone runner addon context | `823af8200df2862b20c1f0d1acda9114ac70e8f1` |
| Installer runner fix | `58cdac3a2da49bc8fd69dfc795631aa90b6ef177` |
| Burst generation isolation and timeout | `2688ed825d736ce5184b998b3cd656cafd96fc33` |

Репозитории:

```text
https://github.com/ilchenkoevgeny/elementum
branch: feature/progressive-results

https://github.com/ilchenkoevgeny/script.elementum.burst
branch: feature/progressive-results

https://github.com/ilchenkoevgeny/plugin.video.elementum
branch: feature/progressive-results
```

## 6. Chromium и browser bridge

Контейнер:

```text
chromium-rutracker
```

Образ:

```text
lscr.io/linuxserver/chromium:latest
```

Параметры:

| Параметр | Значение |
|---|---|
| Сеть | host |
| Профиль | `/storage/.config/chromium-rutracker` -> `/config` |
| Web GUI | `https://192.168.31.235:3001` |
| Relay | `127.0.0.1:9911` |
| QUIC | отключён |

Relay находится на хосте:

```text
/storage/.config/chromium-rutracker/rutracker-bridge/relay.py
```

Сервис relay:

```text
/storage/.config/system.d/rutracker-bridge.service
```

Фактический `ExecStart`:

```text
/usr/bin/python3 -u /storage/.config/chromium-rutracker/rutracker-bridge/relay.py
```

`Restart=always` у этого сервиса относится только к Python relay. Само по себе это не должно запускать контейнер Chromium.

Endpoint relay:

| Endpoint | Назначение |
|---|---|
| `GET /health` | состояние bridge |
| `GET /warmup` | запуск Chromium и ожидание extension |
| `GET /job` | extension забирает работу |
| `POST /result` | extension возвращает результат |
| `POST /request` | HTML-запрос через браузер |
| `GET /torrent?url=...` | скачивание `.torrent` через браузер |

Расширение внутри Chromium опрашивает `/job` примерно раз в 25 секунд, но только когда Chromium уже запущен. Сам `/job` не должен запускать контейнер.

## 7. Итоговая схема on-demand Chromium

Требуемое поведение:

1. В простое:

```text
Running=false
Restart=no
```

2. При поиске RuTracker:

```text
Running=true
Restart=unless-stopped
```

3. После примерно 120 секунд без активности:

```text
Running=false
Restart=no
```

За остановку отвечает один внешний watchdog:

```text
rutracker-chromium-idle-watchdog.service
```

Скрипт:

```text
/storage/.config/rutracker-chromium-deadline-watchdog.sh
```

Файл абсолютного deadline:

```text
/run/rutracker-chromium.deadline
```

Внутренний Python-поток `chromium_idle_watchdog` отключён. Остановкой занимается только внешний systemd watchdog.

## 8. Установленные исправления lifecycle Chromium

### 8.1. Absolute deadline watchdog

Installer:

```text
scripts/install-rutracker-deadline-watchdog-v2.sh
commit: 32b1c941203f2a5b6ad9e4c29ec5cf4afb164452
```

Проверены два цикла start/stop.

Резервная копия:

```text
/storage/rutracker-deadline-watchdog-v2-backup-20260805-124755
```

### 8.2. Один watchdog вместо двух

Installer:

```text
scripts/install-rutracker-single-watchdog-v4.sh
commit: c587ad913e7adde8453089d882ddfb77823e0802
```

Итог установки:

```text
Bridge: active
External watchdog: active
Internal watchdog thread: disabled
Chromium running: false
Chromium restart policy: no
```

Резервная копия:

```text
/storage/rutracker-single-watchdog-v4-backup-20260805-132218
```

### 8.3. Restart policy во время активной работы

Первый installer ошибочно проверял маркер `V3`, хотя установлен был `V4`. Это была ошибка проверки installer, а не состояние системы.

Исправленный installer:

```text
scripts/install-rutracker-active-restart-policy-v6.sh
commit: b4c8545d1875eaf6cb0e03519dae22b38a497476
```

Подтверждён встроенный тест:

```text
=== ACTIVE START TEST ===
Active state: Running=true Restart=unless-stopped

=== IDLE STOP TEST ===
Idle state: Running=false Restart=no
```

Резервная копия:

```text
/storage/rutracker-active-restart-policy-v6-backup-20260805-132910
```

### 8.4. Аудит самопроизвольного запуска

Installer:

```text
scripts/install-rutracker-start-audit-v7.sh
commit: 6464b1fc715e2fdc6e77015547cffcc0d23e73cf
```

Резервная копия:

```text
/storage/rutracker-start-audit-v7-backup-20260807-171337
```

Аудит пишет:

```text
RUTRACKER_HTTP_AUDIT
CHROMIUM_START_AUDIT
CHROMIUM_START_STACK
```

Аудит можно пока оставить: он полезен для диагностики и не является причиной запуска контейнера.

## 9. Найденная причина повторного запуска Chromium

Наблюдалось следующее:

- внешний watchdog корректно останавливал Chromium;
- память освобождалась;
- примерно через секунду Chromium запускался снова;
- `Restart=no`, поэтому это не Docker autorestart;
- в bridge не было `CHROMIUM_START_AUDIT`, поэтому запуск не шёл через `ensure_chromium_ready()`;
- после запуска extension начинала опрашивать `/job`, но это было следствием, а не причиной.

Источник найден:

```text
rutracker-stack-watchdog.timer
```

Таймер запускался каждую минуту и вызывал старую схему:

```text
rutracker-stack-watchdog.service
/storage/.config/rutracker-stack-watchdog.sh
/storage/.config/rutracker-bridge-runner.sh
```

В старом runner присутствует:

```sh
docker start "$CONTAINER"
```

Именно он постоянно поднимал Chromium.

Таймер отключён:

```sh
systemctl disable --now rutracker-stack-watchdog.timer
systemctl stop rutracker-stack-watchdog.service 2>/dev/null || true
```

После остановки контейнера была выполнена проверка 75 секунд. Получено:

```text
Running=false Restart=no
```

Chromium не запустился снова. Проблема постоянного повторного старта считается найденной и устранённой.

**Важно:** `rutracker-stack-watchdog.timer` должен оставаться disabled. Не включать его обратно.

Проверка:

```sh
systemctl is-enabled rutracker-stack-watchdog.timer 2>/dev/null || true
systemctl is-active rutracker-stack-watchdog.timer 2>/dev/null || true

docker inspect -f \
'Running={{.State.Running}} Restart={{.HostConfig.RestartPolicy.Name}}' \
chromium-rutracker
```

## 10. Текущее состояние systemd

Должны работать:

```text
nfqws-rutracker.service
rutracker-bridge.service
rutracker-chromium-idle-watchdog.service
service.system.docker.service
```

Должен быть отключён:

```text
rutracker-stack-watchdog.timer
```

Не путать два watchdog:

- `rutracker-chromium-idle-watchdog.service` — новый нужный внешний watchdog;
- `rutracker-stack-watchdog.timer` — старая схема, которая ошибочно постоянно запускала Chromium.

## 11. Быстрая проверка RuTracker lifecycle

Перед тестом:

```sh
docker inspect -f \
'Running={{.State.Running}} Restart={{.HostConfig.RestartPolicy.Name}}' \
chromium-rutracker
```

В простое ожидается:

```text
Running=false Restart=no
```

После запуска поиска RuTracker:

```sh
docker inspect -f \
'Running={{.State.Running}} Restart={{.HostConfig.RestartPolicy.Name}} Started={{.State.StartedAt}}' \
chromium-rutracker
```

Ожидается:

```text
Running=true Restart=unless-stopped
```

После 130 секунд без нового RuTracker-запроса:

```sh
docker inspect -f \
'Running={{.State.Running}} Restart={{.HostConfig.RestartPolicy.Name}} Finished={{.State.FinishedAt}}' \
chromium-rutracker
```

Ожидается:

```text
Running=false Restart=no
```

Лог watchdog:

```sh
journalctl -u rutracker-chromium-idle-watchdog.service -n 50 --no-pager
```

## 12. Текущая нерешённая задача: RuTor не возвращает результаты

На момент завершения чата Chromium lifecycle исправлен. Следующая задача — отдельно выяснить, почему Burst не показывает результаты RuTor.

Пока **не доказано**, что причина именно в URL или именно в parser. Необходимо сначала получить фактические данные с Orange Pi.

В разных состояниях проекта встречались адреса:

```text
http://rutor.lib
http://rutor.info/search/
```

Рабочий сайт доступен по HTTPS, но нельзя менять конфигурацию вслепую. Сначала нужно прочитать установленный `providers.json` и сравнить ответы HTTP/HTTPS.

### Первый следующий шаг

Выполнить на Orange Pi:

```sh
python3 - <<'PY'
import json

path = "/storage/.kodi/addons/script.elementum.burst/burst/providers/providers.json"

with open(path, "r", encoding="utf-8") as f:
    p = json.load(f)["rutor"]

print("=== RUTOR PROVIDER ===")
for key in (
    "base_url",
    "movie_query",
    "general_query",
    "separator",
    "subpage",
    "enabled",
):
    print("%s=%r" % (key, p.get(key)))

print("parser=%r" % p.get("parser"))
PY

echo
echo "=== NETWORK TESTS ==="

for URL in \
  "http://rutor.info/search/0/0/100/0/interstellar%202014" \
  "https://rutor.info/search/0/0/100/0/interstellar%202014" \
  "https://rutor.is/search/0/0/100/0/interstellar%202014"
do
    FILE="/tmp/rutor-test-$(echo "$URL" | sed 's#[/:]#_#g').html"

    echo
    echo "--- $URL ---"

    curl -kL \
      --connect-timeout 10 \
      --max-time 30 \
      -A "Mozilla/5.0" \
      -o "$FILE" \
      -w 'HTTP=%{http_code} EFFECTIVE=%{url_effective} SIZE=%{size_download}\n' \
      "$URL"

    echo "TORRENT_LINES=$(grep -c '/torrent/' "$FILE" 2>/dev/null || true)"
    echo "MAGNET_LINES=$(grep -ci 'magnet:?' "$FILE" 2>/dev/null || true)"
    echo "TABLE_ROWS=$(grep -ci '<tr' "$FILE" 2>/dev/null || true)"
    grep -i '<title' "$FILE" 2>/dev/null | head -n 1
done

echo
echo "=== BURST LOG ==="

grep -iE \
'rutor|exception|traceback|timeout|connection|403|301|302|parser' \
/storage/.kodi/temp/kodi.log \
  | tail -n 150
```

Интерпретация:

- HTTP не работает, HTTPS содержит результаты — исправить `base_url`/query на HTTPS;
- HTML содержит `/torrent/`, но Burst возвращает ноль — обновить parser;
- все адреса недоступны — разбирать маршрут/DPI/DNS;
- RuTor отсутствует в Kodi log — проверить, включён ли provider и запускается ли он;
- HTML приходит, parser срабатывает, но UI пуст — проверить загрузку `.torrent` и разрешение ссылки в Elementum.

## 13. Что не следует делать

- Не запускать Chromium для RuTor.
- Не включать обратно `rutracker-stack-watchdog.timer`.
- Не возвращать внутренний Python idle-watchdog.
- Не использовать одновременно два механизма остановки Chromium.
- Не считать занятую память доказательством работы Chromium: сначала проверять `docker inspect` и процессы.
- Не очищать Linux page cache вручную через `drop_caches`.
- Не возвращаться к WARP.
- Не возвращаться к headless/CDP для Cloudflare.
- Не копировать `cf_clearance` как самостоятельное решение.
- Не менять RuTor URL или parser до получения прямого HTTP-теста и фактического установленного provider definition.
- Не выполнять большие `find ... -exec grep` по всему `/storage/.kodi/addons`: на LibreELEC это может идти очень долго. Искать точечно.

## 14. Полезные команды

Состояние контейнера:

```sh
docker inspect -f \
'Running={{.State.Running}} Restart={{.HostConfig.RestartPolicy.Name}} Started={{.State.StartedAt}} Finished={{.State.FinishedAt}}' \
chromium-rutracker
```

Память:

```sh
free -m
```

Процессы Chromium:

```sh
ps -o pid,ppid,rss,comm,args \
  | grep -E '[c]hromium|[s]elkies|[l]abwc' \
  || echo "Chromium processes: NONE"
```

Bridge:

```sh
systemctl status rutracker-bridge.service --no-pager -l
curl -fsS http://127.0.0.1:9911/health
a
```

Примечание: в последней строке выше лишняя буква `a` не нужна; корректная команда только:

```sh
curl -fsS http://127.0.0.1:9911/health
```

Логи:

```sh
journalctl -u rutracker-bridge.service -n 100 --no-pager
journalctl -u rutracker-chromium-idle-watchdog.service -n 100 --no-pager
grep -Ei 'rutracker|rutor|returned|timeout|exception|traceback' \
  /storage/.kodi/temp/kodi.log | tail -n 200
```

## 15. Безопасность и резервные копии

Профиль:

```text
/storage/.config/chromium-rutracker
```

Он содержит cookies, авторизацию RuTracker и Cloudflare clearance. Его нельзя публиковать или помещать в GitHub.

Relay должен слушать только:

```text
127.0.0.1:9911
```

Не публиковать:

- `cf_clearance`;
- cookies RuTracker;
- логины и пароли;
- старые данные WARP/VPN;
- содержимое Chromium profile.

Актуальные резервные копии lifecycle:

```text
/storage/rutracker-deadline-watchdog-v2-backup-20260805-124755
/storage/rutracker-single-watchdog-v4-backup-20260805-132218
/storage/rutracker-active-restart-policy-v6-backup-20260805-132910
/storage/rutracker-start-audit-v7-backup-20260807-171337
```

## 16. Короткий текст для нового чата

> Продолжаем работу по `docs/orange-pi-libreelec-rutracker-handover.md` в `ilchenkoevgeny/elementum`, ветка `feature/progressive-results`. Progressive search и повторные поиски работают. RuTracker использует GUI Chromium через bridge `127.0.0.1:9911`. Chromium запускается on-demand, во время работы получает `Restart=unless-stopped`, а после 120 секунд простоя внешний `rutracker-chromium-idle-watchdog.service` ставит `Restart=no` и останавливает контейнер. Внутренний watchdog отключён. Причиной самопроизвольного повторного запуска был старый `rutracker-stack-watchdog.timer`, который каждую минуту вызывал `/storage/.config/rutracker-bridge-runner.sh` с `docker start`; таймер отключён, и через 75 секунд Chromium остался `Running=false Restart=no`. Следующая отдельная задача — RuTor: Chromium для него не использовать. Нужно прочитать установленный `providers.json` и сравнить HTTP/HTTPS `rutor.info`/`rutor.is`, затем по результату исправлять URL либо parser.
