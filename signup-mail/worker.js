// Emails the admin when someone signs up on https://philanthrobot.eu.
//
// Open WebUI posts its event webhooks here (Admin Panel > Settings > Webhooks,
// filtered to auth.signup). It refuses private and loopback targets, so the
// receiver has to be public; this Worker is that receiver. Open WebUI cannot
// add headers to a webhook, so the shared secret travels as the URL path.
//
// Secrets: HOOK_SECRET (the path), RESEND_API_KEY. Vars: MAIL_TO, MAIL_FROM.

const escape = (s) =>
  String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== `/${env.HOOK_SECRET}`) {
      return new Response("Not found", { status: 404 });
    }

    let event;
    try {
      event = await request.json();
    } catch {
      return new Response("Bad request", { status: 400 });
    }
    if (event.event !== "auth.signup") {
      return new Response("Ignored", { status: 202 });
    }

    const name = event.actor?.name || "(no name)";
    const email = event.actor?.email || event.data?.email || "(no email)";
    const when = new Date((event.created_at || Date.now() / 1000) * 1000).toUTCString();
    const admin = "https://philanthrobot.eu/admin/users";

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: env.MAIL_FROM,
        to: [env.MAIL_TO],
        subject: `Philanthrobot sign-up: ${name}`,
        text: `${name} <${email}> signed up at ${when}.\n\nThe account is pending until you approve it:\n${admin}\n`,
        html: `<p>${escape(name)} &lt;${escape(email)}&gt; signed up at ${escape(when)}.</p><p>The account is pending until you approve it: <a href="${admin}">${admin}</a></p>`,
      }),
    });
    if (!res.ok) {
      console.log("Resend failed", res.status, await res.text());
      return new Response("Mail failed", { status: 502 });
    }
    return new Response("Sent", { status: 200 });
  },
};
