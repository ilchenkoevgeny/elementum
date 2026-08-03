#!/bin/sh

# Полный диагностический снимок цепочки:
# Kodi -> plugin.video.elementum -> Burst -> providers -> callback -> Elementum.
# Скрипт не изменяет настройки, файлы аддонов и сервисы.

set -u

WAIT_AFTER_ENTER="${1:-140}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="/storage/elementum-full-diagnostics-$STAMP"
REPORT="$REPORT_DIR/report.txt"
SEARCH_LOG="$REPORT_DIR/search.log"
RUNTIME_LOG="$REPORT_DIR/runtime-samples.log"
PROVIDERS_TSV="$REPORT_DIR/providers-effective.tsv"
PROVIDER_SUMMARY_TSV="$REPORT_DIR/provider-summary.tsv"
SEARCH_URLS_TSV="$REPORT_DIR/search-urls.tsv"
URL_TESTS_TSV="$REPORT_DIR/search-url-tests.tsv"

ELEMENTUM_ADDON="/storage/.kodi/addons/plugin.video.elementum"
ELEMENTUM_PROFILE="/storage/.kodi/userdata/addon_data/plugin.video.elementum"
BURST_ADDON="/storage/.kodi/addons/script.elementum.burst"
BURST_PROFILE="/storage/.kodi/userdata/addon_data/script.elementum.burst"
KODI_LOG="/storage/.kodi/temp/kodi.log"
NFQ_SERVICE="nfqws-rutracker.service"

mkdir -p "$REPORT_DIR" "$REPORT_DIR/http"

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

file_hash() {
    target="$1"
    if [ -f "$target" ]; then
        sha256sum "$target"
    else
        echo "MISSING: $target"
    fi
}

file_marker() {
    label="$1"
    target="$2"
    marker="$3"
    if [ ! -f "$target" ]; then
        echo "MISSING  $label: $target"
    elif grep -Fq "$marker" "$target"; then
        echo "OK       $label"
    else
        echo "MISSING  $label (marker: $marker)"
    fi
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

sanitize_settings() {
    source_file="$1"
    destination_file="$2"
    if [ ! -f "$source_file" ]; then
        echo "MISSING: $source_file" > "$destination_file"
        return
    fi
    python3 - "$source_file" "$destination_file" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

source, destination = sys.argv[1:3]
secret = re.compile(r"password|passwd|token|secret|passkey|login|username|gist|fileurl", re.I)
try:
    root = ET.parse(source).getroot()
except Exception as exc:
    open(destination, "w", encoding="utf-8").write("XML ERROR: %r\n" % (exc,))
    raise SystemExit(0)
rows = []
for node in root.iter("setting"):
    key = node.get("id") or ""
    if not key:
        continue
    value = node.get("value")
    if value is None:
        value = node.text or ""
    value = value.strip()
    if secret.search(key) and value:
        value = "***REDACTED***"
    rows.append((key, value))
rows.sort()
with open(destination, "w", encoding="utf-8") as fh:
    for key, value in rows:
        fh.write("%s=%s\n" % (key, value))
PY
}

build_provider_matrix() {
    settings="$BURST_PROFILE/settings.xml"
    providers="$BURST_ADDON/burst/providers/providers.json"
    definitions_py="$BURST_ADDON/burst/providers/definitions.py"
    hostlist="$1"
    if [ ! -f "$settings" ] || [ ! -f "$providers" ]; then
        : > "$PROVIDERS_TSV"
        return
    fi
    SETTINGS_ENV="$settings" PROVIDERS_ENV="$providers" DEFINITIONS_ENV="$definitions_py" HOSTLIST_ENV="$hostlist" \
    python3 - "$PROVIDERS_TSV" <<'PY'
import copy
import json
import os
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlparse

output = sys.argv[1]
settings_path = os.environ["SETTINGS_ENV"]
providers_path = os.environ["PROVIDERS_ENV"]
definitions_path = os.environ.get("DEFINITIONS_ENV", "")
hostlist_path = os.environ.get("HOSTLIST_ENV", "")
settings = {}
root = ET.parse(settings_path).getroot()
for node in root.iter("setting"):
    key = node.get("id")
    if key:
        value = node.get("value")
        if value is None:
            value = node.text or ""
        settings[key] = value.strip()
with open(providers_path, "r", encoding="utf-8") as fh:
    providers = json.load(fh)
definitions_text = ""
if definitions_path and os.path.isfile(definitions_path):
    definitions_text = open(definitions_path, "r", encoding="utf-8", errors="ignore").read()
legacy_disabled = "pop('opennic_dns_alias', None)" in definitions_text or 'pop("opennic_dns_alias", None)' in definitions_text
hostlist = set()
if hostlist_path and os.path.isfile(hostlist_path):
    for line in open(hostlist_path, "r", encoding="utf-8", errors="ignore"):
        value = line.strip().lower()
        if value and not value.startswith("#"):
            hostlist.add(value)
def true(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")
def apply_alias(definition, alias):
    result = copy.deepcopy(definition)
    if not alias:
        return result
    alias_url = alias if "://" in alias else "https://" + alias
    parsed_alias = urlparse(alias_url)
    new_domain = parsed_alias.netloc
    protocol = parsed_alias.scheme
    old_domain = ""
    for key in ("root_url", "base_url"):
        parsed = urlparse(result.get(key, ""))
        if parsed.netloc:
            old_domain = parsed.netloc
            break
    if not old_domain or not new_domain:
        return result
    def replace(value):
        if not isinstance(value, str):
            return value
        value = value.replace(old_domain, new_domain)
        if protocol:
            value = value.replace("http://", protocol + "://")
            value = value.replace("https://", protocol + "://")
        return value
    for key, value in list(result.items()):
        if isinstance(value, str):
            result[key] = replace(value)
        elif key == "parser" and isinstance(value, dict):
            result[key] = {k: replace(v) for k, v in value.items()}
    return result
def covered(domain):
    domain = domain.lower().split(":", 1)[0]
    return any(domain == item or domain.endswith("." + item) for item in hostlist)
use_opennic = true(settings.get("use_opennic_dns", "false"))
use_tor = true(settings.get("use_tor_dns", "false"))
rows = []
for provider_id, raw in providers.items():
    enabled = true(settings.get("use_" + provider_id, "false")) or bool(raw.get("custom"))
    if not enabled or raw.get("enabled") is False:
        continue
    definition = copy.deepcopy(raw)
    auto_alias = ""
    if use_opennic and not legacy_disabled and definition.get("opennic_dns_alias"):
        auto_alias = definition["opennic_dns_alias"]
        definition = apply_alias(definition, auto_alias)
    if use_tor and definition.get("tor_dns_alias"):
        auto_alias = definition["tor_dns_alias"]
        definition = apply_alias(definition, auto_alias)
    user_alias = settings.get(provider_id + "_alias", "")
    definition = apply_alias(definition, user_alias)
    base_url = definition.get("base_url") or definition.get("root_url") or ""
    domain = urlparse(base_url).netloc
    rows.append((provider_id, str(definition.get("name") or provider_id).replace("\t", " "),
        settings.get(provider_id + "_contains", ""), raw.get("base_url", ""),
        raw.get("opennic_dns_alias", ""), auto_alias, user_alias, base_url, domain,
        "YES" if covered(domain) else "NO", "YES" if legacy_disabled else "NO"))
rows.sort(key=lambda row: row[0])
with open(output, "w", encoding="utf-8") as fh:
    fh.write("provider\tname\tcontains\tconfigured_base_url\tconfigured_opennic_alias\tauto_alias_used\tuser_alias\teffective_base_url\tdomain\tin_zapret\topennic_auto_alias_disabled\n")
    for row in rows:
        fh.write("\t".join(str(v) for v in row) + "\n")
PY
}

monitor_runtime() {
    end_epoch="$1"
    while [ "$(date +%s)" -lt "$end_epoch" ]; do
        echo
        echo "--- $(date '+%Y-%m-%d %H:%M:%S %z') ---"
        ps -ef 2>/dev/null | grep -E '[e]lementum|[k]odi|[r]utracker-bridge|[n]fqws' || true
        ss -lntup 2>/dev/null | grep -E '65220|65221|65222|9911|elementum|kodi' || true
        ss -ntp 2>/dev/null | grep -E '65220|65221|65222|9911|elementum|kodi' || true
        curl -sS --max-time 3 http://127.0.0.1:9911/health 2>&1 || true
        echo
        iptables -t mangle -L ZAPRET_NFQ_OUT -nvx 2>/dev/null || true
        iptables -t mangle -L ZAPRET_NFQ_IN -nvx 2>/dev/null || true
        sleep 5
    done
}

parse_search_log() {
    python3 - "$SEARCH_LOG" "$PROVIDER_SUMMARY_TSV" "$SEARCH_URLS_TSV" "$REPORT_DIR/chain-analysis.txt" <<'PY'
import collections
import re
import sys
from urllib.parse import urlparse

log_path, summary_path, urls_path, analysis_path = sys.argv[1:5]
try:
    text = open(log_path, "r", encoding="utf-8", errors="replace").read()
except OSError:
    text = ""
providers = collections.OrderedDict()
urls = []
def state(provider):
    return providers.setdefault(provider, {"urls": [], "returned": [], "errors": [], "first": "", "last": ""})
for line in text.splitlines():
    match = re.search(r"\[script\.elementum\.burst\].*?\[([^\]]+)\]", line)
    provider = match.group(1) if match else ""
    if provider:
        item = state(provider)
        if not item["first"]:
            item["first"] = line[:23]
        item["last"] = line[:23]
    match = re.search(r"\[([^\]]+)\].*?search URL:\s*(\S.*)$", line)
    if match:
        provider_id, url = match.group(1), match.group(2).strip()
        state(provider_id)["urls"].append(url)
        urls.append((provider_id, urlparse(url).netloc, url))
    match = re.search(r"\[([^\]]+)\].*?returned\s+(\d+)\s+results", line, re.I)
    if match:
        state(match.group(1))["returned"].append(int(match.group(2)))
    if provider and re.search(r"critical|error|failed|exception|traceback|timed out", line, re.I):
        state(provider)["errors"].append(line.strip())
with open(summary_path, "w", encoding="utf-8") as fh:
    fh.write("provider\tmax_returned\treturn_events\turl_count\terror_count\tfirst_seen\tlast_seen\n")
    for provider, item in providers.items():
        values = item["returned"]
        fh.write("%s\t%d\t%d\t%d\t%d\t%s\t%s\n" % (provider, max(values) if values else 0,
            len(values), len(item["urls"]), len(item["errors"]), item["first"], item["last"]))
seen = set()
with open(urls_path, "w", encoding="utf-8") as fh:
    fh.write("provider\tdomain\turl\n")
    for row in urls:
        if row not in seen:
            seen.add(row)
            fh.write("\t".join(row) + "\n")
totals = [int(value) for value in re.findall(r"Providers returned\s+(\d+)\s+results", text, re.I)]
provider_nonzero = any(max(item["returned"] or [0]) > 0 for item in providers.values())
total_nonzero = any(value > 0 for value in totals)
callback_seen = bool(re.search(r"callback returned|provider callback|DIAG_CALLBACK", text, re.I))
elementum_seen = bool(re.search(r"Received\s+\d+\s+unique links|processLinks|provider batch", text, re.I))
dialog_seen = bool(re.search(r"Dialog_Select_Large_Progressive|updateItems|progressive dialog", text, re.I))
with open(analysis_path, "w", encoding="utf-8") as fh:
    fh.write("provider_nonzero=%s\nprovider_total_events=%r\ntotal_nonzero=%s\n" % (provider_nonzero, totals, total_nonzero))
    fh.write("callback_marker_seen=%s\nelementum_receive_marker_seen=%s\nprogressive_dialog_marker_seen=%s\n\n" %
        (callback_seen, elementum_seen, dialog_seen))
    if not provider_nonzero:
        fh.write("PRIMARY_BREAK=PROVIDERS_OR_PARSERS\n")
    elif not total_nonzero:
        fh.write("PRIMARY_BREAK=BURST_AGGREGATION\n")
    elif not elementum_seen:
        fh.write("PRIMARY_BREAK=CALLBACK_OR_ELEMENTUM_RECEIVER\n")
    elif not dialog_seen:
        fh.write("PRIMARY_BREAK=PROGRESSIVE_DIALOG\n")
    else:
        fh.write("PRIMARY_BREAK=NOT_DETERMINED\n")
PY
}

test_search_urls() {
    printf 'provider\tdomain\thttp\ttime\tbytes\tremote_ip\ttitle\teffective_url\terror\n' > "$URL_TESTS_TSV"
    [ -s "$SEARCH_URLS_TSV" ] || return
    tab="$(printf '\t')"
    tail -n +2 "$SEARCH_URLS_TSV" | while IFS="$tab" read -r provider domain url; do
        [ -n "$provider" ] || continue
        safe_name="$(printf '%s-%s' "$provider" "$domain" | tr -c 'A-Za-z0-9._-' '_')"
        body="$REPORT_DIR/http/$safe_name.body"
        headers="$REPORT_DIR/http/$safe_name.headers"
        error_file="$REPORT_DIR/http/$safe_name.error"
        result="$(curl -4 -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/142 Safari/537.36' \
            -L --compressed --connect-timeout 8 --max-time 20 -sS -D "$headers" -o "$body" \
            -w '%{http_code}\t%{time_total}\t%{size_download}\t%{remote_ip}\t%{url_effective}' \
            "$url" 2>"$error_file" || true)"
        http_code="$(printf '%s' "$result" | cut -f1)"
        time_total="$(printf '%s' "$result" | cut -f2)"
        size_download="$(printf '%s' "$result" | cut -f3)"
        remote_ip="$(printf '%s' "$result" | cut -f4)"
        effective_url="$(printf '%s' "$result" | cut -f5-)"
        title="$(tr '\r\n' '  ' < "$body" 2>/dev/null | sed -n 's/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)<\/[Tt][Ii][Tt][Ll][Ee]>.*/\1/p' | head -n 1 | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-100)"
        error_text="$(tr '\r\n\t' '   ' < "$error_file" 2>/dev/null | cut -c1-180)"
        [ -n "$http_code" ] || http_code="000"
        [ -n "$time_total" ] || time_total="-"
        [ -n "$size_download" ] || size_download="0"
        [ -n "$remote_ip" ] || remote_ip="-"
        [ -n "$title" ] || title="-"
        [ -n "$effective_url" ] || effective_url="$url"
        [ -n "$error_text" ] || error_text="-"
        if [ -f "$body" ]; then
            dd if="$body" of="$body.trim" bs=262144 count=1 2>/dev/null || true
            mv "$body.trim" "$body" 2>/dev/null || true
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$provider" "$domain" "$http_code" \
            "$time_total" "$size_download" "$remote_ip" "$title" "$effective_url" "$error_text" >> "$URL_TESTS_TSV"
    done
}

main() {
    section "1. SYSTEM / SERVICES"
    date
    uname -a
    cat /etc/os-release 2>/dev/null || true
    echo "Python: $(python3 --version 2>&1 || true)"
    echo "Curl: $(curl --version 2>/dev/null | head -n 1 || true)"
    systemctl --no-pager --full status kodi 2>&1 | sed -n '1,30p' || true
    systemctl --no-pager --full status "$NFQ_SERVICE" 2>&1 | sed -n '1,30p' || true

    section "2. PROCESSES / PORTS"
    ps -ef 2>/dev/null | grep -E '[e]lementum|[k]odi|[r]utracker-bridge|[n]fqws' || true
    ss -lntup 2>/dev/null || true
    ELEMENTUM_PID="$(pgrep -o elementum 2>/dev/null || true)"
    if [ -n "$ELEMENTUM_PID" ]; then
        echo "Elementum PID=$ELEMENTUM_PID"
        echo "EXE=$(readlink -f "/proc/$ELEMENTUM_PID/exe" 2>/dev/null || true)"
        printf 'CMD='; tr '\0' ' ' < "/proc/$ELEMENTUM_PID/cmdline" 2>/dev/null || true; echo
    fi

    section "3. VERSIONS / HASHES / SYNTAX"
    for addon_xml in "$ELEMENTUM_ADDON/addon.xml" "$BURST_ADDON/addon.xml"; do
        [ -f "$addon_xml" ] && grep -m1 '<addon ' "$addon_xml" || echo "MISSING: $addon_xml"
    done
    for target in \
        "$ELEMENTUM_ADDON/resources/bin/linux_arm64/elementum" \
        "$ELEMENTUM_PROFILE/bin/linux_arm64/elementum" \
        "$ELEMENTUM_ADDON/resources/site-packages/elementum/provider.py" \
        "$ELEMENTUM_ADDON/resources/site-packages/elementum/rpc.py" \
        "$ELEMENTUM_ADDON/resources/site-packages/elementum/dialog_select.py" \
        "$BURST_ADDON/burst/burst.py" "$BURST_ADDON/burst/provider.py" \
        "$BURST_ADDON/burst/filtering.py" "$BURST_ADDON/burst/utils.py" \
        "$BURST_ADDON/burst/providers/definitions.py" "$BURST_ADDON/burst/providers/providers.json"
    do
        file_hash "$target"
    done
    for target in \
        "$ELEMENTUM_ADDON/resources/site-packages/elementum/provider.py" \
        "$ELEMENTUM_ADDON/resources/site-packages/elementum/rpc.py" \
        "$ELEMENTUM_ADDON/resources/site-packages/elementum/dialog_select.py" \
        "$BURST_ADDON/burst/burst.py" "$BURST_ADDON/burst/provider.py" \
        "$BURST_ADDON/burst/filtering.py" "$BURST_ADDON/burst/utils.py" \
        "$BURST_ADDON/burst/providers/definitions.py"
    do
        [ -f "$target" ] && { python3 -m py_compile "$target" 2>&1 && echo "PY_OK: $target" || true; }
    done

    section "4. CRITICAL CODE MARKERS"
    file_marker "provider progressive envelope" "$ELEMENTUM_ADDON/resources/site-packages/elementum/provider.py" '"done": bool(done)'
    file_marker "provider generator consumption" "$ELEMENTUM_ADDON/resources/site-packages/elementum/provider.py" 'for batch in objects'
    file_marker "Burst progressive generator" "$BURST_ADDON/burst/burst.py" 'def search_progressive'
    file_marker "Burst per-provider publish" "$BURST_ADDON/burst/burst.py" 'result_callback(sorted_results)'
    file_marker "progressive RPC create" "$ELEMENTUM_ADDON/resources/site-packages/elementum/rpc.py" 'Dialog_Select_Large_Progressive_Create'
    file_marker "progressive dialog update" "$ELEMENTUM_ADDON/resources/site-packages/elementum/dialog_select.py" 'updateItems'
    file_marker "OpenNIC alias fix" "$BURST_ADDON/burst/providers/definitions.py" "pop('opennic_dns_alias', None)"
    file_marker "RuTracker Chromium bridge" "$BURST_ADDON/burst/provider.py" 'Routing torrent download through Chromium bridge'

    section "5. SANITIZED SETTINGS"
    sanitize_settings "$BURST_PROFILE/settings.xml" "$REPORT_DIR/burst-settings-sanitized.txt"
    sanitize_settings "$ELEMENTUM_PROFILE/settings.xml" "$REPORT_DIR/elementum-settings-sanitized.txt"
    cat "$REPORT_DIR/burst-settings-sanitized.txt" 2>/dev/null || true
    echo "--- ELEMENTUM ---"
    cat "$REPORT_DIR/elementum-settings-sanitized.txt" 2>/dev/null || true

    section "6. ZAPRET / EFFECTIVE PROVIDERS"
    HOSTLIST="$(find_hostlist)"
    echo "Hostlist: ${HOSTLIST:-NOT_FOUND}"
    [ -n "$HOSTLIST" ] && cat "$HOSTLIST" || true
    iptables -t mangle -L ZAPRET_NFQ_OUT -nvx 2>/dev/null || true
    iptables -t mangle -L ZAPRET_NFQ_IN -nvx 2>/dev/null || true
    build_provider_matrix "$HOSTLIST"
    cat "$PROVIDERS_TSV" 2>/dev/null || true

    section "7. CHROMIUM BRIDGE"
    curl -sS --max-time 5 http://127.0.0.1:9911/health 2>&1 || true
    docker ps --filter name=chromium-rutracker 2>/dev/null || true
    docker logs --tail 100 chromium-rutracker 2>&1 | sed -n '/relay.py\|ERROR\|Traceback\|challenge\|cookie\|rutracker/p' || true

    section "8. CONTROLLED SEARCH"
    if [ ! -f "$KODI_LOG" ]; then
        echo "ERROR: Kodi log not found: $KODI_LOG"
        return 1
    fi
    START_LINE="$(wc -l < "$KODI_LOG" | tr -d ' ')"
    END_EPOCH=$(( $(date +%s) + WAIT_AFTER_ENTER + 300 ))
    monitor_runtime "$END_EPOCH" > "$RUNTIME_LOG" 2>&1 &
    MONITOR_PID=$!
    echo "Запустите ОДИН поиск фильма, который точно существует, например Интерстеллар (2014)."
    echo "После появления пустого окна или первых результатов вернитесь в SSH."
    printf 'Нажмите Enter... '
    read dummy
    echo "Жду ещё $WAIT_AFTER_ENTER секунд до полного progressive_timeout."
    remaining="$WAIT_AFTER_ENTER"
    while [ "$remaining" -gt 0 ]; do
        if [ $((remaining % 10)) -eq 0 ] || [ "$remaining" -le 5 ]; then echo "Осталось: $remaining сек."; fi
        sleep 1
        remaining=$((remaining - 1))
    done
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    FROM_LINE=$((START_LINE + 1))
    sed -n "${FROM_LINE},\$p" "$KODI_LOG" > "$SEARCH_LOG"
    tail -n 4000 "$KODI_LOG" > "$REPORT_DIR/kodi-tail.log"

    section "9. RAW SEARCH LOG"
    cat "$SEARCH_LOG"

    section "10. PROVIDER / CHAIN ANALYSIS"
    parse_search_log
    cat "$PROVIDER_SUMMARY_TSV" 2>/dev/null || true
    cat "$REPORT_DIR/chain-analysis.txt" 2>/dev/null || true

    section "11. EXACT SEARCH URL RETEST"
    test_search_urls
    cat "$URL_TESTS_TSV" 2>/dev/null || true

    section "12. RELEVANT MARKERS"
    grep -Eai 'script\.elementum\.burst|plugin\.video\.elementum|returned[[:space:]]+[0-9]+[[:space:]]+results|Providers returned|callback|Received [0-9]+ unique links|processLinks|progressive|Dialog_Select|updateItems|Resolve|panic|fatal|critical|traceback|exception|failed|timed out|ERROR' "$SEARCH_LOG" 2>/dev/null || true

    section "13. OUTPUT"
    echo "Report:           $REPORT"
    echo "Search log:       $SEARCH_LOG"
    echo "Provider summary: $PROVIDER_SUMMARY_TSV"
    echo "Effective config: $PROVIDERS_TSV"
    echo "URL tests:        $URL_TESTS_TSV"
    echo "Runtime:          $RUNTIME_LOG"
    tar -czf "$REPORT_DIR.tar.gz" -C "$(dirname "$REPORT_DIR")" "$(basename "$REPORT_DIR")" 2>/dev/null || true
    if [ -f "$REPORT_DIR.tar.gz" ]; then
        echo "UPLOAD THIS ARCHIVE: $REPORT_DIR.tar.gz"
        ls -lh "$REPORT_DIR.tar.gz"
    fi
}

main 2>&1 | tee "$REPORT"
