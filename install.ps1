<#
  Lumina installer for Windows (PowerShell 5.1 or later).

  Puts the Lumina Google Drive viewer on a Samsung TV (2025 or newer). It
  installs the tools it needs, walks you through the steps only you can do
  (accounts, TV settings), and remembers where it got to: run it again and it
  carries on from there.

    powershell -ExecutionPolicy Bypass -File install.ps1            set up, or carry on
    powershell -ExecutionPolicy Bypass -File install.ps1 -Update    install the newest Lumina
    powershell -ExecutionPolicy Bypass -File install.ps1 -Reset     forget progress, start again

  No administrator rights are needed. Your Google client secret is typed
  straight into Cloudflare's tool and is never stored by this script.

  NOTE: this Windows version has not yet been tested on a Windows PC.
#>
param(
  [switch]$Update,
  [switch]$Reset,
  [string]$ReleaseDir = '',   # testing: use a local release folder
  [string]$RelayUrl = ''      # you already have a sign-in service
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRaw     = if ($env:LUMINA_REPO_RAW) { $env:LUMINA_REPO_RAW } else { 'https://raw.githubusercontent.com/rishmarwah/lumina-tv/main' }
$HomeDir     = Join-Path $env:USERPROFILE '.lumina-installer'
$StateFile   = Join-Path $HomeDir 'state'
# Tizen's tools do not cope with spaces in paths, so they go in C:\tizen-studio.
$TizenDir    = if ($env:LUMINA_TIZEN_DIR) { $env:LUMINA_TIZEN_DIR } else { 'C:\tizen-studio' }
$TizenVer    = '6.1'
$TizenCliUrl = "https://download.tizen.org/sdk/Installer/tizen-studio_$TizenVer/web-cli_Tizen_Studio_${TizenVer}_windows-64.exe"
$Wrangler    = 'wrangler@4'
$AppId       = 'LuminaTV01.Lumina'
$Placeholder = 'https://relay.lumina.invalid'
$Tizen       = Join-Path $TizenDir 'tools\ide\bin\tizen.bat'
$Sdb         = Join-Path $TizenDir 'tools\sdb.exe'
$TotalSteps  = 8

# ---------------------------------------------------------------- output

function Step($n, $title) { Write-Host ""; Write-Host "━━ Step $n of $TotalSteps · $title" -ForegroundColor Cyan; Write-Host "" }
function Say($t)  { Write-Host $t }
function Dim($t)  { Write-Host $t -ForegroundColor DarkGray }
function Ok($t)   { Write-Host "✔ $t" -ForegroundColor Green }
function Warn($t) { Write-Host "! $t" -ForegroundColor Yellow }
function Fail($t) { Write-Host "✘ $t" -ForegroundColor Red; exit 1 }
function Todo($n, $t) { Write-Host "  $n " -NoNewline -ForegroundColor White; Write-Host $t }

function Ask($question, $default = '') {
  $prompt = if ($default) { "$question [$default]" } else { $question }
  $reply = Read-Host $prompt
  if ([string]::IsNullOrWhiteSpace($reply)) { return $default }
  return $reply.Trim()
}
function Confirm($question) { return (Read-Host "$question [y/n]") -match '^(y|yes)$' }
function WaitEnter {
  $r = Read-Host "`nPress Enter when you have done this (or type q to stop; run the installer again to carry on)"
  if ($r -match '^q$') { Say 'Stopped. Run the installer again to carry on from here.'; exit 0 }
}
function OpenUrl($u) { Start-Process $u | Out-Null; Dim "  (opened in your browser: $u)" }

# ---------------------------------------------------------------- state

New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null
if (-not (Test-Path $StateFile)) { New-Item -ItemType File -Path $StateFile | Out-Null }

function Get-State($key) {
  $line = Get-Content $StateFile | Where-Object { $_ -like "$key=*" } | Select-Object -Last 1
  if ($line) { return $line.Substring($key.Length + 1) } else { return '' }
}
function Set-State($key, $value) {
  $lines = @(Get-Content $StateFile | Where-Object { $_ -notlike "$key=*" })
  $lines += "$key=$value"
  Set-Content -Path $StateFile -Value $lines -Encoding ASCII
}
function Test-Done($step) { (Get-State "DONE_$step") -eq '1' }
function Set-Done($step) { Set-State "DONE_$step" '1' }

if ($Reset) {
  if (Confirm 'Forget all installer progress? (Your TV, accounts and installed app are not touched)') {
    Remove-Item $StateFile -Force; Ok 'Progress cleared. Run the installer again to start over.'
  }
  exit 0
}

# ---------------------------------------------------------------- helpers

function Assert-Online {
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 'https://www.google.com/generate_204' | Out-Null }
  catch { Fail 'This PC is not online. Connect to the internet and run the installer again.' }
}

function Get-PcIp {
  $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
  if ($cfg) { return $cfg.IPv4Address.IPAddress }
  return ''
}

function Get-NodeDir {
  $own = Join-Path $HomeDir 'node'
  if (Test-Path (Join-Path $own 'node.exe')) { return $own }
  $sys = Get-Command node -ErrorAction SilentlyContinue
  if ($sys) {
    $major = [int]((& node -p 'process.versions.node.split(".")[0]') 2>$null)
    if ($major -ge 20) { return (Split-Path $sys.Source) }
  }
  return ''
}

function Invoke-Wrangler {   # runs Cloudflare's tool from the relay folder
  param([string[]]$WranglerArgs, [string]$InputText = $null)
  $nodeDir = Get-NodeDir
  $env:Path = "$nodeDir;$env:Path"
  Push-Location (Join-Path $HomeDir 'relay')
  try {
    if ($null -ne $InputText) { $InputText | & (Join-Path $nodeDir 'npx.cmd') --yes $Wrangler @WranglerArgs }
    else { & (Join-Path $nodeDir 'npx.cmd') --yes $Wrangler @WranglerArgs }
  } finally { Pop-Location }
}

function Invoke-Sdb {   # sdb with a time limit: a sleeping TV can make it hang
  param([string[]]$SdbArgs)
  $out = Join-Path $HomeDir 'sdb.out'
  $p = Start-Process -FilePath $Sdb -ArgumentList $SdbArgs -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
  if (-not $p.WaitForExit(20000)) { try { $p.Kill() } catch {} }
  return ((Get-Content $out -Raw -ErrorAction SilentlyContinue) + (Get-Content "$out.err" -Raw -ErrorAction SilentlyContinue))
}

function Connect-Tv($ip) {   # restarts sdb's background service if it got stuck
  for ($i = 0; $i -lt 3; $i++) {
    $c = Invoke-Sdb @('connect', $ip)
    if ($c -match 'connected to|already connected') {
      if ((Invoke-Sdb @('devices')) -match [regex]::Escape("$ip`:26101") + '\s+device') { return $true }
    }
    Invoke-Sdb @('kill-server') | Out-Null; Start-Sleep 1
    Invoke-Sdb @('start-server') | Out-Null; Start-Sleep 2
  }
  return $false
}

function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }

$script:RelDir = ''
$script:RelVersion = ''
function Get-Release {
  $script:RelDir = Join-Path $HomeDir 'release'
  Remove-Item $script:RelDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $script:RelDir | Out-Null
  $latestPath = Join-Path $script:RelDir 'latest.json'
  if ($ReleaseDir) {
    Copy-Item (Join-Path $ReleaseDir 'latest.json') $latestPath
    $latest = Get-Content $latestPath -Raw | ConvertFrom-Json
    Copy-Item (Join-Path $ReleaseDir $latest.app) (Join-Path $script:RelDir 'app.zip')
    Copy-Item (Join-Path $ReleaseDir $latest.relay) (Join-Path $script:RelDir 'relay.js')
  } else {
    try {
      Invoke-WebRequest -UseBasicParsing "$RepoRaw/latest.json" -OutFile $latestPath
      $latest = Get-Content $latestPath -Raw | ConvertFrom-Json
      Invoke-WebRequest -UseBasicParsing "$RepoRaw/$($latest.app)" -OutFile (Join-Path $script:RelDir 'app.zip')
      Invoke-WebRequest -UseBasicParsing "$RepoRaw/$($latest.relay)" -OutFile (Join-Path $script:RelDir 'relay.js')
    } catch { Fail "Couldn't download Lumina from $RepoRaw." }
  }
  $appSha = (Get-FileHash (Join-Path $script:RelDir 'app.zip') -Algorithm SHA256).Hash.ToLower()
  $relaySha = (Get-FileHash (Join-Path $script:RelDir 'relay.js') -Algorithm SHA256).Hash.ToLower()
  if ($appSha -ne $latest.appSha256 -or $relaySha -ne $latest.relaySha256) {
    Fail "The downloaded files don't match their published checksums. Nothing was installed. Try again later."
  }
  $script:RelVersion = $latest.version
  Ok "Downloaded Lumina $($script:RelVersion) (checksums verified)"
}

# ================================================================ intro

Clear-Host
Write-Host 'Lumina installer' -NoNewline -ForegroundColor White; Dim '  · Google Drive on your Samsung TV'
Write-Host ''
Warn 'This Windows installer has not been tested on a Windows PC yet. If a step fails, the message says where its log is.'

if (-not $Update -and -not (Get-State 'STARTED')) {
  Say 'This puts Lumina on your Samsung TV. Allow 45 to 60 minutes the first time;'
  Say 'most of it is downloads. You will need:'
  Say ''
  Todo '•' 'a Samsung TV from 2025 or later, on the same network as this PC'
  Todo '•' 'the TV remote'
  Todo '•' 'a Google account (the one whose Drive you want on the TV)'
  Todo '•' 'a Samsung account (free; for the developer certificate)'
  Todo '•' 'a Cloudflare account (free; for your own small sign-in service)'
  Todo '•' 'about 5 GB of free disk space on drive C:'
  Say ''
  Dim 'The installer saves its progress. You can stop at any prompt and run it again later.'
  if (-not (Confirm 'Ready to start?')) { exit 0 }
  Set-State 'STARTED' (Get-Date -Format 'yyyy-MM-dd')
}

Assert-Online

# ================================================================ 1. tools

function Install-Tools {
  Step 1 "Samsung's TV tools (Tizen Studio)"
  if ((Test-Path $Tizen) -and (Test-Path $Sdb)) {
    Ok "Tizen tools found in $TizenDir"
  } else {
    Say "Lumina is installed with Samsung's free Tizen Studio command-line tools."
    Say 'Download: about 300 MB now, then about 3 GB of TV add-ons.'
    Say ''
    Say "Using them means accepting the Tizen SDK licence and Samsung's TV extension"
    Say 'licences. Read them here before you agree:'
    Say '  https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html'
    Say ''
    if (-not (Confirm 'Do you accept these licences and want to install the tools now?')) { Say 'Stopped. Nothing was installed.'; exit 0 }
    $dl = Join-Path $HomeDir 'downloads'; New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $exe = Join-Path $dl 'tizen-cli.exe'
    Say "Downloading Tizen Studio $TizenVer…"
    try { Invoke-WebRequest -UseBasicParsing $TizenCliUrl -OutFile $exe } catch { Fail 'Download failed. Run the installer again.' }
    Say "Installing into $TizenDir…"
    $log = Join-Path $HomeDir 'tizen-install.log'
    $p = Start-Process -FilePath $exe -ArgumentList @('--accept-license', $TizenDir) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $log
    if ($p.ExitCode -ne 0 -or -not (Test-Path $Tizen)) { Fail "Tizen Studio didn't install. Details: $log" }
    Ok 'Tizen Studio installed'
  }

  $pm = Join-Path $TizenDir 'package-manager\package-manager-cli.exe'
  $installed = (& $pm show-pkgs 2>$null | Select-String -Pattern '^i\s+(TV-SAMSUNG-Public-WebAppDevelopment|cert-add-on)\s').Count
  if ($installed -ge 2) {
    Ok 'TV add-ons already installed'
  } else {
    Say 'Installing the TV add-ons (several GB; often 10 to 30 minutes)…'
    $log = Join-Path $HomeDir 'tizen-packages.log'
    & $pm install --accept-license Certificate-Manager cert-add-on TV-SAMSUNG-Public-WebAppDevelopment TV-SAMSUNG-Extension-Tools *> $log
    if ($LASTEXITCODE -ne 0) { Fail "The TV add-ons didn't install. Details: $log" }
    Ok 'TV add-ons installed'
  }

  if (-not (Get-NodeDir)) {
    Say ''
    Say "The sign-in service is set up with Cloudflare's tool, which needs Node.js."
    Say "The installer can put a private copy in $HomeDir\node (about 60 MB, no admin rights)."
    if (-not (Confirm 'Download Node.js from nodejs.org?')) { Say 'Stopped.'; exit 0 }
    $index = Invoke-RestMethod 'https://nodejs.org/dist/index.json'
    $ver = ($index | Where-Object { $_.lts } | Select-Object -First 1).version
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $name = "node-$ver-win-$arch"
    $dl = Join-Path $HomeDir 'downloads'; New-Item -ItemType Directory -Force -Path $dl | Out-Null
    Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/$ver/$name.zip" -OutFile (Join-Path $dl "$name.zip")
    $sums = (Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/$ver/SHASUMS256.txt").Content
    $expected = ($sums -split "`n" | Where-Object { $_ -match " $name\.zip$" }) -replace '\s.*$', ''
    $actual = (Get-FileHash (Join-Path $dl "$name.zip") -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { Fail 'Node.js checksum did not match. Nothing installed.' }
    Remove-Item (Join-Path $HomeDir 'node') -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive (Join-Path $dl "$name.zip") -DestinationPath $dl -Force
    Move-Item (Join-Path $dl $name) (Join-Path $HomeDir 'node')
    Ok "Node.js $ver ready"
  } else { Ok 'Node.js found' }
  Set-Done 'TOOLS'
}

# ================================================================ 2-4. sign-in service

function Setup-GoogleA {
  Step 2 'Your Google sign-in settings (Google Cloud)'
  Say 'Lumina reads your Drive with permission you grant through your own Google Cloud'
  Say "project. It's free. In your browser, signed in with your Google account:"
  Say ''
  Todo '1.' 'Create a project, for example named Lumina.'
  OpenUrl 'https://console.cloud.google.com/projectcreate'; WaitEnter
  Todo '2.' 'Enable the Google Drive API for that project (check the project name at the top).'
  OpenUrl 'https://console.cloud.google.com/apis/library/drive.googleapis.com'; WaitEnter
  Todo '3.' 'Set up Google Auth Platform: app name Lumina, your email as support and'
  Say  '     developer contact, Audience: External.'
  OpenUrl 'https://console.cloud.google.com/auth/overview'; WaitEnter
  Todo '4.' 'Data Access > Add or remove scopes. Add these four, then Save:'
  Say  '       openid    email    profile'
  Say  '       https://www.googleapis.com/auth/drive.readonly'
  OpenUrl 'https://console.cloud.google.com/auth/scopes'; WaitEnter
  Todo '5.' 'Clients > Create client > type Web application, name Lumina. Leave the'
  Say  '     redirect address empty for now. Create it, and keep that page open:'
  Say  "     you'll need the Client ID now and the Client secret in step 3."
  OpenUrl 'https://console.cloud.google.com/auth/clients/create'
  while ($true) {
    $id = (Ask 'Paste the Client ID (ends in .apps.googleusercontent.com)') -replace '\s', ''
    if ($id -match '^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$') { break }
    Warn "That doesn't look like a Client ID. It looks like 1234-abc….apps.googleusercontent.com"
  }
  Set-State 'CLIENT_ID' $id; Ok 'Client ID saved'; Set-Done 'GOOGLE_A'
}

function Setup-Relay {
  Step 3 'Your sign-in service (Cloudflare, free)'
  Say 'A tiny service of your own handles sign-in from your phone and streams videos to'
  Say "the TV. It runs on Cloudflare's free plan, under your account."
  Say ''
  Todo '1.' "If you don't have a Cloudflare account, create one (free)."
  OpenUrl 'https://dash.cloudflare.com/sign-up'; WaitEnter

  Get-Release
  $relayDir = Join-Path $HomeDir 'relay'
  New-Item -ItemType Directory -Force -Path $relayDir | Out-Null
  Copy-Item (Join-Path $script:RelDir 'relay.js') (Join-Path $relayDir 'worker.js') -Force
  Write-Utf8 (Join-Path $relayDir 'package.json') "{ `"name`": `"lumina-relay-installer`", `"private`": true }`n"

  Todo '2.' "Sign Cloudflare's tool in to your account: a browser page opens; choose Allow."
  $who = (Invoke-Wrangler @('whoami') 2>&1 | Out-String)
  if ($who -notmatch 'You are logged in') { Invoke-Wrangler @('login'); if ($LASTEXITCODE -ne 0) { Fail "Cloudflare sign-in didn't finish." } }
  Ok 'Signed in to Cloudflare'

  $kv = Get-State 'KV_ID'
  if (-not $kv) {
    Write-Utf8 (Join-Path $relayDir 'wrangler.toml') "name = `"lumina-relay`"`nmain = `"worker.js`"`ncompatibility_date = `"2026-11-01`"`n"
    $created = (Invoke-Wrangler @('kv', 'namespace', 'create', 'PAIRINGS') 2>&1 | Out-String)
    if ($created -match 'id = "([0-9a-f]{20,})"') { $kv = $Matches[1] }
    if (-not $kv) {
      $list = (Invoke-Wrangler @('kv', 'namespace', 'list') 2>$null | Out-String) | ConvertFrom-Json
      $kv = ($list | Where-Object { $_.title -match '(^|-)PAIRINGS$' } | Select-Object -First 1).id
    }
    if (-not $kv) { Fail "Couldn't create Cloudflare storage for pairing codes." }
    Set-State 'KV_ID' $kv
  }

  $toml = @"
name = "lumina-relay"
main = "worker.js"
compatibility_date = "2026-11-01"

[observability]
enabled = false

[vars]
GOOGLE_CLIENT_ID = "$(Get-State 'CLIENT_ID')"

[[kv_namespaces]]
binding = "PAIRINGS"
id = "$kv"

[[ratelimits]]
name = "RL_STRICT"
namespace_id = "1001"
  [ratelimits.simple]
  limit = 10
  period = 60

[[ratelimits]]
name = "RL_POLL"
namespace_id = "1002"
  [ratelimits.simple]
  limit = 60
  period = 60

[[ratelimits]]
name = "RL_MEDIA"
namespace_id = "1003"
  [ratelimits.simple]
  limit = 600
  period = 60
"@
  Write-Utf8 (Join-Path $relayDir 'wrangler.toml') $toml

  Say 'Deploying your sign-in service…'
  $log = Join-Path $HomeDir 'relay-deploy.log'
  $out = (Invoke-Wrangler @('deploy') 2>&1 | Out-String)
  Set-Content $log $out
  if ($out -notmatch '(https://[a-zA-Z0-9.-]+\.workers\.dev)') { Fail "Deploy didn't report an address. Details: $log" }
  $url = $Matches[1]
  Set-State 'RELAY_URL' $url
  Ok "Sign-in service deployed at $url"

  # A random key for video links, made here and sent straight to Cloudflare.
  $bytes = New-Object byte[] 48
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  Invoke-Wrangler @('secret', 'put', 'TICKET_KEY') -InputText ([Convert]::ToBase64String($bytes)) | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "Couldn't store the video-link key." }

  Say ''
  Todo '3.' 'Now the Client secret from the Google page you kept open. Paste it at the prompt'
  Say  '     below. It is sent straight to Cloudflare; this installer never sees or keeps it.'
  Invoke-Wrangler @('secret', 'put', 'GOOGLE_CLIENT_SECRET')
  if ($LASTEXITCODE -ne 0) { Fail "The client secret wasn't stored. Run the installer again to retry." }
  Ok 'Client secret stored in Cloudflare'

  Say 'Waiting for the new address to come online (usually 1 to 5 minutes)…'
  for ($i = 0; $i -lt 60; $i++) {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 "$url/pair" | Out-Null; Ok 'Sign-in service is online'; Set-Done 'RELAY'; return } catch { Start-Sleep 10 }
  }
  Fail "The service didn't come online. Run the installer again in a few minutes."
}

function Setup-GoogleB {
  Step 4 'Finish the Google settings'
  $url = Get-State 'RELAY_URL'
  Todo '1.' 'In Clients, open the Lumina client and add this Authorized redirect URI, then Save:'
  Say  ''
  Say  "       $url/auth/callback"
  Set-Clipboard "$url/auth/callback"; Dim '       (copied to your clipboard)'
  OpenUrl 'https://console.cloud.google.com/auth/clients'; WaitEnter
  Todo '2.' 'Audience > Publishing status > Publish app (In production).'
  Say  "     In 'Testing', Google signs the TV out every 7 days. Published but unverified"
  Say  "     is fine for your own use: Google shows a one-time 'unverified app' warning."
  OpenUrl 'https://console.cloud.google.com/auth/audience'; WaitEnter
  Set-Done 'GOOGLE_B'
}

# ================================================================ 5. TV

function Connect-TvStep {
  Step 5 'Connect to your TV'
  $pcIp = Get-PcIp
  if (-not $pcIp) { Fail 'This PC has no network address. Connect to the network and try again.' }
  if (-not $Update -or -not (Get-State 'TV_IP')) {
    Say 'Turn on Developer Mode on the TV, so this PC is allowed to install an app on it:'
    Say ''
    Todo '1.' 'Update the TV first: Settings > Support > Software Update.'
    Todo '2.' 'Open Apps on the TV. Type 1 2 3 4 5 on the remote (on a remote without number'
    Say  "     keys press the 123 button, or use the SmartThings app's remote on your phone)."
    Todo '3.' "Switch Developer mode On and enter this PC's address:  $pcIp"
    Todo '4.' "Restart the TV: hold the remote's power button until the Samsung logo appears."
    Todo '5.' "Find the TV's own address: Settings > Connection > Network > Network Status >"
    Say  '     IP Settings.'
    Say ''
    Dim  'If Windows asks whether sdb may use the network, allow it on private networks.'
  }
  $ip = Get-State 'TV_IP'
  while ($true) {
    $ip = Ask "The TV's IP address" $ip
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Warn "That isn't an address like 192.168.1.20"; continue }
    Say 'Connecting…'
    if (Connect-Tv $ip) { break }
    Warn "The TV didn't answer. Check: same network, Developer mode On with $pcIp, TV restarted after."
    if (-not (Confirm 'Try again?')) { exit 1 }
  }
  Set-State 'TV_IP' $ip
  $duid = ((Invoke-Sdb @('-s', "$ip`:26101", 'shell', '0', 'getduid')).Trim() -split "`n" | Select-Object -Last 1).Trim()
  $cap = Invoke-Sdb @('-s', "$ip`:26101", 'capability')
  $ver = if ($cap -match 'platform_version:([0-9.]+)') { $Matches[1] } else { '' }
  if ($duid) { Set-State 'DUID' $duid }
  Ok "Connected to the TV (model ID $(Get-State 'DUID'), Tizen $(if ($ver) { $ver } else { 'unknown' }))"
  if ($ver -and [double]($ver -replace '^(\d+\.\d+).*', '$1') -lt 9.0) {
    Warn "Lumina needs Tizen 9.0 or newer (Samsung TVs from 2025). This TV reports $ver; installing may fail."
  }
  Set-Done 'TV'
}

# ================================================================ 6. certificate

function Get-Profiles {
  (& $Tizen security-profiles list 2>$null | Select-Object -Skip 2 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })
}

function Setup-Certificate {
  Step 6 'Your Samsung developer certificate'
  $current = Get-State 'PROFILE'
  if ($current -and ((Get-Profiles) -contains $current)) { Ok "Using certificate profile $current"; Set-Done 'CERT'; return }
  $duid = Get-State 'DUID'
  $before = @(Get-Profiles)
  Say 'Samsung TVs only install apps signed for that TV. Certificate Manager is opening.'
  Set-Clipboard $duid; Dim "(Your TV's ID is on the clipboard: $duid)"
  $cm = Join-Path $TizenDir 'tools\certificate-manager\certificate-manager.exe'
  if (Test-Path $cm) { Start-Process $cm } else { Warn "Open Certificate Manager from $TizenDir\tools\certificate-manager" }
  Say ''
  Todo '1.' 'Click + , choose Samsung, then TV. Name the profile lumina.'
  Todo '2.' "Create a new author certificate: any name, and a password you'll remember."
  Say  '     Sign in with your Samsung account when the browser asks (create one if needed).'
  Todo '3.' 'Create a new distributor certificate, privilege Public, and paste this TV ID:'
  Say  "       $duid"
  Todo '4.' 'Finish. The new profile shows with a tick.'
  WaitEnter
  $after = @(Get-Profiles)
  $new = $after | Where-Object { $before -notcontains $_ } | Select-Object -First 1
  if (-not $new) {
    Say 'Your certificate profiles:'; $after | ForEach-Object { Say "   $_" }
    $new = Ask 'Which profile is for this TV?' ($after | Select-Object -First 1)
  }
  if ((Get-Profiles) -notcontains $new) { Fail "No certificate profile named '$new'." }
  Set-State 'PROFILE' $new; Ok "Using certificate profile $new"; Set-Done 'CERT'
}

# ================================================================ 7. install

function Install-App {
  Step 7 'Install Lumina on the TV'
  if (-not $script:RelDir -or -not (Test-Path (Join-Path $script:RelDir 'app.zip'))) { Get-Release }
  $relay = (Get-State 'RELAY_URL').TrimEnd('/')
  $work = Join-Path $HomeDir 'build'
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
  $appDir = Join-Path $work 'app'; $outDir = Join-Path $work 'out'
  New-Item -ItemType Directory -Force -Path $appDir, $outDir | Out-Null
  Expand-Archive (Join-Path $script:RelDir 'app.zip') -DestinationPath $appDir -Force

  # Point the app at your own sign-in service.
  $files = @((Join-Path $appDir 'index.html'), (Join-Path $appDir 'config.xml')) + @(Get-ChildItem (Join-Path $appDir 'assets') -Filter *.js | ForEach-Object FullName)
  $n = 0
  foreach ($f in $files) {
    $text = [IO.File]::ReadAllText($f)
    if ($text.Contains($Placeholder)) { Write-Utf8 $f ($text.Replace($Placeholder, $relay)); $n++ }
  }
  if ($n -lt 3) { Fail "This release doesn't have the expected settings placeholder. Nothing installed." }

  Say 'Signing for your TV…'
  $log = Join-Path $HomeDir 'package.log'
  & $Tizen package -t wgt -s (Get-State 'PROFILE') -o $outDir -- $appDir *> $log
  $wgt = Get-ChildItem $outDir -Filter *.wgt | Select-Object -First 1
  if (-not $wgt) { Fail "Signing failed. Details: $log" }

  $ip = Get-State 'TV_IP'
  if (-not (Connect-Tv $ip)) { Fail 'Lost the connection to the TV. Check it is on, then run the installer again.' }
  Say 'Installing on the TV…'
  Invoke-Sdb @('-s', "$ip`:26101", 'shell', '0', 'kill', $AppId.Split('.')[0]) | Out-Null
  $log = Join-Path $HomeDir 'install.log'
  & $Tizen install -n $wgt.Name -s "$ip`:26101" -- $outDir *> $log
  if (-not (Select-String -Path $log -Pattern 'successfully installed' -Quiet)) {
    if (Select-String -Path $log -Pattern 'certificate|signature|author|distributor|duid' -Quiet) {
      Warn "This usually means the certificate profile doesn't include this TV's ID ($(Get-State 'DUID'))."
      Warn 'Run the installer with -Reset and redo step 6 with that TV ID.'
    }
    Fail "The TV refused the app. Details: $log"
  }
  & $Tizen run -p $AppId -s "$ip`:26101" *> $null
  Set-State 'INSTALLED_VERSION' $script:RelVersion
  Ok "Lumina $($script:RelVersion) is installed and open on your TV"
  Set-Done 'INSTALL'
}

function Show-Finish {
  Step 8 'Connect your Google Drive'
  Todo '1.' 'On the TV, Lumina shows Home. Press OK on Google Drive (Connect).'
  Todo '2.' 'Scan the QR code with your phone and check it shows the same code as the TV.'
  Todo '3.' "Continue with Google, pick your account, and on 'Google hasn't verified this app'"
  Say  '     choose Advanced, then continue. Allow access.'
  Todo '4.' 'The TV shows your name within a few seconds. Enjoy your Drive on the big screen.'
  Say ''
  Dim 'To update Lumina later: run the installer with -Update'
  Dim 'If the TV restarts with Developer Mode off, turn it on again (step 5) before updating.'
  Dim "Installer notes and logs: $HomeDir"
}

# ================================================================ run

if ($Update) {
  if (-not (Get-State 'PROFILE') -or -not (Get-State 'RELAY_URL')) { Fail 'Run the full installer first.' }
  Get-Release
  if ((Get-State 'INSTALLED_VERSION') -eq $script:RelVersion -and -not (Confirm "Lumina $($script:RelVersion) is already the newest. Reinstall it anyway?")) { exit 0 }
  Connect-TvStep
  Install-App
  Ok 'Update finished'
  exit 0
}

if ($RelayUrl) {
  Set-State 'RELAY_URL' $RelayUrl.TrimEnd('/'); Set-Done 'GOOGLE_A'; Set-Done 'RELAY'; Set-Done 'GOOGLE_B'
  Ok "Using your existing sign-in service at $($RelayUrl.TrimEnd('/'))"
}

if (-not (Test-Done 'TOOLS'))    { Install-Tools }
if (-not (Test-Done 'GOOGLE_A')) { Setup-GoogleA }
if (-not (Test-Done 'RELAY'))    { Setup-Relay }
if (-not (Test-Done 'GOOGLE_B')) { Setup-GoogleB }
if (-not (Test-Done 'TV'))       { Connect-TvStep }
if (-not (Test-Done 'CERT'))     { Setup-Certificate }
if (-not (Test-Done 'INSTALL'))  { Install-App }
Show-Finish
