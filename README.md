# Lumina for Samsung TV

Browse and view your Google Drive on your TV with the remote: photos,
videos, PDFs and Google Docs. For Samsung TVs (2025 and later) and, as a test
version, Android TVs such as Sony's. You sign in on your phone by scanning a QR code;
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
- About 4 GB of free space **on the computer** (not the TV; see below), and
  45 to 60 minutes the first time

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

## Android TV (Sony and other Android TVs) · test version

For Android TV 9 or newer, such as Sony's 2020 A8H. No computer needed. This
test version signs in through the author's own sign-in service; it is meant
for trying Lumina with people the author knows.

On the TV, with the remote:

1. **Install Downloader.** Open the Google Play Store on the TV, search for
   **Downloader** (by AFTVnews) and install it.
2. **Allow it to install apps.** Settings > Device Preferences > Security &
   restrictions > Unknown sources > turn on **Downloader**. (On some TVs the
   path is Settings > Apps > Security & restrictions.)
3. **Download Lumina.** Open Downloader, select the address box and type:

   ```
   raw.githubusercontent.com/rishmarwah/lumina-tv/main/tv.apk
   ```

   Choose **Go**, then **Install** when asked, then **Done**. Downloader may
   offer to delete the downloaded file afterwards; that's fine.
4. **Open Lumina** from the Apps row (the banner with the glass prints).
5. **Connect Google Drive.** Press OK on Google Drive (Connect), scan the QR
   code with your phone, choose your Google account, and on "Google hasn't
   verified this app" choose **Advanced**, then continue. Allow access.

**Keep Android System WebView up to date** (Play Store > My apps). Lumina runs
on it; very old versions can't open PDFs beyond their first page.

**Updating:** repeat step 3. Your sign-in is kept.

Remote keys: arrows and OK to move and choose, Back to go up a level, Play/Pause
for slideshows and video, Channel Up/Down (or Next/Previous) to change file.

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

## Disk space

The space is needed **on your Mac or PC, not on the TV**. On the TV, Lumina
takes about 6 MB.

The computer needs Samsung's TV tools to sign Lumina for your TV and send it
over Wi-Fi. They are large:

| On the computer | Size |
|---|---|
| Samsung's Tizen Studio tools (`tizen-studio`) | 3.0 GB |
| Java, which Samsung's tools bring with them (`.package-manager`) | 0.3 GB |
| Node.js and Cloudflare's tool, for setting up your sign-in service | 0.4 GB |
| The installer's own files and downloads (`.lumina-installer`) | 0.3 GB |
| **Total** | **about 4 GB** |

Your sign-in service takes no space on the computer: it runs in your
Cloudflare account.

### Getting the space back

Once Lumina is on your TV, you can delete Samsung's tools and the downloads,
and Lumina keeps working on the TV. These are safe to delete:

| Delete | Where |
|---|---|
| `tizen-studio` | Mac: your home folder. Windows: `C:\tizen-studio` |
| `.package-manager` | your home folder |
| `downloads` and `node` | inside `.lumina-installer` in your home folder |
| `.npm` (Node's download cache) | your home folder |

**Keep these:**

- **`SamsungCertificate`** in your home folder. It is tiny, and every future
  update must be signed with the same certificate. Samsung cannot recover it.
- **The rest of `.lumina-installer`**: it remembers your TV, your sign-in
  service and your certificate, so updating doesn't mean setting up again.

Updating later downloads the tools again, so the 4 GB is needed again while
you update.

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
