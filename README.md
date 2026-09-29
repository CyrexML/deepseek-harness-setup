# DeepSeek Harness: full setup from scratch, with plugins and tuning

**[Русская версия](README.ru.md)**

This repository installs a complete [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
stand on a Windows PC: a local model on your own GPU, a coding agent that reads and edits
your project files, a side panel that renders the result (HTML pages, PDFs, spreadsheets),
and a mobile interface you can actually use from a phone.

It is not a bare harness install. It also sets up the plugins worth having, applies 23
patch layers that fix what does not work out of the box (most of them on the mobile side),
tunes the model server for your GPU, and installs shortcuts, an update button and a full
uninstall.

Everything runs locally. Nothing is sent to a cloud.

## What this is

Not a set of tips, not a list of commands to run yourself. This is a **turnkey install**:
you copy `config.json`, run `install.cmd` as administrator, and end up with a working
system whose parts already fit together.

What you get:

- **a model on your own GPU** — the installer picks one that fits your VRAM, downloads it,
  computes the context window and verifies the result by measurement;
- **an agent that works with files** — reads the project, edits code, runs commands with
  your approval, keeps decisions between sessions;
- **a side panel** — explorer, editor and result view: HTML pages with working JavaScript,
  PDFs, spreadsheets, diffs and git commits;
- **your phone** — an interface that is actually usable on a phone, reachable from anywhere
  through a tunnel;
- **maintenance** — shortcuts, a power button, one-command updates, a complete uninstall,
  and cleanup of what piles up.

Why this is not the same as "installing the harness yourself": the harness is the core.
Around it you still have to choose and wire up plugins, fix what does not work on a phone,
pick a model for your card, compute the context window, set up startup, the tunnel and
power behaviour. Here that is already done and pinned: **24 patch layers** where things
break, every component version recorded in `stand.lock.json`, and model server settings
computed for your GPU instead of copied from someone else's example.

The honest limits: you need an NVIDIA GPU (the stand starts from 6 GB, comfortable from 12) and Windows with WSL2; answer quality
is the quality of the model you choose, not of the installer; and there is only one card,
so your own GPU work (training a network) and the model take turns — there is
[a section about that](#web-access-and-your-own-gpu-work).

<p align="center">
  <img src="docs/images/phone-chat.png" width="260" alt="Agent chat on a phone">
  <img src="docs/images/phone-preview.png" width="260" alt="Project page rendered in the side panel">
</p>

---

## Requirements

| | Minimum | Tuned for |
|---|---|---|
| OS | Windows 10 / 11 | Windows 11 |
| GPU | NVIDIA, 8 GB VRAM (comfortable from 12) | RTX 5080, 16 GB |
| Disk | 40 GB free | |
| RAM | 16 GB | 32 GB |

The configuration in this repository is tuned for an **RTX 5080 with 16 GB**, running
Qwen3.8 27B at UD-Q3_K_XL. With less video memory the installer picks a smaller model
from the same catalog — at 12 GB that is **Qwen3.5 9B (MTP build)**, which supports the
same speculative decoding the stand relies on for speed. If even that does not fit, the
wizard suggests a lower quantization of the same file rather than a different model.

Without an NVIDIA GPU the stand still installs — the installer picks a CPU build of the
engine — but the model then runs tens of times slower.

**Things you do *not* have to prepare:**

- **WSL.** If it is missing, `00-prereqs` installs WSL2 and a distribution for you.
  Windows may ask for a reboot; after it, run the installer again and it continues.
- **A drive named F:.** That is only the default in `config.example.json`. If that drive
  does not exist, the installer picks the drive with the most free space and writes the
  choice back into `config.json`.
- **CUDA Toolkit.** Only the NVIDIA display driver is needed: the engine ships as a
  prebuilt binary together with the matching CUDA runtime libraries, which the installer
  downloads for you. The Toolkit is required only if you choose to build llama.cpp from
  source with `10-llama.ps1 -Build`.
- **A specific CUDA version.** The installer reads what your driver supports and picks
  the newest engine build that fits.

## Install

### 1. Download and unpack

**Code → Download ZIP**, unpack into an ordinary folder such as `C:\harness-setup`.
Do not run it from inside the archive: the scripts look for files next to themselves.

The only things you ever run are in the root of the unpacked folder, and there are
exactly three: `install.cmd`, `update.cmd` and `uninstall.cmd`. Everything else lives in
subfolders and needs no attention.

> **Windows will complain, and that is expected.** SmartScreen shows "Windows protected
> your PC", and an antivirus may flag the installer. The reason is plain: these are
> unsigned PowerShell scripts that download executables from the internet — exactly the
> behaviour heuristics look for. The repository has no code-signing certificate.
> In the SmartScreen dialog: **More info → Run anyway**. If the antivirus already removed
> files, add the folder to its exclusions and unpack again. What gets downloaded is listed
> in [`stand.lock.json`](stand.lock.json) and visible in the scripts themselves.

### 2. Set up config.json

**Just open `config.example.json` and edit it.** Nothing to copy or rename: the installer
creates `config.json` from the example on its first run, with your edits in it.

That is safer than creating the file by hand. Windows Explorer hides file extensions by
default, so "New → Text Document" gives you `config.json.txt`, which looks right and does
not work.

You only need to look at one line — `windowsRoot`, the folder for the model and the
engine. It needs **40 GB of free space**; you do not have to create the folder, the
installer does that.

```json
"windowsRoot": "D:/Harness_AI",
```

**The one real trap is backslashes.** Explorer's address bar gives you a path like
`D:\Harness_AI`, and pasting it as-is does not work: this is JSON, where a backslash is
an escape character. `"D:\Harness_AI"` is a broken file and the installer never gets past
it. Use a forward slash — it works the same and cannot be got wrong:

| Works | Does not |
|---|---|
| `"D:/Harness_AI"` | `"D:\Harness_AI"` — Explorer's path as-is |
| `"D:\\Harness_AI"` | `"D:/Harness AI"` — avoid spaces |

The trailing comma is required — it is already there, do not delete it.

To check the file without running the whole install. Open the folder holding
`install.cmd` in Explorer, click the address bar, type `powershell` and press Enter —
the console opens there. Then, on one line:

```powershell
try { Get-Content .\config.example.json -Raw -EA Stop | ConvertFrom-Json -EA Stop | Out-Null; 'OK' } catch { "ERROR: $($_.Exception.Message)" }
```

`OK` means you can start the install. Anything else prints the reason.

Lines starting with `_` are comments — leave them alone. If the drive in `windowsRoot`
does not exist on this machine, the installer picks the one with the most free space and
writes that choice back into `config.json`.

### 3. Run it

Right-click **install.cmd** → **Run as administrator**.

**If WSL was not installed before**, the install takes three passes. That is by design:

| Pass | What happens | What you do |
|---|---|---|
| 1st | WSL2 is installed, the installer prints "reboot the computer and run this script again" | **reboot**, then run `install.cmd` again |
| 2nd | Ubuntu is installed; a black window opens and asks for a user name and password | type any latin name and a password (**the password does not echo — that is not a hang**), then close that window and run `install.cmd` again |
| 3rd | the full install runs | wait |

That password belongs to the user inside Ubuntu and is rarely needed — write it down.
After the second pass the window is left at a prompt like `you@PC:/mnt/c/...$`. That is
not an error and not a question: just close the window.

The installer explains every step as it goes:

| Step | What happens |
|---|---|
| `00-prereqs` | checks GPU and free space, installs WSL2 and a distribution, opens the model port |
| `10-llama` | installs llama.cpp with the CUDA build matching your driver |
| `20-model` | picks a model for your GPU and downloads it |
| `wsl/*` | builds the harness, installs plugins, applies 24 patch layers, writes the config |
| `30-tune` | computes the context window that fits your VRAM and measures the result |
| `40-shortcuts` | shortcuts, autostart, power-maintenance task |
| `50-verify` | verifies everything came up |

**Message language.** The installer and the launcher speak English by default. To switch to
Russian, set `"lang": "ru"` in `config.json`, or use the environment variable for one run:

```powershell
$env:HARNESS_LANG = 'ru'
```

Translations live in `i18n/ru.json` as a plain "English string -> translation" table. A
string missing from the table is printed in English, so a partial translation breaks
nothing — and a new language is one more file, not a second copy of every script.

**The installer stops at the first failed step** and names the step and how to retry just
that one. Nothing after it runs: continuing on top of a broken step is pointless, and its
message would be buried under the following screens anyway.

Every step is idempotent — an interrupted install can simply be started again, and
finished work is skipped.

### Passing a flag

`install.cmd` forwards its arguments, but neither a double click nor "Run as
administrator" gives you anywhere to type them. So: **Start → cmd → right-click → Run as
administrator**, and from there:

```
cd /d C:\harness-setup
install.cmd -Step model
```

The same goes for `uninstall.cmd -All` and `update.cmd`.

| `install.cmd` flag | What it does |
|---|---|
| `-Step <name>` | run one step: `prereqs`, `llama`, `wsl`, `model`, `tune`, `shortcuts`, `verify` |
| `-SkipModel` | leave the model alone (already downloaded and tuned) |
| `-SkipLlama` | skip the llama.cpp engine |

The steps have their own flags, which matter when something did not come up:

| Command | When you need it |
|---|---|
| `powershell -File windows\10-llama.ps1 -Cpu` | the GPU or driver will not do: a CPU build, slow but it works anywhere |
| `powershell -File windows\20-model.ps1 -ListOnly` | see what fits your VRAM without downloading anything |
| `powershell -File windows\20-model.ps1 -Model <file name>` | take a specific quant instead of the matched one |
| `powershell -File windows\20-model.ps1 -NoDownload` | record the choice, place the file yourself |

Which versions get installed is fixed in [`stand.lock.json`](stand.lock.json): the harness
tag, every plugin version and the list of patch layers. That is the combination this
repository was tested with, which is why the installer does not chase "latest".

### About the model

Choosing a model, knowing where to put it and tuning the server afterwards is where people
usually get stuck. `windows\20-model.ps1` reads your VRAM, shows which models fit and
downloads the one you pick; `windows\30-tune.ps1` then computes the context window, writes
the launch command and the agent preset and measures prefill and generation speed.

The same thing in words — [docs/MODEL.md](docs/MODEL.md).

## Daily use

- **Harness AI** on the desktop starts the model and the interface.
- Interface: <http://127.0.0.1:3080>.
- From a phone — three ways: the home network via a QR code, a temporary tunnel (an address
  right away, no Cloudflare account) and a permanent domain. Set an access password before
  exposing anything: the mobile interface reaches an agent that edits files on your
  computer. Step by step: [docs/MOBILE.md](docs/MOBILE.md).

**Stopping the stand: the power button in the top-left corner of the interface.** It works
from the PC and from the phone, and offers four levels — stop the stand only, stop it
together with WSL, stop and sleep, stop and shut the PC down.

<p align="center">
  <img src="docs/images/power-menu.png" width="330" alt="The power button menu">
</p>

The desktop shortcut **Harness AI — stop** does the same as the first option.

### While the stand is running

The PC **does not go to sleep** — that would cut the agent off mid-task, because CPU and
GPU load does not count as activity for Windows; it waits for keyboard input. The screen
still turns off on the usual idle timeout, which changes nothing: the stand keeps working
and a phone session is unaffected. When you stop the stand, the previous sleep settings
are restored exactly as they were.

To see the current state:

```powershell
powershell -ExecutionPolicy Bypass -File F:\Harness_AI\run\harness-idle-sleep.ps1
```

## Updating

```
update.cmd
```

It pulls the new version of this repository, backs up your profile, applies
`stand.lock.json` (harness, plugins, patch layers, settings), restarts the stand and
verifies it. The backup is made before anything changes, and the command prints how to
roll back.

## Uninstall

```
uninstall.cmd
```

It asks for confirmation and lists what will be removed before doing anything.

| Command | What it removes |
|---|---|
| `uninstall.cmd` | shortcuts, scheduled task, firewall rule, engine, launch scripts, models, and the stand's data inside WSL |
| `uninstall.cmd -KeepModel` | the same, but the downloaded models stay (they take a long time to fetch again) |
| `uninstall.cmd -KeepData` | the same, but your chats, agent memory and settings stay |
| `uninstall.cmd -All` | **everything, down to zero**: the above plus the whole WSL distribution |
| `bash wsl/uninstall.sh` | only the Linux side, from inside WSL |

`-All` also removes the WSL distribution, so anything else you kept inside it goes too —
it asks you to type the distribution name to confirm. Windows itself, WSL as a system
component and the GPU driver are never touched.

## What gets installed

- **DeepSeek Harness** at the tag from `stand.lock.json`, built from source inside WSL2.
- **Plugins** at pinned versions: mobile bridge, side panel with a file explorer and
  viewers, office documents, context meter, graph memory, turn rewind.
- **24 patch layers** — my own fixes on top of the harness and the plugins (below).
- **llama.cpp** plus the GGUF model you chose, on the Windows side.

<p align="center">
  <img src="docs/images/desktop-preview.png" width="700" alt="The stand on a desktop: chat and the side panel preview">
</p>

### Why the patch layers

Out of the box the harness plus plugins work poorly on a phone, and some things do not
work at all. Each layer is a separate script identified by a marker inside the patched
file, so a plugin update cannot silently lose it: `scripts/ensure-patches.sh` re-applies
whatever is missing on every start.

| Layer | What it gives you |
|---|---|
| bridge (translation + 11 fixes) | a usable mobile UI: drawer, rotation, splash screen, power button |
| mobile-ux | the model's question card no longer covers the chat, folds into a strip, and cannot be dismissed by accident; no blue tap flash |
| preview-zoom | pinch zooms the *content* of the preview — page, PDF, table — not the panel itself, and the zoomed page can be panned |
| zoom-scope | pinch does not zoom the conversation while typing |
| pdfjs-map-polyfill | PDFs open in browsers older than Chrome 140 (pdf.js 6.3 calls a very new `Map` method) |
| html-no-store | the app page is never cached, so a phone cannot get stuck on an old bundle |
| session-sync | clicking a file in the side panel opens it (broken outright on harness 0.1.6) |
| relative-path | a file link in the chat opens the same way as from the explorer |
| binary-handoff | PDFs and office files open in the panel instead of being downloaded |
| turnTail slot id | side panel and office plugin stay compatible with harness 0.1.6 |
| better-sidebar preview | multi-page apps preview with working JavaScript |
| llm-pi-ai usage | the model stops truncating answers based on a wrong length estimate |
| graph-memory scope | agent memory does not mix projects |
| ui-conversation eager read | a pasted screenshot actually reaches the model |
| touch-ui-gate | the touch fixes apply to a tablet too, not only below 768 px |
| mobile-attach | a one-tap attach button on the touch composer, and a photo one beside it |
| mobile-back | the system back gesture closes the drawer, the panel or a dialog instead of leaving the app |
| load-monitor | GPU load, temperature, power draw and the energy used since start, in the header |
| fs-edit-tolerant | an edit whose `old_string` differs only in whitespace still applies; when it truly does not match, the error quotes the file |
| fs-missing-path | a write or edit aimed at a path that does not exist says so, instead of telling the model to read a file that cannot be read |
| mobile-input | on a touch screen Enter breaks the line instead of sending; a clipboard carrying only HTML still pastes; a long question leaves room for its answers |
| write-streak-notice (preset) | says so when a turn has run long with nothing written, before the answer hits its cap |

## Housekeeping

The agent keeps per-turn file snapshots (what the panel shows as changes) in
`~/.dsh/change-ledger`, outside your projects — it never lands in a git repository, but it
does grow. Both that and the rest of the stand's leftovers are cleaned by:

```bash
bash ~/Harness_AI/scripts/dsh-cleanup.sh                 # report only
bash ~/Harness_AI/scripts/dsh-cleanup.sh --apply --ledger-days 30
```

If you want to put a project under git, give its folder a `.gitignore` for the files the
agent creates beside your code (screenshots, backups, exports):

```bash
bash ~/Harness_AI/scripts/project-gitignore.sh --all
```

## Web access and your own GPU work

**Reading pages (`web_fetch`) works out of the box** — the agent opens a link and
reads it, no keys involved. The tool is part of the preset's resident set:
anything outside that set does not exist for the model, so registering the plugin
alone is not enough. Private addresses (`127.0.0.1`, your home network) are
refused by design, so a page cannot be used to reach a local service of yours.

**Search (`web_search`) needs a provider.** In the harness bundle search goes to
DeepSeek and takes its key from `DEEPSEEK_API_KEY`
(`packages/bundle/base/cordis.patch.yml:461`); a local model exposes no such
endpoint. Without a key search returns an error while page reading keeps working.
Either set a DeepSeek, Exa or Perplexity key (Settings → search), or just hand
the agent links yourself — it will read them. As soon as a key is present in the
environment, the preset adds `web_search` to the model's set by itself.

**Exa as the search provider.** The bundled `web_search` goes to DeepSeek, which
needs a funded balance. Exa is the free alternative: a $10 credit that comes back
on the first of every month, no card. Its provider ships with the harness but is
not in the base bundle's dependencies, so three things are needed — the key in
Settings -> Plugins -> Web search (it is stored in `~/.dsh/.credentials.yaml`,
never in a file that is published), a `web-search-exa` row inserted in the
profile patch with `searchProvider: exa` on the `web` row, and the symlinks that
`scripts/ensure-patches.sh` keeps in place (`link_pkg`). `start-web.sh` lifts the
stored key into the environment, because the agent preset decides whether to make
`web_search` resident by looking there.

**The agent does not run code silently.** The default is `workspace-write` with
confirmation: the command is shown to you before it runs, and file writes are
confined to the workspace (`packages/bundle/base/cordis.patch.yml:231`). The
sandbox governs file effects only — network and process launches are not
restricted, so `pip install`, dataset downloads and training all work.

**There is only one GPU.** By default the tuning wizard gives the model almost
the whole card: 150–500 MiB stay free. Training a network — a CNN, a diffusion
model — will not fit into that and dies with `CUDA out of memory`. Your job and
the model share one card, so the split is decided up front:

```powershell
# keep 6 GB free for your own work; the context window is computed from the rest
powershell -ExecutionPolicy Bypass -File windows\30-tune.ps1 -ReserveMb 6000
```

**You start the training; the agent prepares it.** From its own shell the agent
cannot reach the card at all: the sandbox gives it a bare `/dev` with no GPU
device, so `nvidia-smi` answers "GPU access blocked" there. The agent's working
rules (`~/.dsh/AGENTS.md`, installed for you) therefore tell it to do the part
that is not blocked and hand the run over: finish the script, the data pipeline
and the config; prove the code runs with a short CPU pass; and leave
`RUN-TRAINING.md` in the project — the instruction you follow yourself: how to
free the card, how to set up the environment, the start command, how to watch it
and how to put the stand back. If it tries to launch training anyway, the first
such command is not executed but answered with the measurement — how much VRAM
is free and how much the model holds.

On 16 GB a sensible split is Qwen3.5 9B (about 7 GB) plus 6–8 GB for training.
If you need the large model instead, the other route is to stop the model server
while you compute (`run\stop-server.ps1`) — the agent is then headless until you
start it again. The GPU is visible from WSL (`nvidia-smi` lives in
`/usr/lib/wsl/lib`) and CUDA PyTorch wheels install with `pip`; no CUDA Toolkit
is required for that.

**About the preview sandbox.** So that multi-page apps render with working
JavaScript, the settings ship `htmlViewerNoSandbox: true`
(`templates/settings.yaml.tmpl`). The cost is stated there: a previewed page runs
with the interface's origin and can read and write session files. That is what
you want for your own projects; do not open someone else's HTML that way.

## Git: keeping a project clean

The agent leaves three different things around your work, and they are worth
telling apart.

**Turn snapshots** — what the panel shows as changes. They live in
`~/.dsh/change-ledger`, outside your projects, and never reach git. They do grow.
Clean them with `dsh-cleanup.sh --apply --ledger-days 30`.

**Restore points** — the `turn-rewind` plugin writes them **into the repository
that contains the project**, as `refs/dsh-turn-rewind/…` refs. They are not
branches: `git branch` does not list them and a normal `git push` does not send
them, but many interfaces show them next to branches, which is why it looks like
you have hundreds of branches. To see and prune them:

```bash
bash ~/Harness_AI/scripts/git-rewind-refs.sh ~/path/to/project            # how many
bash ~/Harness_AI/scripts/git-rewind-refs.sh ~/path/to/project --days 14  # drop old ones
```

A deleted restore point means that turn can no longer be rewound, so by default
the script changes nothing.

**Working litter** — `.shots/` (screenshots), `backups/` (copies made before an
edit), `out/`, logs. This is the only part that would actually land in a commit.

### Putting a project on GitHub

```bash
bash ~/Harness_AI/scripts/project-git-init.sh ~/Harness_AI/projects/MyProject
```

It writes the `.gitignore`, creates the repository on `main`, **shows exactly
what the commit will contain and how big it is**, makes the first commit and
configures pushing so that only branches leave. Then:

```bash
gh repo create <name> --private --source=. --remote=origin --push
```

One warning: `git push --mirror` would send every ref, restore points included.
A normal `git push` does not.

## Troubleshooting

**The phone shows 530 over the tunnel.** Cloudflare Tunnel needs outbound TCP 7844. Some
networks block it, and then nothing helps until you switch network or turn on a VPN. Plain
HTTPS keeps working, which makes this easy to misdiagnose — see [docs/MOBILE.md](docs/MOBILE.md).

**Generation is slower than ~20 tokens/s.** The model did not fit into VRAM. Re-run
`windows\30-tune.ps1` (it recomputes the window) or pick a smaller quantization — see
[docs/MODEL.md](docs/MODEL.md).

**The installer fails and you cannot see why.** That was true until September 2026: the
steps ran in separate processes and a failed step stopped nothing, so a log ended with
four different errors in a row and the first, real one was already off screen. The install
now stops at the first. If your log looks like that, you have an old copy — download the
repository again.

**`the engine fails the startup check`.** `llama-server.exe` downloaded but will not run.
The installer now prints what the binary itself said and the exit code it returned. Three
usual causes:

- **no Microsoft Visual C++ Runtime** — often missing on a clean machine, and llama.cpp
  builds need it. Exit code `-1073741515` (0xC0000135) means exactly this:
  `winget install Microsoft.VCRedist.2015+.x64`, then `install.cmd -Step llama`;
- **the CUDA libraries did not unpack** — no `cudart64_*.dll` next to the binary. Usually
  a truncated download: delete the `llama.cpp` folder under `windowsRoot` and retry the step;
- **the driver is too old** — update the NVIDIA driver, or install the CPU build:
  `powershell -File windows\10-llama.ps1 -Cpu`.

**`the model was not downloaded` with `error: 404` in the log.** A 404 is the file name,
not your network. Open `https://huggingface.co/<repo>/tree/main`, take the exact name, and
run `install.cmd -Step model -Model <file name>`. A truncated download (anything but 404)
resumes by itself when you run the step again.

**Less VRAM than the smallest model asks for.** The installer installs it anyway and says
so: part of the model runs on the CPU, which works but is slow. At 4–6 GB this is
marginal; the honest minimum for comfortable work is 12 GB.

**The WSL step fails with `the WSL step returned code 1`.** The full build log now lives
inside WSL at `~/.harness-stand-logs/build.log` (and `install.log`), with the last 25 lines
shown on screen. To read it all:

```
wsl -d Ubuntu -- tail -100 ~/.harness-stand-logs/build.log
```

**The first request after start is slow.** Expected: the first large prompt runs on a cold
file cache and unbuilt CUDA graphs. The launcher sends a warm-up request, so this only
shows up if you start the server by hand.

## Licensing

This repository contains **my own code**: install and uninstall scripts, patch layers,
config templates, documentation. It does not redistribute the harness or the plugins —
`pnpm` fetches them from the official registry during installation, and the patches are
applied locally on your machine afterwards. The one exception is the UI translation
dictionary for the bridge plugin (strings extracted from its MIT-licensed source plus our
English translations); without it the English UI cannot be re-applied after a plugin
update. The licenses of all upstream projects (MIT, Apache-2.0, BSD-3-Clause) and what
exactly we change are listed in [NOTICE](NOTICE).

Our own code is MIT — see [LICENSE](LICENSE).
