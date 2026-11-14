# Lumina for Samsung TV

Browse and view your Google Drive on a Samsung TV with the remote: photos,
videos, PDFs and Google Docs. You sign in on your phone by scanning a QR code;
the TV never shows a password form.

This repository holds the installers and the built app. The app is not in
Samsung's app store, so it is installed from your computer using the TV's
Developer Mode, and it signs in through a small service of your own on
Cloudflare's free plan. The installer sets all of that up and tells you what
to do at each step that needs you.

## What you need

- A Samsung TV from 2025 or later (Tizen 9.0 or newer), and its remote
- A Mac, or a Windows PC, on the same network as the TV
- A Google account, a Samsung account and a Cloudflare account (all free)
- About 5 GB of disk space and 45 to 60 minutes the first time

## Install

### Mac

Open Terminal and paste:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rishmarwah/lumina-tv/main/install.sh)
```

### Windows

Open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/rishmarwah/lumina-tv/main/install.ps1 -OutFile $env:TEMP\lumina-install.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\lumina-install.ps1
```

The Windows installer has not yet been tested on a Windows PC. Please report
problems.

## What the installer does

| Step | Done for you | Your part |
|---|---|---|
| 1. Samsung's TV tools | Downloads and installs Tizen Studio's command-line tools and TV add-ons, and Node.js if needed | Accept the licences |
| 2. Google settings | Opens each page | Create a Google Cloud project and a sign-in client; paste the Client ID |
| 3. Sign-in service | Deploys it to your Cloudflare account, makes a random key for video links | Sign in to Cloudflare; paste the Client secret (it goes straight to Cloudflare) |
| 4. Finish Google | Copies the redirect address to your clipboard | Paste it into Google; publish the app |
| 5. Your TV | Finds this computer's address, connects, reads the TV's ID | Turn on Developer Mode; type the TV's address |
| 6. Certificate | Opens Certificate Manager, copies the TV's ID | Create a Samsung certificate with your Samsung account |
| 7. Install | Downloads Lumina, checks it, points it at your service, signs it for your TV, installs and opens it | Nothing |
| 8. Connect Drive | | Scan the QR code on the TV with your phone |

The installer remembers its progress. Stop at any prompt and run it again to
carry on.

## Updating

Run the installer with `--update` (Mac) or `-Update` (Windows). It installs the
newest version, keeping your sign-in service and certificate.

If the TV has been restarted with Developer Mode turned off, turn it on again
first (step 5).

## Privacy

- Your Google sign-in is stored encrypted on your TV.
- Your sign-in service is yours, on your Cloudflare account. It keeps a pairing
  code for at most 10 minutes, in a form only your TV can read, and passes
  videos through without storing them. Request logging is off.
- Lumina asks Google only for read-only access to your Drive.
- The installer never sees your Google client secret, and stores nothing secret.
