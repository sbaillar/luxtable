# Exporting

Select photos and choose **File ▸ Export…** (`⌘E`). The export sheet lists your **recipes**; tick one or several and every selected photo is exported through each, in the background.

## Recipes

- **Format:** JPEG, HEIC, 16-bit TIFF, or 8- or 16-bit PNG, with quality.
- **Size** (with or without upscaling, or AI Upscale), output **sharpening** and **colour space** (sRGB, Display P3, or the soft-proof ICC profile with its rendering intent).
- **Destination** and **file name** template.
- **Metadata:** include EXIF, your IPTC fields and keywords, or leave out the GPS position and place names. With metadata included, the star rating and keywords go in too, and **Colour label and pick as keywords** adds tags such as `Luxtable/Label/Red`, `Luxtable/Pick` and `Luxtable/Reject`, which photo servers such as Immich show as tags.
- **Watermark:** a line of text (font, size, colour, opacity, shadow; `{copyright}`, `{year}`, `{filename}` tokens) or a PNG logo, at one of nine positions. It keeps the same relative size at every export size, and the editor previews it on the focused photo.
- **Post-processing:** export steps from plug-ins, for example a border.

## Google Photos

A JPEG or HEIC recipe can also upload its files to Google Photos: tick **Also upload to Google Photos** and name an album. Luxtable adds to its own album with that name or creates it, uses each photo's caption as its description, and shows progress per photo and a list of any that failed. Sign in once in Settings ▸ Google Photos; the sign-in is kept in your Keychain. Google Photos is an [optional integration](12-plugins.md#optional-integrations): turn it on in Settings ▸ Plugins first. A build without a built-in Google client can use your own (see `docs/GOOGLE_PHOTOS.md`).

## Sharing

To send a few photos to someone, select them and choose **File ▸ Share…** (`⌥⌘E`), the **Share** button in the toolbar, or **Share…** in the right-click menu of the grid or filmstrip. Luxtable makes a JPEG of each photo with your edits, shows its progress (with **Cancel**), and then opens the usual macOS share menu: Messages, Mail, AirDrop, Notes, Photos and the other services on your Mac.

- **Size and quality:** 2048 px on the long edge at JPEG quality 85, in sRGB, unless you change them in **Settings ▸ Sharing** (2048, 3072 or 4096 px; quality 60–100).
- **Metadata:** your name, copyright, caption and keywords go in, as in an export. **The location (GPS and place names) is left out** unless you turn on **Include the location** in Settings ▸ Sharing. Colour labels and pick flags are not added as keywords.
- **Files:** the JPEGs are made in a temporary folder, not next to your photos. If you close the share menu without choosing a service they are deleted at once; otherwise they are kept for ten minutes while the service reads them, and anything left over (after quitting, for example) is removed the next time you share or open Luxtable, once it is an hour old.

Share… is for quick sending. For other formats, sizes, watermarks or a folder of your choice, use **File ▸ Export…**.
