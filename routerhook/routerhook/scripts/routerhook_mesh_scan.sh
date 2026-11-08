#!/bin/sh
# AiMesh 节点客户端轮询：覆盖经 AiMesh 节点（中继）接入的设备
# 主机 hostapd 只上报本机无线事件，节点上的关联不会出现在 wlceventd / hostapd_cli 里
source /koolshare/scripts/base.sh
eval $(dbus export routerhook_)

LOG=/tmp/routerhook_wifi.log
STATE=/tmp/.routerhook_mesh_state
PIDF=/var/run/routerhook_mesh.pid
INTERVAL=30
SHARED_WINDOW=30

log_msg() {
    [ -f "$LOG" ] && [ $(wc -c <"$LOG" 2>/dev/null) -gt 65536 ] && : >"$LOG"
    echo "$(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S') $*" >> $LOG
}

local_bssids() {
    out=""
    for k in wl0_hwaddr wl1_hwaddr wl0.1_hwaddr wl0.2_hwaddr wl0.3_hwaddr wl1.1_hwaddr wl1.2_hwaddr wl1.3_hwaddr; do
        v=$(nvram get $k 2>/dev/null | tr 'a-z' 'A-Z')
        [ -n "$v" ] && out="$out $v"
    done
    echo "$out "
}

# 输出 5 列：MAC PAP ISWL IP NAME
scan_clients() {
    if [ -f /tmp/nmp_cache.js ]; then
        jq -r 'to_entries[] | select(.value|type=="object") | select((.value.isWL // "0") != "0")
               | [.key, (.value.amesh_papMac // ""), (.value.isWL // "0"), (.value.ip // ""), (.value.name // "")]
               | @tsv' /tmp/nmp_cache.js 2>/dev/null | tr 'a-z' 'A-Z'
        return 0
    fi
    if [ -f /tmp/clientlist.json ]; then
        jq -r 'to_entries[] as $ap | $ap.value | to_entries[] | select(.key|test("^2G|^5G|^6G")) | .key as $band
               | ($band|if startswith("2G") then "1" else "2" end) as $wl
               | .value | to_entries[] | [.key, $ap.key, $wl, (.value.ip // ""), ""] | @tsv' /tmp/clientlist.json 2>/dev/null | tr 'a-z' 'A-Z'
        return 0
    fi
    return 1
}

resolve_name() {
    mac="$1"
    nmname="$2"
    white_name=$(echo $(dbus get routerhook_trigger_dhcp_white | base64_decode | grep -i "$mac") | cut -d# -f2)
    if [ -n "$white_name" ]; then
        echo "$white_name"
        return
    fi
    custom=$(echo $(nvram get custom_clientlist | sed 's/</\n/g' | awk -F ">" '{print $1"##"$2}' | sed '/^##*$/d' | grep -i "$mac"))
    if [ -n "$custom" ]; then
        echo "$custom" | awk -F "##" '{print $1}' | head -n1
        return
    fi
    [ -n "$nmname" ] && { echo "$nmname"; return; }
    echo "$mac"
}

push_client() {
    mac="$1"; pap="$2"; wl="$3"; ip="$4"; nmname="$5"
    last_mac=$(echo $(dbus get routerhook_wifi_send_mac) | tr 'A-Z' 'a-z')
    last_time=$(dbus get routerhook_wifi_send_time)
    now_ts=$(date +%s)
    if [ "$last_mac" = "$(echo "$mac" | tr 'A-Z' 'a-z')" ] && [ -n "$last_time" ] && [ $((now_ts - last_time)) -lt $SHARED_WINDOW ] 2>/dev/null; then
        log_msg "mesh: skip dedupe $mac ($((now_ts - last_time))s ago)"
        return
    fi

    name=$(resolve_name "$mac" "$nmname")
    if [ -z "$ip" ]; then
        ip=$(grep -i "$mac" /var/lib/misc/dnsmasq.leases 2>/dev/null | sort -rn | head -n1 | awk '{print $3}')
    fi
    if [ "$wl" = "1" ]; then
        band="2.4G"; ssid=$(nvram get wl0_ssid 2>/dev/null)
    else
        band="5G"; ssid=$(nvram get wl1_ssid 2>/dev/null)
    fi
    apname=""
    [ -f "/tmp/$pap.json" ] && apname=$(jq -r '.misc.cfg_alias // empty' "/tmp/$pap.json" 2>/dev/null)
    [ -n "$apname" ] || apname="$pap"

    up_time=$(TZ=UTC-8 date "+%Y年%m月%d日 %H点%M分%S秒")
    text=/tmp/.routerhook_mesh.json
    echo '{' > $text
    echo '"msgTYPE":"wifiJOIN",' >> $text
    echo '"cliNAME":"'"$name"'",' >> $text
    echo '"cliIP":"'"$ip"'",' >> $text
    echo '"cliMAC":"'"$mac"'",' >> $text
    echo '"wifiSSID":"'"$ssid"'",' >> $text
    echo '"wifiBAND":"'"$band"'",' >> $text
    echo '"apNAME":"'"$apname"'",' >> $text
    echo '"apMAC":"'"$pap"'",' >> $text
    echo '"upTIME":"'"$up_time"'"' >> $text
    echo '}' >> $text

    msg_type='wifiJOIN'
    routerhook_send_content=$(jq -c . $text)
    source /koolshare/scripts/routerhook_sender.sh
    dbus set routerhook_wifi_send_mac="$mac"
    dbus set routerhook_wifi_send_time="$now_ts"
    log_msg "mesh: sent $mac $band $ssid ap=$apname ip=$ip"
    rm -f $text
}

run_once() {
    tmp=/tmp/.routerhook_mesh_tmp
    newstate=/tmp/.routerhook_mesh_new
    scan_clients > $tmp || { rm -f $tmp; return; }
    [ -s "$tmp" ] || { rm -f $tmp; return; }
    first=0
    [ -f "$STATE" ] || first=1
    local_bss=$(local_bssids)
    now=$(date +%s)
    : > $newstate
    tab=$(printf '\t')
    while IFS="$tab" read -r mac pap wl ip nmname; do
        [ -n "$mac" ] || continue
        echo "$mac|$pap|$wl|$now" >> $newstate
        [ "$first" = "1" ] && continue
        grep -q "^$mac|$pap|$wl|" $STATE 2>/dev/null && continue
        case "$local_bss" in *" $pap "*) continue;; esac
        push_client "$mac" "$pap" "$wl" "$ip" "$nmname"
    done < $tmp
    mv $newstate $STATE
    rm -f $tmp
    [ "$first" = "1" ] && log_msg "mesh: init state ($(wc -l < $STATE) clients)"
}

echo $$ > $PIDF
log_msg "mesh: watcher started ($INTERVAL s)"
while :; do
    eval $(dbus export routerhook_)
    if [ "$routerhook_enable" = "1" ] && [ "$routerhook_trigger_wifi" = "1" ]; then
        run_once
    fi
    sleep $INTERVAL
done
