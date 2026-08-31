; FoxImg - optical image containers: CUE, NRG, MDS/MDF, CCD/IMG, GDI, TOC, plus a generic "find the ISO inside" fallback
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
g_bContainer    dd 0            ; opened through a container (read-only unless g_bCue)

WSTR szCtCue, <CUE>
WSTR szCtNrg, <NRG>
WSTR szCtMds, <MDS/MDF>
WSTR szCtCcd, <CCD/IMG>
WSTR szCtGdi, <GDI>
WSTR szCtToc, <TOC>
WSTR szCtScan, <Container>
WSTR szExtCue, <.cue>
WSTR szExtNrg, <.nrg>
WSTR szExtMds, <.mds>
WSTR szExtMdf, <.mdf>
WSTR szExtCcd, <.ccd>
WSTR szExtImg, <.img>
WSTR szExtGdi, <.gdi>
WSTR szExtToc, <.toc>
WSTR szExtCdi, <.cdi>
szMEDIA         db 'MEDIA DESCRIPTOR'
szKwDatafile    db 'DATAFILE', 0
szKwFile        db 'FILE', 0
szKwTrack       db 'TRACK', 0
szKwM12048      db 'MODE1/2048', 0
szKwM12352      db 'MODE1/2352', 0
szKwM22352      db 'MODE2/2352', 0
szKwM22336      db 'MODE2/2336', 0
szKwRaw         db '_RAW', 0
szKwFormMix     db 'FORM_MIX', 0

.code

CtIsRawAt PROTO :DWORD,:DWORD,:DWORD

BSwap32 PROC val:DWORD
    mov eax, val
    bswap eax
    ret
BSwap32 ENDP

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
    invoke FileReadAt, hFile, baseLo, baseHi, addr hdr, 16
    .IF eax == 16 && hdr[15] == 2
        mov eax, 24
        ret
    .ENDIF
    mov eax, 16
    ret
CtDataOffset ENDP

; Open the data file, derive the data offset for secSize, record the geometry. Returns TRUE on success.
CtFinish PROC pszData:DWORD, baseLo:DWORD, baseHi:DWORD, secSize:DWORD, lbaBase:DWORD, pszName:DWORD
    LOCAL hFile:DWORD
    invoke CreateFileW, pszData, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hFile, eax
    .IF secSize == 0
        ; unknown: raw when the first sector carries a sync pattern
        mov secSize, 2048
        invoke CtIsRawAt, hFile, baseLo, baseHi
        .IF eax != 0
            mov secSize, 2352
        .ENDIF
    .ENDIF
    invoke CtDataOffset, hFile, baseLo, baseHi, secSize
    push eax
    invoke CloseHandle, hFile
    pop eax
    mov ecx, baseLo
    mov g_ctBaseLo, ecx
    mov ecx, baseHi
    mov g_ctBaseHi, ecx
    mov ecx, secSize
    mov g_ctSecSize, ecx
    mov g_ctSecOff, eax
    mov eax, lbaBase
    mov g_ctLbaBase, eax
    mov eax, pszName
    mov g_ctName, eax
    mov g_bContainer, TRUE
    invoke lstrcpynW, offset g_szBinPath, pszData, MAX_PATH
    mov eax, TRUE
    ret
CtFinish ENDP

; Sync pattern 00 FF*10 00 at the given offset?
CtIsRawAt PROC USES esi hFile:DWORD, offLo:DWORD, offHi:DWORD
    LOCAL hdr[16]:BYTE
    invoke FileReadAt, hFile, offLo, offHi, addr hdr, 12
    .IF eax != 12 || hdr[0] != 0 || hdr[11] != 0
        xor eax, eax
        ret
    .ENDIF
    lea esi, hdr
    mov ecx, 1
    .WHILE ecx < 11
        .IF byte ptr [esi + ecx] != 0FFh
            xor eax, eax
            ret
        .ENDIF
        inc ecx
    .ENDW
    mov eax, TRUE
    ret
CtIsRawAt ENDP

; ---------------------------------------------------------------------------
; CUE: FILE "name" BINARY, first TRACK mode. Writable (Save keeps BIN + CUE).
; ---------------------------------------------------------------------------
CtOpenCue PROC USES esi pszPath:DWORD
    LOCAL pText:DWORD
    LOCAL cb:DWORD
    LOCAL szName[MAX_PATH]:WORD
    LOCAL szData[MAX_PATH]:WORD
    LOCAL secSize:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    invoke ReadTextFile, pszPath, addr cb
    .IF eax == 0
        ret
    .ENDIF
    mov pText, eax
    invoke FindKeyword, pText, cb, offset szKwFile
    .IF eax == 0
        jmp done
    .ENDIF
    mov edx, eax
    invoke ParseName, edx, addr szName
    invoke PathDirJoin, addr szData, pszPath, addr szName
    mov secSize, 0
    invoke FindKeyword, pText, cb, offset szKwTrack
    .IF eax != 0
        mov esi, eax
        mov ecx, pText
        add ecx, cb
        sub ecx, esi
        push ecx
        invoke FindKeyword, esi, ecx, offset szKwM12048
        pop ecx
        .IF eax != 0
            mov secSize, 2048
        .ELSE
            push ecx
            invoke FindKeyword, esi, ecx, offset szKwM12352
            pop ecx
            .IF eax != 0
                mov secSize, 2352
            .ELSE
                push ecx
                invoke FindKeyword, esi, ecx, offset szKwM22352
                pop ecx
                .IF eax != 0
                    mov secSize, 2352
                .ELSE
                    invoke FindKeyword, esi, ecx, offset szKwM22336
                    .IF eax != 0
                        mov secSize, 2336
                    .ENDIF
                .ENDIF
            .ENDIF
        .ENDIF
    .ENDIF
    invoke CtFinish, addr szData, 0, 0, secSize, 0, offset szCtCue
    mov ok, eax
    .IF eax != 0
        mov g_bCue, TRUE
    .ENDIF
done:
    invoke VfsFreeMem, pText
    mov eax, ok
    ret
CtOpenCue ENDP

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
    invoke FileSize64, hFile, addr sizeLo, addr sizeHi
    mov eax, sizeLo
    sub eax, 12
    mov ecx, sizeHi
    sbb ecx, 0
    mov edx, eax
    invoke FileReadAt, hFile, edx, ecx, addr footer, 12
    .IF eax != 12
        jmp done
    .ENDIF
    ; v2: "NER5" + 64-bit big-endian offset; v1: last 8 bytes "NERO" + 32-bit big-endian offset
    .IF dword ptr footer[0] == '5REN'
        invoke BSwap32, dword ptr footer[8]
        mov chunkLo, eax
        invoke BSwap32, dword ptr footer[4]
        mov chunkHi, eax
    .ELSEIF dword ptr footer[4] == 'OREN'
        invoke BSwap32, dword ptr footer[8]
        mov chunkLo, eax
        mov chunkHi, 0
    .ELSE
        jmp done
    .ENDIF
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
    invoke FileReadAt, hFile, chunkLo, chunkHi, pBuf, cb
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
        .IF eax == 'XOAD'                   ; DAOX: header 22, then 42-byte tracks (64-bit offsets)
            .IF ebx >= 22 + 42
                lea ecx, [esi + 8 + 22]
                movzx eax, word ptr [ecx + 12]
                xchg al, ah
                mov secSize, eax
                invoke BSwap32, dword ptr [ecx + 26 + 4]
                mov baseLo, eax
                invoke BSwap32, dword ptr [ecx + 26]
                mov baseHi, eax
                mov lba, 0
                mov ok, TRUE
            .ENDIF
            .BREAK
        .ELSEIF eax == 'IOAD'               ; DAOI: header 22, then 30-byte tracks (32-bit offsets)
            .IF ebx >= 22 + 30
                lea ecx, [esi + 8 + 22]
                invoke BSwap32, dword ptr [ecx + 12]
                mov secSize, eax
                invoke BSwap32, dword ptr [ecx + 24]
                mov baseLo, eax
                mov baseHi, 0
                mov lba, 0
                mov ok, TRUE
            .ENDIF
            .BREAK
        .ELSEIF eax == '2NTE'               ; ETN2: offset(8) length(8) mode(4) lba(4) ...
            .IF ebx >= 32
                lea ecx, [esi + 8]
                invoke BSwap32, dword ptr [ecx + 4]
                mov baseLo, eax
                invoke BSwap32, dword ptr [ecx]
                mov baseHi, eax
                invoke BSwap32, dword ptr [ecx + 16]
                mov secSize, eax
                invoke BSwap32, dword ptr [ecx + 20]
                mov lba, eax
                mov ok, 2
            .ENDIF
            .BREAK
        .ELSEIF eax == 'FNTE'               ; ETNF: offset(4) length(4) mode(4) lba(4) ...
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
        ; Nero track modes: 0/2 = 2048, 3 = MODE2/2336, 5/6/7 = raw 2352, 0F/10 = raw + subchannel 2448
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
free_done:
    invoke VfsFreeMem, pBuf
done:
    invoke CloseHandle, hFile
    .IF ok != 0
        invoke CtFinish, pszPath, baseLo, baseHi, secSize, lba, offset szCtNrg
        mov ok, eax
    .ENDIF
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
    invoke FileReadAt, hFile, 0, 0, addr hdr, 88
    .IF eax != 88
        jmp done
    .ENDIF
    lea esi, hdr
    mov edi, offset szMEDIA
    mov ecx, 16
    repe cmpsb
    jne done
    invoke FileReadAt, hFile, dword ptr hdr[80], 0, addr sess, 24
    .IF eax != 24
        jmp done
    .ENDIF
    movzx eax, byte ptr sess[10]            ; blocks in this session
    mov nBlocks, eax
    mov eax, dword ptr sess[20]             ; track blocks offset
    mov trkOff, eax
    xor ebx, ebx
    .WHILE ebx < nBlocks
        invoke FileReadAt, hFile, trkOff, 0, addr trk, 80
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
done:
    invoke CloseHandle, hFile
    .IF ok != 0
        invoke PathWithExt, addr szMdf, pszPath, offset szExtMdf
        invoke CtFinish, addr szMdf, baseLo, baseHi, secSize, lba, offset szCtMds
        mov ok, eax
    .ENDIF
    mov eax, ok
    ret
CtOpenMds ENDP

; ---------------------------------------------------------------------------
; CCD (CloneCD): the .img beside it is raw sectors
; ---------------------------------------------------------------------------
CtOpenCcd PROC pszPath:DWORD
    LOCAL szImg[MAX_PATH]:WORD
    invoke PathWithExt, addr szImg, pszPath, offset szExtImg
    invoke CtFinish, addr szImg, 0, 0, 2352, 0, offset szCtCcd
    ret
CtOpenCcd ENDP

; ---------------------------------------------------------------------------
; GDI (Dreamcast): "N" then "track lba type sectorsize file offset" per line; the data area is track 3+
; ---------------------------------------------------------------------------
CtOpenGdi PROC USES esi pszPath:DWORD
    LOCAL pText:DWORD
    LOCAL cb:DWORD
    LOCAL n:DWORD
    LOCAL lba:DWORD
    LOCAL ttype:DWORD
    LOCAL secSize:DWORD
    LOCAL szName[MAX_PATH]:WORD
    LOCAL szData[MAX_PATH]:WORD
    LOCAL ok:DWORD

    mov ok, FALSE
    invoke ReadTextFile, pszPath, addr cb
    .IF eax == 0
        ret
    .ENDIF
    mov pText, eax
    mov esi, eax
    invoke ParseUint, esi
    mov esi, edx
    mov n, eax
    .WHILE n != 0
        .WHILE byte ptr [esi] != 0 && byte ptr [esi] != 10
            inc esi
        .ENDW
        .BREAK .IF byte ptr [esi] == 0
        inc esi
        invoke ParseUint, esi               ; track number
        mov esi, edx
        invoke ParseUint, esi               ; lba
        mov esi, edx
        mov lba, eax
        invoke ParseUint, esi               ; type: 4 = data, 0 = audio
        mov esi, edx
        mov ttype, eax
        invoke ParseUint, esi               ; sector size
        mov esi, edx
        mov secSize, eax
        invoke ParseName, esi, addr szName
        mov esi, edx
        .IF ttype == 4 && lba >= 45000
            invoke PathDirJoin, addr szData, pszPath, addr szName
            invoke CtFinish, addr szData, 0, 0, secSize, lba, offset szCtGdi
            mov ok, eax
            .BREAK
        .ENDIF
        dec n
    .ENDW
    invoke VfsFreeMem, pText
    mov eax, ok
    ret
CtOpenGdi ENDP

; ---------------------------------------------------------------------------
; TOC (cdrdao): DATAFILE "name" ...; track mode gives the sector size
; ---------------------------------------------------------------------------
CtOpenToc PROC pszPath:DWORD
    LOCAL pText:DWORD
    LOCAL cb:DWORD
    LOCAL secSize:DWORD
    LOCAL szName[MAX_PATH]:WORD
    LOCAL szData[MAX_PATH]:WORD
    LOCAL ok:DWORD
    mov ok, FALSE
    invoke ReadTextFile, pszPath, addr cb
    .IF eax == 0
        ret
    .ENDIF
    mov pText, eax
    invoke FindKeyword, pText, cb, offset szKwDatafile
    .IF eax == 0
        jmp done
    .ENDIF
    mov edx, eax
    invoke ParseName, edx, addr szName
    invoke PathDirJoin, addr szData, pszPath, addr szName
    mov secSize, 2048
    invoke FindKeyword, pText, cb, offset szKwRaw
    .IF eax != 0
        mov secSize, 2352
    .ELSE
        invoke FindKeyword, pText, cb, offset szKwFormMix
        .IF eax != 0
            mov secSize, 2336
        .ENDIF
    .ENDIF
    invoke CtFinish, addr szData, 0, 0, secSize, 0, offset szCtToc
    mov ok, eax
done:
    invoke VfsFreeMem, pText
    mov eax, ok
    ret
CtOpenToc ENDP

; ---------------------------------------------------------------------------
; Generic fallback: find the first "CD001" primary descriptor and infer sector size and offset.
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
    ; 1 MB windows overlapped by 8 bytes so a signature on a boundary is not missed
    .WHILE posHi == 0 && posLo < CT_SCAN_MAX
        invoke FileReadAt, hFile, posLo, posHi, pBuf, 1024 * 1024 + 8
        .BREAK .IF eax < 7
        mov got, eax
        mov esi, pBuf
        xor ebx, ebx
        mov ecx, got
        sub ecx, 6
        .WHILE ebx < ecx
            .IF byte ptr [esi + ebx] == 'C' && dword ptr [esi + ebx] == '00DC' && byte ptr [esi + ebx + 4] == '1'
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

    ; sector size: the next descriptor ("CD001") sits one sector further
    mov secSize, 0
    mov ebx, 2048
    .WHILE ebx <= 2448
        mov eax, hitLo
        add eax, ebx
        mov ecx, hitHi
        adc ecx, 0
        push ebx
        mov edx, eax
        invoke FileReadAt, hFile, edx, ecx, addr probe, 6
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
    mov secOff, 0
    .IF secSize == 2336
        mov secOff, 8
    .ELSEIF secSize >= 2352
        mov secOff, 16
        ; mode 2 puts the user data 24 in: sync then a mode byte of 2 at sector + 15
        mov eax, hitLo
        sub eax, 24
        mov ecx, hitHi
        sbb ecx, 0
        mov edx, eax
        invoke FileReadAt, hFile, edx, ecx, addr probe, 16
        .IF eax == 16 && probe[0] == 0 && probe[1] == 0FFh && probe[11] == 0 && probe[15] == 2
            mov secOff, 24
        .ENDIF
    .ENDIF
    mov eax, secSize
    shl eax, 4
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
    mov ok, TRUE
free_done:
    invoke VfsFreeMem, pBuf
done:
    invoke CloseHandle, hFile
    .IF ok != 0
        invoke CtFinish, pszPath, baseLo, baseHi, secSize, 0, offset szCtScan
        mov ok, eax
    .ENDIF
    mov eax, ok
    ret
CtScan ENDP

; ---------------------------------------------------------------------------
; ECM (Error Code Modeler): sectors stored without sync / EDC / ECC. Decoded once into %TEMP%\FoxImg\<name>.bin
; as raw 2352-byte sectors (checksums are left zero; the readers never verify them), then opened like a BIN.
; ---------------------------------------------------------------------------
ECM_BUF         equ 1024 * 1024

.data
g_ecmFile       dd 0
g_ecmIn         dd 0
g_ecmInPos      dd 0
g_ecmInLen      dd 0
g_ecmEof        dd 0
g_ecmOut        dd 0
g_ecmOutPos     dd 0
g_ecmHOut       dd 0
szEcmTempFmt    dw '%','s','F','o','x','I','m','g','\','%','s','.','b','i','n',0
szEcmDirFmt     dw '%','s','F','o','x','I','m','g',0
szEcmSync       db 00h, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 00h
WSTR szCtEcm, <ECM>
WSTR szExtEcm, <.ecm>

.code

; Next input byte in eax, or 100h at end of input
EcmByte PROC
    LOCAL nRead:DWORD
    mov eax, g_ecmInPos
    .IF eax >= g_ecmInLen
        .IF g_ecmEof != 0
            mov eax, 100h
            ret
        .ENDIF
        invoke ReadFile, g_ecmFile, g_ecmIn, ECM_BUF, addr nRead, NULL
        .IF eax == 0 || nRead == 0
            mov g_ecmEof, TRUE
            mov eax, 100h
            ret
        .ENDIF
        mov eax, nRead
        mov g_ecmInLen, eax
        mov g_ecmInPos, 0
        xor eax, eax
    .ENDIF
    mov ecx, g_ecmIn
    movzx eax, byte ptr [ecx + eax]
    inc g_ecmInPos
    ret
EcmByte ENDP

; Flush the output buffer to the temp file
EcmFlush PROC
    .IF g_ecmOutPos != 0
        invoke WriteAll, g_ecmHOut, g_ecmOut, g_ecmOutPos
        mov g_ecmOutPos, 0
    .ENDIF
    ret
EcmFlush ENDP

; Append cb bytes from pSrc (or zeros when pSrc == 0) to the output
EcmPut PROC USES esi edi pSrc:DWORD, cb:DWORD
    mov eax, g_ecmOutPos
    add eax, cb
    .IF eax > ECM_BUF
        invoke EcmFlush
    .ENDIF
    mov edi, g_ecmOut
    add edi, g_ecmOutPos
    mov ecx, cb
    .IF pSrc == 0
        xor eax, eax
        rep stosb
    .ELSE
        mov esi, pSrc
        rep movsb
    .ENDIF
    mov eax, cb
    add g_ecmOutPos, eax
    ret
EcmPut ENDP

; Copy cb input bytes straight to the output; returns FALSE at end of input
EcmCopy PROC USES ebx cb:DWORD
    mov ebx, cb
    .WHILE ebx != 0
        invoke EcmByte
        .IF eax == 100h
            xor eax, eax
            ret
        .ENDIF
        mov ecx, g_ecmOut
        add ecx, g_ecmOutPos
        .IF g_ecmOutPos >= ECM_BUF
            push eax
            invoke EcmFlush
            pop eax
            mov ecx, g_ecmOut
        .ENDIF
        mov [ecx], al
        inc g_ecmOutPos
        dec ebx
    .ENDW
    mov eax, TRUE
    ret
EcmCopy ENDP

; Build %TEMP%\FoxImg\<leaf>.bin and make sure the directory exists
CtTempOut PROC pszOut:DWORD, pszPath:DWORD
    LOCAL szTemp[MAX_PATH]:WORD
    LOCAL szDir[MAX_PATH]:WORD
    invoke GetTempPathW, MAX_PATH, addr szTemp
    invoke wsprintfW, addr szDir, offset szEcmDirFmt, addr szTemp
    invoke CreateDirectoryW, addr szDir, NULL
    invoke PathLeaf, pszPath
    invoke wsprintfW, pszOut, offset szEcmTempFmt, addr szTemp, eax
    ret
CtTempOut ENDP

CtOpenEcm PROC USES esi edi ebx pszPath:DWORD
    LOCAL szTemp[MAX_PATH]:WORD
    LOCAL szDir[MAX_PATH]:WORD
    LOCAL szOut[MAX_PATH]:WORD
    LOCAL magic[4]:BYTE
    LOCAL num:DWORD
    LOCAL kind:DWORD
    LOCAL shiftN:DWORD
    LOCAL ok:DWORD
    LOCAL sub4[4]:BYTE
    LOCAL addr3[3]:BYTE
    LOCAL nRead:DWORD

    mov ok, FALSE
    invoke CreateFileW, pszPath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov g_ecmFile, eax
    invoke ReadFile, g_ecmFile, addr magic, 4, addr nRead, NULL
    .IF nRead != 4 || dword ptr magic[0] != 004D4345h     ; "ECM\0"
        invoke CloseHandle, g_ecmFile
        ret
    .ENDIF

    invoke GetTempPathW, MAX_PATH, addr szTemp
    invoke wsprintfW, addr szDir, offset szEcmDirFmt, addr szTemp
    invoke CreateDirectoryW, addr szDir, NULL
    invoke PathLeaf, pszPath
    invoke wsprintfW, addr szOut, offset szEcmTempFmt, addr szTemp, eax
    invoke CreateFileW, addr szOut, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        invoke CloseHandle, g_ecmFile
        ret
    .ENDIF
    mov g_ecmHOut, eax
    invoke VfsAlloc, ECM_BUF
    mov g_ecmIn, eax
    invoke VfsAlloc, ECM_BUF
    mov g_ecmOut, eax
    mov g_ecmInPos, 0
    mov g_ecmInLen, 0
    mov g_ecmEof, 0
    mov g_ecmOutPos, 0
    .IF g_ecmIn == 0 || g_ecmOut == 0
        jmp cleanup
    .ENDIF

    ; records: varint header byte(s): bits 0-1 type, bits 2-6 count, bit 7 more
    .WHILE TRUE
        invoke EcmByte
        .BREAK .IF eax == 100h
        mov ecx, eax
        and ecx, 3
        mov kind, ecx
        mov ecx, eax
        shr ecx, 2
        and ecx, 1Fh
        mov num, ecx
        mov shiftN, 5
        .WHILE eax & 80h
            invoke EcmByte
            .BREAK .IF eax == 100h
            mov ecx, eax
            and ecx, 7Fh
            push eax
            mov eax, ecx
            mov ecx, shiftN
            .IF ecx < 32
                shl eax, cl
                or num, eax
            .ENDIF
            add shiftN, 7
            pop eax
        .ENDW
        .BREAK .IF num == 0FFFFFFFFh         ; end marker
        inc num                             ; stored count - 1
        .IF kind == 0
            invoke EcmCopy, num
            .BREAK .IF eax == 0
        .ELSE
            .WHILE num != 0
                invoke EcmPut, offset szEcmSync, 12
                .IF kind == 1
                    ; mode 1: address(3) + data(2048) stored
                    invoke EcmCopy, 3
                    .BREAK .IF eax == 0
                    mov al, 1
                    mov addr3[0], al
                    invoke EcmPut, addr addr3, 1
                    invoke EcmCopy, 2048
                    .BREAK .IF eax == 0
                    invoke EcmPut, NULL, 288
                .ELSE
                    ; mode 2: address regenerated (left zero), subheader half(4) stored twice, then data
                    invoke EcmPut, NULL, 3
                    mov addr3[0], 2
                    invoke EcmPut, addr addr3, 1
                    mov ecx, 4
                    lea edi, sub4
                    .WHILE ecx != 0
                        push ecx
                        invoke EcmByte
                        pop ecx
                        .IF eax == 100h
                            jmp decode_done
                        .ENDIF
                        mov [edi], al
                        inc edi
                        dec ecx
                    .ENDW
                    invoke EcmPut, addr sub4, 4
                    invoke EcmPut, addr sub4, 4
                    .IF kind == 2
                        invoke EcmCopy, 2048
                        .BREAK .IF eax == 0
                        invoke EcmPut, NULL, 280
                    .ELSE
                        invoke EcmCopy, 2324
                        .BREAK .IF eax == 0
                        invoke EcmPut, NULL, 4
                    .ENDIF
                .ENDIF
                dec num
            .ENDW
        .ENDIF
    .ENDW
decode_done:
    invoke EcmFlush
    mov ok, TRUE
cleanup:
    invoke CloseHandle, g_ecmHOut
    invoke CloseHandle, g_ecmFile
    invoke VfsFreeMem, g_ecmIn
    invoke VfsFreeMem, g_ecmOut
    mov g_ecmIn, 0
    mov g_ecmOut, 0
    .IF ok != 0
        invoke CtFinish, addr szOut, 0, 0, 0, 0, offset szCtEcm
        mov ok, eax
    .ENDIF
    mov eax, ok
    ret
CtOpenEcm ENDP

; ---------------------------------------------------------------------------
; Compressed containers: expanded once into %TEMP%\FoxImg\<name>.bin by deflate.asm,
; then opened like any raw image (sector size sniffed by CtFinish).
; ---------------------------------------------------------------------------
.data
WSTR szCtGz, <GZIP>
WSTR szCtZip, <ZIP>
WSTR szCtCso, <CSO>
WSTR szExtGz, <.gz>
WSTR szExtZip, <.zip>
WSTR szExtCso, <.cso>
WSTR szExtCiso, <.ciso>
WSTR szCtGcz, <GCZ>
WSTR szCtDax, <DAX>
WSTR szCtZso, <ZSO>
WSTR szCtJso, <JSO>
WSTR szCtIsz, <ISZ>
WSTR szCtDaa, <DAA>
WSTR szCtChd, <CHD>
WSTR szExtChd, <.chd>
WSTR szExtGcz, <.gcz>
WSTR szExtDax, <.dax>
WSTR szExtZso, <.zso>
WSTR szExtJso, <.jso>
WSTR szExtIsz, <.isz>
WSTR szExtDaa, <.daa>

.code

CtOpenGz PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke GzExpandFile, pszPath, addr szOut
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 0, 0, offset szCtGz
    ret
CtOpenGz ENDP

CtOpenZip PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke ZipExpandFile, pszPath, addr szOut
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 0, 0, offset szCtZip
    ret
CtOpenZip ENDP

CtOpenCso PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke CsoExpandFile, pszPath, addr szOut
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 0, 0, offset szCtCso
    ret
CtOpenCso ENDP

CtOpenGcz PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke GczExpandFile, pszPath, addr szOut
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 2048, 0, offset szCtGcz
    ret
CtOpenGcz ENDP

CtOpenDax PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke DaxExpandFile, pszPath, addr szOut
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 2048, 0, offset szCtDax
    ret
CtOpenDax ENDP

CtOpenZso PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke CsoExpandFile, pszPath, addr szOut   ; same expander, ZISO magic selects LZ4
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 2048, 0, offset szCtZso
    ret
CtOpenZso ENDP

CtOpenJso PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke JsoExpandFile, pszPath, addr szOut
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 2048, 0, offset szCtJso
    ret
CtOpenJso ENDP

CtOpenIsz PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke IszExpandFile, pszPath, addr szOut
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 0, 0, offset szCtIsz
    ret
CtOpenIsz ENDP

CtOpenDaa PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke DaaExpandFile, pszPath, addr szOut
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 0, 0, offset szCtDaa
    ret
CtOpenDaa ENDP

CtOpenChd PROC pszPath:DWORD
    LOCAL szOut[MAX_PATH]:WORD
    invoke CtTempOut, addr szOut, pszPath
    invoke ChdExpandFile, pszPath, addr szOut
    .IF eax == 0
        ret
    .ENDIF
    invoke CtFinish, addr szOut, 0, 0, 0, 0, offset szCtChd
    ret
CtOpenChd ENDP

; ---------------------------------------------------------------------------
; BlindWrite 5/6 (.b5t/.b6t): "BWT5 STREAM SIGN" descriptor beside a .b5i/.b6i
; data file. A chain of variable blocks leads to the data-block table, which
; names the data file and gives byte offset, start sector and sector count.
; ---------------------------------------------------------------------------
.data
szB6tSig        db 'BWT5 STREAM SIGN'
WSTR szCtB6t, <BlindWrite>
WSTR szExtB5t, <.b5t>
WSTR szExtB6t, <.b6t>
WSTR szCtC2d, <C2D>
WSTR szExtC2d, <.c2d>
szC2dSig1       db 'Roxio Im'
szC2dSig2       db 'Adaptec '

.code

CtOpenB6t PROC USES esi edi ebx pszPath:DWORD
    LOCAL pBuf:DWORD
    LOCAL cb:DWORD
    LOCAL p:DWORD
    LOCAL dtype:DWORD
    LOCAL nBlocks:DWORD
    LOCAL i:DWORD
    LOCAL bestSecs:DWORD
    LOCAL bestBytes:DWORD
    LOCAL bestOff:DWORD
    LOCAL bestStart:DWORD
    LOCAL fnPtr:DWORD
    LOCAL fnLen:DWORD
    LOCAL secSize:DWORD
    LOCAL baseLo:DWORD
    LOCAL baseHi:DWORD
    LOCAL lba:DWORD
    LOCAL szName[MAX_PATH]:WORD
    LOCAL szData[MAX_PATH]:WORD
    LOCAL ok:DWORD

    mov ok, FALSE
    invoke ReadTextFile, pszPath, addr cb
    .IF eax == 0
        ret
    .ENDIF
    mov pBuf, eax
    mov esi, eax
    .IF cb < 264
        jmp done
    .ENDIF
    push esi
    mov edi, offset szB6tSig
    mov ecx, 16
    repe cmpsb
    pop esi
    jne done
    movzx eax, word ptr [esi + 48]          ; disc type, at 16 + 32
    mov dtype, eax
    ; skip: header, disc block 1, 32 junk, drive inquiry, volume id -> disc block 2 at 240
    mov eax, 260
    add eax, dword ptr [esi + 240]          ; mode page 2A
    add eax, dword ptr [esi + 244]          ; unknown block
    movzx ecx, word ptr [esi + 96]          ; PMA
    add eax, ecx
    movzx ecx, word ptr [esi + 98]          ; ATIP
    add eax, ecx
    movzx ecx, word ptr [esi + 100]         ; CD-TEXT
    add eax, ecx
    add eax, dword ptr [esi + 104]          ; BCA
    add eax, dword ptr [esi + 120]          ; DVD structures
    mov ecx, dtype
    .IF ecx == 8 || ecx == 9 || ecx == 0Ah
        movzx ecx, word ptr [esi + 102]     ; CD-ROM info
    .ELSE
        mov ecx, dword ptr [esi + 124]      ; DVD-ROM info
    .ENDIF
    add eax, ecx
    mov p, eax
    add eax, 8
    .IF eax > cb
        jmp done
    .ENDIF
    mov eax, p
    mov ecx, dword ptr [esi + eax]          ; data block count
    mov nBlocks, ecx
    mov edx, dword ptr [esi + eax + 4]      ; drive path length
    lea eax, [eax + edx + 8]
    mov p, eax
    .IF ecx == 0 || ecx > 64
        jmp done
    .ENDIF
    mov bestSecs, 0
    mov i, 0
    .WHILE TRUE
        mov eax, i
        .BREAK .IF eax >= nBlocks
        mov eax, p
        add eax, 52
        .IF eax > cb
            jmp done
        .ENDIF
        mov ebx, p
        mov eax, dword ptr [esi + ebx + 44] ; sectors in this block
        .IF !(eax & 80000000h) && eax > bestSecs
            mov ecx, dword ptr [esi + ebx + 4]
            .IF ecx != 0
                mov bestSecs, eax
                mov bestBytes, ecx
                mov eax, dword ptr [esi + ebx + 24]
                mov bestOff, eax
                mov eax, dword ptr [esi + ebx + 40]
                mov bestStart, eax
                lea eax, [esi + ebx + 52]
                mov fnPtr, eax
                mov eax, dword ptr [esi + ebx + 48]
                mov fnLen, eax
            .ENDIF
        .ENDIF
        mov eax, dword ptr [esi + ebx + 48]
        lea eax, [ebx + eax + 52 + 4]
        mov p, eax
        .IF eax > cb
            jmp done
        .ENDIF
        inc i
    .ENDW
    .IF bestSecs == 0
        jmp done
    .ENDIF
    mov eax, bestBytes
    xor edx, edx
    div bestSecs
    mov secSize, eax
    .IF eax < 2048 || eax > 2448
        jmp done
    .ENDIF
    mov eax, bestOff
    mov baseLo, eax
    mov baseHi, 0
    mov eax, bestStart
    mov lba, eax
    .IF eax & 80000000h                     ; block covers lead-in: shift to sector 0
        neg eax
        mul secSize
        add baseLo, eax
        adc baseHi, edx
        mov lba, 0
    .ENDIF
    ; data file: the leaf of the name stored in the descriptor
    mov eax, fnLen
    shr eax, 1
    .IF eax == 0 || eax >= MAX_PATH
        jmp try_ext
    .ENDIF
    push eax
    mov ecx, eax
    lea edi, szName
    mov edx, fnPtr
    .WHILE ecx != 0
        mov ax, word ptr [edx]
        mov word ptr [edi], ax
        add edi, 2
        add edx, 2
        dec ecx
    .ENDW
    xor eax, eax
    mov word ptr [edi], ax
    pop eax
    lea ecx, szName
    invoke PathLeaf, ecx
    invoke PathDirJoin, addr szData, pszPath, eax
    invoke CtFinish, addr szData, baseLo, baseHi, secSize, lba, offset szCtB6t
    mov ok, eax
    .IF eax != 0
        jmp done
    .ENDIF
try_ext:
    ; fall back to the paired image: same name with the extension's t swapped for i
    invoke lstrcpynW, addr szData, pszPath, MAX_PATH
    invoke lstrlenW, addr szData
    .IF eax != 0
        lea ecx, szData
        mov word ptr [ecx + eax * 2 - 2], 'i'
        invoke CtFinish, addr szData, baseLo, baseHi, secSize, lba, offset szCtB6t
        mov ok, eax
    .ENDIF
done:
    invoke VfsFreeMem, pBuf
    mov eax, ok
    ret
CtOpenB6t ENDP

; ---------------------------------------------------------------------------
; MDX (Alcohol 120% v2): same "MEDIA DESCRIPTOR" magic as MDS but version 2,
; with the track data appended to the descriptor file itself. Track blocks are
; 80 bytes; encrypted or compressed images are declined.
; ---------------------------------------------------------------------------
.data
WSTR szCtMdx, <MDX>
WSTR szExtMdx, <.mdx>

.code

CtOpenMdx PROC USES esi edi ebx pszPath:DWORD
    LOCAL hFile:DWORD
    LOCAL hdr[96]:BYTE
    LOCAL sess[32]:BYTE
    LOCAL trk[80]:BYTE
    LOCAL foot[32]:BYTE
    LOCAL trkOff:DWORD
    LOCAL nBlocks:DWORD
    LOCAL i:DWORD
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
    invoke FileReadAt, hFile, 0, 0, addr hdr, 96
    .IF eax != 96
        jmp done
    .ENDIF
    lea esi, hdr
    mov edi, offset szMEDIA
    mov ecx, 16
    repe cmpsb
    jne done
    .IF byte ptr hdr[16] != 2               ; MDSv1 goes through CtOpenMds
        jmp done
    .ENDIF
    .IF dword ptr hdr[88] != 0              ; encrypted
        jmp done
    .ENDIF
    invoke FileReadAt, hFile, dword ptr hdr[80], 0, addr sess, 32
    .IF eax != 32
        jmp done
    .ENDIF
    movzx eax, byte ptr sess[10]            ; blocks in this session
    mov nBlocks, eax
    mov eax, dword ptr sess[20]
    mov trkOff, eax
    mov i, 0
    .WHILE TRUE
        mov eax, i
        .BREAK .IF eax >= nBlocks
        invoke FileReadAt, hFile, trkOff, 0, addr trk, 80
        .BREAK .IF eax != 80
        movzx eax, byte ptr trk[4]          ; point
        .IF eax >= 1 && eax <= 99
            movzx eax, byte ptr trk[0]
            and eax, 7                      ; sector type: 2..5 are data
            .IF eax >= 2 && eax <= 5
                movzx eax, word ptr trk[16]
                mov secSize, eax
                .IF eax >= 2048 && eax <= 2448
                    mov eax, dword ptr trk[36]
                    mov lba, eax
                    mov eax, dword ptr trk[40]
                    mov baseLo, eax
                    mov eax, dword ptr trk[44]
                    mov baseHi, eax
                    ; a footer with a compression table means compressed data
                    mov eax, dword ptr trk[48]
                    .IF eax != 0
                        invoke FileReadAt, hFile, dword ptr trk[52], 0, addr foot, 32
                        .IF eax == 32
                            mov eax, dword ptr foot[24]
                            or eax, dword ptr foot[28]
                            .IF eax != 0
                                jmp done
                            .ENDIF
                        .ENDIF
                    .ENDIF
                    mov ok, TRUE
                    .BREAK
                .ENDIF
            .ENDIF
        .ENDIF
        add trkOff, 80
        inc i
    .ENDW
done:
    invoke CloseHandle, hFile
    .IF ok != 0
        invoke CtFinish, pszPath, baseLo, baseHi, secSize, lba, offset szCtMdx
        mov ok, eax
    .ENDIF
    mov eax, ok
    ret
CtOpenMdx ENDP

; ---------------------------------------------------------------------------
; C2D (WinOnCD / Roxio): header names the track table; tracks carry byte offset,
; sector size and first sector. The data sits in the same file.
; ---------------------------------------------------------------------------
CtOpenC2d PROC USES esi edi ebx pszPath:DWORD
    LOCAL hFile:DWORD
    LOCAL hdr[64]:BYTE
    LOCAL nTracks:DWORD
    LOCAL offTracks:DWORD
    LOCAL pTrk:DWORD
    LOCAL cbTrk:DWORD
    LOCAL i:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov pTrk, 0
    invoke CreateFileW, pszPath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov hFile, eax
    invoke FileReadAt, hFile, 0, 0, addr hdr, 64
    .IF eax != 64
        jmp done
    .ENDIF
    lea esi, hdr
    mov eax, dword ptr [esi]
    mov ecx, dword ptr [esi + 4]
    .IF eax == dword ptr szC2dSig1 && ecx == dword ptr szC2dSig1[4]
    .ELSEIF eax == dword ptr szC2dSig2 && ecx == dword ptr szC2dSig2[4]
    .ELSE
        jmp done
    .ENDIF
    movzx eax, word ptr [esi + 50]
    mov nTracks, eax
    .IF eax == 0 || eax > 256
        jmp done
    .ENDIF
    mov eax, dword ptr [esi + 56]
    mov offTracks, eax
    mov eax, nTracks
    mov ecx, 44
    mul ecx
    mov cbTrk, eax
    invoke VfsAlloc, eax
    mov pTrk, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke FileReadAt, hFile, offTracks, 0, pTrk, cbTrk
    .IF eax != cbTrk
        jmp done
    .ENDIF
    mov esi, pTrk
    mov i, 0
    .WHILE TRUE
        mov eax, i
        .BREAK .IF eax >= nTracks
        movzx eax, byte ptr [esi + 40]      ; mode: 0 audio, 1 mode1, 2 mode2, FF audio
        movzx ecx, byte ptr [esi + 39]      ; index
        .IF (eax == 1 || eax == 2) && ecx <= 1
            .IF byte ptr [esi + 41] != 0    ; compressed C2D, not carried
                jmp done
            .ENDIF
            mov eax, dword ptr [esi + 20]   ; sector size
            .IF eax >= 2048 && eax <= 2448
                push eax
                invoke CloseHandle, hFile
                mov hFile, INVALID_HANDLE_VALUE
                pop eax
                push esi
                invoke CtFinish, pszPath, dword ptr [esi + 12], dword ptr [esi + 16], eax, dword ptr [esi + 4], offset szCtC2d
                pop esi
                mov ok, eax
                jmp done
            .ENDIF
        .ENDIF
        add esi, 44
        inc i
    .ENDW
done:
    invoke VfsFreeMem, pTrk
    .IF hFile != INVALID_HANDLE_VALUE
        invoke CloseHandle, hFile
    .ENDIF
    mov eax, ok
    ret
CtOpenC2d ENDP

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
    invoke HasExt, pszPath, offset szExtCue
    .IF eax != 0
        invoke CtOpenCue, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtNrg
    .IF eax != 0
        invoke CtOpenNrg, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtMds
    .IF eax != 0
        invoke CtOpenMds, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtCcd
    .IF eax != 0
        invoke CtOpenCcd, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtGdi
    .IF eax != 0
        invoke CtOpenGdi, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtToc
    .IF eax != 0
        invoke CtOpenToc, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtCdi
    .IF eax != 0
        invoke CtScan, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtEcm
    .IF eax != 0
        invoke CtOpenEcm, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtGz
    .IF eax != 0
        invoke CtOpenGz, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtZip
    .IF eax != 0
        invoke CtOpenZip, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtCso
    .IF eax != 0
        invoke CtOpenCso, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtCiso
    .IF eax != 0
        invoke CtOpenCso, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtGcz
    .IF eax != 0
        invoke CtOpenGcz, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtDax
    .IF eax != 0
        invoke CtOpenDax, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtZso
    .IF eax != 0
        invoke CtOpenZso, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtJso
    .IF eax != 0
        invoke CtOpenJso, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtIsz
    .IF eax != 0
        invoke CtOpenIsz, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtDaa
    .IF eax != 0
        invoke CtOpenDaa, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtB5t
    .IF eax != 0
        invoke CtOpenB6t, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtB6t
    .IF eax != 0
        invoke CtOpenB6t, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtC2d
    .IF eax != 0
        invoke CtOpenC2d, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtMdx
    .IF eax != 0
        invoke CtOpenMdx, pszPath
        ret
    .ENDIF
    invoke HasExt, pszPath, offset szExtChd
    .IF eax != 0
        invoke CtOpenChd, pszPath
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
