#!/bin/bash
# Lumina installer for macOS.
#
# Puts the Lumina Google Drive viewer on a Samsung TV (2025 or newer). It
# installs the tools it needs, walks you through the steps only you can do
# (accounts, TV settings), and remembers where it got to: run it again and it
# carries on from there.
#
#   bash install.sh             set up, or carry on where you left off
#   bash install.sh --update    install the newest Lumina on your TV
#   bash install.sh --reset     forget all progress and start again
#
# Nothing here needs your Mac password. Your Google client secret is typed
# straight into Cloudflare's tool and is never stored by this script.

set -u

REPO_RAW="${LUMINA_REPO_RAW:-https://raw.githubusercontent.com/rishmarwah/lumina-tv/main}"
HOME_DIR="$HOME/.lumina-installer"
STATE="$HOME_DIR/state"
TIZEN_DIR="${LUMINA_TIZEN_DIR:-$HOME/tizen-studio}"
TIZEN_VERSION="6.1"
TIZEN_CLI_URL="https://download.tizen.org/sdk/Installer/tizen-studio_${TIZEN_VERSION}/web-cli_Tizen_Studio_${TIZEN_VERSION}_macos-64.bin"
WRANGLER="wrangler@4"
APP_ID="LuminaTV01.Lumina"
PLACEHOLDER="https://relay.lumina.invalid"

MODE="setup"
RELEASE_DIR=""
for arg in "$@"; do
  case "$arg" in
    --update) MODE="update" ;;
    --reset) MODE="reset" ;;
    --release-dir=*) RELEASE_DIR="${arg#*=}" ;;   # testing: use a local release
    --relay-url=*) PRESET_RELAY="${arg#*=}" ;;    # you already have a relay
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; D=""; G=""; Y=""; R=""; C=""; N=""
fi

TOTAL_STEPS=8
step()  { printf "\n${B}${C}━━ Step %s of %s · %s${N}\n\n" "$1" "$TOTAL_STEPS" "$2"; }
say()   { printf "%s\n" "$*"; }
dim()   { printf "${D}%s${N}\n" "$*"; }
ok()    { printf "${G}✔ %s${N}\n" "$*"; }
warn()  { printf "${Y}! %s${N}\n" "$*"; }
fail()  { printf "${R}✘ %s${N}\n" "$*" >&2; }
todo()  { printf "  ${B}%s${N} %s\n" "$1" "$2"; }   # numbered instruction

# Read from the terminal even when the script itself came through a pipe.
ask() {   # ask "Question" VAR [default]
  local prompt="$1" var="$2" def="${3:-}" reply
  if [ -n "$def" ]; then printf "${B}%s${N} [%s]: " "$prompt" "$def"; else printf "${B}%s${N}: " "$prompt"; fi
  IFS= read -r reply </dev/tty || reply=""
  [ -z "$reply" ] && reply="$def"
  eval "$var=\$reply"
}

confirm() {   # confirm "Question" -> 0 for yes
  local reply
  printf "${B}%s${N} [y/n]: " "$1"
  IFS= read -r reply </dev/tty || reply=""
  case "$reply" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

wait_enter() {
  printf "\n${B}Press Enter when you have done this${N} ${D}(or type q to stop; run the installer again to carry on)${N} "
  local reply
  IFS= read -r reply </dev/tty || reply=""
  case "$reply" in q|Q) say "Stopped. Run the installer again to carry on from here."; exit 0 ;; esac
}

open_url() { open "$1" >/dev/null 2>&1 || true; dim "  (opened in your browser: $1)"; }

# ---------------------------------------------------------------- state

mkdir -p "$HOME_DIR"
chmod 700 "$HOME_DIR"
touch "$STATE"
chmod 600 "$STATE"

get() { grep -E "^$1=" "$STATE" | tail -1 | cut -d= -f2-; }
set_state() {   # set_state KEY value   (values never contain secrets)
  local tmp="$STATE.tmp"
  grep -vE "^$1=" "$STATE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$STATE"
}
done_step() { [ "$(get "DONE_$1")" = "1" ]; }
mark_done() { set_state "DONE_$1" 1; }

if [ "$MODE" = "reset" ]; then
  if confirm "Forget all installer progress? (Your TV, accounts and installed app are not touched)"; then
    rm -f "$STATE"; ok "Progress cleared. Run the installer again to start over."
  fi
  exit 0
fi

TIZEN="$TIZEN_DIR/tools/ide/bin/tizen"
SDB="$TIZEN_DIR/tools/sdb"

# ---------------------------------------------------------------- helpers

need_internet() {
  if ! curl -fsS --max-time 10 -o /dev/null https://www.google.com/generate_204; then
    fail "This Mac is not online. Connect to the internet and run the installer again."
    exit 1
  fi
}

this_mac_ip() {
  local ifc ip
  ifc=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  ip=$(ipconfig getifaddr "${ifc:-en0}" 2>/dev/null)
  [ -z "$ip" ] && ip=$(ipconfig getifaddr en0 2>/dev/null)
  [ -z "$ip" ] && ip=$(ipconfig getifaddr en1 2>/dev/null)
  printf '%s' "$ip"
}

node_bin() {
  if command -v node >/dev/null 2>&1; then
    local major; major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
    if [ "${major:-0}" -ge 20 ]; then command -v node; return; fi
  fi
  [ -x "$HOME_DIR/node/bin/node" ] && printf '%s' "$HOME_DIR/node/bin/node"
}

run_wrangler() {   # runs wrangler from the relay folder; reads nothing from stdin
  local node; node=$(node_bin)
  ( cd "$HOME_DIR/relay" && PATH="$(dirname "$node"):$PATH" npx --yes "$WRANGLER" "$@" ) </dev/null
}

run_wrangler_tty() {   # the same, for steps where you type or a browser opens
  local node; node=$(node_bin)
  ( cd "$HOME_DIR/relay" && PATH="$(dirname "$node"):$PATH" npx --yes "$WRANGLER" "$@" ) </dev/tty
}

run_wrangler_stdin() {   # the same, reading a value piped in by this script
  local node; node=$(node_bin)
  ( cd "$HOME_DIR/relay" && PATH="$(dirname "$node"):$PATH" npx --yes "$WRANGLER" "$@" )
}

sdb_try() {   # sdb with a time limit: a sleeping TV can make sdb hang
  "$SDB" "$@" </dev/null 2>&1 &
  local pid=$!
  ( sleep 20; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local killer=$!
  disown "$killer" 2>/dev/null   # so its end is not reported as "Terminated"
  wait "$pid" 2>/dev/null
  local code=$?
  kill "$killer" 2>/dev/null
  return $code
}

# Connect to the TV. After the TV has slept, sdb's background service on this
# computer can get stuck refusing to reconnect; restarting it fixes that.
tv_connect() {   # tv_connect IP -> 0 when the TV is connected and ready
  local ip="$1" attempt
  for attempt in 1 2 3; do
    if sdb_try connect "$ip" | grep -qE "connected to|already connected" &&
       sdb_try devices | grep -q "^$ip:26101[[:space:]]*device"; then
      return 0
    fi
    sdb_try kill-server >/dev/null
    sleep 1
    sdb_try start-server >/dev/null
    sleep 2
  done
  return 1
}

download_release() {   # sets REL_DIR, REL_VERSION
  REL_DIR="$HOME_DIR/release"
  rm -rf "$REL_DIR"; mkdir -p "$REL_DIR"
  local base latest
  if [ -n "$RELEASE_DIR" ]; then
    base="file://$RELEASE_DIR"
  else
    base="$REPO_RAW"
  fi
  if ! curl -fsSL "$base/latest.json" -o "$REL_DIR/latest.json"; then
    fail "Couldn't download the release list from $base/latest.json"
    exit 1
  fi
  latest="$REL_DIR/latest.json"
  json() { /usr/bin/perl -ne 'print $1 if /"'"$1"'"\s*:\s*"([^"]*)"/' "$latest"; }
  REL_VERSION=$(json version)
  local app relay app_sha relay_sha
  app=$(json app); relay=$(json relay); app_sha=$(json appSha256); relay_sha=$(json relaySha256)
  curl -fsSL "$base/$app" -o "$REL_DIR/app.zip" && curl -fsSL "$base/$relay" -o "$REL_DIR/relay.js" || {
    fail "Couldn't download Lumina $REL_VERSION."; exit 1; }
  if [ "$(shasum -a 256 "$REL_DIR/app.zip" | cut -d' ' -f1)" != "$app_sha" ] ||
     [ "$(shasum -a 256 "$REL_DIR/relay.js" | cut -d' ' -f1)" != "$relay_sha" ]; then
    fail "The downloaded files don't match their published checksums. Nothing was installed. Try again later."
    exit 1
  fi
  ok "Downloaded Lumina $REL_VERSION (checksums verified)"
}

# ================================================================ intro

clear 2>/dev/null || true
printf "${B}Lumina installer${N}  ${D}· Google Drive on your Samsung TV${N}\n\n"

if [ "$MODE" = "setup" ] && [ -z "$(get STARTED)" ]; then
  say "This puts Lumina on your Samsung TV. Allow 45 to 60 minutes the first time;"
  say "most of it is downloads. You will need:"
  say ""
  todo "•" "a Samsung TV from 2025 or later, on the same Wi-Fi as this Mac"
  todo "•" "the TV remote"
  todo "•" "a Google account (the one whose Drive you want on the TV)"
  todo "•" "a Samsung account (free; for the developer certificate)"
  todo "•" "a Cloudflare account (free; for your own small sign-in service)"
  todo "•" "about 5 GB of free disk space"
  say ""
  dim "The installer saves its progress. You can stop at any prompt and run it again later."
  say ""
  confirm "Ready to start?" || exit 0
  set_state STARTED "$(date +%Y-%m-%d)"
fi

need_internet

# ================================================================ 1. tools

install_tools() {
  step 1 "Samsung's TV tools (Tizen Studio)"
  if [ "$(uname -s)" != "Darwin" ]; then fail "This installer is for macOS. On Windows use install.ps1."; exit 1; fi

  if [ "$(uname -m)" = "arm64" ] && ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    warn "Samsung's tools are built for Intel Macs and need Apple's Rosetta 2 on this Mac."
    say  "Run this in Terminal (it asks for your Mac password and Apple's licence):"
    say  ""
    say  "    softwareupdate --install-rosetta --agree-to-license"
    wait_enter
    /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || { fail "Rosetta 2 is still missing."; exit 1; }
  fi

  if [ -x "$TIZEN" ] && [ -x "$SDB" ]; then
    ok "Tizen tools found in $TIZEN_DIR"
  else
    say "Lumina is installed with Samsung's free Tizen Studio command-line tools."
    say "Download: about 280 MB now, then about 3 GB of TV add-ons."
    say ""
    say "Using them means accepting the Tizen SDK licence and Samsung's TV extension"
    say "licences. Read them here before you agree:"
    say "  https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html"
    say ""
    confirm "Do you accept these licences and want to install the tools now?" || { say "Stopped. Nothing was installed."; exit 0; }
    local dl="$HOME_DIR/downloads"; mkdir -p "$dl"
    say "Downloading Tizen Studio $TIZEN_VERSION…"
    curl -fL -C - --retry 3 -o "$dl/tizen-cli.bin" "$TIZEN_CLI_URL" || { fail "Download failed. Run the installer again to resume."; exit 1; }
    chmod +x "$dl/tizen-cli.bin"
    say "Installing into $TIZEN_DIR…"
    "$dl/tizen-cli.bin" --accept-license "$TIZEN_DIR" </dev/null >"$HOME_DIR/tizen-install.log" 2>&1 || {
      fail "Tizen Studio didn't install. Details: $HOME_DIR/tizen-install.log"; exit 1; }
    ok "Tizen Studio installed"
  fi

  local pm="$TIZEN_DIR/package-manager/package-manager-cli.bin"
  if [ "$("$pm" show-pkgs </dev/null 2>/dev/null | grep -cE '^i[[:space:]]+(TV-SAMSUNG-Public-WebAppDevelopment|cert-add-on)[[:space:]]')" -ge 2 ]; then
    ok "TV add-ons already installed"
  else
    say "Installing the TV add-ons (several GB; often 10 to 30 minutes)…"
    "$pm" install --accept-license Certificate-Manager cert-add-on TV-SAMSUNG-Public-WebAppDevelopment TV-SAMSUNG-Extension-Tools \
      </dev/null >"$HOME_DIR/tizen-packages.log" 2>&1 || {
      fail "The TV add-ons didn't install. Details: $HOME_DIR/tizen-packages.log"; exit 1; }
    ok "TV add-ons installed"
  fi

  if [ -z "$(node_bin)" ]; then
    say ""
    say "The sign-in service is set up with Cloudflare's tool, which needs Node.js."
    say "The installer can put a private copy in $HOME_DIR/node (about 50 MB, no password)."
    confirm "Download Node.js from nodejs.org?" || { say "Stopped."; exit 0; }
    local arch=x64; [ "$(uname -m)" = "arm64" ] && arch=arm64
    local ver; ver=$(curl -fsSL https://nodejs.org/dist/index.json | /usr/bin/perl -ne 'if (/"version":"(v[0-9.]+)"[^}]*"lts":"/) { print $1; exit }')
    [ -z "$ver" ] && { fail "Couldn't find the current Node.js version."; exit 1; }
    local f="node-$ver-darwin-$arch.tar.gz" dl="$HOME_DIR/downloads"
    mkdir -p "$dl"
    curl -fsSL -o "$dl/$f" "https://nodejs.org/dist/$ver/$f" && curl -fsSL -o "$dl/SHASUMS256.txt" "https://nodejs.org/dist/$ver/SHASUMS256.txt" || {
      fail "Node.js download failed."; exit 1; }
    ( cd "$dl" && grep " $f\$" SHASUMS256.txt | shasum -a 256 -c - >/dev/null ) || { fail "Node.js checksum didn't match. Nothing installed."; exit 1; }
    rm -rf "$HOME_DIR/node"; mkdir -p "$HOME_DIR/node"
    tar -xzf "$dl/$f" -C "$HOME_DIR/node" --strip-components=1
    ok "Node.js $ver ready"
  else
    ok "Node.js found"
  fi
  mark_done TOOLS
}

# ================================================================ 2-4. sign-in service

google_part_a() {
  step 2 "Your Google sign-in settings (Google Cloud)"
  say "Lumina reads your Drive with permission you grant through your own Google Cloud"
  say "project. It's free. In your browser, signed in with your Google account:"
  say ""
  todo "1." "Create a project, for example named Lumina."
  open_url "https://console.cloud.google.com/projectcreate"
  wait_enter
  todo "2." "Enable the Google Drive API for that project (check the project name at the top)."
  open_url "https://console.cloud.google.com/apis/library/drive.googleapis.com"
  wait_enter
  todo "3." "Set up Google Auth Platform: app name Lumina, your email as support and"
  say  "     developer contact, Audience: External."
  open_url "https://console.cloud.google.com/auth/overview"
  wait_enter
  todo "4." "Data Access > Add or remove scopes. Add these four, then Save:"
  say  "       openid    email    profile"
  say  "       https://www.googleapis.com/auth/drive.readonly"
  open_url "https://console.cloud.google.com/auth/scopes"
  wait_enter
  todo "5." "Clients > Create client > type Web application, name Lumina. Leave the"
  say  "     redirect address empty for now. Create it, and keep that page open:"
  say  "     you'll need the Client ID now and the Client secret in step 3."
  open_url "https://console.cloud.google.com/auth/clients/create"
  say ""
  local id=""
  while :; do
    ask "Paste the Client ID (ends in .apps.googleusercontent.com)" id
    id=$(printf '%s' "$id" | tr -d '[:space:]')
    if printf '%s' "$id" | grep -Eq '^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$'; then break; fi
    warn "That doesn't look like a Client ID. It looks like 1234-abc….apps.googleusercontent.com"
  done
  set_state CLIENT_ID "$id"
  ok "Client ID saved"
  mark_done GOOGLE_A
}

cloudflare_relay() {
  step 3 "Your sign-in service (Cloudflare, free)"
  say "A tiny service of your own handles sign-in from your phone and streams videos to"
  say "the TV. It runs on Cloudflare's free plan, under your account."
  say ""
  todo "1." "If you don't have a Cloudflare account, create one (free)."
  open_url "https://dash.cloudflare.com/sign-up"
  wait_enter

  download_release
  mkdir -p "$HOME_DIR/relay"
  cp "$REL_DIR/relay.js" "$HOME_DIR/relay/worker.js"
  printf '{ "name": "lumina-relay-installer", "private": true }\n' > "$HOME_DIR/relay/package.json"

  todo "2." "Sign Cloudflare's tool in to your account: a browser page opens; choose Allow."
  run_wrangler whoami 2>/dev/null | grep -q "You are logged in" || run_wrangler_tty login || { fail "Cloudflare sign-in didn't finish."; exit 1; }
  ok "Signed in to Cloudflare"

  # Storage for pairing codes. Reuse it if an earlier run made it.
  local kv; kv=$(get KV_ID)
  if [ -z "$kv" ]; then
    printf 'name = "lumina-relay"\nmain = "worker.js"\ncompatibility_date = "2026-11-01"\n' > "$HOME_DIR/relay/wrangler.toml"
    kv=$(run_wrangler kv namespace create PAIRINGS 2>&1 | grep -oE 'id = "[0-9a-f]+"' | grep -oE '[0-9a-f]{20,}' | head -1)
    if [ -z "$kv" ]; then
      kv=$(run_wrangler kv namespace list 2>/dev/null | "$(node_bin)" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const l=JSON.parse(s);const n=l.find(x=>/(^|-)PAIRINGS$/.test(x.title));if(n)process.stdout.write(n.id)}catch{}})')
    fi
    [ -z "$kv" ] && { fail "Couldn't create Cloudflare storage for pairing codes."; exit 1; }
    set_state KV_ID "$kv"
  fi

  cat > "$HOME_DIR/relay/wrangler.toml" <<EOF
name = "lumina-relay"
main = "worker.js"
compatibility_date = "2026-11-01"

[observability]
enabled = false

[vars]
GOOGLE_CLIENT_ID = "$(get CLIENT_ID)"

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
EOF

  say "Deploying your sign-in service…"
  local out url
  out=$(run_wrangler deploy 2>&1 | tee "$HOME_DIR/relay-deploy.log")
  url=$(printf '%s' "$out" | grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -1)
  [ -z "$url" ] && { fail "Deploy didn't report an address. Details: $HOME_DIR/relay-deploy.log"; exit 1; }
  set_state RELAY_URL "$url"
  ok "Sign-in service deployed at $url"

  # A random key for video links, made here and sent straight to Cloudflare.
  openssl rand -base64 48 | tr -d '\n' | run_wrangler_stdin secret put TICKET_KEY >/dev/null 2>&1 || { fail "Couldn't store the video-link key."; exit 1; }

  say ""
  todo "3." "Now the Client secret from the Google page you kept open. Paste it at the prompt"
  say  "     below. It is sent straight to Cloudflare; this installer never sees or keeps it."
  run_wrangler_tty secret put GOOGLE_CLIENT_SECRET || { fail "The client secret wasn't stored. Run the installer again to retry."; exit 1; }
  ok "Client secret stored in Cloudflare"

  say "Waiting for the new address to come online (usually 1 to 5 minutes)…"
  local i=0
  until curl -fsS -o /dev/null --max-time 10 "$url/pair"; do
    i=$((i + 1)); [ $i -gt 60 ] && { fail "The service didn't come online. Run the installer again in a few minutes."; exit 1; }
    sleep 10
  done
  ok "Sign-in service is online"
  mark_done RELAY
}

google_part_b() {
  step 4 "Finish the Google settings"
  local url; url=$(get RELAY_URL)
  todo "1." "In Clients, open the Lumina client and add this Authorized redirect URI, then Save:"
  say  ""
  say  "       $url/auth/callback"
  printf '%s' "$url/auth/callback" | pbcopy 2>/dev/null && dim "       (copied to your clipboard)"
  open_url "https://console.cloud.google.com/auth/clients"
  wait_enter
  todo "2." "Audience > Publishing status > Publish app (In production)."
  say  "     In 'Testing', Google signs the TV out every 7 days. Published but unverified"
  say  "     is fine for your own use: Google shows a one-time 'unverified app' warning."
  open_url "https://console.cloud.google.com/auth/audience"
  wait_enter
  mark_done GOOGLE_B
}

# ================================================================ 5. TV

connect_tv() {
  step 5 "Connect to your TV"
  local mac_ip; mac_ip=$(this_mac_ip)
  [ -z "$mac_ip" ] && { fail "This Mac has no network address. Connect to Wi-Fi and try again."; exit 1; }
  if [ "$MODE" = "setup" ] || [ -z "$(get TV_IP)" ]; then
    say "Turn on Developer Mode on the TV, so this Mac is allowed to install an app on it:"
    say ""
    todo "1." "Update the TV first: Settings > Support > Software Update."
    todo "2." "Open Apps on the TV. Type 1 2 3 4 5 on the remote (on a remote without number"
    say  "     keys press the 123 button, or use the SmartThings app's remote on your phone)."
    todo "3." "Switch Developer mode On and enter this Mac's address:  ${B}$mac_ip${N}"
    todo "4." "Restart the TV: hold the remote's power button until the Samsung logo appears."
    todo "5." "Find the TV's own address: Settings > Connection > Network > Network Status >"
    say  "     IP Settings."
    say ""
  fi
  local ip; ip=$(get TV_IP)
  while :; do
    ask "The TV's IP address" ip "$ip"
    printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { warn "That isn't an address like 192.168.1.20"; continue; }
    say "Connecting…"
    tv_connect "$ip" && break
    warn "The TV didn't answer. Check: same Wi-Fi, Developer mode On with $mac_ip, TV restarted after."
    confirm "Try again?" || exit 1
  done
  set_state TV_IP "$ip"
  local duid ver
  duid=$(sdb_try -s "$ip:26101" shell 0 getduid | tr -d '\r' | tail -1)
  ver=$(sdb_try -s "$ip:26101" capability | tr -d '\r' | grep '^platform_version' | cut -d: -f2)
  [ -n "$duid" ] && set_state DUID "$duid"
  ok "Connected to the TV (model ID $(get DUID), Tizen ${ver:-unknown})"
  case "$ver" in
    9.*|1[0-9].*) ;;
    *) warn "Lumina needs Tizen 9.0 or newer (Samsung TVs from 2025). This TV reports ${ver:-nothing}; installing may fail." ;;
  esac
  mark_done TV
}

# ================================================================ 6. certificate

certificate() {
  step 6 "Your Samsung developer certificate"
  if [ -n "$(get PROFILE)" ] && "$TIZEN" security-profiles list </dev/null 2>/dev/null | grep -q "^$(get PROFILE)[[:space:]]"; then
    ok "Using certificate profile $(get PROFILE)"
    mark_done CERT; return
  fi
  local duid; duid=$(get DUID)
  local before; before=$("$TIZEN" security-profiles list </dev/null 2>/dev/null | awk 'NR>2{print $1}' | sort)
  say "Samsung TVs only install apps signed for that TV. Certificate Manager is opening."
  printf '%s' "$duid" | pbcopy 2>/dev/null && dim "(Your TV's ID is on the clipboard: $duid)"
  open "$TIZEN_DIR/tools/certificate-manager/certificate-manager.app" 2>/dev/null || true
  say ""
  todo "1." "Click + , choose Samsung, then TV. Name the profile lumina."
  todo "2." "Create a new author certificate: any name, and a password you'll remember."
  say  "     Sign in with your Samsung account when the browser asks (create one if needed)."
  todo "3." "Create a new distributor certificate, privilege Public, and paste this TV ID:"
  say  "       ${B}$duid${N}"
  todo "4." "Finish. The new profile shows with a tick."
  wait_enter
  local after new
  after=$("$TIZEN" security-profiles list </dev/null 2>/dev/null | awk 'NR>2{print $1}' | sort)
  new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
  if [ -z "$new" ]; then
    say "Your certificate profiles:"; printf '%s\n' "$after" | sed 's/^/   /'
    ask "Which profile is for this TV?" new "$(printf '%s\n' "$after" | head -1)"
  fi
  "$TIZEN" security-profiles list </dev/null 2>/dev/null | grep -q "^$new[[:space:]]" || { fail "No certificate profile named '$new'."; exit 1; }
  set_state PROFILE "$new"
  ok "Using certificate profile $new"
  mark_done CERT
}

# ================================================================ 7. install

install_app() {
  step 7 "Install Lumina on the TV"
  [ -n "${REL_DIR:-}" ] && [ -f "$REL_DIR/app.zip" ] || download_release
  local relay; relay=$(get RELAY_URL)
  relay="${relay%/}"
  local work="$HOME_DIR/build"; rm -rf "$work"; mkdir -p "$work/app" "$work/out"
  unzip -q "$REL_DIR/app.zip" -d "$work/app"
  # Point the app at your own sign-in service.
  local f n=0
  for f in "$work/app/index.html" "$work/app/config.xml" "$work/app"/assets/*.js; do
    [ -f "$f" ] || continue
    if grep -qF "$PLACEHOLDER" "$f"; then
      RELAY="$relay" PH="$PLACEHOLDER" /usr/bin/perl -pi -e 's/\Q$ENV{PH}\E/$ENV{RELAY}/g' "$f"; n=$((n + 1))
    fi
  done
  [ $n -ge 3 ] || { fail "This release doesn't have the expected settings placeholder. Nothing installed."; exit 1; }
  grep -rqF "$PLACEHOLDER" "$work/app" && { fail "Couldn't set the sign-in address everywhere. Nothing installed."; exit 1; }

  say "Signing for your TV…"
  "$TIZEN" package -t wgt -s "$(get PROFILE)" -o "$work/out" -- "$work/app" </dev/null >"$HOME_DIR/package.log" 2>&1 || {
    fail "Signing failed. Details: $HOME_DIR/package.log"; exit 1; }
  local wgt; wgt=$(ls "$work/out"/*.wgt | head -1)

  local ip; ip=$(get TV_IP)
  tv_connect "$ip" || { fail "Lost the connection to the TV. Check it is on, then run the installer again."; exit 1; }
  say "Installing on the TV…"
  sdb_try -s "$ip:26101" shell 0 kill "${APP_ID%%.*}" >/dev/null
  if ! "$TIZEN" install -n "$(basename "$wgt")" -s "$ip:26101" -- "$work/out" </dev/null >"$HOME_DIR/install.log" 2>&1 ||
     ! grep -q "successfully installed" "$HOME_DIR/install.log"; then
    fail "The TV refused the app. Details: $HOME_DIR/install.log"
    if grep -qiE "certificate|signature|author|distributor|duid" "$HOME_DIR/install.log"; then
      say "This usually means the certificate profile doesn't include this TV's ID ($(get DUID))."
      say "Run:  bash install.sh --reset   and redo step 6 with the TV ID above."
    fi
    exit 1
  fi
  "$TIZEN" run -p "$APP_ID" -s "$ip:26101" </dev/null >/dev/null 2>&1 || true
  set_state INSTALLED_VERSION "$REL_VERSION"
  ok "Lumina $REL_VERSION is installed and open on your TV"
  mark_done INSTALL
}

finish() {
  step 8 "Connect your Google Drive"
  todo "1." "On the TV, Lumina shows Home. Press OK on Google Drive (Connect)."
  todo "2." "Scan the QR code with your phone and check it shows the same code as the TV."
  todo "3." "Continue with Google, pick your account, and on 'Google hasn't verified this app'"
  say  "     choose Advanced, then continue. Allow access."
  todo "4." "The TV shows your name within a few seconds. Enjoy your Drive on the big screen."
  say ""
  dim "To update Lumina later:   bash install.sh --update"
  dim "If the TV restarts with Developer Mode off, turn it on again (step 5) before updating."
  dim "Installer notes and logs:  $HOME_DIR"
}

# ================================================================ run

if [ "$MODE" = "update" ]; then
  [ -n "$(get PROFILE)" ] && [ -n "$(get RELAY_URL)" ] || { fail "Run the full installer first:  bash install.sh"; exit 1; }
  download_release
  if [ "$(get INSTALLED_VERSION)" = "$REL_VERSION" ] && ! confirm "Lumina $REL_VERSION is already the newest. Reinstall it anyway?"; then exit 0; fi
  connect_tv
  install_app
  ok "Update finished"
  exit 0
fi

if [ -n "${PRESET_RELAY:-}" ]; then
  set_state RELAY_URL "${PRESET_RELAY%/}"; mark_done GOOGLE_A; mark_done RELAY; mark_done GOOGLE_B
  ok "Using your existing sign-in service at ${PRESET_RELAY%/}"
fi

done_step TOOLS    || install_tools
done_step GOOGLE_A || google_part_a
done_step RELAY    || cloudflare_relay
done_step GOOGLE_B || google_part_b
done_step TV       || connect_tv
done_step CERT     || certificate
done_step INSTALL  || install_app
finish
