#!/bin/sh

# Диагностика связки LibreELEC + Zapret/nfqws + Burst + Elementum.
# Скрипт ничего не изменяет и не перезапускает.

set -u

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="/storage/elementum-diagnostics-$STAMP"
REPORT="$REPORT_DIR/report.txt"
NETWORK_TSV="$REPORT_DIR/provider-network.tsv"
PROVIDERS_TSV="$REPORT_DIR/enabled-providers.tsv"

ELEMENTUM_ADDON="/storage/.kodi/addons/plugin.video.elementum"
ELEMENTUM_PROFILE="/storage/.kodi/userdata/addon_data/plugin.video.elementum"
BURST_ADDON="/storage/.kodi/addons/script.elementum.burst"
BURST_PROFILE="/storage/.kodi/userdata/addon_data/script.elementum.burst"
KODI_LOG="/storage/.kodi/temp/kodi.log"
NFQ_SERVICE="nfqws-rutracker.service"

mkdir -p "$REPORT_DIR"

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

file_hash() {
    file="$1"
    if [ -f "$file" ]; then
        sha256sum "$file"
    else
        echo "MISSING: $file"
    fi
}

check_marker() {
    label="$1"
    file="$2"
    marker="$3"

    if [ ! -f "$file" ]; then
        echo "MISSING  $label: $file"
        return 1
    fi

    if grep -Fq "$marker" "$file"; then
        echo "OK       $label"
        return 0
    fi

    echo "MISSING  $label (нет маркера: $marker)"
    return 1
}

find_hostlist() {
    service_text="$(systemctl cat "$NFQ_SERVICE" 2>/dev/null || true)"
    hostlist="$(printf '%s\n' "$service_text" | sed -n 's/.*--hostlist[= ]\([^ ]*\).*/\1/p' | tr -d "'\"" | head -n 1)"

    if [ -n "$hostlist" ] && [ -f "$hostlist" ]; then
        printf '%s' "$hostlist"
        return
    fi

    for candidate in \
        /storage/zapret-v72.13/config/rutracker-hosts.txt \
        /storage/zapret/config/rutracker-hosts.txt \
        /storage/zapret/config/list-general.txt
    do
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return
        fi
    done

    printf ''
}

extract_title() {
    body="$1"
    if [ ! -s "$body" ]; then
        printf '-'
        return
    fi

    title="$(tr '\r\n' '  ' < "$body" | sed -n 's/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)<\/[Tt][Ii][Tt][Ll][Ee]>.*/\1/p' | head -n 1 | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
    if [ -z "$title" ]; then
        title="-"
    fi
    printf '%.80s' "$title"
}

run_diagnostics() {
    section "1. СИСТЕМА"
    date
    uname -a
    cat /etc/os-release 2>/dev/null || true
    echo
    echo "Python: $(python3 --version 2>&1 || true)"
    echo "Curl:   $(curl --version 2>/dev/null | head -n 1 || true)"

    section "2. NFQUEUE / ZAPRET"
    systemctl status "$NFQ_SERVICE" --no-pager 2>&1 | sed -n '1,35p' || true
    echo
    lsmod 2>/dev/null | grep -E 'nfnetlink_queue|xt_NFQUEUE|nft_queue|nf_tables' || true
    echo
    iptables -t mangle -S ZAPRET_NFQ_OUT 2>/dev/null || true
    iptables -t mangle -S ZAPRET_NFQ_IN 2>/dev/null || true

    HOSTLIST="$(find_hostlist)"
    echo
    if [ -n "$HOSTLIST" ]; then
        echo "Hostlist: $HOSTLIST"
        sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$HOSTLIST" 2>/dev/null || true
    else
        echo "Hostlist: НЕ НАЙДЕН"
    fi

    section "3. УСТАНОВЛЕННЫЕ ВЕРСИИ И ФАЙЛЫ"
    for addon_xml in "$ELEMENTUM_ADDON/addon.xml" "$BURST_ADDON/addon.xml"; do
        if [ -f "$addon_xml" ]; then
            grep -m1 '<addon ' "$addon_xml" || true
        else
            echo "MISSING: $addon_xml"
        fi
    done

    echo
    echo "Elementum binary:"
    file_hash "$ELEMENTUM_ADDON/resources/bin/linux_arm64/elementum"
    file_hash "$ELEMENTUM_PROFILE/bin/linux_arm64/elementum"

    ELEMENTUM_PID="$(pgrep -o elementum 2>/dev/null || true)"
    if [ -n "$ELEMENTUM_PID" ]; then
        echo "Running PID: $ELEMENTUM_PID"
        readlink -f "/proc/$ELEMENTUM_PID/exe" 2>/dev/null || true
        tr '\0' ' ' < "/proc/$ELEMENTUM_PID/cmdline" 2>/dev/null || true
        echo
    else
        echo "Running PID: НЕ НАЙДЕН"
    fi

    section "4. ПРОВЕРКА PROGRESSIVE-КОМПОНЕНТОВ"
    progressive_missing=0

    check_marker \
        "plugin provider callback envelopes" \
        "$ELEMENTUM_ADDON/resources/site-packages/elementum/provider.py" \
        "_send_provider_callback" || progressive_missing=1

    check_marker \
        "plugin progressive RPC create" \
        "$ELEMENTUM_ADDON/resources/site-packages/elementum/rpc.py" \
        "Dialog_Select_Large_Progressive_Create" || progressive_missing=1

    check_marker \
        "plugin progressive dialog updates" \
        "$ELEMENTUM_ADDON/resources/site-packages/elementum/dialog_select.py" \
        "updateItems" || progressive_missing=1

    check_marker \
        "Burst progressive generator" \
        "$BURST_ADDON/burst/burst.py" \
        "def search_progressive" || progressive_missing=1

    check_marker \
        "Burst Chromium torrent bridge" \
        "$BURST_ADDON/burst/provider.py" \
        "Routing torrent download through Chromium bridge" || progressive_missing=1

    echo
    file_hash "$ELEMENTUM_ADDON/resources/site-packages/elementum/provider.py"
    file_hash "$ELEMENTUM_ADDON/resources/site-packages/elementum/rpc.py"
    file_hash "$ELEMENTUM_ADDON/resources/site-packages/elementum/dialog_select.py"
    file_hash "$BURST_ADDON/burst/burst.py"
    file_hash "$BURST_ADDON/burst/provider.py"

    if [ "$progressive_missing" -ne 0 ]; then
        echo
        echo "!!! НАЙДЕНА ВЕРОЯТНАЯ ПРИЧИНА ПУСТОГО ОКНА:"
        echo "!!! установленный plugin.video.elementum/Burst содержит не все progressive-файлы."
    else
        echo
        echo "Все обязательные progressive-маркеры присутствуют."
    fi

    section "5. CHROMIUM BRIDGE"
    curl -sS --max-time 5 http://127.0.0.1:9911/health 2>&1 || true
    echo
    docker ps --filter name=chromium-rutracker 2>/dev/null || true
    docker exec chromium-rutracker sh -c "ps -ef | grep '[r]utracker-bridge/relay.py'" 2>/dev/null || true

    section "6. ВКЛЮЧЁННЫЕ BURST-ПРОВАЙДЕРЫ"
    SETTINGS_XML="$BURST_PROFILE/settings.xml"
    PROVIDERS_JSON="$BURST_ADDON/burst/providers/providers.json"

    if [ ! -f "$SETTINGS_XML" ]; then
        echo "ERROR: не найден $SETTINGS_XML"
    elif [ ! -f "$PROVIDERS_JSON" ]; then
        echo "ERROR: не найден $PROVIDERS_JSON"
    elif ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 не найден"
    else
        HOSTLIST_ENV="$HOSTLIST" \
        SETTINGS_ENV="$SETTINGS_XML" \
        PROVIDERS_ENV="$PROVIDERS_JSON" \
        python3 - "$PROVIDERS_TSV" <<'PY'
import copy
import json
import os
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlparse, urlunparse

output_path = sys.argv[1]
settings_path = os.environ["SETTINGS_ENV"]
providers_path = os.environ["PROVIDERS_ENV"]
hostlist_path = os.environ.get("HOSTLIST_ENV", "")

settings = {}
root = ET.parse(settings_path).getroot()
for node in root.iter("setting"):
    key = node.get("id")
    if not key:
        continue
    value = node.get("value")
    if value is None:
        value = node.text or ""
    settings[key] = value.strip()

with open(providers_path, "r", encoding="utf-8") as fh:
    providers = json.load(fh)

hostlist = set()
if hostlist_path and os.path.isfile(hostlist_path):
    with open(hostlist_path, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip().lower()
            if line and not line.startswith("#"):
                hostlist.add(line)

def is_true(value):
    return str(value).strip().lower() in ("true", "1", "yes", "on")

def apply_alias(definition, alias):
    definition = copy.deepcopy(definition)
    if not alias:
        return definition

    alias_url = alias if "://" in alias else "https://" + alias
    parsed_alias = urlparse(alias_url)
    new_domain = parsed_alias.netloc
    new_scheme = parsed_alias.scheme

    old_domain = ""
    for key in ("root_url", "base_url"):
        value = definition.get(key) or ""
        parsed = urlparse(value)
        if parsed.netloc:
            old_domain = parsed.netloc
            break

    if not old_domain or not new_domain:
        return definition

    def replace(value):
        if not isinstance(value, str):
            return value
        value = value.replace(old_domain, new_domain)
        if new_scheme:
            value = value.replace("http://", new_scheme + "://")
            value = value.replace("https://", new_scheme + "://")
        return value

    for key, value in list(definition.items()):
        if isinstance(value, str):
            definition[key] = replace(value)
        elif key == "parser" and isinstance(value, dict):
            definition[key] = {k: replace(v) for k, v in value.items()}
    return definition

def sanitize_url(url):
    replacements = {
        "QUERYEXTRA": "interstellar+2014",
        "QUERY": "interstellar",
        "EXTRA": "",
        "FIRSTLETTER": "i",
        "TOKEN": "test",
        "USERNAME": "test",
        "PASSKEY": "test",
    }
    for source, target in replacements.items():
        url = url.replace(source, target)
    return url.replace(" ", "%20")

def in_hostlist(domain):
    domain = domain.lower().split(":", 1)[0]
    return any(domain == item or domain.endswith("." + item) for item in hostlist)

rows = []
for provider_id, raw_definition in providers.items():
    if raw_definition.get("enabled") is False:
        continue

    enabled = is_true(settings.get("use_" + provider_id, "false"))
    if raw_definition.get("custom"):
        enabled = True
    if not enabled:
        continue

    contains = settings.get(provider_id + "_contains", "")
    if contains not in ("", "0", "1", "All", "Movies"):
        continue

    alias = settings.get(provider_id + "_alias", "")
    definition = apply_alias(raw_definition, alias)
    url = definition.get("base_url") or definition.get("root_url") or ""
    if not url:
        continue
    url = sanitize_url(url)
    parsed = urlparse(url)
    domain = parsed.netloc
    if not domain:
        continue

    rows.append((
        provider_id,
        str(definition.get("name") or provider_id).replace("\t", " "),
        domain,
        "YES" if in_hostlist(domain) else "NO",
        url,
        alias,
    ))

rows.sort(key=lambda row: row[0])
with open(output_path, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write("\t".join(row) + "\n")

print("Найдено включённых movie-провайдеров:", len(rows))
for provider_id, name, domain, zapret, url, alias in rows:
    alias_text = " alias=" + alias if alias else ""
    print("%-18s %-32s %-28s ZAPRET=%s%s" % (
        provider_id, name[:32], domain[:28], zapret, alias_text
    ))
PY
    fi

    section "7. СЕТЕВАЯ ПРОВЕРКА ВКЛЮЧЁННЫХ ПРОВАЙДЕРОВ"
    printf 'provider\tdomain\tzapret\tstatus\thttp\ttime\tbytes\tremote_ip\ttitle\turl_effective\n' > "$NETWORK_TSV"

    if [ -s "$PROVIDERS_TSV" ]; then
        tab="$(printf '\t')"
        while IFS="$tab" read -r provider_id provider_name domain in_zapret test_url alias; do
            body="$REPORT_DIR/body-$provider_id.tmp"
            err="$REPORT_DIR/error-$provider_id.tmp"

            result="$(curl \
                -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/142 Safari/537.36' \
                -L --compressed \
                --connect-timeout 6 \
                --max-time 15 \
                -sS \
                -o "$body" \
                -w '%{http_code}\t%{time_total}\t%{size_download}\t%{remote_ip}\t%{url_effective}' \
                "$test_url" 2>"$err" || true)"

            http_code="$(printf '%s' "$result" | cut -f1)"
            time_total="$(printf '%s' "$result" | cut -f2)"
            size_download="$(printf '%s' "$result" | cut -f3)"
            remote_ip="$(printf '%s' "$result" | cut -f4)"
            effective_url="$(printf '%s' "$result" | cut -f5-)"

            [ -n "$http_code" ] || http_code="000"
            [ -n "$time_total" ] || time_total="-"
            [ -n "$size_download" ] || size_download="0"
            [ -n "$remote_ip" ] || remote_ip="-"
            [ -n "$effective_url" ] || effective_url="$test_url"

            status="HTTP"
            case "$http_code" in
                2*|3*) status="OPEN" ;;
                401) status="AUTH" ;;
                403|429|503)
                    if grep -Eqi 'just a moment|cloudflare|cf-chl|challenge-platform' "$body" 2>/dev/null; then
                        status="CLOUDFLARE"
                    else
                        status="REACHABLE"
                    fi
                    ;;
                000)
                    status="FAIL"
                    ;;
            esac

            title="$(extract_title "$body")"
            error_text="$(tr '\r\n\t' '   ' < "$err" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-100)"
            if [ "$status" = "FAIL" ] && [ -n "$error_text" ]; then
                title="$error_text"
            fi

            printf '%-18s %-28s ZAPRET=%-3s %-11s HTTP=%-3s %6ss %8s B  %s\n' \
                "$provider_id" "$domain" "$in_zapret" "$status" "$http_code" "$time_total" "$size_download" "$title"

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$provider_id" "$domain" "$in_zapret" "$status" "$http_code" "$time_total" "$size_download" "$remote_ip" "$title" "$effective_url" \
                >> "$NETWORK_TSV"

            rm -f "$body" "$err"
        done < "$PROVIDERS_TSV"
    else
        echo "Список включённых провайдеров пуст или не создан."
    fi

    section "8. КОНТРОЛЬНЫЙ ПОИСК BURST → ELEMENTUM"
    if [ ! -f "$KODI_LOG" ]; then
        echo "ERROR: не найден $KODI_LOG"
    else
        start_line="$(wc -l < "$KODI_LOG" | tr -d ' ')"
        echo "Сейчас запустите в Kodi ОДИН поиск фильма обычным способом."
        echo "Дождитесь пустого окна, ошибки либо завершения поиска."
        echo "После этого вернитесь в SSH и нажмите Enter."
        echo

        if [ -t 0 ]; then
            printf 'Нажмите Enter после контрольного поиска... '
            read dummy || true
            echo
            search_log="$REPORT_DIR/search.log"
            sed -n "$((start_line + 1)),\$p" "$KODI_LOG" > "$search_log"
        else
            echo "Интерактивный ввод недоступен — анализируются последние 1200 строк kodi.log."
            search_log="$REPORT_DIR/search.log"
            tail -n 1200 "$KODI_LOG" > "$search_log"
        fi

        grep -Ei \
            "Burstin'|returned [0-9]+ results|Providers returned|callback returned|callbacks/|progressive|Dialog_Select_Large_Progressive|Resolving torrent|Resolve failed|Received [0-9]+ unique links|Failed to unmarshal|too slow|Chromium bridge|rutracker|rutor|HTTP [0-9]+" \
            "$search_log" || true

        section "9. АВТОМАТИЧЕСКИЙ ВЫВОД ПО ЦЕПОЧКЕ"

        if grep -Eq '\[[^]]+\].*returned +[1-9][0-9]* results' "$search_log"; then
            echo "OK: Burst получил ненулевые результаты хотя бы от одного провайдера."
        else
            echo "FAIL: в контрольном логе нет ненулевых результатов Burst."
        fi

        if grep -Eq 'callback returned: 2[0-9][0-9]|POST +/callbacks/' "$search_log"; then
            echo "OK: callback Burst → Elementum зафиксирован."
        else
            echo "FAIL: callback Burst → Elementum не подтверждён логом."
        fi

        if grep -Eq 'Received +[1-9][0-9]* unique links' "$search_log"; then
            echo "OK: Elementum успешно разрешил хотя бы одну torrent/magnet-ссылку."
        else
            echo "FAIL: Elementum не дошёл до ненулевого 'Received N unique links'."
        fi

        if grep -Eq 'Dialog_Select_Large_Progressive_Create|Dialog_Select_Large_Progressive_Update' "$search_log"; then
            echo "OK: progressive RPC вызывался."
        else
            echo "WARN: вызов progressive RPC не виден в логе. Проверка файлов выше важнее."
        fi

        if grep -Eq 'Resolve failed' "$search_log"; then
            echo "WARN: есть ошибки разрешения .torrent/magnet — смотрите строки Resolve failed выше."
        fi

        if grep -Eq 'Failed to unmarshal torrents' "$search_log"; then
            echo "FAIL: Elementum не смог разобрать callback Burst."
        fi
    fi

    section "10. ФАЙЛЫ ОТЧЁТА"
    echo "Основной отчёт: $REPORT"
    echo "Сеть:           $NETWORK_TSV"
    echo "Провайдеры:     $PROVIDERS_TSV"
    echo "Лог поиска:     $REPORT_DIR/search.log"
    echo
    echo "Для передачи отчёта выполните:"
    echo "cat '$REPORT'"
}

run_diagnostics 2>&1 | tee "$REPORT"
