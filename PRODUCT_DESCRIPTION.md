# Watermark Factory — product description

Three things, for real estate agents specifically. Everything else in the app exists to make
these three actually easy to do on a folder of 40-200 listing photos, not just possible in
principle.

## 1. Create watermarks and rename images in bulk

Batch-watermark an entire shoot in one drag, and rename every file to a consistent,
listing-tied naming pattern (numbered, prefixed) at the same time.

**Why it matters for real estate agents:** a listing shoot produces dozens to hundreds of
photos, and every one of them needs your mark on it before it goes anywhere public — a
watermark is the only thing standing between "this is my listing" and a competitor or a
scraper site lifting your photos wholesale, which happens constantly in this business.
Doing that by hand in Preview or Photoshop, one file at a time, doesn't scale past a couple
of listings before it eats an afternoon. And a folder of `IMG_4821.jpg`, `IMG_4822.jpg`...
across a dozen active listings is unmanageable the moment you need to find "the kitchen shot
from the Maple St. listing" three weeks later, or hand a folder to a client/MLS coordinator
who has no idea which photos belong to which property.

## 2. Make images light for fast loading and uploading to platforms

Auto-compress every export to a target file size and dimension, tuned for where it's going
(MLS, a listing portal, email, social) — without doing it image-by-image.

**Why it matters for real estate agents:** MLS systems and listing portals have hard upload
size limits and slow, timeout-prone bulk-upload flows — a folder of full-resolution
12MP-plus camera originals routinely fails or stalls partway through an upload, right when
you're trying to get a listing live fast. And once it's live, a buyer scrolling listings on
their phone on cell data will bounce off a slow-loading gallery before they ever see the
kitchen — page speed is not a nice-to-have here, it's the difference between a listing that
gets looked at and one that gets scrolled past.

## 3. Remove geolocation from images

Strip or fuzz embedded GPS coordinates from every exported photo, independent of the
watermark step — on by default, adjustable per export.

**Why it matters for real estate agents:** every photo straight off a phone or camera
carries the exact GPS coordinates of where it was taken, embedded invisibly in the file. For
a listing photo, that's your seller's exact address, sitting in the file metadata for anyone
who knows to look — before the listing is public, before a showing is scheduled, before you
control who knows the house is empty or when. It also means anyone can pull the coordinates
straight from a photo you sent out and go find the property directly, cutting you out of the
deal entirely. Watermarking protects the image; this protects the people and the address
behind it — a separate concern the app treats as separately non-negotiable.

## How it fits together

The flow is deliberately linear, because the underlying job always runs in this order:

1. **Pick your photos** — a folder or a multi-select, whatever's fastest.
2. **Choose watermark or skip it** — apply a watermark (size, position, opacity, tint —
   presets or manual) and/or optimize/rename only, with no watermark at all. Not everyone
   needs both every time.
3. **Organize by name** — numbered/prefixed batch rename, with a preview of exactly what
   each file will be called before anything is written to disk.
4. **Export, optimized** — compressed to a target size/format, GPS stripped or fuzzed per
   your privacy setting, written out as a new set of files (originals untouched).

A batch's embedded GPS data — before it gets stripped on export — is also the fastest way to
confirm *which* property a folder of photos is actually from, using a free map view rather
than opening each file's metadata by hand. That's a planning tool for the agent, not
something that ships in the exported files.
