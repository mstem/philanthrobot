#!/bin/bash
# Temporarily expose the Studio's SSH through the philanthrobot Cloudflare
# tunnel at ssh.philanthrobot.eu, behind an Access rule that admits only Matt.
# Undo with scripts/ssh-tunnel-close.sh.
set -euo pipefail

T=$(security find-generic-password -s cloudflare-philanthrobot-admin -a matt -w)
ZONE=68bbb688a0b254e5509b3fbd1de77709
TUNNEL=1de9d2e2-e715-4a04-aadf-4c23ce6a44ec
HOST=ssh.philanthrobot.eu
API=https://api.cloudflare.com/client/v4
cf() { curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "$@"; }
# The admin token has no DNS access; the Caddy token has DNS edit on this zone.
TD=$(security find-generic-password -s cloudflare-philanthrobot -a matt -w)
cfd() { curl -s -H "Authorization: Bearer $TD" -H 'Content-Type: application/json' "$@"; }
has() { python3 -c 'import sys,json;sys.exit(0 if any(r.get(sys.argv[1])==sys.argv[2] for r in json.load(sys.stdin)["result"]) else 1)' "$@"; }
ok() { python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("errors") or "ok");sys.exit(0 if d["success"] else 1)'; }

ACC=$(cf "$API/zones/$ZONE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["account"]["id"])')

echo "1/3 Access rule (only matt.stempeck@evensfoundation.eu)"
if cf "$API/accounts/$ACC/access/apps" | has domain "$HOST"; then
  echo "already there"
else
  cf -X POST "$API/accounts/$ACC/access/apps" -d '{"name":"philanthrobot ssh (temporary)","domain":"'$HOST'","type":"self_hosted","session_duration":"8h","app_launcher_visible":false,"policies":[{"name":"Matt only","decision":"allow","include":[{"email":{"email":"matt.stempeck@evensfoundation.eu"}}]}]}' | ok \
    || { echo "Access rule failed; nothing opened."; exit 1; }
fi

echo "2/3 DNS record"
if cfd "$API/zones/$ZONE/dns_records?name=$HOST" | has name "$HOST"; then
  echo "already there"
else
  cfd -X POST "$API/zones/$ZONE/dns_records" -d '{"type":"CNAME","name":"'$HOST'","content":"'$TUNNEL'.cfargotunnel.com","proxied":true}' | ok
fi

echo "3/3 Tunnel route to the Studio's SSH"
CFG=$(cf "$API/accounts/$ACC/cfd_tunnel/$TUNNEL/configurations" | python3 -c '
import sys,json
c=json.load(sys.stdin)["result"]["config"]
ing=[r for r in c["ingress"] if r.get("hostname")!="'$HOST'"]
ing.insert(len(ing)-1,{"hostname":"'$HOST'","service":"ssh://localhost:22"})
c["ingress"]=ing
print(json.dumps({"config":c}))')
cf -X PUT "$API/accounts/$ACC/cfd_tunnel/$TUNNEL/configurations" -d "$CFG" | ok

echo "Done. Close it afterwards with scripts/ssh-tunnel-close.sh"
