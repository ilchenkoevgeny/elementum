# Orange Pi 3 + LibreELEC + Elementum: актуальный handover

> Обновлено 2026-08-12. Этот файл является основной точкой продолжения работы в новом чате.

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

## 17. H6 Hantro G2 VP9: cold-start проблема и подтверждённый workaround

### 17.1. Симптом

На Orange Pi 3 / Allwinner H6 аппаратный VP9-декодер Hantro G2 после холодной загрузки LibreELEC может не завершать первый decode job.

Устройство и драйверы:

```text
/dev/video0 = cedrus
/dev/video1 = sun50i-di
/dev/video2 = allwinner,sun50i-h6-vpu-g2-dec
```

Поддерживаемые compressed INPUT-форматы:

```text
Cedrus /dev/video0:
MG2S, S264, S265, VP8F

Hantro /dev/video2:
VP9F
```

То есть VP9 реально идёт через Hantro G2, а H.264 — через Cedrus.

Типичный cold failure в Kodi:

```text
CDVDVideoCodecDRMPRIME::Open - using decoder Google VP9
[vp9] v4l2_request_queue_decode: request ... timeout
...
CDVDVideoCodecDRMPRIME::AddData - send packet failed: Operation not permitted (-1)
```

Kernel:

```text
hantro_watchdog:127: frame processing timed out!
```

При этом Hantro не генерирует completion IRQ:

```text
Cedrus IRQ 121 = 0
Hantro IRQ 122 = 0
```

После того как Hantro однажды переведён в рабочее состояние, VP9 1080p60/1440p60 работает, 2160p60 запускается. Проблемы устойчивой производительности 2160p60 (`OutputPicture - timeout`, визуальное замедление видео при нормальном аудио) являются отдельной задачей и не смешиваются с cold-start.

### 17.2. Стабильный тестовый ролик

Для прямого запуска через YouTube addon использовался:

```sh
kodi-send --action="PlayMedia(plugin://plugin.video.youtube/play/?video_id=TEklhVioz7I)"
```

Это длинный русскоязычный ролик по квантовой механике. Он использовался как стабильный повторяемый тест, а не как HDR demo.

### 17.3. Первое важное наблюдение: Cedrus/H.264 прогревает Hantro

На чистой загрузке:

```text
Cedrus IRQ 121 = 0
Hantro IRQ 122 = 0
```

VP9 зависал с watchdog.

Для диагностики YouTube addon временно принудительно фильтровался до AVC (`codec == avc1`). Был подтверждён реальный hardware H.264 decode:

```text
CDVDVideoCodecDRMPRIME::Open - using decoder H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10
Cedrus IRQ 121 > 0
Hantro IRQ 122 = 0
```

После остановки H.264, восстановления addon, restart Kodi и запуска VP9 в том же boot:

```text
CDVDVideoCodecDRMPRIME::Open - using decoder Google VP9
Hantro IRQ 122 > 0
```

VP9 начинал работать.

Ключевой контрольный тест с ранней остановкой Cedrus дал всего:

```text
Cedrus IRQ 121 = 10
```

после чего Hantro набрал тысячи IRQ и VP9 работал.

Это сначала указывало на возможную связь с реальным Cedrus job, но дальнейшие тесты сузили механизм ещё сильнее.

### 17.4. Что было проверено и исключено

#### Restart Kodi

Один `systemctl restart kodi` на холодном состоянии Hantro проблему не исправляет.

#### Runtime-PM самого Hantro

Принудительное:

```sh
echo on > /sys/bus/platform/devices/1c00000.video-codec-g2/power/control
```

переводило `runtime_status` в `active`, но первый VP9 всё равно зависал. То есть обычный autosuspend/runtime-PM самого Hantro не является достаточным объяснением.

#### Hantro reset pulse

Для H6 reset VP9 находится в CCU `0x030016cc`, bit 16 (`RST_BUS_VP9`). На холодной системе вручную выполнялся assert/deassert reset с сохранением остальных битов.

Результат: VP9 всё равно зависал, Hantro IRQ оставался 0, появлялись watchdog timeout.

Следовательно, одного reset pulse Hantro недостаточно.

#### IOMMU TLB flush

H6 IOMMU base:

```text
0x030f0000
```

Проверялся полный TLB flush:

```sh
busybox devmem 0x030f0080 32 0x0003003F
```

Flush завершался, но cold VP9 всё равно зависал. Следовательно, проблема не сводится к обычному stale TLB.

Ранее наблюдавшийся IOMMU page fault с `master 0` относится к display mixer, а не к Hantro/Cedrus. Использованная карта masters:

```text
master 0 = display mixer
master 3 = Cedrus
master 5 = Hantro G2
```

#### Общий MBUS/DRAM/IOMMU clock state

Сравнивались COLD и GOOD состояния CCU/clock tree. Они совпали для общей fabric:

```text
0x03001540 = 0xC1000002   # MBUS
0x030017bc = 0x00000001   # bus-IOMMU
0x03001800 = 0x40000000   # DRAM
0x03001804 = 0x00000005   # MBUS gates
```

То есть persistent difference в обычных MBUS/DRAM/bus-IOMMU clock/gate не найден.

#### `mbus-ve` pulse

Cedrus использует `mbus-ve` (`CCU 0x804 BIT1`) как `ram_clk`. На холодной системе вручную включался и выключался только этот gate.

Результат: Hantro IRQ остался 0, появились новые watchdog timeout. Зелёный кадр, который однажды появился на экране, оказался display/invalid-buffer артефактом и не означал успешный Hantro progress.

Следовательно, простой `mbus-ve` pulse не исправляет проблему.

#### Полная ручная последовательность Cedrus clocks/reset/MBUS

Вручную воспроизводилась последовательность, близкая к `cedrus_hw_resume()`/suspend:

- VE reset;
- bus/AHB clock;
- module clock;
- `mbus-ve`;
- обратное выключение.

Физические CCU-регистры:

```text
VE mod:  0x03001690
VE bus/reset: 0x0300169c
MBUS gates:   0x03001804
```

Результат: VP9 всё равно зависал.

Следовательно, простая ручная имитация видимых clock/reset/MBUS регистров недостаточна.

#### REQBUFS-only Cedrus

После clean boot выполнялся только `VIDIOC_REQBUFS` для OUTPUT и CAPTURE `/dev/video0`, без `QBUF` и без `STREAMON`.

Получено:

```text
REQBUFS type=2 count=4 memory=1 caps=0x0000001d
REQBUFS type=1 count=4 memory=1 caps=0x00000015
REQBUFS_ONLY=SUCCESS

Cedrus IRQ 121 = 0
Hantro IRQ 122 = 0
```

После этого VP9 всё равно висел с ромашкой.

Следовательно, обычного выделения vb2 DMA/MMAP buffers недостаточно.

### 17.5. Ключевой разделяющий тест: STREAMON Cedrus без decode-job

Это итоговое наблюдение, на котором построен workaround.

Cedrus driver для OUTPUT-очереди в `cedrus_start_streaming()` вызывает:

```c
pm_runtime_resume_and_get(dev->dev);
```

до аппаратного decode job.

Был выполнен следующий путь на `/dev/video0`:

```text
open
VIDIOC_REQBUFS (1 OUTPUT MMAP buffer)
VIDIOC_STREAMON
sleep 0.2 s
VIDIOC_STREAMOFF
VIDIOC_REQBUFS(count=0)
close
```

При этом принципиально НЕ выполнялись:

```text
QBUF
Media Request queue
decode request
hardware frame job
```

После такого праймера:

```text
Cedrus IRQ 121 = 0
```

но первый VP9 сразу запускался и Hantro начинал генерировать completion IRQ. Один из подтверждённых результатов:

```text
Cedrus IRQ 121 = 0
Hantro IRQ 122 = 3860
```

Новых `hantro_watchdog` после успешного запуска не было; показанные watchdog'и относились к предыдущему cold-failure до праймера.

Это доказывает, что успешный Cedrus decode-job НЕ требуется.

### 17.6. Важная деталь про codec в минимальном тесте

В одном промежуточном тесте перед Python выполнялось:

```sh
v4l2-ctl -d /dev/video0 --set-fmt-video-out=width=1920,height=1080,pixelformat=S264
```

Но `v4l2-ctl` открывает и закрывает собственный file descriptor. Python затем открывал новый `/dev/video0`, то есть создавался новый Cedrus context, и H.264 format туда не переносился.

В `cedrus_open()` новый context вызывает reset output format и выбирает первый доступный source codec. Для обычной конфигурации это MPEG-2. У MPEG-2 `cedrus_dec_ops_mpeg2` не имеет `.start` callback.

Следовательно, успешный STREAMON-only primer не зависел от H.264-specific DMA buffers и не выполнял H.264 start path.

Это дополнительно подтверждает, что достаточно самого реального kernel runtime-PM path Cedrus.

### 17.7. Точная формулировка установленного результата

**Доказано:**

```text
Cold boot
  -> Hantro G2 VP9 не выдаёт completion IRQ, watchdog timeout
  -> один реальный runtime-resume/runtime-suspend Cedrus через V4L2 STREAMON/STREAMOFF
     без QBUF и без Cedrus IRQ
  -> Hantro G2 VP9 работает и выдаёт IRQ
```

**Не доказано:** какой именно скрытый аппаратный side effect внутри runtime-resume Cedrus является первопричиной.

Нельзя утверждать, что найден конкретный "бит" или конкретный clock. Наоборот, ручная имитация известных clocks/reset/MBUS этого эффекта не дала.

Корректная текущая гипотеза: реальный kernel/CCF/reset/runtime-PM путь Cedrus выполняет side effect, необходимый для корректного первого запуска Hantro G2 на H6. Точная низкоуровневая причина пока не локализована.

### 17.8. Upstream Linux source points, использованные при диагностике

Основные файлы upstream Linux:

```text
drivers/staging/media/sunxi/cedrus/cedrus_hw.c
drivers/staging/media/sunxi/cedrus/cedrus_video.c
drivers/staging/media/sunxi/cedrus/cedrus.c
drivers/staging/media/sunxi/cedrus/cedrus_h264.c
drivers/staging/media/sunxi/cedrus/cedrus_mpeg2.c

drivers/media/platform/verisilicon/hantro_drv.c
drivers/media/platform/verisilicon/sunxi_vpu_hw.c

drivers/clk/sunxi-ng/ccu-sun50i-h6.c
```

Важные факты из исходников:

- Cedrus queues используют `vb2_dma_contig_memops`;
- Cedrus OUTPUT queue имеет `supports_requests=true`, `requires_requests=true`;
- `cedrus_start_streaming()` делает `pm_runtime_resume_and_get()`;
- только реальная queue/request нужна для decode job, но STREAMON сам по себе может вызвать start_streaming;
- `cedrus_hw_resume()` работает через reset framework и clocks `ahb`, `mod`, `ram`;
- H6 Hantro G2 имеет clocks `mod`, `bus`, отдельный reset и аппаратный VP9 backend;
- H6 VP9 reset: CCU offset `0x6cc`, BIT16;
- Cedrus VE clock/reset: `0x690`/`0x69c`;
- VP9 clock/reset: `0x6c0`/`0x6cc`;
- `mbus-ve`: CCU `0x804`, BIT1.

### 17.9. Установленный постоянный workaround

Файл:

```text
/storage/.config/cedrus-vpu-primer.py
```

Содержимое:

```python
#!/usr/bin/python3

import os
import fcntl
import struct
import time

DEV = "/dev/video0"

VIDIOC_REQBUFS   = 0xC0145608
VIDIOC_STREAMON  = 0x40045612
VIDIOC_STREAMOFF = 0x40045613

V4L2_BUF_TYPE_VIDEO_OUTPUT = 2
V4L2_MEMORY_MMAP = 1

REQ_FMT = "=IIIIB3x"

# Wait for Cedrus node after boot.
for _ in range(100):
    if os.path.exists(DEV):
        break
    time.sleep(0.1)
else:
    raise RuntimeError("/dev/video0 did not appear")

fd = os.open(DEV, os.O_RDWR | os.O_NONBLOCK)

try:
    req = bytearray(struct.pack(
        REQ_FMT,
        1,
        V4L2_BUF_TYPE_VIDEO_OUTPUT,
        V4L2_MEMORY_MMAP,
        0,
        0
    ))

    fcntl.ioctl(fd, VIDIOC_REQBUFS, req, True)

    count, typ, mem, caps, flags = struct.unpack(REQ_FMT, req)

    if count == 0:
        raise RuntimeError("Cedrus REQBUFS returned zero buffers")

    qtype = bytearray(struct.pack("=I", V4L2_BUF_TYPE_VIDEO_OUTPUT))

    # Actual Cedrus runtime-PM primer.
    # No QBUF -> no decode job -> no Cedrus IRQ required.
    fcntl.ioctl(fd, VIDIOC_STREAMON, qtype, True)

    time.sleep(0.2)

    fcntl.ioctl(fd, VIDIOC_STREAMOFF, qtype, True)

    req = bytearray(struct.pack(
        REQ_FMT,
        0,
        V4L2_BUF_TYPE_VIDEO_OUTPUT,
        V4L2_MEMORY_MMAP,
        0,
        0
    ))

    fcntl.ioctl(fd, VIDIOC_REQBUFS, req, True)

finally:
    os.close(fd)

print("Cedrus VPU primer completed")
```

Права:

```sh
chmod 0755 /storage/.config/cedrus-vpu-primer.py
```

Systemd unit:

```text
/storage/.config/system.d/cedrus-vpu-primer.service
```

Содержимое:

```ini
[Unit]
Description=Prime Allwinner H6 Cedrus VPU for Hantro G2
Before=kodi.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /storage/.config/cedrus-vpu-primer.py
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Включение:

```sh
systemctl daemon-reload
systemctl enable cedrus-vpu-primer.service
```

### 17.10. Подтверждение сервиса

Перед финальным reboot сервис был проверен вручную:

```text
systemctl is-enabled cedrus-vpu-primer.service
-> enabled

Active: active (exited)
ExecStart=... (code=exited, status=0/SUCCESS)
Cedrus VPU primer completed
```

Фактический journal:

```text
Starting cedrus-vpu-primer.service...
Cedrus VPU primer completed
Finished cedrus-vpu-primer.service.
```

После нового reboot сервис отработал автоматически до первого тестового видео. Первым видео после boot был напрямую запущен VP9 через YouTube addon, и он **запустился сразу**.

Это является финальным cold-boot подтверждением workaround.

### 17.11. Проверка после будущих обновлений LibreELEC/kernel

После обновления ядра или LibreELEC проверить:

```sh
systemctl status cedrus-vpu-primer.service --no-pager -l
journalctl -b -u cedrus-vpu-primer.service --no-pager

grep -Ei '1c0e000|1c00000' /proc/interrupts

dmesg | grep -Ei 'hantro_watchdog|iommu.*fault|page fault' | tail -n 30
```

Контрольный первый VP9:

```sh
kodi-send --action="PlayMedia(plugin://plugin.video.youtube/play/?video_id=TEklhVioz7I)"
```

В рабочем состоянии Hantro IRQ должен расти:

```text
1c00000.video-codec-g2 / GICv2 122 > 0
```

Если будущий kernel исправит cold-start самостоятельно, сервис можно будет временно disable и повторить чистый cold test. Не удалять workaround до такого подтверждения.

### 17.12. Что не делать при продолжении этой задачи

- Не отключать DRM PRIME как окончательное решение: software VP9 не обеспечивает нормальный 4K60.
- Не возвращаться к повторным Kodi restart как к лечению cold Hantro.
- Не повторять обычный Hantro reset pulse — он уже проверен и не помог.
- Не повторять обычный IOMMU TLB flush — он уже проверен и не помог.
- Не считать `mbus-ve` pulse решением — он уже проверен и не помог.
- Не считать ручную последовательность CCU clock/reset эквивалентом runtime-PM Cedrus — экспериментально это не так.
- Не считать REQBUFS-only достаточным праймером — экспериментально не помогает.
- Не связывать проблему с RuTracker/nfqws/Chromium: сетевой стек к decoder cold-start отношения не имеет.
- Не менять рабочую сетевую конфигурацию при диагностике видео.

### 17.13. Короткий текст для продолжения именно hardware decode

> На Orange Pi 3 / H6 cold-start VP9/Hantro G2 локализован. После cold boot первый VP9 через DRM PRIME висит: `hantro_watchdog`, Hantro IRQ 122 остаётся 0. Исключены Kodi restart, runtime-PM Hantro, reset pulse Hantro, IOMMU TLB flush, persistent MBUS/DRAM/bus-IOMMU clocks, `mbus-ve` pulse, ручная полная Cedrus clocks/reset/MBUS последовательность и Cedrus REQBUFS-only. Доказано, что достаточно одного реального Cedrus V4L2 `REQBUFS -> STREAMON -> STREAMOFF` на OUTPUT без QBUF и без decode job: Cedrus IRQ остаётся 0, после чего Hantro выдаёт IRQ и VP9 работает. Установлен `/storage/.config/cedrus-vpu-primer.py` и `cedrus-vpu-primer.service` с `Before=kodi.service`; сервис enabled, oneshot отрабатывает SUCCESS. После финального cold reboot первым видео был VP9 и он запустился. Точный скрытый side effect Cedrus runtime-PM пока не найден; workaround считается подтверждённым.
