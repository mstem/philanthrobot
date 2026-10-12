#!/bin/bash
# Planned-update notice for the Philanthrobot chat.
#
#   update-notice.sh check   Saturday 04:00: download the newest Open WebUI
#                            image. If it differs from the running one, switch
#                            the notice on. Watchtower runs with --no-pull, so
#                            it only ever installs an image downloaded here,
#                            a day after the notice went up.
#   update-notice.sh clear   Sunday 04:30: switch the notice off.
#
# The notice file is served by Caddy at /update-notice.json and shown by
# loader.js. Safe to run any number of times.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
IMAGE=ghcr.io/open-webui/open-webui:main
CONTAINER=open-webui
NOTICE=/Users/evensfoundation/caddy/notice/update-notice.json
TEXT="The Philanthrobot chat will be updated on Sunday at 04:00 Brussels time (03:00 Lisbon). It will be offline for a few seconds, but you may need to refresh the page once it's done."

log() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z') $*"; }

write_notice() {
	local tmp="$NOTICE.tmp"
	printf '%s\n' "$1" > "$tmp"
	mv "$tmp" "$NOTICE"
}

case "${1:-}" in
check)
	docker pull --quiet "$IMAGE" >/dev/null
	newest=$(docker image inspect -f '{{.Id}}' "$IMAGE")
	running=$(docker inspect -f '{{.Image}}' "$CONTAINER")
	if [ "$newest" = "$running" ]; then
		log "no new version; notice stays off"
		exit 0
	fi
	# The id is the date of the Sunday the update lands, so a reader who
	# closed last week's notice still sees this one.
	sunday=$(date -v+1d '+%Y-%m-%d')
	write_notice "$(python3 -c 'import json,sys; print(json.dumps({"id": sys.argv[1], "active": True, "text": sys.argv[2]}))' "$sunday" "$TEXT")"
	log "new version ${newest:7:12} downloaded; notice on for $sunday"
	;;
clear)
	write_notice '{"id": "none", "active": false}'
	log "notice off"
	;;
*)
	echo "usage: $0 check|clear" >&2
	exit 2
	;;
esac
