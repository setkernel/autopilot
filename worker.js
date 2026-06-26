// Cloudflare Worker — serves register.ps1 at a short URL on setkernel.net (e.g. https://setkernel.net/ap).
// Deploy: wrangler deploy  (see wrangler.toml). It streams the latest script from this repo's main branch,
// so editing register.ps1 here updates the short URL automatically (5-min edge cache).
const SRC = "https://raw.githubusercontent.com/setkernel/autopilot/main/register.ps1";

export default {
  async fetch() {
    const res = await fetch(SRC, { cf: { cacheTtl: 300, cacheEverything: true } });
    if (!res.ok) return new Response("registration script unavailable", { status: 502 });
    return new Response(await res.text(), {
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": "public, max-age=300",
      },
    });
  },
};
