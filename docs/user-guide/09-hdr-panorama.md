# HDR and panorama

Select two or more photos and choose:

- **Photo ▸ Merge to HDR…** (`⇧⌘H`): bracketed exposures are aligned, deghosted (anything that moved comes from one frame) and merged in linear light.
- **Photo ▸ Merge to Panorama…** (`⇧⌘M`): overlapping frames are stitched with a perspective, cylindrical or spherical projection (chosen automatically from the angle covered) and cropped to the largest clean rectangle.

The result is a new linear DNG next to the sources, with the full editing latitude of a RAW. The originals are not changed. Merging needs the [RAW helper](01-install.md#the-raw-helper).

## Best Shot

A hand-held burst rarely has one frame where everyone's eyes are open and everything is sharp. **Photo ▸ Merge to Best Shot…** (`⇧⌘B`) makes that frame. Select the frames of a burst, or one photo of a [burst stack](04-culling.md#burst-stacks) for its whole burst, and choose it. You can also right-click a burst in the filmstrip or the grid and choose **Merge to Best Shot…**: that merges that burst's frames, whatever is selected.

The best frame is the base and the others are aligned to it. Each face that is better in another frame, open eyes first, is blended in, and so are regions that are clearly sharper elsewhere. The preview says what was taken: faces improved, sharper regions, and faces that moved too much to swap.

The result is `<name>-Best.dng` next to the sources. It joins the burst and becomes its cover, unless you chose a cover yourself.

## Deleting a merge

A merged photo is a photo like any other. In a session you imported, the trash button on its frame in the burst strip (or **Photo ▸ Move to Session Trash**) moves it to the session Trash, and `⌘Z` brings it back. In a folder opened in place, **Move to Trash…** asks first, then sends the DNG to the macOS Trash and takes it out of the session; drag it back out of the Trash in Finder if you change your mind. A deleted Best Shot stops being its burst's cover.
