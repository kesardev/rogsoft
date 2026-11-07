#!/bin/sh
out=$(/koolshare/acme/acme.sh --cron --home /koolshare/acme 2>&1)
echo "$out"
echo "$out" | grep -q "Cert success" && sh /koolshare/scripts/acme_config.sh "" 4
