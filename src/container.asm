; FoxImg - optical image containers: NRG, MDS/MDF, CCD/IMG, GDI, TOC, plus a generic "find the ISO inside" fallback
;
; A container resolves to: the file that holds the sectors (g_szBinPath), the byte offset where the data track
; starts (g_ctBaseLo/Hi), the physical sector size and the offset of the 2048 user bytes inside it, and the LBA
; the track starts at (g_ctLbaBase). The block layer in iso9660.asm then reads it like any other image.
include foximg.inc

CT_SCAN_MAX     equ 1024 * 1024 * 1024  ; bytes searched by the generic fallback

.data
g_ctBaseLo      dd 0
g_ctBaseHi      dd 0
g_ctSecSize     dd 0
g_ctSecOff      dd 0
g_ctLbaBase     dd 0
g_ctName        dd 0            ; WSTR of the container kind, 0 when none
g_bContainer    dd 0            ; opened through a read-only container

WSTR szCtNrg, <NRG>
WSTR szCtMds, <MDS/MDF>
WSTR szCtCcd, <CCD/IMG>
WSTR szCtGdi, <GDI>
WSTR szCtToc, <TOC>
WSTR szCtScan, <Container>
WSTR szExtNrg, <.nrg>
WSTR szExtMds, <.mds>
WSTR szExtMdf, <.mdf>
WSTR szExtCcd, <.ccd>
WSTR szExtImg, <.img>
WSTR szExtGdi, <.gdi>
WSTR szExtToc, <.toc>
WSTR szExtCdi, <.cdi>
szNER5          db 'NER5'
szNERO          db 'NERO'
szDAOX          db 'DAOX'
szDAOI          db 'DAOI'
szETN2          db 'ETN2'
szETNF          db 'ETNF'
szMEDIA         db 'MEDIA DESCRIPTOR'
szKwDatafile    db 'DATAFILE', 0
szKwFile        db 'FILE', 0
szKwRaw         db '_RAW', 0
szKwFormMix     db 'FORM_MIX', 0
szCD001         db 'CD001'

.code

; ---------------------------------------------------------------------------
; Small file helpers (the image is not mapped yet while a container is being resolved)
; ---------------------------------------------------------------------------
; Read cb bytes at 64-bit offset into pDst. Returns bytes read.
CtReadAt PROC hFile:DWORD, offLo:DWORD, offHi:DWORD, pDst:DWORD, cb:DWORD
    LOCAL nRead:DWORD
    invoke SetFilePointerEx, hFile, offLo, offHi, NULL, FILE_BEGIN
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov nRead, 0
    invoke ReadFile, hFile, pDst, cb, addr nRead, NULL
    mov eax, nRead
    ret
CtReadAt ENDP

CtFileSize PROC hFile:DWORD, pLo:DWORD, pHi:DWORD
    LOCAL li[2]:DWORD
    invoke GetFileSizeEx, hFile, addr li
    mov eax, li[0]
    mov ecx, pLo
    mov [ecx], eax
    mov eax, li[4]
    mov ecx, pHi
    mov [ecx], eax
    ret
CtFileSize ENDP

BSwap32 PROC val:DWORD
    mov eax, val
    bswap eax
    ret
BSwap32 ENDP

; Replace the extension of pszPath (into pszOut) with pszExt
CtSibling PROC USES esi pszOut:DWORD, pszPath:DWORD, pszExt:DWORD
    invoke lstrcpynW, pszOut, pszPath, MAX_PATH - 8
    mov esi, pszOut
    mov edx, 0
    .WHILE word ptr [esi] != 0
        .IF word ptr [esi] == '.'
            mov edx, esi
        .ELSEIF word ptr [esi] == '\'
            mov edx, 0
        .ENDIF
        add esi, 2
    .ENDW
    .IF edx == 0
        mov edx, esi
    .ENDIF
    mov word ptr [edx], 0
    invoke lstrcatW, pszOut, pszExt
    ret
CtSibling ENDP

; Does pszPath end with pszExt (case-insensitive)?
CtHasExt PROC pszPath:DWORD, pszExt:DWORD
    LOCAL cchExt:DWORD
    invoke lstrlenW, pszExt
    mov cchExt, eax
    invoke lstrlenW, pszPath
    .IF eax < cchExt
        xor eax, eax
        ret
    .ENDIF
    sub eax, cchExt
    mov ecx, pszPath
    lea ecx, [ecx + eax * 2]
    invoke lstrcmpiW, ecx, pszExt
    .IF eax == 0
        mov eax, TRUE
    .ELSE
        xor eax, eax
    .ENDIF
    ret
CtHasExt ENDP

; Data offset of the 2048 user bytes for a physical sector size, sniffing the mode byte when raw
CtDataOffset PROC hFile:DWORD, baseLo:DWORD, baseHi:DWORD, secSize:DWORD
    LOCAL hdr[32]:BYTE
    mov eax, secSize
    .IF eax == 2048 || eax == 2056
        xor eax, eax
        ret
    .ELSEIF eax == 2336
        mov eax, 8
        ret
    .ENDIF
    ; 2352 / 2368 / 2448: sync + header; mode byte at 15
    invoke CtReadAt, hFile, baseLo, baseHi, addr hdr, 16
    .IF eax == 16 && hdr[15] == 2
        mov eax, 24
        ret
    .ENDIF
    mov eax, 16
    ret
CtDataOffset ENDP

CtSet PROC baseLo:DWORD, baseHi:DWORD, secSize:DWORD, secOff:DWORD, lbaBase:DWORD, pszName:DWORD
    mov eax, baseLo
    mov g_ctBaseLo, eax
    mov eax, baseHi
    mov g_ctBaseHi, eax
    mov eax, secSize
    mov g_ctSecSize, eax
    mov eax, secOff
    mov g_ctSecOff, eax
    mov eax, lbaBase
    mov g_ctLbaBase, eax
    mov eax, pszName
    mov g_ctName, eax
    mov g_bContainer, TRUE
    ret
CtSet ENDP

; Case-insensitive ASCII keyword search (same as the CUE parser's)
CtFindKeyword PROC USES esi edi ebx pBuf:DWORD, cb:DWORD, pszKey:DWORD
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
CtFindKeyword ENDP

; Read a small text file into a NUL-terminated heap buffer (caller frees); returns pointer, *pcb = length
CtReadText PROC pszPath:DWORD, pcb:DWORD
    LOCAL hFile:DWORD
    LOCAL lo:DWORD
    LOCAL hi:DWORD
    LOCAL pBuf:DWORD
    invoke CreateFileW, pszPath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hFile, eax
    invoke CtFileSize, hFile, addr lo, addr hi
    .IF hi != 0 || lo > 65536
        mov lo, 65536
    .ENDIF
    mov eax, lo
    inc eax
    invoke VfsAlloc, eax
    mov pBuf, eax
    .IF eax != 0
        invoke CtReadAt, hFile, 0, 0, pBuf, lo
        mov ecx, pcb
        mov [ecx], eax
    .ENDIF
    invoke CloseHandle, hFile
    mov eax, pBuf
    ret
CtReadText ENDP

; Parse an unsigned decimal at pText; returns value in eax and pointer past it in edx
CtParseUint PROC USES esi pText:DWORD
    mov esi, pText
    .WHILE byte ptr [esi] == ' ' || byte ptr [esi] == 9
        inc esi
    .ENDW
    xor eax, eax
    .WHILE byte ptr [esi] >= '0' && byte ptr [esi] <= '9'
        movzx ecx, byte ptr [esi]
        sub ecx, '0'
        imul eax, 10
        add eax, ecx
        inc esi
    .ENDW
    mov edx, esi
    ret
CtParseUint ENDP

; Quoted or bare token at pText -> UTF-16 into pszOut (MAX_PATH); returns pointer past it in edx
CtParseName PROC USES esi edi ebx pText:DWORD, pszOut:DWORD
    mov esi, pText
    .WHILE byte ptr [esi] == ' ' || byte ptr [esi] == 9
        inc esi
    .ENDW
    mov ebx, esi
    .IF byte ptr [esi] == '"'
        inc esi
        mov ebx, esi
        .WHILE byte ptr [esi] != 0 && byte ptr [esi] != '"' && byte ptr [esi] != 13 && byte ptr [esi] != 10
            inc esi
        .ENDW
    .ELSE
        .WHILE byte ptr [esi] != 0 && byte ptr [esi] != ' ' && byte ptr [esi] != 9 && byte ptr [esi] != 13 && byte ptr [esi] != 10
            inc esi
        .ENDW
    .ENDIF
    mov ecx, esi
    sub ecx, ebx
    .IF ecx >= MAX_PATH
        mov ecx, MAX_PATH - 1
    .ENDIF
    push esi
    invoke MultiByteToWideChar, CP_ACP, 0, ebx, ecx, pszOut, MAX_PATH - 1
    mov ecx, pszOut
    mov word ptr [ecx + eax * 2], 0
    pop esi
    .IF byte ptr [esi] == '"'
        inc esi
    .ENDIF
    mov edx, esi
    ret
CtParseName ENDP

; pszOut = directory of pszRef + pszName, unless pszName is absolute
CtResolveRelative PROC USES esi edi pszOut:DWORD, pszRef:DWORD, pszName:DWORD
    mov eax, pszName
    .IF word ptr [eax] == '\' || word ptr [eax + 2] == ':'
        invoke lstrcpynW, pszOut, pszName, MAX_PATH
        ret
    .ENDIF
    invoke lstrcpynW, pszOut, pszRef, MAX_PATH
    mov esi, pszOut
    mov edi, esi
    .WHILE word ptr [esi] != 0
        .IF word ptr [esi] == '\'
            lea edi, [esi + 2]
        .ENDIF
        add esi, 2
    .ENDW
    mov word ptr [edi], 0
    invoke lstrlenW, pszOut
    mov esi, eax
    invoke lstrlenW, pszName
    add eax, esi
    .IF eax < MAX_PATH
        invoke lstrcatW, pszOut, pszName
    .ENDIF
    ret
CtResolveRelative ENDP

; ---------------------------------------------------------------------------
; NRG (Nero): chunk list at the end of the file, pointed to by a NERO (v1) or NER5 (v2) footer
; ---------------------------------------------------------------------------
CtOpenNrg PROC USES esi edi ebx pszPath:DWORD
    LOCAL hFile:DWORD
    LOCAL sizeLo:DWORD
    LOCAL sizeHi:DWORD
    LOCAL footer[12]:BYTE
    LOCAL chunkLo:DWORD
    LOCAL chunkHi:DWORD
    LOCAL pBuf:DWORD
    LOCAL cb:DWORD
    LOCAL v2:DWORD
    LOCAL secSize:DWORD
    LOCAL baseLo:DWORD
    LOCAL baseHi:DWORD
    LOCAL lba:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    invoke CreateFileW, pszPath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov hFile, eax
    invoke CtFileSize, hFile, addr sizeLo, addr sizeHi
    mov eax, sizeLo
    sub eax, 12
    mov ecx, sizeHi
    sbb ecx, 0
    mov edx, eax
    invoke CtReadAt, hFile, edx, ecx, addr footer, 12
    .IF eax != 12
        jmp done
    .ENDIF
    ; v2: "NER5" + 64-bit big-endian offset; v1: last 8 bytes "NERO" + 32-bit big-endian offset
    .IF dword ptr footer[0] == '5REN'
        mov v2, TRUE
        invoke BSwap32, dword ptr footer[8]
        mov chunkLo, eax
        invoke BSwap32, dword ptr footer[4]
        mov chunkHi, eax
    .ELSEIF dword ptr footer[4] == 'OREN'
        mov v2, FALSE
        invoke BSwap32, dword ptr footer[8]
        mov chunkLo, eax
        mov chunkHi, 0
    .ELSE
        jmp done
    .ENDIF
    ; chunk area = from chunk offset to the footer
    mov eax, sizeLo
    sub eax, chunkLo
    mov ecx, sizeHi
    sbb ecx, chunkHi
    .IF ecx != 0 || eax > 1024 * 1024 || eax < 16
        jmp done
    .ENDIF
    mov cb, eax
    invoke VfsAlloc, eax
    mov pBuf, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke CtReadAt, hFile, chunkLo, chunkHi, pBuf, cb
    .IF eax != cb
        jmp free_done
    .ENDIF

    ; walk chunks: id(4) size(4 BE) payload
    mov esi, pBuf
    mov edi, esi
    add edi, cb
    .WHILE TRUE
        lea eax, [esi + 8]
        .BREAK .IF eax > edi
        invoke BSwap32, dword ptr [esi + 4]
        mov ebx, eax                        ; payload size
        lea eax, [esi + 8 + ebx]
        .BREAK .IF eax > edi
        mov eax, dword ptr [esi]
        .IF eax == 'XOAD'                   ; DAOX: header 22, then 42-byte tracks
            .IF ebx >= 22 + 42
                lea ecx, [esi + 8 + 22]
                movzx eax, word ptr [ecx + 12]
                xchg al, ah
                mov secSize, eax
                invoke BSwap32, dword ptr [ecx + 26 + 4]    ; index1 low (offset 26..33, big-endian 64)
                mov baseLo, eax
                invoke BSwap32, dword ptr [ecx + 26]
                mov baseHi, eax
                mov lba, 0
                mov ok, TRUE
            .ENDIF
            .BREAK
        .ELSEIF eax == 'IOAD'               ; DAOI: header 22, then 30-byte tracks (32-bit fields)
            .IF ebx >= 22 + 30
                lea ecx, [esi + 8 + 22]
                invoke BSwap32, dword ptr [ecx + 12]
                mov secSize, eax
                invoke BSwap32, dword ptr [ecx + 24]        ; index1
                mov baseLo, eax
                mov baseHi, 0
                mov lba, 0
                mov ok, TRUE
            .ENDIF
            .BREAK
        .ELSEIF eax == '2NTE'               ; ETN2: 32-byte entries: offset(8) length(8) mode(4) lba(4) ...
            .IF ebx >= 32
                lea ecx, [esi + 8]
                invoke BSwap32, dword ptr [ecx + 4]
                mov baseLo, eax
                invoke BSwap32, dword ptr [ecx]
                mov baseHi, eax
                invoke BSwap32, dword ptr [ecx + 16]
                mov secSize, eax                            ; mode, translated below
                invoke BSwap32, dword ptr [ecx + 20]
                mov lba, eax
                mov ok, 2
            .ENDIF
            .BREAK
        .ELSEIF eax == 'FNTE'               ; ETNF: 20-byte entries: offset(4) length(4) mode(4) lba(4) ...
            .IF ebx >= 20
                lea ecx, [esi + 8]
                invoke BSwap32, dword ptr [ecx]
                mov baseLo, eax
                mov baseHi, 0
                invoke BSwap32, dword ptr [ecx + 8]
                mov secSize, eax
                invoke BSwap32, dword ptr [ecx + 12]
                mov lba, eax
                mov ok, 2
            .ENDIF
            .BREAK
        .ENDIF
        lea esi, [esi + 8 + ebx]
    .ENDW
    .IF ok == 2
        ; Nero track modes: 0 = MODE1/2048, 2 = MODE2 form1/2048, 3 = MODE2/2336, 5 = raw MODE1/2352,
        ; 6 = raw MODE2/2352, 7 = audio 2352, 0F/10 = raw + subchannel 2448
        mov eax, secSize
        .IF eax == 0 || eax == 2
            mov secSize, 2048
        .ELSEIF eax == 3
            mov secSize, 2336
        .ELSEIF eax == 0Fh || eax == 10h
            mov secSize, 2448
        .ELSE
            mov secSize, 2352
        .ENDIF
        mov ok, TRUE
    .ENDIF
    .IF ok != 0
        invoke CtDataOffset, hFile, baseLo, baseHi, secSize
        invoke CtSet, baseLo, baseHi, secSize, eax, lba, offset szCtNrg
        invoke lstrcpynW, offset g_szBinPath, pszPath, MAX_PATH
    .ENDIF
free_done:
    invoke VfsFreeMem, pBuf
done:
    invoke CloseHandle, hFile
    mov eax, ok
    ret
CtOpenNrg ENDP

; ---------------------------------------------------------------------------
; MDS (Alcohol 120%): "MEDIA DESCRIPTOR" header, session blocks, track blocks; data in the sibling .mdf
; ---------------------------------------------------------------------------
CtOpenMds PROC USES esi edi ebx pszPath:DWORD
    LOCAL hFile:DWORD
    LOCAL hdr[88]:BYTE
    LOCAL sess[24]:BYTE
    LOCAL trk[80]:BYTE
    LOCAL sessOff:DWORD
    LOCAL trkOff:DWORD
    LOCAL nBlocks:DWORD
    LOCAL secSize:DWORD
    LOCAL baseLo:DWORD
    LOCAL baseHi:DWORD
    LOCAL lba:DWORD
    LOCAL ok:DWORD
    LOCAL szMdf[MAX_PATH]:WORD

    mov ok, FALSE
    invoke CreateFileW, pszPath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov hFile, eax
    invoke CtReadAt, hFile, 0, 0, addr hdr, 88
    .IF eax != 88
        jmp done
    .ENDIF
    lea esi, hdr
    mov edi, offset szMEDIA
    mov ecx, 16
    repe cmpsb
    jne done
    mov eax, dword ptr hdr[80]              ; sessions block offset
    mov sessOff, eax
    invoke CtReadAt, hFile, sessOff, 0, addr sess, 24
    .IF eax != 24
        jmp done
    .ENDIF
    movzx eax, byte ptr sess[10]            ; number of all blocks in this session
    mov nBlocks, eax
    mov eax, dword ptr sess[20]             ; tracks block offset
    mov trkOff, eax
    ; first real track (point < A0h) with a data mode
    xor ebx, ebx
    .WHILE ebx < nBlocks
        invoke CtReadAt, hFile, trkOff, 0, addr trk, 80
        .BREAK .IF eax != 80
        movzx eax, byte ptr trk[4]          ; point
        .IF eax < 0A0h && eax != 0
            movzx eax, byte ptr trk[0]      ; mode: A9 audio, AA mode1, AB mode2, AC/AD mode2 forms, EC DVD
            .IF eax != 0A9h && eax != 0
                movzx eax, word ptr trk[16]
                mov secSize, eax
                mov eax, dword ptr trk[36]
                mov lba, eax
                mov eax, dword ptr trk[40]
                mov baseLo, eax
                mov eax, dword ptr trk[44]
                mov baseHi, eax
                mov ok, TRUE
                .BREAK
            .ENDIF
        .ENDIF
        add trkOff, 80
        inc ebx
    .ENDW
    .IF ok != 0
        .IF secSize == 0
            mov secSize, 2048
        .ENDIF
        invoke CtSibling, addr szMdf, pszPath, offset szExtMdf
        invoke CloseHandle, hFile
        invoke CreateFileW, addr szMdf, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
        .IF eax == INVALID_HANDLE_VALUE
            mov ok, FALSE
            ret
        .ENDIF
        mov hFile, eax
        invoke CtDataOffset, hFile, baseLo, baseHi, secSize
        invoke CtSet, baseLo, baseHi, secSize, eax, lba, offset szCtMds
        invoke lstrcpynW, offset g_szBinPath, addr szMdf, MAX_PATH
    .ENDIF
done:
    invoke CloseHandle, hFile
    mov eax, ok
    ret
CtOpenMds ENDP

; ---------------------------------------------------------------------------
; CCD (CloneCD): the .img beside it is raw sectors; nothing to parse
; ---------------------------------------------------------------------------
CtOpenCcd PROC pszPath:DWORD
    LOCAL szImg[MAX_PATH]:WORD
    LOCAL hFile:DWORD
    invoke CtSibling, addr szImg, pszPath, offset szExtImg
    invoke CreateFileW, addr szImg, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hFile, eax
    invoke CtDataOffset, hFile, 0, 0, 2352
    invoke CtSet, 0, 0, 2352, eax, 0, offset szCtCcd
    invoke CloseHandle, hFile
    invoke lstrcpynW, offset g_szBinPath, addr szImg, MAX_PATH
    mov eax, TRUE
    ret
CtOpenCcd ENDP

; ---------------------------------------------------------------------------
; GDI (Dreamcast): "N\n" then "track lba type sectorsize file offset" per line; the data area is track 3+
; ---------------------------------------------------------------------------
CtOpenGdi PROC USES esi edi ebx pszPath:DWORD
    LOCAL pText:DWORD
    LOCAL cb:DWORD
    LOCAL n:DWORD
    LOCAL lba:DWORD
    LOCAL ttype:DWORD
    LOCAL secSize:DWORD
    LOCAL szName[MAX_PATH]:WORD
    LOCAL szData[MAX_PATH]:WORD
    LOCAL hFile:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    invoke CtReadText, pszPath, addr cb
    .IF eax == 0
        ret
    .ENDIF
    mov pText, eax
    mov esi, eax
    invoke CtParseUint, esi                 ; track count
    mov esi, edx
    mov n, eax
    .WHILE n != 0
        ; skip to next line start
        .WHILE byte ptr [esi] != 0 && byte ptr [esi] != 10
            inc esi
        .ENDW
        .BREAK .IF byte ptr [esi] == 0
        inc esi
        invoke CtParseUint, esi             ; track number
        mov esi, edx
        invoke CtParseUint, esi             ; lba
        mov esi, edx
        mov lba, eax
        invoke CtParseUint, esi             ; type: 4 = data, 0 = audio
        mov esi, edx
        mov ttype, eax
        invoke CtParseUint, esi             ; sector size
        mov esi, edx
        mov secSize, eax
        invoke CtParseName, esi, addr szName
        mov esi, edx
        .IF ttype == 4 && lba >= 45000
            invoke CtResolveRelative, addr szData, pszPath, addr szName
            invoke CreateFileW, addr szData, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
            .IF eax != INVALID_HANDLE_VALUE
                mov hFile, eax
                invoke CtDataOffset, hFile, 0, 0, secSize
                invoke CtSet, 0, 0, secSize, eax, lba, offset szCtGdi
                invoke CloseHandle, hFile
                invoke lstrcpynW, offset g_szBinPath, addr szData, MAX_PATH
                mov ok, TRUE
            .ENDIF
            .BREAK
        .ENDIF
        dec n
    .ENDW
    invoke VfsFreeMem, pText
    mov eax, ok
    ret
CtOpenGdi ENDP

; ---------------------------------------------------------------------------
; TOC (cdrdao): DATAFILE "name" [#offset] ...; track mode gives the sector size
; ---------------------------------------------------------------------------
CtOpenToc PROC USES esi pszPath:DWORD
    LOCAL pText:DWORD
    LOCAL cb:DWORD
    LOCAL secSize:DWORD
    LOCAL szName[MAX_PATH]:WORD
    LOCAL szData[MAX_PATH]:WORD
    LOCAL hFile:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    invoke CtReadText, pszPath, addr cb
    .IF eax == 0
        ret
    .ENDIF
    mov pText, eax
    invoke CtFindKeyword, pText, cb, offset szKwDatafile
    .IF eax == 0
        jmp done
    .ENDIF
    mov edx, eax
    invoke CtParseName, edx, addr szName
    invoke CtResolveRelative, addr szData, pszPath, addr szName
    invoke CreateFileW, addr szData, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hFile, eax
    ; MODE1_RAW / MODE2_RAW -> 2352, MODE2_FORM_MIX -> 2336, else 2048
    mov secSize, 2048
    invoke CtFindKeyword, pText, cb, offset szKwRaw
    .IF eax != 0
        mov secSize, 2352
    .ELSE
        invoke CtFindKeyword, pText, cb, offset szKwFormMix
        .IF eax != 0
            mov secSize, 2336
        .ENDIF
    .ENDIF
    invoke CtDataOffset, hFile, 0, 0, secSize
    invoke CtSet, 0, 0, secSize, eax, 0, offset szCtToc
    invoke CloseHandle, hFile
    invoke lstrcpynW, offset g_szBinPath, addr szData, MAX_PATH
    mov ok, TRUE
done:
    invoke VfsFreeMem, pText
    mov eax, ok
    ret
CtOpenToc ENDP

; ---------------------------------------------------------------------------
; Generic fallback: find the first "CD001" primary descriptor in the file and infer sector size and offset.
; Works for CDI and any container that stores the data track as plain sectors.
; ---------------------------------------------------------------------------
CtScan PROC USES esi edi ebx pszPath:DWORD
    LOCAL hFile:DWORD
    LOCAL pBuf:DWORD
    LOCAL posLo:DWORD
    LOCAL posHi:DWORD
    LOCAL got:DWORD
    LOCAL hitLo:DWORD
    LOCAL hitHi:DWORD
    LOCAL secSize:DWORD
    LOCAL probe[32]:BYTE
    LOCAL ok:DWORD
    LOCAL baseLo:DWORD
    LOCAL baseHi:DWORD
    LOCAL secOff:DWORD

    mov ok, FALSE
    invoke CreateFileW, pszPath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov hFile, eax
    invoke VfsAlloc, 1024 * 1024 + 8
    mov pBuf, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov posLo, 0
    mov posHi, 0
    mov hitLo, 0
    mov hitHi, 0
    mov got, 0
    ; 1 MB windows, overlapped by 8 bytes so a signature on a boundary is not missed
    .WHILE posHi == 0 && posLo < CT_SCAN_MAX
        invoke CtReadAt, hFile, posLo, posHi, pBuf, 1024 * 1024 + 8
        .BREAK .IF eax < 7
        mov got, eax
        mov esi, pBuf
        xor ebx, ebx
        mov ecx, got
        sub ecx, 6
        .WHILE ebx < ecx
            .IF byte ptr [esi + ebx] == 'C' && dword ptr [esi + ebx] == '00DC' && byte ptr [esi + ebx + 4] == '1'
                ; descriptor type byte precedes the id
                .IF ebx != 0 && byte ptr [esi + ebx - 1] == 1
                    mov eax, posLo
                    add eax, ebx
                    dec eax
                    mov hitLo, eax
                    mov eax, posHi
                    mov hitHi, eax
                    mov ok, 1
                    .BREAK
                .ENDIF
            .ENDIF
            inc ebx
        .ENDW
        .BREAK .IF ok != 0
        add posLo, 1024 * 1024
        adc posHi, 0
    .ENDW
    .IF ok == 0
        jmp free_done
    .ENDIF
    mov ok, FALSE

    ; sector size: the next descriptor (type 2 or 255, "CD001") sits one sector further
    mov secSize, 0
    mov ebx, 2048
    .WHILE ebx <= 2448
        mov eax, hitLo
        add eax, ebx
        mov ecx, hitHi
        adc ecx, 0
        push ebx
        mov edx, eax
        invoke CtReadAt, hFile, edx, ecx, addr probe, 6
        pop ebx
        .IF eax == 6 && dword ptr probe[1] == '00DC' && probe[5] == '1'
            mov secSize, ebx
            .BREAK
        .ENDIF
        .IF ebx == 2048
            mov ebx, 2336
        .ELSEIF ebx == 2336
            mov ebx, 2352
        .ELSEIF ebx == 2352
            mov ebx, 2448
        .ELSE
            inc ebx
        .ENDIF
    .ENDW
    .IF secSize == 0
        jmp free_done
    .ENDIF
    ; data offset inside the sector by size, then base = hit - 16 sectors - offset
    mov secOff, 0
    .IF secSize == 2336
        mov secOff, 8
    .ELSEIF secSize >= 2352
        ; mode byte 15 of the sector holding the PVD
        mov eax, hitLo
        sub eax, 16
        mov ecx, hitHi
        sbb ecx, 0
        push eax
        push ecx
        mov edx, eax
        invoke CtReadAt, hFile, edx, ecx, addr probe, 1
        pop ecx
        pop eax
        mov secOff, 16
        ; when the data offset is 24 (mode 2) the mode byte is 8 bytes earlier than assumed; probe both
        mov eax, hitLo
        sub eax, 24
        mov ecx, hitHi
        sbb ecx, 0
        mov edx, eax
        invoke CtReadAt, hFile, edx, ecx, addr probe, 16
        .IF eax == 16 && probe[0] == 0 && probe[1] == 0FFh && probe[11] == 0 && probe[15] == 2
            mov secOff, 24
        .ENDIF
    .ENDIF
    mov eax, secSize
    shl eax, 4                              ; 16 * secSize
    add eax, secOff
    mov ecx, hitLo
    sub ecx, eax
    mov baseLo, ecx
    mov ecx, hitHi
    sbb ecx, 0
    mov baseHi, ecx
    .IF ecx == 0 && baseLo == 0 && secSize == 2048
        jmp free_done                       ; a plain image; no container needed
    .ENDIF
    invoke CtSet, baseLo, baseHi, secSize, secOff, 0, offset szCtScan
    invoke lstrcpynW, offset g_szBinPath, pszPath, MAX_PATH
    mov ok, TRUE
free_done:
    invoke VfsFreeMem, pBuf
done:
    invoke CloseHandle, hFile
    mov eax, ok
    ret
CtScan ENDP

; ---------------------------------------------------------------------------
; Entry points
; ---------------------------------------------------------------------------
CtReset PROC
    mov g_ctBaseLo, 0
    mov g_ctBaseHi, 0
    mov g_ctSecSize, 0
    mov g_ctSecOff, 0
    mov g_ctLbaBase, 0
    mov g_ctName, 0
    mov g_bContainer, 0
    ret
CtReset ENDP

; By extension. Returns TRUE when a container was recognised and g_szBinPath / geometry are set.
CtResolve PROC pszPath:DWORD
    invoke CtReset
    invoke CtHasExt, pszPath, offset szExtNrg
    .IF eax != 0
        invoke CtOpenNrg, pszPath
        ret
    .ENDIF
    invoke CtHasExt, pszPath, offset szExtMds
    .IF eax != 0
        invoke CtOpenMds, pszPath
        ret
    .ENDIF
    invoke CtHasExt, pszPath, offset szExtCcd
    .IF eax != 0
        invoke CtOpenCcd, pszPath
        ret
    .ENDIF
    invoke CtHasExt, pszPath, offset szExtGdi
    .IF eax != 0
        invoke CtOpenGdi, pszPath
        ret
    .ENDIF
    invoke CtHasExt, pszPath, offset szExtToc
    .IF eax != 0
        invoke CtOpenToc, pszPath
        ret
    .ENDIF
    invoke CtHasExt, pszPath, offset szExtCdi
    .IF eax != 0
        invoke CtScan, pszPath
        ret
    .ENDIF
    xor eax, eax
    ret
CtResolve ENDP

; Last resort for files that did not show a descriptor at block 16
CtResolveByScan PROC pszPath:DWORD
    invoke CtReset
    invoke CtScan, pszPath
    ret
CtResolveByScan ENDP

END
