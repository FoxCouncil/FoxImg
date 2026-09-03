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
- Save or convert any open image to ISO 9660 + Joliet + UDF 1.02, to BIN/CUE (2048 or raw), to cdrdao TOC, CloneCD, Nero, Alcohol 120% or ECM with the sector EDC and ECC generated, to a gzip- or zip-compressed ISO, or to CSO, ZSO, CHD, ISZ, DAX, JSO, GCZ, UIF, DAA or DMG.
- Keep El Torito boot records through a save. BIOS and UEFI entries survive, and
  isolinux/GRUB boot info tables are patched for the new layout.
- Open images of any size. A sliding 64 MB mapping window keeps memory use flat.
- Long operations run on a worker thread with a progress bar and a Cancel button.
- Dark mode follows the Windows setting. The window scales per monitor (PerMonitorV2).
- Preview pane shows text files and every frame of an .ico file.
- CD audio tracks appear as TrackNN.wav files: extract them as real WAVs, or
  double-click one to play it. Audio-only discs open too (CUE, MDS, CHD).

## Command line

    FoxImg image.iso                  open an image
    FoxImg image.iso out.isz          convert without a window; the format follows the extension
    FoxImg image.iso out.cue /raw     BIN/CUE with MODE1/2352 raw sectors

The convert returns exit code 0 on success and prints one line to the console it was started from.

## Format support

| Format | Extensions | Read | Write | Notes |
| --- | --- | :-: | :-: | --- |
| ISO 9660 + Joliet | .iso .img | Yes | Yes | Level 1 names with ~N de-duplication on write |
| UDF 1.02 - 2.60 | .iso | Yes | Yes | Writes a 1.02 bridge volume; reads metadata, virtual, and sparable partitions |
| El Torito boot | - | Yes | Yes | BIOS and UEFI entries; boot info table patching; FAT size detection for UEFI images |
| Raw sectors | .bin .img | Yes | Yes | Reads MODE1/2352, MODE2/2352, MODE2/2336, detected by sync sniff; writes MODE1/2352 with the EDC and ECC generated |
| BIN/CUE | .cue .bin | Yes | Yes | Writes MODE1/2048, or MODE1/2352 raw with the EDC and ECC generated; cue sheet included |
| Files over 4 GB | - | Yes | Yes | Stored in the UDF half only, as Windows install media does |
| Nero | .nrg | Yes | Yes | Reads v1 and v2, DAO and TAO chunk lists; writes v2 DAO with one raw track |
| Alcohol 120% | .mds .mdf | Yes | Yes | Reads the first data track of the first session; writes one raw track |
| Alcohol MDX | .mdx | Yes | No | Single-file v2 descriptor; encrypted and compressed declined |
| CloneCD | .ccd .img | Yes | Yes | Raw image beside the sheet; writes one MODE1 track with its TOC entries |
| DiscJuggler | .cdi | Yes | No | Found by signature scan |
| Dreamcast | .gdi | Yes | No | Data track with its 45000 block base |
| cdrdao | .toc | Yes | Yes | DATAFILE with track mode; writes MODE1_RAW |
| ECM | .ecm | Yes | Yes | Decoded once to a temporary raw image with the parity restored; writes MODE1 records |
| Xbox / Xbox 360 | .iso (XDVDFS) | Yes | No | XISO and all redump partition offsets |
| 3DO | .iso .cue (Opera) | Yes | No | Volume label, directory chains, copies |
| CD-i | .iso .bin | Yes | No | Green Book descriptors beside CD001 |
| gzip | .iso.gz .gz | Yes | Yes | Any image inside; Save As writes a gzip ISO |
| bzip2 | .iso.bz2 .bz2 | Yes | No | Any image inside |
| zip | .zip | Yes | Yes | Reads the largest stored or deflated entry, CRC verified; Save As writes one deflated entry, zip64 past 4 GB |
| CSO / CISO | .cso .ciso | Yes | Yes | Reads v0/v1/v2, deflate and LZ4 blocks (PSP, Dreamcast tooling); Save As writes v1 with 2 KB deflate blocks |
| ZSO | .zso | Yes | Yes | CISO layout with LZ4 blocks |
| DAX | .dax | Yes | Yes | PSP: zlib frames and raw NC areas; writes 8 KB zlib frames |
| JSO | .jso | Yes | Yes | PSP: reads deflate and LZO methods; writes deflate, 2 KB blocks |
| PBP | .pbp | Yes | No | PS1 Classics EBOOT (PSISOIMG); multi-disc takes disc 1; encrypted PSP UMD declined |
| CHD | .chd | Yes | Yes | Reads v5: zlib, LZMA, FLAC, all CD codecs, stored and self hunks; parented CHDs declined. Writes v5 raw (uncompressed hunks, SHA-1 filled) |
| GCZ | .gcz | Yes | Yes | Dolphin: zlib and stored blocks with the Adler-32 block hashes Dolphin checks |
| RVZ | .rvz | Yes | No | Dolphin, GameCube discs: Zstandard groups and packed junk; Wii (encrypted partitions) and WIA declined |
| WBFS | .wbfs | Planned | No | Wii backup file system |
| GCM | .gcm .iso | Yes | No | Big-endian FST reader; files need no block alignment |
| NKit | .nkit.iso | Planned | No | Wii / GameCube |
| ISZ | .isz | Yes | Yes | UltraISO: reads zlib, bzip2, raw and zero chunks, AES declined; writes zlib, raw and zero |
| DAA | .daa | Yes | Yes | PowerISO v0x100 deflate; v0x110, LZMA and encrypted declined |
| UIF | .uif | Yes | Yes | MagicISO: zlib, raw and zero blocks; passworded declined |
| BlindWrite 5/6 | .b5t .b6t | Yes | No | Descriptor beside the .b5i/.b6i data file |
| C2D | .c2d | Yes | No | WinOnCD / Roxio; compressed C2D declined |
| PDI | .pdi | Planned | No | Instant CD/DVD |
| DMG | .dmg | Yes | Yes | Apple UDIF: reads zlib, bzip2, raw and zero chunks, ADC and lzfse declined; writes zlib and zero |
| Unknown containers | any | Yes | No | Signature scan finds an ISO 9660 volume at any offset |

Read-only formats convert on save: open the image, then save it in any writable format.

CD audio tracks (from cue sheets, Alcohol images and CHDs) show up as `TrackNN.wav`
pseudo-files: extraction writes real WAV files, and a double-click plays the track.

## Compression

The exe carries its own DEFLATE (RFC 1951) codec - an inflate decoder and a compressor - because the built-in Windows compression APIs only speak their own framings
(MSZIP, XPRESS, LZMS), not the raw deflate streams these files hold. CRC-32 comes from
ntdll, so no table lives in the image. Compressed images expand once to `%TEMP%\FoxImg\`
and then open like any other image, the same way ECM does.

The other codecs share that same input and output path, so a container can mix them
chunk by chunk - an ISZ may hold zlib and bzip2 blocks in one image.

| Codec | Status | Used by |
| --- | --- | --- |
| DEFLATE (inflate) | Yes | .gz, .zip, .cso, .gcz, .dax, .jso, .isz, .pbp (raw and zlib framing, auto-detected) |
| DEFLATE (compress) | Yes | Save As gzip ISO: lazy matching over a 32 KB window; per block the cheaper of dynamic Huffman, fixed, or stored |
| LZMA | Yes | CHD hunks; DAA v0x110 and LZMA-compressed RVZ later |
| bzip2 | Yes | .bz2, ISZ and DMG chunks; bzip2-compressed RVZ later |
| Zstandard | Yes | RVZ groups and tables |
| LZ4 | Yes | ZSO, CISO v2; Save As ZSO encodes 2 KB blocks |
| FLAC | Yes | CHD cdfl and flac hunks (16-bit stereo) |
| LZO1X | Yes | JSO method 0 |
| CD-ROM EDC/ECC (generate) | Yes | Raw BIN/CUE, TOC, CCD and ECM writers; the ECM and CHD readers restore the parity those formats strip |

## Download

Get the latest build from the
[Releases page](https://github.com/FoxCouncil/FoxImg/releases/latest), or fetch the
executable directly:

```
https://github.com/FoxCouncil/FoxImg/releases/latest/download/FoxImg.exe
```

There is nothing to install.

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
