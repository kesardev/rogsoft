#!/bin/sh
# Wi-Fi 关联事件 -> Wi-Fi 接入推送（msgTYPE=wifiJOIN），与 DHCP 上线通知区分开
source /koolshare/scripts/base.sh
eval $(dbus export routerhook_)

IF="$1"
EV="$2"
MAC=$(echo "$3" | tr 'A-Z' 'a-z')

LOG=/tmp/routerhook_wifi.log
log_msg() { [ -f "$LOG" ] && [ $(wc -c <"$LOG" 2>/dev/null) -gt 65536 ] && : >"$LOG"; echo "$(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S') $*" >> $LOG; }
log_msg "event IF=$IF EV=$EV MAC=$MAC"

[ -n "$MAC" ] || { log_msg 'skip: empty mac'; exit 0; }
[ "$EV" = "AP-STA-CONNECTED" ] || { log_msg "skip: not connect ($EV)"; exit 0; }
[ "${routerhook_enable}" = "1" ] || { log_msg 'skip: routerhook disabled'; exit 0; }
[ "${routerhook_trigger_wifi}" = "1" ] || { log_msg 'skip: trigger_wifi off'; exit 0; }

(
    # 等 DHCP 租约出现，拿到 IP
    i=0
    while [ $i -lt 15 ]; do
        grep -qi "$MAC" /var/lib/misc/dnsmasq.leases 2>/dev/null && break
        sleep 1
        i=$((i+1))
    done
    lease=$(grep -i "$MAC" /var/lib/misc/dnsmasq.leases 2>/dev/null | sort -rn | head -n1)
    [ -n "$lease" ] || { log_msg "skip: no lease for $MAC"; exit 0; }

    ip=$(echo "$lease" | awk '{print $3}')
    name=$(echo "$lease" | awk '{print $4}')
    [ "$name" = "*" ] && name=""
    white_name=$(echo $(dbus get routerhook_trigger_dhcp_white | base64_decode | grep -i "$MAC") | cut -d# -f2)
    if [ -n "$white_name" ]; then
        name="$white_name"
    else
        custom=$(echo $(nvram get custom_clientlist | sed 's/</\n/g' | awk -F ">" '{print $1"##"$2}' | sed '/^##*$/d' | grep -i "$MAC"))
        [ -n "$custom" ] && name=$(echo "$custom" | awk -F "##" '{print $1}')
    fi
    [ -n "$name" ] || name="$MAC"

    # 频段/SSID：eth6=wl0=2.4G，eth7=wl1=5G
    band=""
    idx=$(echo "$IF" | sed 's/[^0-9]//g')
    [ -n "$idx" ] || idx=0
    if [ "$idx" -ge 6 ] 2>/dev/null; then idx=$((idx - 6)); fi
    [ "$idx" = "0" ] && band="2.4G"
    [ "$idx" = "1" ] && band="5G"
    ssid=$(nvram get wl${idx}_ssid 2>/dev/null)
    apname=$(nvram get lan_hostname 2>/dev/null)
    [ -n "$apname" ] || apname=$(nvram get productid 2>/dev/null)
    [ -n "$ssid" ] || ssid=$(wl -i "$IF" status 2>/dev/null | sed -n 's/^SSID: "\(.*\)"$/\1/p' | head -n1)

    # 同一设备 30 秒内不重复推 Wi-Fi 接入
    last_mac=$(echo $(dbus get routerhook_wifi_send_mac) | tr 'A-Z' 'a-z')
    last_time=$(dbus get routerhook_wifi_send_time)
    now_ts=$(date +%s)
    if [ "$last_mac" = "$MAC" ] && [ -n "$last_time" ] && [ $((now_ts - last_time)) -lt 30 ] 2>/dev/null; then
        log_msg "skip: dedupe $MAC ($((now_ts - last_time))s ago)"
        exit 0
    fi
    dbus set routerhook_wifi_send_mac="$MAC"
    dbus set routerhook_wifi_send_time="$now_ts"

    up_time=$(TZ=UTC-8 date "+%Y年%m月%d日 %H点%M分%S秒")
    text=/tmp/.routerhook_wifi.json
    echo '{' > $text
    echo '"msgTYPE":"wifiJOIN",' >> $text
    echo '"cliNAME":"'"$name"'",' >> $text
    echo '"cliIP":"'"$ip"'",' >> $text
    echo '"cliMAC":"'"$MAC"'",' >> $text
    echo '"wifiSSID":"'"$ssid"'",' >> $text
    echo '"wifiBAND":"'"$band"'",' >> $text
    echo '"apNAME":"'"$apname"'",' >> $text
    echo '"upTIME":"'"$up_time"'"' >> $text
    echo '}' >> $text

    msg_type='wifiJOIN'
    routerhook_send_content=$(jq -c . $text)
    source /koolshare/scripts/routerhook_sender.sh
    log_msg "sent: $MAC $band $ssid ip=$ip"
    sleep 1
    rm -f $text
) &

exit 0
