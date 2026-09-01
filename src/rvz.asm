; FoxImg - RVZ (Dolphin) reader for GameCube discs.
;
; RVZ is WIA with a different magic, chunk sizes down to 32 KiB, Zstandard as
; a compression choice, and "packing": stretches of a disc that are the console
; firmware's own junk padding are not stored at all, only the 68-byte seed of
; the lagged Fibonacci generator that produced them, and the reader regenerates
; the bytes. That generator lives here too (Dolphin's LaggedFibonacciGenerator,
; CC0), including its two oddities - a shift by 18 where 16 would be expected,
; and the buffer being byte-swapped once at setup so output is a plain copy.
;
; Layout (all big-endian): a 0x48-byte header with the disc size; a second
; header with the disc type, compression, chunk size, the first 0x80 disc bytes,
; and the offsets of three arrays; the arrays themselves - partitions (Wii
; only), raw data entries covering the rest of the disc, and one group entry
; per chunk - with the last two compressed like the data. Each group entry is
; a file offset in 4-byte units, a length whose top bit says whether the group
; is compressed at all, and the packed length when packing was used.
;
; Only what a GameCube disc needs is here: raw data, no partitions. Wii images
; keep their filesystem inside AES-encrypted partitions and are declined, as
; every other encrypted image is. Only Zstandard compression is taken; bzip2
; and LZMA groups could follow, the codecs exist. SHA-1 hashes over the headers
; are not verified.
include foximg.inc

RVZ_MAGIC       equ 015A5652h           ; "RVZ" 01
RVZ_H1          equ 48h
RVZ_H2          equ 0DCh                ; through the compressor data
RVZ_RAW_ENTRY   equ 24
RVZ_GRP_ENTRY   equ 12
RVZ_SECTOR      equ 8000h               ; raw entries are served on this alignment
RVZ_CHUNK_MAX   equ 32 * 1024 * 1024
RVZ_TBL_MAX     equ 16 * 1024 * 1024

LFG_K           equ 521
LFG_J           equ 32
LFG_SEED        equ 17
LFG_BYTES       equ LFG_K * 4           ; 2084

.data
g_lfgPos        dd 0

.data?
g_lfg           dd LFG_K dup(?)

.code

; ---------------------------------------------------------------------------
; Lagged Fibonacci generator
; ---------------------------------------------------------------------------
LfgForward PROC USES esi
    mov esi, offset g_lfg
    xor ecx, ecx
    .WHILE ecx < LFG_J
        mov eax, dword ptr [esi + ecx * 4 + (LFG_K - LFG_J) * 4]
        xor dword ptr [esi + ecx * 4], eax
        inc ecx
    .ENDW
    .WHILE ecx < LFG_K
        mov eax, dword ptr [esi + ecx * 4 - LFG_J * 4]
        xor dword ptr [esi + ecx * 4], eax
        inc ecx
    .ENDW
    ret
LfgForward ENDP

; 68 seed bytes, big-endian words, then the fill, the shift fix-up and swap,
; and four advances - as Dolphin's SetSeed + Initialize
LfgSeed PROC USES esi edi ebx pSeed:DWORD
    mov esi, pSeed
    mov edi, offset g_lfg
    xor ecx, ecx
    .WHILE ecx < LFG_SEED
        mov eax, dword ptr [esi + ecx * 4]
        bswap eax
        mov dword ptr [edi + ecx * 4], eax
        inc ecx
    .ENDW
    .WHILE ecx < LFG_K
        mov eax, dword ptr [edi + ecx * 4 - 17 * 4]
        shl eax, 23
        mov edx, dword ptr [edi + ecx * 4 - 16 * 4]
        shr edx, 9
        xor eax, edx
        xor eax, dword ptr [edi + ecx * 4 - 4]
        mov dword ptr [edi + ecx * 4], eax
        inc ecx
    .ENDW
    ; the "shift by 18 instead of 16" quirk is applied once here, and the words
    ; are byte-swapped so that output is a straight copy of the buffer
    xor ecx, ecx
    .WHILE ecx < LFG_K
        mov eax, dword ptr [edi + ecx * 4]
        mov edx, eax
        and eax, 0FF00FFFFh
        shr edx, 2
        and edx, 00FF0000h
        or eax, edx
        bswap eax
        mov dword ptr [edi + ecx * 4], eax
        inc ecx
    .ENDW
    mov g_lfgPos, 0
    invoke LfgForward
    invoke LfgForward
    invoke LfgForward
    invoke LfgForward
    ret
LfgSeed ENDP

; skip n bytes of output
LfgSkip PROC n:DWORD
    mov eax, g_lfgPos
    add eax, n
    .WHILE eax >= LFG_BYTES
        push eax
        invoke LfgForward
        pop eax
        sub eax, LFG_BYTES
    .ENDW
    mov g_lfgPos, eax
    ret
LfgSkip ENDP

LfgGet PROC USES esi edi ebx n:DWORD, pOut:DWORD
    mov edi, pOut
    mov ebx, n
    .WHILE ebx != 0
        mov ecx, LFG_BYTES
        sub ecx, g_lfgPos
        .IF ecx > ebx
            mov ecx, ebx
        .ENDIF
        mov esi, offset g_lfg
        add esi, g_lfgPos
        add g_lfgPos, ecx
        sub ebx, ecx
        rep movsb
        .IF g_lfgPos == LFG_BYTES
            invoke LfgForward
            mov g_lfgPos, 0
        .ENDIF
    .ENDW
    ret
LfgGet ENDP

; ---------------------------------------------------------------------------
; RVZ packing: runs of [size][data] or [size|0x80000000][68-byte seed]
; ---------------------------------------------------------------------------
; dataOff is the run's offset within the raw data entry; only its position
; inside a 0x8000-byte sector matters, and that equals the disc position.
RvzUnpack PROC USES esi edi ebx pSrc:DWORD, cbSrc:DWORD, pDst:DWORD, cbDst:DWORD, dataOff:DWORD
    LOCAL srcPos:DWORD
    LOCAL dstPos:DWORD
    LOCAL runv:DWORD
    LOCAL junk:DWORD
    mov srcPos, 0
    mov dstPos, 0
    .WHILE 1
        mov eax, dstPos
        .BREAK .IF eax >= cbDst
        mov eax, srcPos
        add eax, 4
        .IF eax > cbSrc
            xor eax, eax
            ret
        .ENDIF
        mov esi, pSrc
        add esi, srcPos
        mov eax, dword ptr [esi]
        bswap eax
        add srcPos, 4
        mov edx, eax
        shr edx, 31
        mov junk, edx
        and eax, 7FFFFFFFh
        mov runv, eax
        .IF junk != 0
            mov eax, srcPos
            add eax, LFG_SEED * 4
            .IF eax > cbSrc
                xor eax, eax
                ret
            .ENDIF
            mov eax, pSrc
            add eax, srcPos
            invoke LfgSeed, eax
            add srcPos, LFG_SEED * 4
            mov eax, dataOff
            and eax, RVZ_SECTOR - 1
            invoke LfgSkip, eax
        .ENDIF
        mov eax, dstPos
        add eax, runv
        .IF eax > cbDst
            xor eax, eax
            ret
        .ENDIF
        mov edi, pDst
        add edi, dstPos
        .IF junk != 0
            invoke LfgGet, runv, edi
        .ELSE
            mov eax, srcPos
            add eax, runv
            .IF eax > cbSrc
                xor eax, eax
                ret
            .ENDIF
            mov esi, pSrc
            add esi, srcPos
            mov ecx, runv
            rep movsb
            mov eax, runv
            add srcPos, eax
        .ENDIF
        mov eax, runv
        add dstPos, eax
        add dataOff, eax
    .ENDW
    mov eax, srcPos
    .IF eax != cbSrc
        xor eax, eax                    ; the packed stream must be spent exactly
        ret
    .ENDIF
    mov eax, TRUE
    ret
RvzUnpack ENDP

; ---------------------------------------------------------------------------
; Big-endian helpers on a buffer (BE32 is opera.asm's)
; ---------------------------------------------------------------------------
; 64-bit big-endian into edx:eax
RvzBE64 PROC p:DWORD
    mov ecx, p
    mov edx, dword ptr [ecx]
    bswap edx
    mov eax, dword ptr [ecx + 4]
    bswap eax
    ret
RvzBE64 ENDP

; cb zero bytes to the output, in bounded steps
RvzZeros PROC cbLo:DWORD, cbHi:DWORD
    .WHILE g_zfErr == 0
        mov eax, cbLo
        or eax, cbHi
        .BREAK .IF eax == 0
        mov eax, 1000000h
        .IF cbHi == 0 && eax > cbLo
            mov eax, cbLo
        .ENDIF
        push eax
        invoke ZfPutZeros, eax
        pop eax
        sub cbLo, eax
        sbb cbHi, 0
    .ENDW
    ret
RvzZeros ENDP

; ---------------------------------------------------------------------------
; Expand an RVZ to a plain GameCube disc image
; ---------------------------------------------------------------------------
RvzExpandFile PROC USES esi edi ebx hIn:DWORD, pszDst:DWORD
    LOCAL hOut:DWORD
    LOCAL h1[RVZ_H1]:BYTE
    LOCAL h2[RVZ_H2]:BYTE
    LOCAL totLo:DWORD
    LOCAL totHi:DWORD
    LOCAL chunk:DWORD
    LOCAL nRaw:DWORD
    LOCAL rawOffLo:DWORD
    LOCAL rawOffHi:DWORD
    LOCAL rawCb:DWORD
    LOCAL nGrp:DWORD
    LOCAL grpOffLo:DWORD
    LOCAL grpOffHi:DWORD
    LOCAL grpCb:DWORD
    LOCAL pC:DWORD                      ; compressed group
    LOCAL cbC:DWORD
    LOCAL pD:DWORD                      ; decoded group (zstd output)
    LOCAL cbD:DWORD
    LOCAL pG:DWORD                      ; unpacked group
    LOCAL pRaw:DWORD
    LOCAL pGrp:DWORD
    LOCAL curLo:DWORD
    LOCAL curHi:DWORD
    LOCAL i:DWORD
    LOCAL g:DWORD
    LOCAL entOffLo:DWORD
    LOCAL entOffHi:DWORD
    LOCAL entSizeLo:DWORD
    LOCAL entSizeHi:DWORD
    LOCAL gIndex:DWORD
    LOCAL gCount:DWORD
    LOCAL skipped:DWORD
    LOCAL remLo:DWORD
    LOCAL remHi:DWORD
    LOCAL gsize:DWORD
    LOCAL dOffLo:DWORD
    LOCAL dOffHi:DWORD
    LOCAL dSize:DWORD
    LOCAL isComp:DWORD
    LOCAL packed:DWORD
    LOCAL pOutG:DWORD
    LOCAL cbOutG:DWORD
    LOCAL skipNow:DWORD
    LOCAL tmp:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    mov pC, 0
    mov pD, 0
    mov pG, 0
    mov pRaw, 0
    mov pGrp, 0

    ; --- headers ---
    invoke FileReadAt, hIn, 0, 0, addr h1, RVZ_H1
    .IF eax != RVZ_H1 || dword ptr h1[0] != RVZ_MAGIC
        jmp done
    .ENDIF
    invoke RvzBE64, addr h1[24h]        ; iso_file_size
    mov totLo, eax
    mov totHi, edx
    invoke BE32, addr h1[0Ch]        ; header 2 size
    .IF eax < 0D4h
        jmp done
    .ENDIF
    invoke FileReadAt, hIn, RVZ_H1, 0, addr h2, RVZ_H2
    .IF eax < 0D4h
        jmp done
    .ENDIF
    invoke BE32, addr h2[0]          ; disc type: 1 GameCube, 2 Wii
    .IF eax != 1
        jmp done
    .ENDIF
    invoke BE32, addr h2[4]          ; compression: 5 is Zstandard
    .IF eax != 5
        jmp done
    .ENDIF
    invoke BE32, addr h2[0Ch]
    mov chunk, eax
    .IF eax < RVZ_SECTOR || eax > RVZ_CHUNK_MAX
        jmp done
    .ENDIF
    test eax, RVZ_SECTOR - 1
    .IF !ZERO?
        jmp done
    .ENDIF
    invoke BE32, addr h2[90h]        ; partitions: none on a GameCube disc
    .IF eax != 0
        jmp done
    .ENDIF
    invoke BE32, addr h2[0B4h]
    mov nRaw, eax
    .IF eax == 0 || eax > 65536
        jmp done
    .ENDIF
    invoke RvzBE64, addr h2[0B8h]
    mov rawOffLo, eax
    mov rawOffHi, edx
    invoke BE32, addr h2[0C0h]
    mov rawCb, eax
    invoke BE32, addr h2[0C4h]
    mov nGrp, eax
    .IF eax == 0 || eax > 4000000h
        jmp done
    .ENDIF
    invoke RvzBE64, addr h2[0C8h]
    mov grpOffLo, eax
    mov grpOffHi, edx
    invoke BE32, addr h2[0D0h]
    mov grpCb, eax
    .IF rawCb > RVZ_TBL_MAX || grpCb > RVZ_TBL_MAX
        jmp done
    .ENDIF

    ; --- buffers ---
    mov eax, chunk
    mov ecx, eax
    shr ecx, 2
    add eax, ecx
    add eax, 65536                      ; compressed groups can exceed the chunk a little
    .IF eax < rawCb
        mov eax, rawCb
    .ENDIF
    .IF eax < grpCb
        mov eax, grpCb
    .ENDIF
    mov cbC, eax
    invoke VfsAlloc, eax
    mov pC, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov eax, chunk
    mov ecx, eax
    shr ecx, 6
    add eax, ecx
    add eax, 65536                      ; a packed stream is the chunk plus run headers
    mov cbD, eax
    invoke VfsAlloc, eax
    mov pD, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke VfsAlloc, chunk
    mov pG, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov eax, nRaw
    mov ecx, RVZ_RAW_ENTRY
    mul ecx
    mov tmp, eax
    invoke VfsAlloc, eax
    mov pRaw, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov eax, nGrp
    mov ecx, RVZ_GRP_ENTRY
    mul ecx
    invoke VfsAlloc, eax
    mov pGrp, eax
    .IF eax == 0
        jmp done
    .ENDIF

    ; --- the two tables, each one compressed frame ---
    invoke FileReadAt, hIn, rawOffLo, rawOffHi, pC, rawCb
    .IF eax != rawCb
        jmp done
    .ENDIF
    invoke ZsDecode, pC, rawCb, pRaw, tmp
    .IF eax != tmp
        jmp done
    .ENDIF
    invoke FileReadAt, hIn, grpOffLo, grpOffHi, pC, grpCb
    .IF eax != grpCb
        jmp done
    .ENDIF
    mov eax, nGrp
    mov ecx, RVZ_GRP_ENTRY
    mul ecx
    mov tmp, eax
    invoke ZsDecode, pC, grpCb, pGrp, tmp
    .IF eax != tmp
        jmp done
    .ENDIF

    ; --- output: the disc header from header 2, then the raw data entries ---
    invoke ZfBeginOut, pszDst, hIn, totLo, totHi
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    invoke ZfPutMem, addr h2[10h], 80h
    mov curLo, 80h
    mov curHi, 0
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nRaw
        mov esi, i
        imul esi, RVZ_RAW_ENTRY
        add esi, pRaw
        invoke RvzBE64, esi
        mov entOffLo, eax
        mov entOffHi, edx
        lea eax, [esi + 8]
        invoke RvzBE64, eax
        mov entSizeLo, eax
        mov entSizeHi, edx
        lea eax, [esi + 16]
        invoke BE32, eax
        mov gIndex, eax
        lea eax, [esi + 20]
        invoke BE32, eax
        mov gCount, eax
        mov eax, entSizeLo
        or eax, entSizeHi
        .IF eax == 0
            inc i
            .CONTINUE
        .ENDIF
        ; entries arrive in disc order; a gap is zero-filled, an overlap is an error
        mov eax, entOffHi
        mov ecx, entOffLo
        .IF eax < curHi || (eax == curHi && ecx < curLo)
            mov g_zfErr, 1
            .BREAK
        .ENDIF
        sub ecx, curLo
        sbb eax, curHi
        .IF eax != 0 || ecx != 0
            invoke RvzZeros, ecx, eax
            mov eax, entOffLo
            mov curLo, eax
            mov eax, entOffHi
            mov curHi, eax
        .ENDIF
        ; groups start on the sector boundary at or before the entry
        mov eax, entOffLo
        and eax, RVZ_SECTOR - 1
        mov skipped, eax
        mov eax, entSizeLo
        add eax, skipped
        mov remLo, eax
        mov eax, entSizeHi
        adc eax, 0
        mov remHi, eax
        mov g, 0
        .WHILE g_zfErr == 0
            mov eax, g
            .BREAK .IF eax >= gCount
            ; this group's share of the entry
            mov eax, chunk
            .IF remHi == 0 && eax > remLo
                mov eax, remLo
            .ENDIF
            mov gsize, eax
            .IF eax == 0
                .BREAK
            .ENDIF
            mov eax, gIndex
            add eax, g
            .IF eax >= nGrp
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            imul eax, RVZ_GRP_ENTRY
            add eax, pGrp
            mov ebx, eax
            invoke BE32, ebx
            mov edx, eax
            shr edx, 30
            shl eax, 2
            mov dOffLo, eax
            mov dOffHi, edx
            lea eax, [ebx + 4]
            invoke BE32, eax
            mov edx, eax
            shr edx, 31
            mov isComp, edx
            and eax, 7FFFFFFFh
            mov dSize, eax
            lea eax, [ebx + 8]
            invoke BE32, eax
            mov packed, eax
            ; where in the group this entry's bytes begin
            mov skipNow, 0
            .IF g == 0
                mov eax, skipped
                mov skipNow, eax
            .ENDIF
            .IF dSize == 0
                mov eax, gsize
                sub eax, skipNow
                invoke ZfPutZeros, eax
            .ELSE
                mov eax, dSize
                .IF eax > cbC
                    mov g_zfErr, 1
                    .BREAK
                .ENDIF
                invoke FileReadAt, hIn, dOffLo, dOffHi, pC, dSize
                .IF eax != dSize
                    mov g_zfErr, 1
                    .BREAK
                .ENDIF
                .IF isComp != 0
                    invoke ZsDecode, pC, dSize, pD, cbD
                    .IF eax == 0
                        mov g_zfErr, 1
                        .BREAK
                    .ENDIF
                    mov cbOutG, eax
                    mov eax, pD
                    mov pOutG, eax
                .ELSE
                    mov eax, dSize
                    mov cbOutG, eax
                    mov eax, pC
                    mov pOutG, eax
                .ENDIF
                .IF packed != 0
                    mov eax, cbOutG
                    .IF eax != packed
                        mov g_zfErr, 1
                        .BREAK
                    .ENDIF
                    mov eax, g
                    mul chunk                   ; offset of the group within the entry
                    invoke RvzUnpack, pOutG, packed, pG, gsize, eax
                    .IF eax == 0
                        mov g_zfErr, 1
                        .BREAK
                    .ENDIF
                    mov eax, pG
                    mov pOutG, eax
                .ELSE
                    mov eax, cbOutG
                    .IF eax < gsize
                        mov g_zfErr, 1
                        .BREAK
                    .ENDIF
                .ENDIF
                mov eax, pOutG
                add eax, skipNow
                mov ecx, gsize
                sub ecx, skipNow
                invoke ZfPutMem, eax, ecx
            .ENDIF
            mov eax, gsize
            sub eax, skipNow
            add curLo, eax
            adc curHi, 0
            mov eax, gsize
            sub remLo, eax
            sbb remHi, 0
            inc g
        .ENDW
        inc i
    .ENDW
    .IF g_zfErr != 0
        jmp done
    .ENDIF
    ; anything the entries did not reach is blank disc
    mov eax, totHi
    mov ecx, totLo
    .IF eax > curHi || (eax == curHi && ecx > curLo)
        sub ecx, curLo
        sbb eax, curHi
        invoke RvzZeros, ecx, eax
    .ENDIF
    invoke ZfOutFinal
    .IF g_zfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke VfsFreeMem, pC
    invoke VfsFreeMem, pD
    invoke VfsFreeMem, pG
    invoke VfsFreeMem, pRaw
    invoke VfsFreeMem, pGrp
    mov eax, ok
    ret
RvzExpandFile ENDP

END
