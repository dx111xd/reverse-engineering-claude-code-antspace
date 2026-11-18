#!/usr/bin/env python3
"""scraper: download video/audio + metadata from a public media URL via yt-dlp.

Works with Facebook (reels, /share/r/ and /share/v/ links, watch pages),
Instagram, TikTok, YouTube, X/Twitter, Vimeo, Reddit and the ~1800 other
sites yt-dlp supports.

Usage:
  scrape.py URL [URL ...] [--out DIR] [--audio-only] [--info-only]
            [--max-height N] [--format SPEC] [--cookies FILE]
            [--cookies-from-browser BROWSER]

Prints one JSON object per URL on stdout: {"ok": true, "file": ..., ...}
or {"ok": false, "error": ..., "hint": ...}. Exit code is non-zero if any
URL failed.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys


def load_yt_dlp():
    try:
        import yt_dlp  # noqa: F401
    except ImportError:
        print("yt-dlp not found, installing...", file=sys.stderr)
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "-q", "-U", "yt-dlp"]
        )
    import yt_dlp

    return yt_dlp


def hint_for(err: str) -> str:
    e = err.lower()
    if "tunnel connection failed: 403" in e or "proxyerror" in e or "connect tunnel failed" in e:
        return ("The network proxy refused this host. The environment's network "
                "policy must allow the site (and its video CDN host) before it can be downloaded.")
    if "login" in e or "cookies" in e or "private" in e or "not available" in e:
        return ("The site wants a logged-in session or the post is private/removed. "
                "Retry with --cookies cookies.txt (Netscape format, exported from a "
                "browser that is logged in) or --cookies-from-browser chrome.")
    if "unsupported url" in e:
        return "yt-dlp has no extractor for this URL; try the canonical post URL instead of a share/short link."
    if "ffmpeg" in e:
        return "ffmpeg is needed to merge audio+video or extract audio; install it (apt-get install -y ffmpeg)."
    if "certificate" in e or "ssl" in e:
        return "TLS verification failed; make sure SSL_CERT_FILE points at the CA bundle the proxy uses."
    return ""


def build_opts(args):
    have_ffmpeg = shutil.which("ffmpeg") is not None
    os.makedirs(args.out, exist_ok=True)
    # Audio-only gets its own name: the audio extractor deletes its source file,
    # which must never be a video the user downloaded earlier into the same dir.
    suffix = ".audio" if args.audio_only else ""
    opts = {
        "outtmpl": os.path.join(args.out, f"%(extractor)s_%(id)s_%(title).60B{suffix}.%(ext)s"),
        "restrictfilenames": True,
        "noplaylist": not args.playlist,
        "writeinfojson": not args.no_info_json,
        "quiet": True,
        "no_warnings": False,
        "noprogress": True,
        "retries": 5,
        "fragment_retries": 5,
        "concurrent_fragment_downloads": 4,
    }
    # Behind a TLS-intercepting proxy, use the CA bundle from the environment
    # (SSL_CERT_FILE) instead of certifi's bundled roots.
    if os.environ.get("SSL_CERT_FILE") or os.environ.get("REQUESTS_CA_BUNDLE"):
        opts["compat_opts"] = {"no-certifi"}
    if args.cookies:
        opts["cookiefile"] = args.cookies
    if args.cookies_from_browser:
        opts["cookiesfrombrowser"] = (args.cookies_from_browser,)

    if args.audio_only:
        opts["format"] = "bestaudio/best"
        if have_ffmpeg:
            opts["postprocessors"] = [{
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "192",
            }]
    elif args.format:
        opts["format"] = args.format
    else:
        h = f"[height<={args.max_height}]" if args.max_height else ""
        if have_ffmpeg:
            # Best video+audio merged into an mp4 that plays everywhere.
            opts["format"] = f"bv*{h}[ext=mp4]+ba[ext=m4a]/bv*{h}+ba/b{h}/b"
            opts["merge_output_format"] = "mp4"
        else:
            # Without ffmpeg only pre-muxed formats are usable.
            opts["format"] = f"b{h}[acodec!=none][vcodec!=none]/b"
    return opts


def final_path(ydl, info, audio_only):
    reqs = info.get("requested_downloads") or []
    if reqs and reqs[-1].get("filepath"):
        return reqs[-1]["filepath"]
    path = ydl.prepare_filename(info)
    if audio_only:
        path = os.path.splitext(path)[0] + ".mp3"
    return path


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("urls", nargs="+")
    p.add_argument("--out", default="downloads", help="output directory (default: ./downloads)")
    p.add_argument("--audio-only", action="store_true", help="extract audio as mp3")
    p.add_argument("--info-only", action="store_true", help="print metadata, download nothing")
    p.add_argument("--max-height", type=int, help="cap video resolution, e.g. 720")
    p.add_argument("--format", help="raw yt-dlp format selector (overrides --max-height)")
    p.add_argument("--cookies", help="Netscape cookies.txt for login-only/private posts")
    p.add_argument("--cookies-from-browser", help="read cookies from a local browser (chrome, firefox, ...)")
    p.add_argument("--playlist", action="store_true", help="download every item if the URL is a playlist/album")
    p.add_argument("--no-info-json", action="store_true", help="skip writing the .info.json sidecar")
    args = p.parse_args()

    yt_dlp = load_yt_dlp()
    opts = build_opts(args)
    failed = 0

    with yt_dlp.YoutubeDL(opts) as ydl:
        for url in args.urls:
            try:
                info = ydl.extract_info(url, download=not args.info_only)
                if info.get("_type") == "playlist" and info.get("entries"):
                    entries = [e for e in info["entries"] if e]
                else:
                    entries = [info]
                for e in entries:
                    out = {
                        "ok": True,
                        "url": url,
                        "id": e.get("id"),
                        "title": e.get("title"),
                        "uploader": e.get("uploader") or e.get("channel"),
                        "duration": e.get("duration"),
                        "resolution": e.get("resolution")
                        or (f"{e.get('width')}x{e.get('height')}" if e.get("width") else None),
                        "webpage_url": e.get("webpage_url"),
                        "extractor": e.get("extractor_key"),
                    }
                    if not args.info_only:
                        path = final_path(ydl, e, args.audio_only)
                        out["file"] = os.path.abspath(path)
                        if os.path.exists(path):
                            out["size_mb"] = round(os.path.getsize(path) / 1e6, 2)
                    print(json.dumps(out, ensure_ascii=False))
            except Exception as exc:  # yt_dlp.utils.DownloadError and friends
                failed += 1
                msg = str(exc).replace("ERROR: ", "", 1)
                print(json.dumps({"ok": False, "url": url, "error": msg, "hint": hint_for(msg)},
                                 ensure_ascii=False))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
