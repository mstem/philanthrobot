#!/bin/bash
# Install the planned-update notice on the Studio. Run from the laptop.
# Safe to re-run: each step checks whether it is already done.
#   1. copy loader.js and update-notice.sh to ~/caddy/notice, notice off
#   2. Caddy: serve them at /static/loader.js and /update-notice.json
#   3. launchd: check on Saturday 04:00, clear on Sunday 04:30
#   4. Watchtower: recreate with --no-pull, same env, mounts and schedule
set -euo pipefail

HOST=evensfoundation@100.88.31.96
HERE=$(cd "$(dirname "$0")" && pwd)

ssh -o BatchMode=yes "$HOST" 'mkdir -p ~/caddy/notice/logs ~/Library/LaunchAgents'
scp -q "$HERE/loader.js" "$HERE/update-notice.sh" "$HOST:caddy/notice/"
scp -q "$HERE/ai.evens.update-notice-check.plist" "$HERE/ai.evens.update-notice-clear.plist" "$HOST:Library/LaunchAgents/"

ssh -o BatchMode=yes "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd ~/caddy

echo "1/4 notice files"
chmod +x notice/update-notice.sh
[ -f notice/update-notice.json ] || notice/update-notice.sh clear

echo "2/4 Caddy"
if grep -q '^(chat) {' Caddyfile; then
	echo "already there"
else
	cp -n Caddyfile Caddyfile.bak-2026-10-12
	python3 - <<'EOF'
p = "/Users/evensfoundation/caddy/Caddyfile"
s = open(p).read()
snip = """# Planned-update notice: loader.js replaces Open WebUI's empty stock file and
# reads update-notice.json. Both live outside the container, so updates
# cannot overwrite them. Source: philanthrobot repo, update-notice/.
(chat) {
	handle /static/loader.js {
		root * /Users/evensfoundation/caddy/notice
		rewrite * /loader.js
		header Cache-Control "no-store"
		file_server
	}
	handle /update-notice.json {
		root * /Users/evensfoundation/caddy/notice
		header Cache-Control "no-store"
		file_server
	}
	handle {
		reverse_proxy 127.0.0.1:3000
	}
}

"""
assert s.count("\treverse_proxy 127.0.0.1:3000\n") == 2, "Caddyfile changed since it was read"
s = s.replace("\treverse_proxy 127.0.0.1:3000\n", "\timport chat\n")
s = s.replace("philanthrobot.eu {", snip + "philanthrobot.eu {", 1)
open(p, "w").write(s)
EOF
fi
# validate and reload take no --envfile, unlike run, so load it ourselves.
set -a; . ./.env; set +a
if ! ./caddy validate --config Caddyfile >/dev/null 2>&1; then
	cp Caddyfile.bak-2026-10-12 Caddyfile
	echo "Caddyfile did not validate; restored the backup"; exit 1
fi
./caddy reload --config Caddyfile
for path in /static/loader.js /update-notice.json; do
	code=$(curl -s -o /dev/null -w '%{http_code}' --resolve philanthrobot.eu:443:127.0.0.1 "https://philanthrobot.eu$path")
	echo "  $path $code"
done

echo "3/4 schedules"
for mode in check clear; do
	label=ai.evens.update-notice-$mode
	launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
	launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/$label.plist
	launchctl print "gui/$(id -u)/$label" | grep -m1 'state ='
done

echo "4/4 Watchtower"
if docker inspect -f '{{json .Config.Cmd}}' watchtower | grep -q -- '--no-pull'; then
	echo "already there"
else
	envs=()
	while IFS= read -r e; do
		[ -n "$e" ] && [[ "$e" != PATH=* ]] && envs+=(-e "$e")
	done < <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' watchtower)
	docker rename watchtower watchtower-old
	docker stop watchtower-old >/dev/null
	if docker run -d --name watchtower --restart unless-stopped "${envs[@]}" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v /Users/evensfoundation/watchtower/slack-template.txt:/slack-template.txt:ro \
		nickfedor/watchtower:latest \
		--cleanup --enable-lifecycle-hooks --no-pull --schedule "0 0 4 * * 0" open-webui >/dev/null \
		&& sleep 5 && [ "$(docker inspect -f '{{.State.Running}}' watchtower)" = true ]; then
		docker rm watchtower-old >/dev/null
	else
		docker rm -f watchtower 2>/dev/null || true
		docker rename watchtower-old watchtower
		docker start watchtower >/dev/null
		echo "new Watchtower did not start; old one restored"; exit 1
	fi
fi
docker logs --since 2m watchtower 2>&1 | grep -E 'notifications|Next scheduled' || true
echo "  slack urls: $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' watchtower | grep -c 'slack://' ) env line, $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' watchtower | grep -o 'slack://' | wc -l | tr -d ' ') webhooks"
echo "Done."
REMOTE
