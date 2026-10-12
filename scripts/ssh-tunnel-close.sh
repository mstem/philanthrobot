#!/bin/bash
# Remove everything scripts/ssh-tunnel-open.sh created.
set -uo pipefail

T=$(security find-generic-password -s cloudflare-philanthrobot-admin -a matt -w)
ZONE=68bbb688a0b254e5509b3fbd1de77709
TUNNEL=1de9d2e2-e715-4a04-aadf-4c23ce6a44ec
HOST=ssh.philanthrobot.eu
API=https://api.cloudflare.com/client/v4
cf() { curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "$@"; }
# The admin token has no DNS access; the Caddy token has DNS edit on this zone.
TD=$(security find-generic-password -s cloudflare-philanthrobot -a matt -w)
cfd() { curl -s -H "Authorization: Bearer $TD" -H 'Content-Type: application/json' "$@"; }

ACC=$(cf "$API/zones/$ZONE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["account"]["id"])')

echo "Tunnel route"
CFG=$(cf "$API/accounts/$ACC/cfd_tunnel/$TUNNEL/configurations" | python3 -c '
import sys,json
c=json.load(sys.stdin)["result"]["config"]
c["ingress"]=[r for r in c["ingress"] if r.get("hostname")!="'$HOST'"]
print(json.dumps({"config":c}))')
cf -X PUT "$API/accounts/$ACC/cfd_tunnel/$TUNNEL/configurations" -d "$CFG" | python3 -c 'import sys,json;print(json.load(sys.stdin)["success"])'

echo "DNS record"
for id in $(cfd "$API/zones/$ZONE/dns_records?name=$HOST" | python3 -c 'import sys,json;[print(r["id"]) for r in json.load(sys.stdin)["result"]]'); do
  cfd -X DELETE "$API/zones/$ZONE/dns_records/$id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["success"])'
done

echo "Access rule"
for id in $(cf "$API/accounts/$ACC/access/apps" | python3 -c 'import sys,json;[print(a["id"]) for a in json.load(sys.stdin)["result"] if a.get("domain")=="'$HOST'"]'); do
  cf -X DELETE "$API/accounts/$ACC/access/apps/$id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["success"])'
done
