# Using the stand from a phone

**[Русская версия](MOBILE.ru.md)**

The stand opens in a phone browser like an ordinary app: the conversation, project files,
the rendered result. There are three ways to reach your computer, from the simplest to the
most convenient.

| Way | What it needs | Address |
|---|---|---|
| Home network | nothing | `http://192.168.x.x:3080`, at home only |
| Temporary tunnel | nothing, not even a Cloudflare account | a random `https://…trycloudflare.com`, changes on restart |
| Permanent tunnel | a Cloudflare account and a domain | your own `https://dsh.your-domain`, never changes |

All of it is configured in one place: **Settings → Plugins → mobile bridge (dsh-bridge)**.

---

## First: protect the access

Do this before exposing the stand. The mobile interface gives access to an agent that reads
and edits files on your computer, so an open address means an open computer.

The bridge panel has a security section. The options:

- **access password** — every external device types it in;
- **token only** — entry solely through a personal link or QR code, a password will not do;
- **token and password** — both.

You can additionally set an **admin password**: without it the bridge's own settings stay
closed even to a visitor who is already in. Local access from the computer itself
(`127.0.0.1`) is exempt from the prompt — that is a separate flag, and it is on.

Until a password is set the panel says so outright: "access is currently open and any
visitor can enter directly". Do not leave that step for later.

## Option 1: home network

The phone and the computer on the same Wi-Fi — nothing to configure.

```powershell
ipconfig | findstr IPv4
```

The address looks like `http://192.168.1.50:3080`. For this case the bridge panel shows a
**QR code** — point the camera and you are in, no typing.

The one downside: it only works at home.

## Option 2: a temporary tunnel (no account)

The fastest way to get access from anywhere. No Cloudflare account, no domain, no sign-up.

1. In the bridge panel turn on **"Enable public tunnel"**.
2. Leave the token field **empty**.
3. The bridge downloads `cloudflared` itself (~37 MB, into `~/.dsh-bridge/bin/`) and brings
   the tunnel up.
4. The panel then shows an address like `https://random-words.trycloudflare.com` and a QR
   code for it.

Worth knowing: **the address is random and changes** every time the tunnel restarts, so you
have to re-send yourself the link. For "try it from my phone right now" it is exactly right;
for daily use take option 3.

## Option 3: a permanent domain

The address never changes, so you can add it to the phone's home screen once.

1. Create a free Cloudflare account and add a domain (any will do, including a cheap one).
2. In Cloudflare Zero Trust: **Networks → Tunnels → Create a tunnel**, type **Cloudflared**.
   Copy the **token** it gives you.
3. In the same place bind a hostname to the tunnel — `dsh.your-domain`, say — pointing at
   `http://127.0.0.1:3080`.
4. In the bridge panel paste that token and the same hostname into the tunnel fields and
   enable autostart.

From then on the tunnel comes up together with the stand. The launch scripts already give it
sane limits: `TUNNEL_RETRIES=1000` instead of the default five attempts (otherwise a dropped
connection would switch the tunnel off for good) and its own log at `run/cloudflared.log`.

If you run a tunnel yourself — `cloudflared` in Docker or on a server — the panel can simply
register its address: the bridge then downloads and starts nothing, and only shows the link
and the QR code.

## Install it as an app

In the phone browser: menu → **"Add to Home Screen"**. The stand then opens like an ordinary
app, with no address bar: it has an icon, a splash screen and rotation that follows the
system lock.

## When something does not work

**The phone gets a 530.** Almost always one of two things.

*Your network blocks port 7844.* Cloudflare Tunnel holds its connection over outbound TCP
7844, and some networks — mobile, hotel, corporate — block it. Check from the computer:

```powershell
Test-NetConnection 198.41.192.167 -Port 7844
```

If the port is closed, the tunnel will not come up until you change network or turn on a
VPN. Plain HTTPS keeps working meanwhile, which makes this easy to misdiagnose.

*Cloudflared gave up after a drop.* By default it exits after five failed attempts. The
stand's scripts fix that; if you started the tunnel by hand, look at `run/cloudflared.log`.

**The phone shows an old version of the interface.** That is what the `html-no-store` patch
layer is for: the app page used to be cached and the phone got stuck on the previous bundle.
If it still happens, reload with the cache cleared or reinstall the home-screen shortcut.

**The address stopped opening after a restart.** That is the signature of a temporary
tunnel — its name is random. Take the new address from the bridge panel, or move to a
permanent domain.

## What was done specifically for phones

The harness UI is designed for a monitor, so the bridge is extended by our patch layers:

- a drawer with sessions, a power button, a splash screen, rotation following the system
  lock, an icon for "add to home screen";
- **the model's question card** no longer covers the conversation: it takes at most 58%
  of the screen, folds into a one-line strip with a single tap, and cannot be dismissed
  by accident — closing asks for confirmation, because for the model that is a cancelled
  question;
- **pinch** does not zoom the conversation (it got in the way while typing) but does zoom
  the content of the preview — a page, a PDF, a spreadsheet. The panel itself stays put,
  the zoomed page can be dragged with a finger, and a two-finger double tap returns to
  100%;
- no blue flash on tap — a short dimming instead;
- PDFs and office documents open right in the panel instead of being downloaded;
- a file link in the conversation opens the same way as one from the file explorer.
