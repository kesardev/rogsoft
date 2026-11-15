#!/bin/sh
# Wi-Fi 客户端状态机：数据源 /tmp/allwclientlist.json（AiMesh 全量无线表，事件时立即写盘）
# 统一处理 上线 / 漫游去抖 / 下线，替代旧版 hostapd 直推 + 节点轮询两套逻辑
source /koolshare/scripts/base.sh
eval $(dbus export routerhook_)

LOG=/tmp/routerhook_wifi.log
STATE=/tmp/.routerhook_wifi_state
PIDF=/var/run/routerhook_wifi.pid
SRC=/tmp/allwclientlist.json

TICK=2
ROAM_WINDOW=120
LEAVE_GRACE=60

log_msg() {
    [ -f "$LOG" ] && [ $(wc -c <"$LOG" 2>/dev/null) -gt 65536 ] && : >"$LOG"
    echo "$(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S') $*" >> $LOG
}

# ---------- 单实例 ----------
if [ -f "$PIDF" ]; then
    oldpid=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$oldpid" ] && [ -d "/proc/$oldpid" ]; then
        log_msg "scan: already running (pid $oldpid), exit"
        exit 0
    fi
fi
echo $$ > "$PIDF"
trap 'rm -f "$PIDF"' 0

# ---------- 工具函数 ----------
band_label() {
    case "$1" in
        2G|24G) echo "2.4G" ;;
        5G|5G1) echo "5G" ;;
        6G) echo "6G" ;;
        *) echo "$1" ;;
    esac
}

band_ssid() {
    case "$1" in
        2.4G) nvram get wl0_ssid 2>/dev/null ;;
        5G) nvram get wl1_ssid 2>/dev/null ;;
        *) echo "" ;;
    esac
}

local_bssids() {
    out=" "
    for k in wl0_hwaddr wl1_hwaddr wl0.1_hwaddr wl0.2_hwaddr wl0.3_hwaddr wl1.1_hwaddr wl1.2_hwaddr wl1.3_hwaddr; do
        v=$(nvram get $k 2>/dev/null | tr 'a-z' 'A-Z')
        [ -n "$v" ] && out="$out$v "
    done
    echo "$out"
}

ap_name() {
    ap="$1"
    case "$(local_bssids)" in
        *" $ap "*)
            n=$(nvram get lan_hostname 2>/dev/null)
            [ -n "$n" ] || n=$(nvram get productid 2>/dev/null)
            [ -n "$n" ] || n="$ap"
            echo "$n"
            return
            ;;
    esac
    n=""
    if [ -f /tmp/nmp_cache.js ]; then
        n=$(jq -r --arg m "$ap" 'to_entries[] | select(.key|ascii_upcase==$m) | (.value.name // empty)' /tmp/nmp_cache.js 2>/dev/null | head -n1)
    fi
    if [ -z "$n" ] && [ -f "/tmp/$ap.json" ]; then
        n=$(jq -r '.misc.cfg_alias // empty' "/tmp/$ap.json" 2>/dev/null)
    fi
    [ -n "$n" ] || n="$ap"
    echo "$n"
}

lease_ip() {
    grep -i "$1" /var/lib/misc/dnsmasq.leases 2>/dev/null | sort -rn | head -n1 | awk '{print $3}'
}

resolve_name() {
    mac_lc="$1"
    cached="$2"
    w=$(echo $(dbus get routerhook_trigger_dhcp_white | base64_decode | grep -i "$mac_lc") | cut -d# -f2)
    if [ -n "$w" ]; then
        echo "$w"
        return
    fi
    c=$(echo $(nvram get custom_clientlist | sed 's/</\n/g' | awk -F ">" '{print $1"##"$2}' | sed '/^##*$/d' | grep -i "$mac_lc"))
    if [ -n "$c" ]; then
        echo "$c" | awk -F "##" '{print $1}' | head -n1
        return
    fi
    if [ -n "$cached" ]; then
        echo "$cached"
        return
    fi
    l=$(grep -i "$mac_lc" /var/lib/misc/dnsmasq.leases 2>/dev/null | sort -rn | head -n1 | awk '{print $4}')
    if [ -n "$l" ] && [ "$l" != "*" ]; then
        echo "$l"
        return
    fi
    echo "$mac_lc"
}

send_json() {
    msg_type="$1"
    text=/tmp/.routerhook_wifi.json
    routerhook_send_content=$(jq -c . $text 2>/dev/null)
    if [ -z "$routerhook_send_content" ]; then
        log_msg "scan: json build failed ($msg_type)"
        rm -f $text
        return 1
    fi
    source /koolshare/scripts/routerhook_sender.sh
    rm -f $text
    return 0
}

push_join() {
    mac_uc="$1"; ap="$2"; band="$3"; name="$4"; ip="$5"
    ssid=$(band_ssid "$band")
    apn=$(ap_name "$ap")
    up_time=$(TZ=UTC-8 date "+%Y年%m月%d日 %H点%M分%S秒")
    text=/tmp/.routerhook_wifi.json
    {
        echo '{'
        echo '"msgTYPE":"wifiJOIN",'
        echo '"cliNAME":"'"$name"'",'
        echo '"cliIP":"'"$ip"'",'
        echo '"cliMAC":"'"$mac_uc"'",'
        echo '"wifiSSID":"'"$ssid"'",'
        echo '"wifiBAND":"'"$band"'",'
        echo '"apNAME":"'"$apn"'",'
        echo '"apMAC":"'"$ap"'",'
        echo '"upTIME":"'"$up_time"'"'
        echo '}'
    } > $text
    if send_json wifiJOIN; then
        log_msg "scan: sent wifiJOIN $mac_uc $band $ssid ap=$apn ip=$ip"
    fi
}

push_leave() {
    mac_uc="$1"; ap="$2"; band="$3"; name="$4"; ip="$5"
    ssid=$(band_ssid "$band")
    apn=$(ap_name "$ap")
    off_time=$(TZ=UTC-8 date "+%Y年%m月%d日 %H点%M分%S秒")
    text=/tmp/.routerhook_wifi.json
    {
        echo '{'
        echo '"msgTYPE":"wifiLEAVE",'
        echo '"cliNAME":"'"$name"'",'
        echo '"cliIP":"'"$ip"'",'
        echo '"cliMAC":"'"$mac_uc"'",'
        echo '"wifiSSID":"'"$ssid"'",'
        echo '"wifiBAND":"'"$band"'",'
        echo '"apNAME":"'"$apn"'",'
        echo '"apMAC":"'"$ap"'",'
        echo '"offTIME":"'"$off_time"'"'
        echo '}'
    } > $text
    if send_json wifiLEAVE; then
        log_msg "scan: sent wifiLEAVE $mac_uc $band $ssid ap=$apn"
    fi
}

# ---------- 采集当前无线客户端 ----------
scan_clients() {
    if [ -f /tmp/allwclientlist.json ]; then
        jq -r 'to_entries[] | .key as $ap | .value | to_entries[]
               | select(.key|test("^[0-9]+G$")) | .key as $band
               | .value | keys[] | [$ap, $band, .] | join("\u001f")'             /tmp/allwclientlist.json 2>/dev/null
        return 0
    fi
    if [ -f /tmp/clientlist.json ]; then
        jq -r 'to_entries[] | .key as $ap | .value | to_entries[]
               | select(.key|test("^[0-9]+G$")) | .key as $band
               | .value | to_entries[] | [$ap, $band, .key] | join("\u001f")'             /tmp/clientlist.json 2>/dev/null
        return 0
    fi
    if [ -f /tmp/nmp_cache.js ]; then
        jq -r 'to_entries[] | select(.value|type=="object") | select((.value.isWL//"0")!="0")
               | [.key, (if (.value.isWL=="1") then "2G" else "5G" end)] | join("\u001f")'             /tmp/nmp_cache.js 2>/dev/null \
            | awk -F'\037' '{print $1 "\037" $2 "\037" $1}'
        return 0
    fi
    return 1
}

# ---------- 一次完整比对 ----------
run_scan() {
    tmp=/tmp/.routerhook_wifi_tmp
    newstate=/tmp/.routerhook_wifi_new
    seen=/tmp/.routerhook_wifi_seen
    : > $newstate
    : > $seen
    scan_clients > $tmp || { rm -f $tmp; return 1; }
    [ -s "$tmp" ] || { rm -f $tmp; return 1; }

    first=0
    [ -f "$STATE" ] || first=1
    now=$(date +%s)
    sep=$(printf '\037')

    while IFS="$sep" read -r ap band rawmac; do
        [ -n "$rawmac" ] || continue
        mac_uc=$(echo "$rawmac" | tr 'a-z' 'A-Z')
        echo "$mac_uc" >> $seen
        bandlbl=$(band_label "$band")
        old=$(grep -i "^$mac_uc|" $STATE 2>/dev/null | head -n1)
        if [ -n "$old" ]; then
            old_ap=$(echo "$old" | cut -d'|' -f2)
            old_band=$(echo "$old" | cut -d'|' -f3)
            old_name=$(echo "$old" | cut -d'|' -f5)
            old_ip=$(echo "$old" | cut -d'|' -f6)
            old_last=$(echo "$old" | cut -d'|' -f7)
            [ -n "$old_last" ] || old_last=0
            name=$(resolve_name "$mac_uc" "$old_name")
            ip="$old_ip"
            [ -n "$ip" ] || ip=$(lease_ip "$mac_uc")
            if [ "$old_ap" = "$ap" ] && [ "$old_band" = "$bandlbl" ]; then
                :
            else
                gap=$((now - old_last))
                if [ "$gap" -le "$ROAM_WINDOW" ]; then
                    log_msg "scan: roam $mac_uc $old_band at $old_ap -> $bandlbl at $ap ($gap s, silent)"
                else
                    push_join "$mac_uc" "$ap" "$bandlbl" "$name" "$ip"
                fi
            fi
        else
            name=$(resolve_name "$mac_uc" "")
            ip=$(lease_ip "$mac_uc")
            if [ "$first" = "1" ]; then
                :
            else
                push_join "$mac_uc" "$ap" "$bandlbl" "$name" "$ip"
            fi
        fi
        echo "$mac_uc|$ap|$bandlbl|$name|$ip|$now|0" >> $newstate
    done < $tmp

    if [ -f "$STATE" ]; then
        while IFS='|' read -r s_mac s_ap s_band s_name s_ip s_last s_leave; do
            [ -n "$s_mac" ] || continue
            grep -q "^$s_mac$" $seen && continue
            [ "$s_leave" = "0" ] && s_leave=$now
            echo "$s_mac|$s_ap|$s_band|$s_name|$s_ip|$s_last|$s_leave" >> $newstate
        done < $STATE
    fi

    mv $newstate $STATE
    rm -f $tmp $seen
    if [ "$first" = "1" ]; then
        log_msg "scan: init state ($(wc -l < $STATE) clients)"
    fi
    return 0
}

# ---------- 宽限期到点后推下线 ----------
age_state() {
    [ -f "$STATE" ] || return 0
    now=$(date +%s)
    newstate=/tmp/.routerhook_wifi_age
    : > $newstate
    while IFS='|' read -r s_mac s_ap s_band s_name s_ip s_last s_leave; do
        [ -n "$s_mac" ] || continue
        [ -n "$s_leave" ] || s_leave=0
        if [ "$s_leave" = "0" ]; then
            echo "$s_mac|$s_ap|$s_band|$s_name|$s_ip|$s_last|0" >> $newstate
            continue
        fi
        if [ $((now - s_leave)) -ge "$LEAVE_GRACE" ]; then
            if [ "$routerhook_trigger_wifi_leave" = "1" ]; then
                push_leave "$s_mac" "$s_ap" "$s_band" "$s_name" "$s_ip"
            else
                log_msg "scan: leave $s_mac (notify off)"
            fi
        else
            echo "$s_mac|$s_ap|$s_band|$s_name|$s_ip|$s_last|$s_leave" >> $newstate
        fi
    done < $STATE
    mv $newstate $STATE
    return 0
}

# ---------- 主循环 ----------
last_mtime=""
log_msg "scan: watcher started ($TICK s tick)"
while :; do
    if [ "$routerhook_enable" = "1" ] && [ "$routerhook_trigger_wifi" = "1" ]; then
        mt=$(date -r $SRC +%s 2>/dev/null)
        [ -z "$mt" ] && mt=$(date -r /tmp/clientlist.json +%s 2>/dev/null)
        if [ -n "$mt" ] && [ "$mt" != "$last_mtime" ]; then
            last_mtime="$mt"
            run_scan
        fi
        age_state
    fi
    sleep $TICK
done
