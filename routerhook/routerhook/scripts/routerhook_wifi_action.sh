#!/bin/sh
# Wi-Fi 关联事件 -> 复用 RouterHook 的设备上线推送
source /koolshare/scripts/base.sh

IF="$1"
EV="$2"
MAC=$(echo "$3" | tr 'A-Z' 'a-z')

[ -n "$MAC" ] || exit 0
[ "$EV" = "AP-STA-CONNECTED" ] || exit 0
[ "$(dbus get routerhook_enable)" = "1" ] || exit 0
[ "$(dbus get routerhook_trigger_wifi)" = "1" ] || exit 0

(
    i=0
    while [ $i -lt 15 ]; do
        grep -qi "$MAC" /var/lib/misc/dnsmasq.leases && break
        sleep 1
        i=$((i+1))
    done
    grep -qi "$MAC" /var/lib/misc/dnsmasq.leases || exit 0
    ROUTERHOOK_MAC="$MAC" /koolshare/scripts/routerhook_dhcp_trigger.sh
) &

exit 0
