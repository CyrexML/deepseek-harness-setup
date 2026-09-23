# Launcher splash screen (WinForms) in its own hidden process: harness-start.ps1
# -Hidden writes stages into launch.status (model | web | done | stopping |
# stopped | "error: text"), this script shows them and closes on done. Needs -STA.
# If the status stops changing for 120 s the launcher is dead and the window
# closes itself rather than hanging forever.
param(
  [string]$StatusFile = 'F:\Harness_AI\run\launch.status',
  [string]$Image      = 'F:\Harness_AI\run\splash-whale.png'
)
# A short stage log: the only way to tell what the screen showed when the
# launcher runs without a console.
$LogFile = [IO.Path]::ChangeExtension($StatusFile, '.splash.log')
function Log([string]$m) { try { Add-Content -Path $LogFile -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m) } catch { } }
Log ('start pid=' + $PID)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace DshSplash -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
# powershell.exe is DPI-unaware: the window would blur and centre itself in
# virtual coordinates. Declare DPI awareness and scale pixels by hand (WinForms
# scales point-sized fonts itself).
[void][DshSplash.Native]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
$gg = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $k = $gg.DpiX / 96.0; $gg.Dispose()
function S([double]$v) { return [int][Math]::Round($v * $k) }

$bg     = [System.Drawing.Color]::FromArgb(15, 17, 23)
$fg     = [System.Drawing.Color]::FromArgb(243, 244, 248)
$muted  = [System.Drawing.Color]::FromArgb(139, 147, 167)
$brand  = [System.Drawing.Color]::FromArgb(77, 107, 254)
$errCol = [System.Drawing.Color]::FromArgb(252, 165, 165)
$W = S 440; $H = S 300

$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle = 'None'
$f.Size            = New-Object System.Drawing.Size($W, $H)
$f.StartPosition   = 'Manual'
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$f.Location        = New-Object System.Drawing.Point(($wa.Left + [int](($wa.Width - $W) / 2)), ($wa.Top + [int](($wa.Height - $H) / 2)))
$f.BackColor       = $bg
$f.TopMost         = $true
$f.ShowInTaskbar   = $false
$f.Opacity         = 0
$f.Text            = 'Harness AI'
$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
$r = S 22
$gp.AddArc(0, 0, $r, $r, 180, 90); $gp.AddArc($W - $r, 0, $r, $r, 270, 90)
$gp.AddArc($W - $r, $H - $r, $r, $r, 0, 90); $gp.AddArc(0, $H - $r, $r, $r, 90, 90)
$gp.CloseFigure()
$f.Region = New-Object System.Drawing.Region($gp)

$pic = New-Object System.Windows.Forms.PictureBox
$pic.Size     = New-Object System.Drawing.Size((S 96), (S 96))
$pic.Location = New-Object System.Drawing.Point([int](($W - (S 96)) / 2), (S 34))
$pic.SizeMode = 'Zoom'
if (Test-Path $Image) { $pic.Image = [System.Drawing.Image]::FromFile($Image) }
$f.Controls.Add($pic)

$title = New-Object System.Windows.Forms.Label
$title.Text      = 'DeepSeek Harness'
$title.Font      = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $fg
$title.TextAlign = 'MiddleCenter'
$title.Size      = New-Object System.Drawing.Size($W, (S 34))
$title.Location  = New-Object System.Drawing.Point(0, (S 140))
$f.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text      = (T 'Starting')
$sub.Font      = New-Object System.Drawing.Font('Segoe UI', 10)
$sub.ForeColor = $muted
$sub.TextAlign = 'MiddleCenter'
$sub.Size      = New-Object System.Drawing.Size($W, (S 26))
$sub.Location  = New-Object System.Drawing.Point(0, (S 178))
$f.Controls.Add($sub)

$track = New-Object System.Windows.Forms.Panel
$track.Size      = New-Object System.Drawing.Size((S 220), (S 4))
$track.Location  = New-Object System.Drawing.Point([int](($W - (S 220)) / 2), (S 222))
$track.BackColor = [System.Drawing.Color]::FromArgb(34, 38, 52)
$runner = New-Object System.Windows.Forms.Panel
$runner.Size      = New-Object System.Drawing.Size((S 70), (S 4))
$runner.Location  = New-Object System.Drawing.Point(0, 0)
$runner.BackColor = $brand
$track.Controls.Add($runner)
$f.Controls.Add($track)

$hint = New-Object System.Windows.Forms.Label
$hint.Text      = (T 'the browser will open by itself when everything is ready')
$hint.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5)
$hint.ForeColor = [System.Drawing.Color]::FromArgb(96, 104, 124)
$hint.TextAlign = 'MiddleCenter'
$hint.Size      = New-Object System.Drawing.Size($W, (S 22))
$hint.Location  = New-Object System.Drawing.Point(0, (S 248))
$f.Controls.Add($hint)

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Text      = (T 'Close')
$closeBtn.FlatStyle = 'Flat'
$closeBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 76, 96)
$closeBtn.ForeColor = $fg
$closeBtn.BackColor = [System.Drawing.Color]::FromArgb(27, 35, 64)
$closeBtn.Size      = New-Object System.Drawing.Size((S 120), (S 30))
$closeBtn.Location  = New-Object System.Drawing.Point([int](($W - (S 120)) / 2), (S 250))
$closeBtn.Visible   = $false
$closeBtn.Add_Click({ $f.Close() })
$f.Controls.Add($closeBtn)

# Message language, same mechanism as the launcher: run\lang.txt or HARNESS_LANG,
# translations in run\i18n\<lang>.json, untranslated strings stay English.
$RunDir = Split-Path -Parent $StatusFile
$Lang = if ($env:HARNESS_LANG) { $env:HARNESS_LANG }
        elseif (Test-Path "$RunDir\lang.txt") { (Get-Content -Raw "$RunDir\lang.txt").Trim() }
        else { 'en' }
$I18n = @{}
if ($Lang -and $Lang -ne 'en' -and (Test-Path "$RunDir\i18n\$Lang.json")) {
  try {
    (Get-Content "$RunDir\i18n\$Lang.json" -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
      ForEach-Object { $I18n[$_.Name] = [string]$_.Value }
  } catch { }
}
function T([string]$Text) { if ($I18n.ContainsKey($Text)) { $I18n[$Text] } else { $Text } }

$stages = @{
  model    = (T 'Loading the model into video memory')
  web      = (T 'Starting the DSH web interface')
  done     = (T 'Ready, opening the browser')
  stopping = (T 'Stopping the stand')
  stopped  = (T 'The stand is stopped')
}
# Animation is driven by a Stopwatch rather than by tick counts: ~60 fps and
# smooth curves. Window and panels are double-buffered or the runner flickers.
foreach ($c in @($f, $track)) {
  $c.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($c, $true, $null)
}
$script:phase = 'start'; $script:fading = $false; $script:lastChange = Get-Date
$script:lastPoll = 0.0; $script:doneT = 0.0
$picTop = $pic.Top
$travel = $track.Width - $runner.Width
$clock = [System.Diagnostics.Stopwatch]::StartNew()
function EaseOutCubic([double]$x) { return 1 - [Math]::Pow(1 - $x, 3) }
function EaseInOutSine([double]$x) { return -([Math]::Cos([Math]::PI * $x) - 1) / 2 }
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 16
$timer.Add_Tick({
  $t = $clock.Elapsed.TotalSeconds
  # Fade-in: 0.7 s, ease-out.
  if (-not $script:fading) {
    $f.Opacity = EaseOutCubic ([Math]::Min(1.0, $t / 0.7))
  }
  # The runner sweeps back and forth on a sine, period 2.2 s.
  $u = ($t % 2.2) / 2.2
  $ping = if ($u -lt 0.5) { $u * 2 } else { 2 - $u * 2 }
  $runner.Left = [int][Math]::Round($travel * (EaseInOutSine $ping))
  $pic.Top = $picTop + [int][Math]::Round(3 * [Math]::Sin($t * 1.6))
  # Poll the status file at most 6 times a second.
  if ($t - $script:lastPoll -ge 0.15) {
    $script:lastPoll = $t
    $status = $null
    # ReadAllText reads UTF-8, matching the launcher's WriteAllText. Get-Content
    # in PS 5.1 would read ANSI and mangle non-ASCII text in error:/warn: stages.
    if (Test-Path $StatusFile) { try { $status = ([IO.File]::ReadAllText($StatusFile)).Trim() } catch { } }
    if ($status -and $status -ne $script:phase) {
      $script:phase = $status; $script:lastChange = Get-Date
      Log ('stage ' + $status)
      if ($status -like 'error:*') {
        $sub.ForeColor = $errCol
        $sub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $sub.Size = New-Object System.Drawing.Size(($W - (S 40)), (S 60))
        $sub.Location = New-Object System.Drawing.Point((S 20), (S 172))
        $sub.Text = (T 'Could not start: ') + $status.Substring(6).Trim()
        $track.Visible = $false; $hint.Visible = $false; $closeBtn.Visible = $true
      } elseif ($status -like 'warn:*') {
        # The stand is up but something is worth showing (VRAM): yellow text,
        # a close button, and it fades out by itself after 25 s.
        $sub.ForeColor = [System.Drawing.Color]::FromArgb(230, 180, 60)
        $sub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $sub.Size = New-Object System.Drawing.Size(($W - (S 40)), (S 60))
        $sub.Location = New-Object System.Drawing.Point((S 20), (S 172))
        $sub.Text = (T 'Started, but: ') + $status.Substring(5).Trim()
        $track.Visible = $false; $hint.Visible = $false; $closeBtn.Visible = $true
        $script:fading = $true
        $script:doneT = $t + 24.2
      } elseif ($status -eq 'done' -or $status -eq 'stopped') {
        $sub.Text = $stages[$status]
        $script:fading = $true
        $script:doneT = $t
      }
    }
    if (-not $script:fading -and $script:phase -notlike 'error:*' -and $script:phase -notlike 'warn:*') {
      $base = if ($stages.ContainsKey($script:phase)) { $stages[$script:phase] } else { (T 'Starting') }
      $sub.Text = $base + ('.' * ([int][Math]::Floor($t / 0.45) % 4))
      if (((Get-Date) - $script:lastChange).TotalSeconds -gt 120) { Log 'close (watchdog)'; $timer.Stop(); $f.Close() }
    }
  }
  # Fade-out: 0.8 s pause, then 0.45 s ease-in.
  if ($script:fading) {
    $k2 = ($t - $script:doneT - 0.8) / 0.45
    if ($k2 -ge 0) {
      $f.Opacity = [Math]::Max(0.0, 1 - [Math]::Pow([Math]::Min(1.0, $k2), 2))
      if ($k2 -ge 1) { Log 'close (done)'; $timer.Stop(); $f.Close() }
    }
  }
})
$f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $f.Close() } })
# The process starts hidden (Start-Process -WindowStyle Hidden) and Windows
# applies SW_HIDE from STARTUPINFO to the process's FIRST window, which would
# leave the form invisible. Show it explicitly with a second ShowWindow call.
$f.Show()
[void][DshSplash.Native]::ShowWindow($f.Handle, 5)
$f.Activate()
$timer.Start()
[System.Windows.Forms.Application]::Run($f)
Log 'exit'
