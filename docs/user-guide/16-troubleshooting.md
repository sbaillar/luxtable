# Troubleshooting

## "Luxtable can't develop this file yet"

Many RAW formats need the [RAW helper](01-install.md#the-raw-helper): click **Get RAW Helper** on the photo, or open Settings ▸ RAW. Fujifilm X-Trans RAFs and Nikon High Efficiency (HE/HE\*) NEFs import and cull from their embedded previews, but don't develop yet. A few rare formats (Canon CRW, Sigma X3F, Phase One IIQ, ARRI) are refused. `docs/CAMERAS.md` lists what is tested.

## A session or photos show as disconnected or missing

Connect the drive they are on. If you moved the files, use **Locate…** or **Locate Folder…**; files moved by Luxtable itself or renamed are found by content. Nothing is removed while a drive is away.

## AI Denoise is unavailable

The app was built with `LT_SKIP_MODELS=1`, or without Python 3.13 or a network connection at build time. Rebuild without that variable.

## An AI tool says its model isn't installed

Some models (removal, sky and people masks, depth, photo search) are downloaded the first time you use the tool. Check the network connection and try again; a damaged download is offered again. AI Upscale needs a build that sets a download location.

## The map is blank

Map tiles may be turned off: choose **Show Map**, or turn them on in Settings ▸ General. Photos without a location don't appear until you drag them onto the map.

## The archive says it is offline or behind

The archive drive or NAS isn't mounted, or the object storage service didn't answer. Syncs wait until it is back, and nothing in the archive is ever deleted. For object storage, **Test Connection** in Settings ▸ Archive says what is wrong; an `http://` endpoint outside your local network is refused (use `https://`).

## The Archive, Immich or Google Photos settings are missing

That integration is off. Turn it on in Settings ▸ Plug-ins ▸ Integrations; its settings were kept.

## Immich doesn't show my albums or ratings

Check that the archive goes to a folder (Immich can't index object storage), that the path mapping in Settings ▸ Immich is right (**Detect** fills it in), and that Immich's external library points at the archive. Without an admin API key, Immich finds new files only on its own schedule.

## macOS keeps asking for permissions after each build

Run `scripts/make-signing-identity.sh` once and rebuild, so every build is signed with the same identity.

## The keys don't do what this guide says

Settings ▸ Familiar may be set to Lightroom Classic or Capture One keys, or a key may have been rebound in Settings ▸ Shortcuts. Press `?` to see the keys in use.

## Reporting a problem

**Help ▸ Report a Problem…** opens the issue page at [github.com/sbaillar/luxtable](https://github.com/sbaillar/luxtable). Report security issues privately, as described in `SECURITY.md`.

**Help ▸ Save Diagnostic Report…** writes a text file to attach: the Luxtable version, your Mac, what is open (counts, the current photo's camera and file type) and what Luxtable logged since it was opened. It has no photos, and file names, folders and servers are masked. Save it right after the problem, before you quit, and read it before you share it: issues are public.
