# Building a partitioned, formatted disk image with no loop device and no root

## The problem

`nixstorage.layout.images.<name>.result` has to be a pure Nix derivation --
built inside a Nix build sandbox, with no root privilege and no access to
the host's own block-device tree. The obvious way to build a partitioned,
formatted disk image (`losetup` a backing file, partition the loop device,
mount and populate each partition, `losetup -d`) needs exactly the two
things a build sandbox does not have: a loop device, and `mount`.

## What was measured

GPT tools do not actually require a block device. `sgdisk` and `sfdisk`
operate on whatever path they are given as plain, ordinary file I/O -- the
partition table is just bytes at known offsets, and nothing about writing
it requires the target to *be* a device node:

```
$ truncate -s $((16*1024*1024)) img.raw
$ sgdisk -n 1:0:+2MiB -t 1:C12A7328-F81F-11D2-BA4B-00A0C93EC93B -c 1:ESP img.raw
$ sgdisk -n 2:0:0 -t 2:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 2:raw-a img.raw
$ sgdisk -p img.raw
Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048            6143   2.0 MiB     EF00  ESP
   2            6144           32734   13.0 MiB    8300  raw-a
```

This confirms two things worth relying on rather than assuming:

- **`start:0` and `end:0` both do the right thing without loop-device
  math.** `0` for start means "the next aligned sector"; bare `0` for end
  (used only on the last partition) means "every remaining usable sector",
  automatically stopping short of the space GPT's own secondary header
  needs. `sgdisk -p`'s own accounting on the run above shows the entire gap
  is the ~1 MiB *leading* alignment padding before partition 1 (`Total free
  space is 2014 sectors (1007.0 KiB)`) -- nothing is wasted at the tail.
- **Every declared size lands on the next alignment boundary for free.**
  1 MiB = 2048 sectors = `sgdisk`'s own default alignment unit, so any
  partition sized in whole MiB always ends exactly on a boundary, and the
  next partition starts immediately after with no extra gap. This is why
  `nixstorage.layout`'s own reserved-overhead assumption (2 MiB: ~1 MiB
  leading alignment + a negligible trailing GPT-footer reservation) is a
  real, measured number, not a guess -- see `modules/layout.nix`'s own
  `reservedOverheadMiB`.

The one partition role that needs real filesystem content (`esp`, formatted
vfat) uses the identical trick a second time: `mkfs.vfat -C <file> <size>`
*creates* a correctly-sized plain file and formats it -- no loop device
here either. That file is then spliced into the main image at the exact
byte offset `sgdisk -i <n>` reports back for that partition (queried, never
recomputed by hand -- see below for why that matters):

```
$ mkfs.vfat -n ESPVOL -C esp.img 2048        # size in KiB
$ dd if=esp.img of=img.raw bs=512 seek=2048 conv=notrunc,fsync
$ dd if=img.raw bs=512 skip=2048 count=4096 of=extracted.img
$ cmp esp.img extracted.img && echo IDENTICAL
IDENTICAL
```

## Why the offset is queried back, not computed by hand

`lib/image.nix` could, in principle, recompute each partition's start
sector itself (accumulate sizes, add the alignment padding once at the
front). It deliberately does not: `sgdisk -i <partnum> <file>` is asked
what it actually decided, and that string is parsed for `First sector`/
`Partition size` instead. `sgdisk`'s own alignment behavior is real
implementation detail that could change across versions or with a
`-a`/`--set-alignment` override this repo doesn't currently expose --
asking the tool that made the decision is correct regardless of which way
that behavior ever moves; re-deriving it by hand is a second, independent
implementation of the same arithmetic that could silently drift from the
first.

## Read-back for verification is the same story, one layer up

`nixstorage.layout.verify` needs to read a *live* device's partition table
without writing to it. `sfdisk --json <device>` is the read-only listing
counterpart to the two write commands above, and it works identically
against a plain file (used directly by every check in this repo's own
`checks/`) or a real block device (the only case `nixstorage-layout-verify`
itself ever runs against) -- one code path, no special-casing needed
between "this is a file I built" and "this is a disk somebody dd'd it
onto".

## Where this is exercised for real

`checks/default.nix`'s `layout-image-build-proof` builds a real 8 MiB,
two-partition image via `lib/image.nix` and asserts on it directly: total
byte size, partition count, names, type-GUIDs, that the built ESP passes
`fsck.vfat -n`, and that the `raw` partition's entire data region is still
all-zero (proving the builder never writes into a slot it has no business
formatting). `layout-verify-detects-drift` runs the real
`nixstorage-layout-verify` script against that same image twice -- once
with a config that matches it, once with one deliberately wrong partition
size -- and asserts the first exits clean with no `FAIL` line and the
second exits non-zero with one. See that check's own comments for how it
resolves a `/dev/disk/by-id/*` device string to the real fixture file
without ever creating a real device node (a fake `readlink`, the same
technique nixboot's own checks use for its fake `efibootmgr`).
