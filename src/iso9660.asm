; FoxImg - ISO 9660 / Joliet reader over cooked (2048) or raw (2352 / 2336) sector images
; The whole image is memory-mapped read-only. Logical block N lives at g_pView + N * g_secSize + g_secOff, so
; .iso/.img, .bin (MODE1/2048), and raw .bin (MODE1/2352, MODE2/2352, MODE2/2336) all read through one path.
include foximg.inc

.data
g_pView     dd 0            ; base of mapped view
g_cbView    dd 0            ; bytes mapped
g_pRoot     dd 0            ; root directory record (inside PVD or Joliet SVD)
g_bJoliet   dd 0            ; nonzero when names are UCS-2 big-endian
g_pPVD      dd 0
g_pSVD      dd 0
g_hFile     dd 0
g_hMap      dd 0
g_secSize   dd 2048         ; physical sector size in the file
g_secOff    dd 0            ; offset of the 2048 user bytes inside a physical sector
g_nSectors  dd 0
g_fmt       dd 0            ; FMT_*
g_bCue      dd 0            ; opened through a .cue sheet (g_szBinPath holds the data file)

szDateFmt   dw '%','0','4','u','-','%','0','2','u','-','%','0','2','u',' ','%','0','2','u',':','%','0','2','u',0
WSTR szExtCue, <.cue>
WSTR szFmtIso, <ISO 9660>
WSTR szFmtRaw2352, <RAW 2352 ISO 9660>
WSTR szFmtRaw2336, <RAW 2336 ISO 9660>
WSTR szFmtJoliet, < + Joliet>
szCatFmt    dw '%','s','%','s',0
szKwFile    db 'FILE', 0
szKwTrack   db 'TRACK', 0
szKwM12048  db 'MODE1/2048', 0
szKwM12352  db 'MODE1/2352', 0
szKwM22352  db 'MODE2/2352', 0
szKwM22336  db 'MODE2/2336', 0
szSync      db 00h, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 00h

.data?
g_szBinPath dw MAX_PATH dup(?)
g_cueFmt    dd ?            ; -1 = not specified by the sheet

.code

; ---------------------------------------------------------------------------
; IsoSectorPtr - pointer to the 2048 user bytes of logical block lba, or 0 when out of range
; ---------------------------------------------------------------------------
IsoSectorPtr PROC lba:DWORD
    mov eax, lba
    .IF eax >= g_nSectors
        xor eax, eax
        ret
    .ENDIF
    mul g_secSize
    add eax, g_secOff
    add eax, g_pView
    ret
IsoSectorPtr ENDP

; ---------------------------------------------------------------------------
; IsoClose - release mapping and file
; ---------------------------------------------------------------------------
IsoClose PROC
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
    mov g_cbView, 0
    mov g_nSectors, 0
    mov g_pRoot, 0
    mov g_bJoliet, 0
    mov g_pPVD, 0
    mov g_pSVD, 0
    mov g_secSize, 2048
    mov g_secOff, 0
    mov g_fmt, FMT_ISO
    mov g_bCue, 0
    ret
IsoClose ENDP

; ---------------------------------------------------------------------------
; CUE sheet parsing (first FILE and first TRACK only)
; ---------------------------------------------------------------------------
; Case-insensitive ASCII substring search; returns pointer past the keyword or 0
FindKeyword PROC USES esi edi ebx pBuf:DWORD, cb:DWORD, pszKey:DWORD
    LOCAL keyLen:DWORD
    invoke lstrlenA, pszKey
    mov keyLen, eax
    mov esi, pBuf
    mov ecx, cb
    .WHILE ecx >= keyLen
        mov edi, pszKey
        xor ebx, ebx
        .WHILE ebx < keyLen
            mov al, [esi + ebx]
            .IF al >= 'a' && al <= 'z'
                sub al, 20h
            .ENDIF
            .BREAK .IF al != [edi + ebx]
            inc ebx
        .ENDW
        .IF ebx == keyLen
            lea eax, [esi + ebx]
            ret
        .ENDIF
        inc esi
        dec ecx
    .ENDW
    xor eax, eax
    ret
FindKeyword ENDP

CueParse PROC USES esi edi ebx pszCue:DWORD
    LOCAL hFile:DWORD
    LOCAL liSize[2]:DWORD
    LOCAL pBuf:DWORD
    LOCAL cb:DWORD
    LOCAL nRead:DWORD
    LOCAL pName:DWORD
    LOCAL nameLen:DWORD
    LOCAL szName[MAX_PATH]:WORD
    LOCAL ok:DWORD

    mov g_cueFmt, -1
    mov ok, FALSE
    invoke CreateFileW, pszCue, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov hFile, eax
    invoke GetFileSizeEx, hFile, addr liSize
    mov eax, liSize[0]
    .IF liSize[4] != 0 || eax > 65536
        mov eax, 65536
    .ENDIF
    mov cb, eax
    inc eax
    invoke VfsAlloc, eax
    mov pBuf, eax
    .IF eax == 0
        invoke CloseHandle, hFile
        ret
    .ENDIF
    invoke ReadFile, hFile, pBuf, cb, addr nRead, NULL
    invoke CloseHandle, hFile
    mov eax, nRead
    mov cb, eax

    ; FILE "name" BINARY
    invoke FindKeyword, pBuf, cb, offset szKwFile
    .IF eax == 0
        jmp done
    .ENDIF
    mov esi, eax
    .WHILE byte ptr [esi] == ' ' || byte ptr [esi] == 9
        inc esi
    .ENDW
    .IF byte ptr [esi] == '"'
        inc esi
        mov pName, esi
        .WHILE byte ptr [esi] != 0 && byte ptr [esi] != '"' && byte ptr [esi] != 13 && byte ptr [esi] != 10
            inc esi
        .ENDW
    .ELSE
        mov pName, esi
        .WHILE byte ptr [esi] != 0 && byte ptr [esi] != ' ' && byte ptr [esi] != 13 && byte ptr [esi] != 10
            inc esi
        .ENDW
    .ENDIF
    mov eax, esi
    sub eax, pName
    mov nameLen, eax
    .IF eax == 0 || eax >= MAX_PATH
        jmp done
    .ENDIF
    invoke MultiByteToWideChar, CP_ACP, 0, pName, nameLen, addr szName, MAX_PATH - 1
    mov word ptr szName[eax * 2], 0

    ; absolute (has ':' or starts with '\') or relative to the sheet's directory
    .IF szName[0] == '\' || szName[2] == ':'
        invoke lstrcpynW, offset g_szBinPath, addr szName, MAX_PATH
    .ELSE
        invoke lstrcpynW, offset g_szBinPath, pszCue, MAX_PATH
        mov esi, offset g_szBinPath
        mov edi, esi
        .WHILE word ptr [esi] != 0
            .IF word ptr [esi] == '\'
                lea edi, [esi + 2]
            .ENDIF
            add esi, 2
        .ENDW
        mov word ptr [edi], 0
        invoke lstrlenW, addr szName
        mov nameLen, eax
        invoke lstrlenW, offset g_szBinPath
        add eax, nameLen
        .IF eax >= MAX_PATH
            jmp done
        .ENDIF
        invoke lstrcatW, offset g_szBinPath, addr szName
    .ENDIF
    mov ok, TRUE

    ; TRACK 01 MODE1/2048 etc.
    invoke FindKeyword, pBuf, cb, offset szKwTrack
    .IF eax != 0
        mov esi, eax
        mov ecx, pBuf
        add ecx, cb
        sub ecx, esi
        push ecx
        invoke FindKeyword, esi, ecx, offset szKwM12048
        pop ecx
        .IF eax != 0
            mov g_cueFmt, FMT_ISO
        .ELSE
            push ecx
            invoke FindKeyword, esi, ecx, offset szKwM12352
            pop ecx
            .IF eax != 0
                mov g_cueFmt, FMT_RAW2352_M1
            .ELSE
                push ecx
                invoke FindKeyword, esi, ecx, offset szKwM22352
                pop ecx
                .IF eax != 0
                    mov g_cueFmt, FMT_RAW2352_M2
                .ELSE
                    invoke FindKeyword, esi, ecx, offset szKwM22336
                    .IF eax != 0
                        mov g_cueFmt, FMT_RAW2336
                    .ENDIF
                .ENDIF
            .ENDIF
        .ENDIF
    .ENDIF
done:
    invoke VfsFreeMem, pBuf
    mov eax, ok
    ret
CueParse ENDP

; ---------------------------------------------------------------------------
; IsoSetFormat - sector geometry for a FMT_* value
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
    mov eax, g_cbView
    xor edx, edx
    div g_secSize
    mov g_nSectors, eax
    ret
IsoSetFormat ENDP

; Does this file look like raw 2352-byte sectors? Returns FMT_* or -1.
IsoSniff PROC USES esi
    mov eax, g_cbView
    .IF eax < 2352 * 17
        mov eax, -1
        ret
    .ENDIF
    xor edx, edx
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
    LOCAL fmt:DWORD

    invoke IsoClose
    mov g_cueFmt, -1
    mov pData, 0

    ; .cue -> data file from the sheet
    invoke lstrlenW, pszPath
    .IF eax >= 4
        mov ecx, pszPath
        lea ecx, [ecx + eax * 2 - 8]
        invoke lstrcmpiW, ecx, offset szExtCue
        .IF eax == 0
            invoke CueParse, pszPath
            .IF eax == 0
                xor eax, eax
                ret
            .ENDIF
            mov g_bCue, TRUE
            mov pData, offset g_szBinPath
        .ENDIF
    .ENDIF
    .IF pData == 0
        mov eax, pszPath
        mov pData, eax
    .ENDIF

    invoke CreateFileW, pData, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov g_hFile, eax

    invoke GetFileSizeEx, g_hFile, addr liSize
    ; A 32-bit process cannot map more than ~2 GB in one view. Larger images need windowed views (TODO).
    cmp liSize[4], 0
    jne fail
    mov eax, liSize[0]
    cmp eax, 7FF00000h
    jae fail
    mov g_cbView, eax
    cmp eax, (ISO_VD_FIRST + 1) * ISO_SECTOR
    jb fail

    invoke CreateFileMappingW, g_hFile, NULL, PAGE_READONLY, 0, 0, NULL
    .IF eax == 0
        jmp fail
    .ENDIF
    mov g_hMap, eax
    invoke MapViewOfFile, g_hMap, FILE_MAP_READ, 0, 0, 0
    .IF eax == 0
        jmp fail
    .ENDIF
    mov g_pView, eax

    ; geometry: sheet wins, otherwise sniff for raw sectors, otherwise cooked
    mov eax, g_cueFmt
    .IF eax == -1
        invoke IsoSniff
    .ENDIF
    .IF eax == -1
        mov eax, FMT_ISO
    .ENDIF
    invoke IsoSetFormat, eax

    ; Walk the volume descriptor set starting at block 16 until the terminator.
    mov ebx, ISO_VD_FIRST
vd_loop:
    invoke IsoSectorPtr, ebx
    test eax, eax
    jz vd_done
    mov esi, eax
    cmp dword ptr [esi + ISO_VD_ID], 30304443h  ; "CD00"
    jne vd_done
    cmp byte ptr [esi + ISO_VD_ID + 4], '1'
    jne vd_done

    movzx eax, byte ptr [esi + ISO_VD_TYPE]
    .IF al == ISO_VD_TERMINATOR
        jmp vd_done
    .ELSEIF al == ISO_VD_PRIMARY
        .IF g_pPVD == 0
            mov g_pPVD, esi
        .ENDIF
    .ELSEIF al == ISO_VD_SUPPLEMENTARY
        .IF byte ptr [esi + ISO_VD_ESCAPES] == 25h && byte ptr [esi + ISO_VD_ESCAPES + 1] == 2Fh
            mov cl, byte ptr [esi + ISO_VD_ESCAPES + 2]
            .IF cl == 40h || cl == 43h || cl == 45h
                .IF g_pSVD == 0
                    mov g_pSVD, esi
                .ENDIF
            .ENDIF
        .ENDIF
    .ENDIF
    inc ebx
    cmp ebx, ISO_VD_FIRST + 64
    jb vd_loop

vd_done:
    .IF g_pPVD == 0
        jmp fail
    .ENDIF
    mov eax, g_pSVD
    .IF eax != 0
        mov g_bJoliet, TRUE
    .ELSE
        mov eax, g_pPVD
    .ENDIF
    add eax, ISO_VD_ROOT_RECORD
    mov g_pRoot, eax
    mov eax, TRUE
    ret

fail:
    invoke IsoClose
    xor eax, eax
    ret
IsoOpen ENDP

; ---------------------------------------------------------------------------
; IsoEnumDir - iterate the directory records in the extent described by pDirRec, one block at a time.
; Skips "." and "..". Callback is stdcall (pRec, lParam) and returns nonzero to continue.
; ---------------------------------------------------------------------------
IsoEnumDir PROC USES esi edi ebx pDirRec:DWORD, pfnCallback:DWORD, lParam:DWORD
    LOCAL lba:DWORD
    LOCAL remaining:DWORD
    LOCAL blk:DWORD

    mov esi, pDirRec
    mov eax, [esi].ISO_DIRREC.extentLE
    mov lba, eax
    mov eax, [esi].ISO_DIRREC.dataLenLE
    mov remaining, eax
    mov blk, 0

    .WHILE remaining != 0
        mov eax, lba
        add eax, blk
        invoke IsoSectorPtr, eax
        .IF eax == 0
            xor eax, eax
            ret
        .ENDIF
        mov esi, eax
        mov ecx, remaining
        .IF ecx > ISO_SECTOR
            mov ecx, ISO_SECTOR
        .ENDIF
        sub remaining, ecx
        lea edi, [esi + ecx]
        inc blk

        .WHILE esi < edi
            movzx eax, [esi].ISO_DIRREC.recLen
            .BREAK .IF eax == 0                 ; padding to the end of this block
            .IF eax < 33
                mov eax, TRUE
                ret
            .ENDIF
            lea edx, [esi + eax]
            .IF edx > edi
                mov eax, TRUE
                ret
            .ENDIF
            mov ebx, eax
            .IF [esi].ISO_DIRREC.nameLen == 1 && byte ptr [esi + 33] <= 1
                add esi, ebx
                .CONTINUE
            .ENDIF
            push lParam
            push esi
            call pfnCallback
            .IF eax == 0
                mov eax, TRUE
                ret
            .ENDIF
            add esi, ebx
        .ENDW
    .ENDW
    mov eax, TRUE
    ret
IsoEnumDir ENDP

; ---------------------------------------------------------------------------
; Extent access (block-wise, so raw images work)
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

IsoRecDate PROC USES esi pRec:DWORD, pszBuf:DWORD
    mov esi, pRec
    movzx eax, [esi].ISO_DIRREC.recMinute
    push eax
    movzx eax, [esi].ISO_DIRREC.recHour
    push eax
    movzx eax, [esi].ISO_DIRREC.recDay
    push eax
    movzx eax, [esi].ISO_DIRREC.recMonth
    push eax
    movzx eax, [esi].ISO_DIRREC.recYear
    add eax, 1900
    push eax
    push offset szDateFmt
    push pszBuf
    call wsprintfW
    add esp, 7 * 4
    ret
IsoRecDate ENDP

IsoVolumeName PROC USES esi edi pszBuf:DWORD, cchBuf:DWORD
    mov edi, pszBuf
    mov edx, cchBuf
    dec edx
    .IF edx > 32
        mov edx, 32
    .ENDIF
    .IF g_pPVD == 0
        xor eax, eax
        stosw
        ret
    .ENDIF
    .IF g_bJoliet != 0
        mov esi, g_pSVD
        add esi, ISO_VD_VOLUME_ID
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
        mov esi, g_pPVD
        add esi, ISO_VD_VOLUME_ID
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
    mov pBase, offset szFmtIso
    mov eax, g_fmt
    .IF eax == FMT_RAW2352_M1 || eax == FMT_RAW2352_M2
        mov pBase, offset szFmtRaw2352
    .ELSEIF eax == FMT_RAW2336
        mov pBase, offset szFmtRaw2336
    .ENDIF
    mov ecx, offset szFmtJoliet
    .IF g_bJoliet == 0
        mov ecx, offset szCatFmt
        add ecx, 8                          ; empty string (the terminator of szCatFmt)
    .ENDIF
    invoke wsprintfW, pszBuf, offset szCatFmt, pBase, ecx
    ret
IsoFormatName ENDP

END
