// Cloudflare Pages Function: POST /api/social/meta-hook — the Uninstall and Delete callback URLs Meta asks for
// in the Threads app settings. 10nis only connects its own account, so there is no user data to remove here;
// disconnect from /ad4min → Threads instead.
export async function onRequestPost() {
  return new Response(JSON.stringify({url: 'https://10nis.win/privacy', confirmation_code: '10nis-threads'}),
    {headers: {'content-type': 'application/json'}});
}
