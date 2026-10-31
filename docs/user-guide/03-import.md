# Importing from a memory card

Insert a card and choose **File ▸ Import from Card…** (`⇧⌘I`) or the **Import** button. The import sheet lists the photos on the card. You can also import from any folder (**Choose Folder…**), or **Browse Card** to look at a card read-only without copying anything.

![An import in progress (demo mode simulates the card).](../screenshots/import-card.png)

## Options

- **Session:** a new session (named for you, or by you) or an existing one.
- **Subfolder** inside the session's Capture folder, with tokens such as `{date}`, `{time}`, `{camera}` and `{text}`.
- **Rename Files** with a template: `{original}`, `{date}`, `{time}`, `{seq}`, `{seq4}`, `{camera}`, `{text}`.
- **Skip duplicates:** files already in any session are not copied again.
- **Backup Copy:** a second destination that receives the same verified files.
- **Re-read the card after copying:** reads every file from the card a second time and compares it. This catches a card reader that returned bad data once, and takes twice as long.

## What makes it safe

- Files are copied in parallel, and each copy's BLAKE3 checksum is verified before the import counts it as done.
- Nothing is ever deleted from the card. When the import finishes you can eject the card safely from the sheet.
- If an import is interrupted (the card is pulled, the Mac sleeps), Luxtable offers to resume it the next time, and unfinished copies are never mistaken for complete ones.
- Metadata presets (for example your name and copyright) can be applied to every import, and the camera's own artist and copyright fields are read.

## Importing from Photos or an iPhone

Your photos don't have to be on a memory card.

**From the Photos app.** Choose **File ▸ Import from Photos Library…**. The first time, your Mac asks whether Luxtable may access your photos: click **Allow**. (If you said no, turn it on later in **System Settings ▸ Privacy & Security ▸ Photos**.) Show all your photos, one album, or a date range, then tick the ones you want. RAW files, Apple ProRAW, HEIC and JPEG photos come in. Luxtable always takes the original the camera made, never an edited version, and for photos shot as RAW+JPEG it takes the RAW. Photos kept only in iCloud are downloaded first, which can take a while.

**From an iPhone or iPad.** Plug it in with a cable, unlock it, and tap **Trust** if it asks whether to trust this Mac. Open the import sheet (**File ▸ Import from Card…**): the device is listed under **Other Sources**, or offered right away when no card is inserted. You see its photos with thumbnails and tick the ones you want.

Either way, click **Continue**. Luxtable copies the photos you picked and checks each copy, then the usual import sheet opens: choose a new or existing session, rename if you like, and click **Import**. Photos that are already in your library are recognised and skipped, and every file is verified as it is copied into the session, just like a card.

- Nothing in Photos or on the device is ever changed or deleted.
- Videos aren't imported from Photos or a device yet. The sheet tells you how many it left out.
- Luxtable keeps its own temporary copies only until the import is done, and removes them when you close the sheet.

Photos from Capture One, Lightroom Classic, Aperture and iPhoto come in another way: see [Coming from other apps](14-migrate.md#coming-from-other-apps).
