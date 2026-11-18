---
name: scraper
description: Download videos, reels and audio (plus title/uploader/duration metadata) from a public link on Facebook, Instagram, TikTok, YouTube, X/Twitter, Vimeo, Reddit and the ~1800 other sites yt-dlp supports. Use when the user pastes a media or share link and asks to download, save, grab, rip or scrape it, wants just the audio/mp3, or wants the metadata of a post.
---

# scraper

Download media from a public URL with `yt-dlp`, merge it into a single playable
file with `ffmpeg`, and hand the file to the user.

## Steps

1. **Check the tools.** `ffmpeg -version` and `python3 -m yt_dlp --version`.
   The script installs or upgrades yt-dlp with pip if it is missing. Sites change
   often, so on an extractor error run `pip install -U yt-dlp` and retry once.
   Without ffmpeg the script only picks pre-muxed formats, so quality may be lower.

2. **Run the script** from the project root:

   ```bash
   python3 .claude/skills/scraper/scripts/scrape.py "<URL>" --out downloads
   ```

   Useful flags:
   - `--audio-only`: extract the audio track as an mp3.
   - `--info-only`: print the metadata and download nothing (use it to check a link first).
   - `--max-height 720`: cap the resolution to keep the file small.
   - `--cookies cookies.txt` or `--cookies-from-browser chrome`: for posts that need a login.
   - `--playlist`: download every item from an album, carousel or playlist.
   - several URLs in one call: all of them are downloaded.

   The script prints one JSON line per item. On success it looks like
   `{"ok": true, "file": "/abs/path.mp4", "title": ..., "duration": ..., "size_mb": ...}`.
   On failure it looks like `{"ok": false, "error": ..., "hint": ...}`.
   An `.info.json` sidecar with the full metadata is written next to each file;
   pass `--no-info-json` to skip it.

3. **Verify the file.** Run
   `ffprobe -v error -show_entries format=duration:stream=codec_type,width,height -of compact <file>`.
   It should show both a video and an audio stream, and its duration should match the
   duration in the metadata.

4. **Deliver it.** Send the file to the user (SendUserFile, `display: "attach"`),
   then report the title, uploader, duration, resolution and size.
   Don't commit media files to git unless the user asks: they are large, and the
   copyright belongs to their creators.

## Site notes

- **Facebook**: `facebook.com/share/r/<code>`, `/share/v/<code>`, `/reel/<id>`,
  `/watch?v=<id>`, `fb.watch/<code>` and `/<page>/videos/<id>` all work. Share links
  redirect to the canonical reel or video first. Video bytes come from a regional
  `video-*.xx.fbcdn.net` host. Posts that are private, in a group, or age-gated
  need `--cookies`.
- **Instagram**: reels and posts often need a login, so use `--cookies`.
  Use `--playlist` for carousels.
- **TikTok, YouTube, X, Vimeo, Reddit**: public posts work as they are.

## When it fails

| Symptom | Cause / fix |
|---|---|
| `Tunnel connection failed: 403`, `ProxyError` | The sandbox network policy blocks the host. In a Claude Code cloud session, add the site's hosts (e.g. `www.facebook.com`, `facebook.com`, `m.facebook.com`, `web.facebook.com`, plus the CDN host shown in the next error) to the environment's allowed domains, then retry. Don't route around the policy. |
| `login required`, `This video is only available for registered users`, `private` | Pass `--cookies` with a Netscape-format cookies.txt exported from a logged-in browser. |
| `Unsupported URL` | Upgrade yt-dlp. If that doesn't help, open the share link in a browser and use the canonical URL it redirects to. |
| `CERTIFICATE_VERIFY_FAILED` | The script already uses `SSL_CERT_FILE` instead of certifi when that variable is set; make sure it points at the proxy's CA bundle. |
| Video has no sound | ffmpeg is missing, so only the video-only stream was saved. Install ffmpeg and rerun. |

Only download content the user is entitled to save (their own, public, or
licensed). Don't try to get around paywalls, DRM or private-account restrictions.
