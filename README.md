# FoxImg

[![Build](https://github.com/FoxCouncil/FoxImg/actions/workflows/build.yml/badge.svg)](https://github.com/FoxCouncil/FoxImg/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/FoxCouncil/FoxImg)](https://github.com/FoxCouncil/FoxImg/releases/latest)
[![Download](https://img.shields.io/badge/download-FoxImg.exe-blue)](https://github.com/FoxCouncil/FoxImg/releases/latest/download/FoxImg.exe)

FoxImg is a disc image tool for Windows. It opens, edits, converts, and writes disc images
through an explorer-style window. It is written in x86 assembly (MASM) against the Win32 API.
The program is one small executable with no runtime dependencies.

## Features

- Browse an image as a folder tree with a file list, preview pane, and status bar.
- Add, rename, move, and delete files and folders inside an image.
- Drag and drop in both directions: from Explorer into the image, and from the image to Explorer.
- Save or convert any open image to ISO 9660 + Joliet + UDF 1.02, or to BIN/CUE.
- Keep El Torito boot records through a save. BIOS and UEFI entries survive, and
  isolinux/GRUB boot info tables are patched for the new layout.
- Open images of any size. A sliding 64 MB mapping window keeps memory use flat.
- Long operations run on a worker thread with a progress bar and a Cancel button.
- Dark mode follows the Windows setting. The window scales per monitor (PerMonitorV2).
- Preview pane shows text files and every frame of an .ico file.

## Format support

| Format | Extensions | Read | Write | Notes |
| --- | --- | :-: | :-: | --- |
| ISO 9660 + Joliet | .iso .img | Yes | Yes | Level 1 names with ~N de-duplication on write |
| UDF 1.02 - 2.60 | .iso | Yes | Yes | Writes a 1.02 bridge volume; reads metadata, virtual, and sparable partitions |
| El Torito boot | - | Yes | Yes | BIOS and UEFI entries; boot info table patching; FAT size detection for UEFI images |
| Raw sectors | .bin .img | Yes | No | MODE1/2352, MODE2/2352, MODE2/2336, detected by sync sniff |
| BIN/CUE | .cue .bin | Yes | Yes | Writes MODE1/2048 with a generated cue sheet |
| Files over 4 GB | - | Yes | Yes | Stored in the UDF half only, as Windows install media does |
| Nero | .nrg | Yes | No | v1 and v2, DAO and TAO chunk lists |
| Alcohol 120% | .mds .mdf | Yes | No | First data track of the first session |
| CloneCD | .ccd .img | Yes | No | Raw image beside the sheet |
| DiscJuggler | .cdi | Yes | No | Found by signature scan |
| Dreamcast | .gdi | Yes | No | Data track with its 45000 block base |
| cdrdao | .toc | Yes | No | DATAFILE with track mode |
| ECM | .ecm | Yes | No | Decoded once to a temporary raw image |
| Xbox / Xbox 360 | .iso (XDVDFS) | Yes | No | XISO and all redump partition offsets |
| 3DO | .iso .cue (Opera) | Yes | No | Volume label, directory chains, copies |
| CD-i | .iso .bin | Yes | No | Green Book descriptors beside CD001 |
| Unknown containers | any | Yes | No | Signature scan finds an ISO 9660 volume at any offset |

Read-only formats convert on save: open the image, then save it as ISO or BIN/CUE.

## Download

Get the latest build from the
[Releases page](https://github.com/FoxCouncil/FoxImg/releases/latest), or fetch the
executable directly:

```
https://github.com/FoxCouncil/FoxImg/releases/latest/download/FoxImg.exe
```

There is nothing to install. The program is a single .exe under 100 KB.

## Build

Requirements: Visual Studio Build Tools (MASM, the linker, and the Windows SDK).

```
build.cmd          release build to build\FoxImg.exe
build.cmd debug    build with debug information
```

CI builds every push and pull request. A tag that starts with `v` publishes a release
with the executable and a zip attached.

## Requirements

- Windows 10 version 1607 or later, x86 or x64.
- No runtime libraries. The executable imports only Windows system DLLs.

## License

See [LICENSE](LICENSE).
