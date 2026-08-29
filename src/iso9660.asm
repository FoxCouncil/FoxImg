; FoxImg - ISO 9660 / Joliet reader over cooked (2048) or raw (2352 / 2336) sector images
;
; The image is read through a sliding 64 MB file-mapping window, so a 32-bit process handles DVD and
; Blu-ray sized files. Logical block N lives at byte N * g_secSize + g_secOff. IsoSectorPtr maps the window
; that holds a block and returns a pointer to its 2048 user bytes; that pointer is only valid until the next
; IsoSectorPtr call, so callers re-fetch after anything that may read another block.
include foximg.inc

WINDOW_SIZE     equ 64 * 1024 * 1024
WINDOW_ALIGN    equ 65536

.data
g_pView     dd 0            ; base of the current window (nonzero while an image is open)
g_winBase   dd 0            ; window start, low dword
g_winBaseHi dd 0            ; window start, high dword
g_winSize   dd 0            ; bytes mapped
g_cbFileLo  dd 0
g_cbFileHi  dd 0
g_pvdLba    dd 0            ; Primary Volume Descriptor block
g_svdLba    dd 0            ; Joliet Supplementary Volume Descriptor block, or 0
g_bJoliet   dd 0            ; nonzero when names are UCS-2 big-endian
g_hFile     dd 0
g_hMap      dd 0
g_secSize   dd 2048         ; physical sector size in the file
g_secOff    dd 0            ; offset of the 2048 user bytes inside a physical sector
g_nSectors  dd 0
g_fmt       dd 0            ; FMT_*
g_bCue      dd 0            ; opened through a .cue sheet (g_szBinPath holds the data file)
g_dataBaseLo dd 0           ; byte offset of the data track inside the file (containers)
g_dataBaseHi dd 0
g_lbaBase   dd 0            ; LBA of the first block of the data track (Dreamcast: 45000)
g_bCdi      dd 0            ; descriptors carry "CD-I " (Green Book) instead of "CD001"

WSTR szFmtIso, <ISO 9660>
WSTR szFmtCdi, <CD-i>
WSTR szFmtXdvdfs, <XDVDFS (Xbox)>
WSTR szFmtOpera, <Opera (3DO)>
WSTR szFmtRaw2352, <RAW 2352 ISO 9660>
WSTR szFmtRaw2336, <RAW 2336 ISO 9660>
WSTR szFmtJoliet, < + Joliet>
szFmtUdf    dw ' ','+',' ','U','D','F',' ','%','u','.','%','0','2','u',0
szCtPrefixFmt dw '%','s',':',' ',0
szSync      db 00h, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 00h

.data?
g_szBinPath dw MAX_PATH dup(?)

.code

IsoCountSectors PROTO
IsoSetGeometry  PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD

; ---------------------------------------------------------------------------
; Window management
; ---------------------------------------------------------------------------
; Map the window that starts at 64 KB-aligned offset hi:lo. Returns TRUE on success.
IsoMapWindow PROC baseLo:DWORD, baseHi:DWORD
    LOCAL cb:DWORD
    .IF g_pView != 0
        invoke UnmapViewOfFile, g_pView
        mov g_pView, 0
    .ENDIF
    ; bytes left in the file from this base, capped at the window size
    mov eax, g_cbFileLo
    mov edx, g_cbFileHi
    sub eax, baseLo
    sbb edx, baseHi
    .IF edx != 0 || eax > WINDOW_SIZE
        mov eax, WINDOW_SIZE
    .ENDIF
    mov cb, eax
    invoke MapViewOfFile, g_hMap, FILE_MAP_READ, baseHi, baseLo, cb
    .IF eax == 0
        mov g_winSize, 0
        ret
    .ENDIF
    mov g_pView, eax
    mov eax, baseLo
    mov g_winBase, eax
    mov eax, baseHi
    mov g_winBaseHi, eax
    mov eax, cb
    mov g_winSize, eax
    mov eax, TRUE
    ret
IsoMapWindow ENDP

; Pointer to the 2048 user bytes of logical block lba, or 0 when out of range. Remaps as needed.
; Byte offset = (lba - g_lbaBase) * secSize + secOff + g_dataBase (a container's data track may start anywhere).
IsoSectorPtr PROC lba:DWORD
    LOCAL offLo:DWORD
    LOCAL offHi:DWORD
    LOCAL baseLo:DWORD
    LOCAL baseHi:DWORD
    mov eax, lba
    .IF eax >= g_nSectors || eax < g_lbaBase
        xor eax, eax
        ret
    .ENDIF
    sub eax, g_lbaBase
    mul g_secSize                           ; edx:eax = block * secSize
    add eax, g_secOff
    adc edx, 0
    add eax, g_dataBaseLo
    adc edx, g_dataBaseHi
    mov offLo, eax
    mov offHi, edx

    ; inside the current window (with the full 2048 bytes)?
    .IF g_pView != 0 && edx == g_winBaseHi
        mov ecx, eax
        sub ecx, g_winBase
        .IF eax >= g_winBase
            mov edx, ecx
            add edx, ISO_SECTOR
            .IF edx <= g_winSize
                add ecx, g_pView
                mov eax, ecx
                ret
            .ENDIF
        .ENDIF
    .ENDIF

    ; remap: window starts at the block's offset rounded down to the allocation granularity
    mov eax, offLo
    and eax, not (WINDOW_ALIGN - 1)
    mov baseLo, eax
    mov eax, offHi
    mov baseHi, eax
    invoke IsoMapWindow, baseLo, baseHi
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, offLo
    sub eax, g_winBase
    add eax, g_pView
    ret
IsoSectorPtr ENDP

; ---------------------------------------------------------------------------
; IsoClose - release mapping and file
; ---------------------------------------------------------------------------
IsoClose PROC
    invoke UdfClose
    invoke XdvdfsClose
    invoke OperaClose
    mov g_bCdi, 0
    .IF g_pView != 0
        invoke UnmapViewOfFile, g_pView
        mov g_pView, 0
    .ENDIF
    .IF g_hMap != 0
        invoke CloseHandle, g_hMap
        mov g_hMap, 0
    .ENDIF
    .IF g_hFile != 0
        invoke CloseHandle, g_hFile
        mov g_hFile, 0
    .ENDIF
    mov g_winSize, 0
    mov g_cbFileLo, 0
    mov g_cbFileHi, 0
    mov g_nSectors, 0
    mov g_pvdLba, 0
    mov g_svdLba, 0
    mov g_bJoliet, 0
    mov g_secSize, 2048
    mov g_secOff, 0
    mov g_fmt, FMT_ISO
    mov g_bCue, 0
    mov g_dataBaseLo, 0
    mov g_dataBaseHi, 0
    mov g_lbaBase, 0
    invoke CtReset
    ret
IsoClose ENDP

; ---------------------------------------------------------------------------
; Geometry
; ---------------------------------------------------------------------------
IsoSetFormat PROC fmt:DWORD
    mov eax, fmt
    mov g_fmt, eax
    .IF eax == FMT_RAW2352_M1
        mov g_secSize, 2352
        mov g_secOff, 16
    .ELSEIF eax == FMT_RAW2352_M2
        mov g_secSize, 2352
        mov g_secOff, 24
    .ELSEIF eax == FMT_RAW2336
        mov g_secSize, 2336
        mov g_secOff, 8
    .ELSE
        mov g_secSize, 2048
        mov g_secOff, 0
    .ENDIF
    invoke IsoCountSectors
    ret
IsoSetFormat ENDP

; g_nSectors = (file size - data base) / sector size + lba base
IsoCountSectors PROC
    mov eax, g_cbFileLo
    mov edx, g_cbFileHi
    sub eax, g_dataBaseLo
    sbb edx, g_dataBaseHi
    .IF edx > 0FFFFh                        ; keep the divide in range (files under 16 TB)
        mov edx, 0FFFFh
    .ENDIF
    div g_secSize
    add eax, g_lbaBase
    mov g_nSectors, eax
    ret
IsoCountSectors ENDP

; Geometry dictated by a container
IsoSetGeometry PROC secSize:DWORD, secOff:DWORD, baseLo:DWORD, baseHi:DWORD, lbaBase:DWORD
    mov eax, secSize
    mov g_secSize, eax
    mov eax, secOff
    mov g_secOff, eax
    mov eax, baseLo
    mov g_dataBaseLo, eax
    mov eax, baseHi
    mov g_dataBaseHi, eax
    mov eax, lbaBase
    mov g_lbaBase, eax
    mov g_fmt, FMT_ISO
    .IF secSize == 2352
        mov g_fmt, FMT_RAW2352_M1
        .IF secOff == 24
            mov g_fmt, FMT_RAW2352_M2
        .ENDIF
    .ELSEIF secSize == 2336
        mov g_fmt, FMT_RAW2336
    .ELSEIF secSize != 2048
        mov g_fmt, FMT_RAW2352_M1           ; 2448 / 2368 with subchannel: report as raw
    .ENDIF
    invoke IsoCountSectors
    ret
IsoSetGeometry ENDP

; Raw 2352-byte sectors? Looks at the first sector of the (already mapped, offset 0) window. Returns FMT_* or -1.
IsoSniff PROC USES esi
    .IF g_cbFileHi == 0
        mov eax, g_cbFileLo
        .IF eax < 2352 * 17
            mov eax, -1
            ret
        .ENDIF
    .ENDIF
    mov edx, g_cbFileHi
    mov eax, g_cbFileLo
    mov ecx, 2352
    div ecx
    .IF edx != 0
        mov eax, -1
        ret
    .ENDIF
    mov esi, g_pView
    xor ecx, ecx
    .WHILE ecx < 12
        mov al, [esi + ecx]
        .IF al != szSync[ecx]
            mov eax, -1
            ret
        .ENDIF
        inc ecx
    .ENDW
    mov eax, FMT_RAW2352_M1
    .IF byte ptr [esi + 15] == 2
        mov eax, FMT_RAW2352_M2
    .ENDIF
    ret
IsoSniff ENDP

; ---------------------------------------------------------------------------
; IsoOpen - map an image (or the data file of a .cue) and locate the volume descriptors
; ---------------------------------------------------------------------------
IsoOpen PROC USES esi edi ebx pszPath:DWORD
    LOCAL liSize[2]:DWORD
    LOCAL pData:DWORD

    invoke IsoClose
    mov pData, 0

    .IF pData == 0
        ; NRG / MDS / CCD / GDI / TOC / CDI: the container names the data file and its geometry
        invoke CtResolve, pszPath
        .IF eax != 0
            mov pData, offset g_szBinPath
        .ELSE
            mov eax, pszPath
            mov pData, eax
        .ENDIF
    .ENDIF

retry_open:
    invoke CreateFileW, pData, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov g_hFile, eax

    invoke GetFileSizeEx, g_hFile, addr liSize
    mov eax, liSize[0]
    mov g_cbFileLo, eax
    mov eax, liSize[4]
    mov g_cbFileHi, eax
    .IF eax == 0
        mov ecx, g_cbFileLo
        cmp ecx, ISO_SECTOR                 ; foreign filesystems can be tiny; ISO 9660 checks block 16 itself
        jb fail
    .ENDIF

    invoke CreateFileMappingW, g_hFile, NULL, PAGE_READONLY, 0, 0, NULL
    .IF eax == 0
        jmp fail
    .ENDIF
    mov g_hMap, eax
    invoke IsoMapWindow, 0, 0
    .IF eax == 0
        jmp fail
    .ENDIF

    .IF g_bContainer != 0
        invoke IsoSetGeometry, g_ctSecSize, g_ctSecOff, g_ctBaseLo, g_ctBaseHi, g_ctLbaBase
    .ELSE
        invoke IsoSniff
        .IF eax == -1
            mov eax, FMT_ISO
        .ENDIF
        invoke IsoSetFormat, eax
    .ENDIF

    ; Walk the volume descriptor set starting at block 16 until the terminator.
    mov ebx, ISO_VD_FIRST
vd_loop:
    invoke IsoSectorPtr, ebx
    test eax, eax
    jz vd_done
    mov esi, eax
    cmp dword ptr [esi + ISO_VD_ID], 30304443h  ; "CD00"
    jne vd_notiso
    cmp byte ptr [esi + ISO_VD_ID + 4], '1'
    je vd_isiso
vd_notiso:
    ; Green Book (CD-i) discs use the same layout with a "CD-I " identifier
    cmp dword ptr [esi + ISO_VD_ID], 492D4443h  ; "CD-I"
    jne vd_done
    cmp byte ptr [esi + ISO_VD_ID + 4], ' '
    jne vd_done
    mov g_bCdi, TRUE
vd_isiso:
    movzx eax, byte ptr [esi + ISO_VD_TYPE]
    .IF al == ISO_VD_TERMINATOR
        jmp vd_done
    .ELSEIF al == ISO_VD_PRIMARY
        .IF g_pvdLba == 0
            mov g_pvdLba, ebx
        .ENDIF
    .ELSEIF al == ISO_VD_SUPPLEMENTARY
        .IF byte ptr [esi + ISO_VD_ESCAPES] == 25h && byte ptr [esi + ISO_VD_ESCAPES + 1] == 2Fh
            mov cl, byte ptr [esi + ISO_VD_ESCAPES + 2]
            .IF cl == 40h || cl == 43h || cl == 45h
                .IF g_svdLba == 0
                    mov g_svdLba, ebx
                .ENDIF
            .ENDIF
        .ENDIF
    .ENDIF
    inc ebx
    cmp ebx, ISO_VD_FIRST + 64
    jb vd_loop

vd_done:
    .IF g_pvdLba == 0
        ; not ISO 9660: Xbox or 3DO volumes have their own descriptors (read-only, saving converts)
        invoke XdvdfsDetect
        .IF eax == 0
            invoke OperaDetect
        .ENDIF
        .IF eax != 0
            mov g_bContainer, TRUE
            mov eax, TRUE
            ret
        .ENDIF
        ; nothing at block 16: maybe the data track starts somewhere inside (CDI and friends)
        .IF g_bContainer == 0 && g_bCue == 0
            invoke UnmapViewOfFile, g_pView
            mov g_pView, 0
            invoke CloseHandle, g_hMap
            mov g_hMap, 0
            invoke CloseHandle, g_hFile
            mov g_hFile, 0
            invoke CtResolveByScan, pszPath
            .IF eax != 0
                mov pData, offset g_szBinPath
                jmp retry_open
            .ENDIF
        .ENDIF
        jmp fail
    .ENDIF
    .IF g_svdLba != 0
        mov g_bJoliet, TRUE
    .ENDIF
    mov eax, TRUE
    ret

fail:
    invoke IsoClose
    xor eax, eax
    ret
IsoOpen ENDP

; Pointer to the root directory record of the active (Joliet or primary) descriptor. Valid until the next block fetch.
IsoRootRecord PROC
    mov eax, g_pvdLba
    .IF g_bJoliet != 0
        mov eax, g_svdLba
    .ENDIF
    invoke IsoSectorPtr, eax
    .IF eax != 0
        add eax, ISO_VD_ROOT_RECORD
    .ENDIF
    ret
IsoRootRecord ENDP

; ---------------------------------------------------------------------------
; IsoEnumDir - iterate the directory records of the extent at lba/cb, one block at a time.
; Skips "." and "..". Callback is stdcall (pRec, lParam) and returns nonzero to continue; pRec is only
; valid inside the callback. The block pointer is re-fetched after every callback because the callback
; may have read other blocks (directory recursion).
; ---------------------------------------------------------------------------
IsoEnumDir PROC USES esi edi ebx lba:DWORD, cb:DWORD, pfnCallback:DWORD, lParam:DWORD
    LOCAL remaining:DWORD
    LOCAL blk:DWORD
    LOCAL pos:DWORD                         ; byte offset inside the current block
    LOCAL n:DWORD                           ; bytes used in the current block

    mov eax, cb
    mov remaining, eax
    mov blk, 0

    .WHILE remaining != 0
        mov ecx, remaining
        .IF ecx > ISO_SECTOR
            mov ecx, ISO_SECTOR
        .ENDIF
        mov n, ecx
        sub remaining, ecx
        mov pos, 0

        .WHILE TRUE
            mov eax, pos
            .BREAK .IF eax >= n
            mov eax, lba
            add eax, blk
            invoke IsoSectorPtr, eax
            .IF eax == 0
                xor eax, eax
                ret
            .ENDIF
            mov esi, eax
            add esi, pos
            movzx ebx, [esi].ISO_DIRREC.recLen
            .BREAK .IF ebx == 0                 ; padding to the end of this block
            .IF ebx < 33
                mov eax, TRUE
                ret
            .ENDIF
            mov eax, pos
            add eax, ebx
            .IF eax > n
                mov eax, TRUE
                ret
            .ENDIF
            mov pos, eax
            .IF [esi].ISO_DIRREC.nameLen == 1 && byte ptr [esi + 33] <= 1
                .CONTINUE
            .ENDIF
            push lParam
            push esi
            call pfnCallback
            .IF eax == 0
                mov eax, TRUE
                ret
            .ENDIF
        .ENDW
        inc blk
    .ENDW
    mov eax, TRUE
    ret
IsoEnumDir ENDP

; ---------------------------------------------------------------------------
; Extent access (block-wise, so raw images and window remaps work)
; ---------------------------------------------------------------------------
IsoCopyExtent PROC USES ebx lba:DWORD, cb:DWORD, hOut:DWORD
    LOCAL blk:DWORD
    mov blk, 0
    .WHILE cb != 0
        mov eax, lba
        add eax, blk
        invoke IsoSectorPtr, eax
        .IF eax == 0
            xor eax, eax
            ret
        .ENDIF
        mov ebx, cb
        .IF ebx > ISO_SECTOR
            mov ebx, ISO_SECTOR
        .ENDIF
        invoke WriteAll, hOut, eax, ebx
        .IF eax == 0
            ret
        .ENDIF
        sub cb, ebx
        inc blk
    .ENDW
    mov eax, TRUE
    ret
IsoCopyExtent ENDP

IsoReadExtent PROC USES ebx edi lba:DWORD, cb:DWORD, pDst:DWORD
    LOCAL blk:DWORD
    mov blk, 0
    mov edi, pDst
    .WHILE cb != 0
        mov eax, lba
        add eax, blk
        invoke IsoSectorPtr, eax
        .IF eax == 0
            xor eax, eax
            ret
        .ENDIF
        mov ebx, cb
        .IF ebx > ISO_SECTOR
            mov ebx, ISO_SECTOR
        .ENDIF
        invoke RtlMoveMemory, edi, eax, ebx
        add edi, ebx
        sub cb, ebx
        inc blk
    .ENDW
    mov eax, TRUE
    ret
IsoReadExtent ENDP

; ---------------------------------------------------------------------------
; IsoRecName - identifier of a record into a UTF-16 buffer; files lose ";version" and a trailing "."
; ---------------------------------------------------------------------------
IsoRecName PROC USES esi edi ebx pRec:DWORD, pszBuf:DWORD, cchBuf:DWORD
    mov esi, pRec
    movzx ecx, [esi].ISO_DIRREC.nameLen
    mov bl, [esi].ISO_DIRREC.fileFlags
    add esi, 33
    mov edi, pszBuf
    mov edx, cchBuf
    dec edx
    .IF g_bJoliet != 0
        shr ecx, 1
        .IF ecx > edx
            mov ecx, edx
        .ENDIF
        .WHILE ecx != 0
            lodsw
            xchg al, ah
            stosw
            dec ecx
        .ENDW
    .ELSE
        .IF ecx > edx
            mov ecx, edx
        .ENDIF
        .WHILE ecx != 0
            lodsb
            movzx eax, al
            stosw
            dec ecx
        .ENDW
    .ENDIF
    xor eax, eax
    stosw
    test bl, ISO_FLAG_DIRECTORY
    jnz finished
    mov esi, pszBuf
    mov edi, esi
    .WHILE word ptr [esi] != 0
        .IF word ptr [esi] == ';'
            mov word ptr [esi], 0
            .BREAK
        .ENDIF
        add esi, 2
    .ENDW
    .IF esi > edi
        .IF word ptr [esi - 2] == '.'
            mov word ptr [esi - 2], 0
        .ENDIF
    .ENDIF
finished:
    ret
IsoRecName ENDP

IsoVolumeName PROC USES esi edi pszBuf:DWORD, cchBuf:DWORD
    mov edi, pszBuf
    mov edx, cchBuf
    dec edx
    .IF edx > 32
        mov edx, 32
    .ENDIF
    .IF g_pvdLba == 0
        xor eax, eax
        stosw
        ret
    .ENDIF
    mov eax, g_pvdLba
    .IF g_bJoliet != 0
        mov eax, g_svdLba
    .ENDIF
    push edx
    invoke IsoSectorPtr, eax
    pop edx
    .IF eax == 0
        xor eax, eax
        stosw
        ret
    .ENDIF
    lea esi, [eax + ISO_VD_VOLUME_ID]
    .IF g_bJoliet != 0
        mov ecx, 16
        .IF ecx > edx
            mov ecx, edx
        .ENDIF
        .WHILE ecx != 0
            lodsw
            xchg al, ah
            stosw
            dec ecx
        .ENDW
    .ELSE
        mov ecx, edx
        .WHILE ecx != 0
            lodsb
            movzx eax, al
            stosw
            dec ecx
        .ENDW
    .ENDIF
    .WHILE edi > pszBuf
        .IF word ptr [edi - 2] != ' ' && word ptr [edi - 2] != 0
            .BREAK
        .ENDIF
        sub edi, 2
    .ENDW
    xor eax, eax
    stosw
    ret
IsoVolumeName ENDP

; "ISO 9660 + Joliet", "RAW 2352 ISO 9660" ...
IsoFormatName PROC pszBuf:DWORD
    LOCAL pBase:DWORD
    ; "NRG: " prefix when read through a container
    mov eax, pszBuf
    mov word ptr [eax], 0
    .IF g_ctName != 0
        invoke wsprintfW, pszBuf, offset szCtPrefixFmt, g_ctName
        invoke lstrlenW, pszBuf
        mov ecx, pszBuf
        lea ecx, [ecx + eax * 2]
        mov pszBuf, ecx
    .ENDIF
    ; foreign filesystems: just their name
    .IF g_bXdvdfs != 0
        invoke lstrcpyW, pszBuf, offset szFmtXdvdfs
        ret
    .ELSEIF g_bOpera != 0
        invoke lstrcpyW, pszBuf, offset szFmtOpera
        ret
    .ENDIF
    mov pBase, offset szFmtIso
    .IF g_bCdi != 0
        mov pBase, offset szFmtCdi
    .ENDIF
    mov eax, g_fmt
    .IF eax == FMT_RAW2352_M1 || eax == FMT_RAW2352_M2
        mov pBase, offset szFmtRaw2352
    .ELSEIF eax == FMT_RAW2336
        mov pBase, offset szFmtRaw2336
    .ENDIF
    mov ecx, offset szFmtJoliet
    .IF g_bJoliet == 0
        mov ecx, offset g_szCatFmt
        add ecx, 8                          ; empty string (the terminator of szCatFmt)
    .ENDIF
    invoke wsprintfW, pszBuf, offset g_szCatFmt, pBase, ecx
    .IF g_bUdf != 0
        ; " + UDF 1.02" from the BCD-ish revision word (0102h)
        mov eax, g_udfVersion
        mov ecx, eax
        shr eax, 8
        and ecx, 0FFh
        push ecx
        push eax
        invoke lstrlenW, pszBuf
        mov edx, pszBuf
        lea edx, [edx + eax * 2]
        pop eax
        pop ecx
        invoke wsprintfW, edx, offset szFmtUdf, eax, ecx
    .ENDIF
    ret
IsoFormatName ENDP

END
