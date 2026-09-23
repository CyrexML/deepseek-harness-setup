# Using the stand from a phone

**[Русская версия](MOBILE.ru.md)**

The stand runs in a phone browser like an ordinary app: the conversation, the project
files, the rendered result. There are two ways to reach your computer.

## Option 1: home network (simplest, works immediately)

If the phone and the computer are on the same Wi-Fi, nothing needs configuring — find
the computer's address and open it on the phone:

```powershell
ipconfig | findstr IPv4
```

The address looks like `http://192.168.1.50:3080`. The interface asks for a token; it is
printed when the stand starts and stored in `run/web.log`.

Downsides: only at home, and only while both devices share a network.

## Option 2: Cloudflare Tunnel (from anywhere)

A tunnel gives you a permanent address like `https://your-domain`, reachable from
anywhere, with no port forwarding and no static IP.

1. Create a free Cloudflare account and add a domain (any cheap one works).
2. Turn the tunnel on in `config.json`:
   ```json
   "tunnel": { "enabled": true, "domain": "dsh.your-domain" }
   ```
3. Run the configuration step:
   ```powershell
   powershell -ExecutionPolicy Bypass -File install.ps1 -Step wsl
   ```
   The bridge plugin walks you through the Cloudflare login and issues the tunnel.

### When the phone gets a 530

This happens, and it is almost always one of two things.

**Your network blocks port 7844.** Cloudflare Tunnel keeps its connection over TCP 7844,
and some networks — mobile and hotel ones especially — block it. Check from the computer:

```powershell
Test-NetConnection 198.41.192.167 -Port 7844
```

If the port is closed, the tunnel cannot come up until you switch networks or turn on a
VPN. Ordinary HTTPS keeps working the whole time, which is exactly why this is easy to
misdiagnose.

**cloudflared gave up after a disconnect.** By default it exits after five failed
attempts. Our launch scripts already fix this (`TUNNEL_RETRIES=1000`), but if you
started the tunnel by hand, check `run/cloudflared.log`.

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

## Install it as an app

In the phone browser: menu → "Add to Home screen". After that the stand opens like a
regular app, without the address bar.
