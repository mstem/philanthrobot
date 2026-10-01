# Public access for philanthrobot.eu: status (2026-09-30)

Goal: https://philanthrobot.eu reachable without Tailscale, sign-ups moderated (pending), email to matt.stempeck@evensfoundation.eu on each sign-up.

Done:

- Cloudflare tunnel `philanthrobot` created (id 1de9d2e2-e715-4a04-aadf-4c23ce6a44ec), remote-managed, ingress philanthrobot.eu and www to https://localhost:443 (Caddy) with originServerName set per host.
- Run script on the Mac Studio: ~/philanthrobot-tunnel/cloudflared-run.sh (0700, holds the tunnel token), logs in ~/philanthrobot-tunnel/logs/.
- Worker `philanthrobot-signup-mail` deployed at philanthrobot-signup-mail.stempeck.workers.dev with MAIL_TO, MAIL_FROM and HOOK_SECRET. Source: signup-mail/worker.js. The hook secret is in the session scratchpad only, so it will be regenerated if this session ends.
- Cloudflare API token `philanthrobot-tunnel` (Tunnel, Workers Scripts, DNS on philanthrobot.eu) in laptop Keychain, service cloudflare-philanthrobot-admin, account matt.

LaunchAgent ai.evens.philanthrobot-tunnel installed 2026-09-30 18:11 WEST (Matt approved), 4 connections registered (bru, mrs), protocol http2.

Not done (waiting on Matt):

1. (done, see above)
2. (done 2026-10-01) RESEND_API_KEY secret on the Worker; sender is noreply@theory.evensfoundation.eu, the only domain verified for that key.
3. (done 2026-09-30 18:57 WEST, Matt approved) Open WebUI config: ui.default_user_role = pending, events.webhooks = one webhook `signup-mail` on auth.signup to the Worker URL. Backup at /app/backend/data/webui.db.bak-2026-09-30 inside the container. No env overrides; value persisted across restart.
4. (done 2026-10-01, Matt approved) DNS: replace the two dns-only A records (100.88.31.96) for philanthrobot.eu and www with proxied CNAMEs to 1de9d2e2-e715-4a04-aadf-4c23ce6a44ec.cfargotunnel.com. Do this only after 1 and 3, so the site never goes public with open sign-up.
5. (done 2026-10-01) Two test sign-ups pending, both emails delivered. Test users deleted and Always Use HTTPS on (Matt, 2026-10-01).

Rollback: delete the CNAMEs and restore both A records to 100.88.31.96 (dns-only).
