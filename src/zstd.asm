; FoxImg - Zstandard (RFC 8878) frame decoder, memory to memory.
;
; Unlike the deflate and bzip2 sides this does not stream through the shared
; input: a zstd block's Huffman and FSE bitstreams are read backwards from their
; end, so the whole compressed group has to sit in memory first. The caller
; hands over one frame and a buffer at least as large as its content, which is
; how RVZ uses it - one frame per chunk-sized group.
;
; The layout of the decoder follows the reference "educational decoder" in the
; zstd repository, which is the spec written as code: FSE tables are spread with
; the (size/2 + size/8 + 3) step, Huffman weights arrive direct or as two
; interleaved FSE streams, literals come as one or four streams, and sequences
; interleave three FSE states with raw offset / length bits. Sequences are
; executed as they are decoded rather than collected first.
;
; Not handled, and declined: dictionaries, skippable frames, and the optional
; XXH64 content checksum (its four bytes are stepped over, not verified).
include foximg.inc

ZS_MAGIC        equ 0FD2FB528h
ZS_BLOCK_MAX    equ 131072              ; block content limit, also the literals buffer
ZS_FSE_MAXLOG   equ 9                   ; accuracy limits: LL 9, OF 8, ML 9, weights 7
ZS_HUF_MAXBITS  equ 11

; one FSE decoding table: symbol per state, bits per state, next-state base per
; state, then the accuracy log - sized for the largest allowed table
FSE_SYM         equ 0                   ; 512 bytes
FSE_NB          equ 512                 ; 512 bytes
FSE_BASE        equ 1024                ; 512 words
FSE_LOG         equ 2048                ; dword
FSE_OK          equ 2052                ; dword: table has been built (repeat mode needs one)
FSE_TBL         equ 2056

.data
; literal length codes: baseline and extra bits (RFC 8878 3.1.1.3.2.1.1)
g_zsLLBase      dw 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,18
                dw 20,22,24,28,32,40,48,64,128,256,512,1024,2048,4096,8192,16384,32768,0    ; code 35 is 65536: the 17th bit is added in code
g_zsLLExtra     db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1
                db 1,1,2,2,3,3,4,6,7,8,9,10,11,12,13,14,15,16
; match length codes
g_zsMLBase      dw 3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28
                dw 29,30,31,32,33,34,35,37,39,41,43,47,51,59,67,83,99,131,259,515,1027,2051,4099,8195,16387,32771,3    ; code 52 is 65539
g_zsMLExtra     db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
                db 0,0,0,0,0,0,1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,12,13,14,15,16
; predefined distributions (signed; -1 is "less than one")
g_zsLLDef       dw 4,3,2,2,2,2,2,2,2,2,2,2,2,1,1,1,2,2
                dw 2,2,2,2,2,2,2,3,2,1,1,1,1,1,-1,-1,-1,-1
g_zsOFDef       dw 1,1,1,1,1,1,2,2,2,1,1,1,1,1,1
                dw 1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1
g_zsMLDef       dw 1,4,3,2,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1
                dw 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1,-1,-1

g_zsErr         dd 0
; forward byte/bit cursor over the block, little-endian bit order
g_zsP           dd 0
g_zsEnd         dd 0
g_zsFBit        dd 0
; backward bit reader: base pointer and a signed bit offset that counts down
g_zsBSrc        dd 0
g_zsBOff        dd 0
; output
g_zsOut         dd 0
g_zsOutPos      dd 0
g_zsOutMax      dd 0
g_zsRep         dd 1, 4, 8              ; repeat offsets, most recent first
g_zsHufMax      dd 0
g_zsHufOk       dd 0
g_zsLitLen      dd 0

.data?
g_zsTblLL       db FSE_TBL dup(?)
g_zsTblOF       db FSE_TBL dup(?)
g_zsTblML       db FSE_TBL dup(?)
g_zsTblW        db FSE_TBL dup(?)
g_zsFreq        dw 256 dup(?)           ; signed normalised frequencies being read
g_zsDesc        dw 256 dup(?)           ; per-symbol state counter while building
g_zsWeights     db 256 dup(?)
g_zsBits        db 256 dup(?)
g_zsHufSym      db 2048 dup(?)
g_zsHufNb       db 2048 dup(?)
g_zsRankCnt     dd 16 dup(?)
g_zsRankIdx     dd 16 dup(?)
g_zsLit         db ZS_BLOCK_MAX dup(?)

.code

ZsBlock         PROTO
ZsLiterals      PROTO
ZsSequences     PROTO
ZsHufTable      PROTO
ZsHufStream     PROTO :DWORD,:DWORD,:DWORD
ZsFseHeader     PROTO :DWORD,:DWORD
ZsFseBuild      PROTO :DWORD,:DWORD,:DWORD,:DWORD
ZsSeqTable      PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD

; ---------------------------------------------------------------------------
; Small helpers
; ---------------------------------------------------------------------------
; n bits (0-32) little-endian from an arbitrary bit offset into a buffer
ZsReadLE PROC USES esi ebx pSrc:DWORD, nBits:DWORD, bitOff:DWORD
    LOCAL res:DWORD
    LOCAL shiftv:DWORD
    LOCAL leftv:DWORD
    mov res, 0
    mov shiftv, 0
    mov eax, nBits
    mov leftv, eax
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov esi, pSrc
    mov eax, bitOff
    mov ecx, eax
    shr eax, 3
    add esi, eax
    and ecx, 7                          ; bits already used in the first byte
    mov ebx, ecx
    .WHILE sdword ptr leftv > 0         ; goes negative on the last byte: signed, or it never ends
        movzx eax, byte ptr [esi]
        inc esi
        mov ecx, ebx
        shr eax, cl
        mov edx, 0FFh
        .IF leftv < 8
            mov ecx, leftv
            mov edx, 1
            shl edx, cl
            dec edx
        .ENDIF
        and eax, edx
        mov ecx, shiftv
        .IF ecx < 32
            shl eax, cl
            add res, eax
        .ENDIF
        mov eax, 8
        sub eax, ebx
        add shiftv, eax
        sub leftv, eax
        xor ebx, ebx
    .ENDW
    mov eax, res
    ret
ZsReadLE ENDP

; forward cursor: n bits, little-endian, spanning bytes
ZsFBits PROC USES ebx n:DWORD
    LOCAL v:DWORD
    mov ebx, n
    .IF ebx == 0
        xor eax, eax
        ret
    .ENDIF
    ; enough bytes left?
    mov eax, g_zsFBit
    add eax, ebx
    add eax, 7
    shr eax, 3
    mov ecx, g_zsP
    add ecx, eax
    .IF ecx > g_zsEnd
        mov g_zsErr, 1
        xor eax, eax
        ret
    .ENDIF
    invoke ZsReadLE, g_zsP, ebx, g_zsFBit
    mov v, eax
    mov eax, g_zsFBit
    add eax, ebx
    mov ecx, eax
    shr eax, 3
    add g_zsP, eax
    and ecx, 7
    mov g_zsFBit, ecx
    mov eax, v
    ret
ZsFBits ENDP

; step back n bits on the forward cursor (used by the FSE header's short values)
ZsFRewind PROC n:DWORD
    mov eax, g_zsFBit
    sub eax, n
    .WHILE eax & 80000000h
        add eax, 8
        dec g_zsP
    .ENDW
    mov g_zsFBit, eax
    ret
ZsFRewind ENDP

ZsFAlign PROC
    .IF g_zsFBit != 0
        mov g_zsFBit, 0
        inc g_zsP
    .ENDIF
    ret
ZsFAlign ENDP

; backward reader: n bits ending at the current offset; bits before the start
; of the stream read as zero, as the spec allows for the final states
ZsBBits PROC USES ebx n:DWORD
    LOCAL abits:DWORD
    LOCAL aoff:DWORD
    mov ebx, n
    mov eax, g_zsBOff
    sub eax, ebx
    mov g_zsBOff, eax
    mov abits, ebx
    mov aoff, eax
    .IF sdword ptr g_zsBOff < 0
        add abits, eax                  ; only what lies inside the buffer
        mov aoff, 0
        .IF sdword ptr abits <= 0
            xor eax, eax
            ret
        .ENDIF
    .ENDIF
    invoke ZsReadLE, g_zsBSrc, abits, aoff
    .IF sdword ptr g_zsBOff < 0
        mov ecx, g_zsBOff
        neg ecx
        .IF ecx >= 32
            xor eax, eax
        .ELSE
            shl eax, cl                 ; the missing low bits are zero
        .ENDIF
    .ENDIF
    ret
ZsBBits ENDP

; ---------------------------------------------------------------------------
; FSE
; ---------------------------------------------------------------------------
; Build a decoding table from signed normalised frequencies (RFC 8878 4.1.1)
ZsFseBuild PROC USES esi edi ebx pTbl:DWORD, pFreq:DWORD, nSym:DWORD, accLog:DWORD
    LOCAL size_:DWORD
    LOCAL highT:DWORD
    LOCAL step_:DWORD
    LOCAL pos:DWORD
    LOCAL s:DWORD
    LOCAL k:DWORD
    mov ecx, accLog
    mov eax, 1
    shl eax, cl
    mov size_, eax
    mov highT, eax
    mov edi, pTbl
    ; "less than one" symbols take single cells from the top down
    mov s, 0
    .WHILE 1
        mov ecx, nSym
        .BREAK .IF s >= ecx
        mov esi, pFreq
        mov ecx, s
        movsx eax, word ptr [esi + ecx * 2]
        .IF eax == -1
            dec highT
            mov eax, highT
            mov edx, s
            mov byte ptr [edi + FSE_SYM + eax], dl
            mov word ptr g_zsDesc[ecx * 2], 1
        .ENDIF
        inc s
    .ENDW
    mov eax, size_
    mov ecx, eax
    shr eax, 1
    shr ecx, 3
    add eax, ecx
    add eax, 3
    mov step_, eax
    mov pos, 0
    mov s, 0
    .WHILE 1
        mov ecx, nSym
        .BREAK .IF s >= ecx
        mov esi, pFreq
        mov ecx, s
        movsx eax, word ptr [esi + ecx * 2]
        .IF eax != 0 && !(eax & 80000000h)
            mov word ptr g_zsDesc[ecx * 2], ax
            mov k, eax
            .WHILE k != 0
                mov eax, pos
                mov edx, s
                mov byte ptr [edi + FSE_SYM + eax], dl
                .REPEAT
                    mov eax, pos
                    add eax, step_
                    mov ecx, size_
                    dec ecx
                    and eax, ecx
                    mov pos, eax
                .UNTIL eax < highT
                dec k
            .ENDW
        .ENDIF
        inc s
    .ENDW
    .IF pos != 0
        mov g_zsErr, 2
        xor eax, eax
        ret
    .ENDIF
    ; bits to read and next-state base for every state
    mov k, 0
    .WHILE 1
        mov ecx, size_
        .BREAK .IF k >= ecx
        mov ecx, k
        movzx ebx, byte ptr [edi + FSE_SYM + ecx]
        movzx eax, word ptr g_zsDesc[ebx * 2]
        inc word ptr g_zsDesc[ebx * 2]
        push eax
        bsr eax, eax
        mov ecx, accLog
        sub ecx, eax                    ; accuracy log - highest bit of the counter
        pop eax
        mov edx, k
        mov byte ptr [edi + FSE_NB + edx], cl
        shl eax, cl
        sub eax, size_
        mov word ptr [edi + FSE_BASE + edx * 2], ax
        inc k
    .ENDW
    mov eax, accLog
    mov dword ptr [edi + FSE_LOG], eax
    mov dword ptr [edi + FSE_OK], 1
    mov eax, TRUE
    ret
ZsFseBuild ENDP

; Read a distribution from the forward cursor and build the table (RFC 8878 4.1.1)
ZsFseHeader PROC USES esi edi ebx pTbl:DWORD, maxLog:DWORD
    LOCAL accLog:DWORD
    LOCAL remaining:DWORD
    LOCAL nSym:DWORD
    LOCAL bits:DWORD
    LOCAL v:DWORD
    LOCAL lowerMask:DWORD
    LOCAL threshold:DWORD
    LOCAL proba:DWORD
    LOCAL repv:DWORD
    invoke ZsFBits, 4
    add eax, 5
    mov accLog, eax
    .IF eax > maxLog
        mov g_zsErr, 3
        xor eax, eax
        ret
    .ENDIF
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    mov remaining, eax
    mov nSym, 0
    .WHILE g_zsErr == 0
        .BREAK .IF sdword ptr remaining <= 0
        mov eax, remaining
        .BREAK .IF nSym >= 256
        inc eax
        bsr eax, eax
        inc eax
        mov bits, eax
        invoke ZsFBits, bits
        mov v, eax
        mov ecx, bits
        dec ecx
        mov eax, 1
        shl eax, cl
        dec eax
        mov lowerMask, eax
        inc ecx
        mov eax, 1
        shl eax, cl
        dec eax
        sub eax, remaining
        dec eax
        mov threshold, eax
        mov eax, v
        and eax, lowerMask
        .IF eax < threshold
            invoke ZsFRewind, 1         ; small values use one bit fewer
            mov eax, v
            and eax, lowerMask
            mov v, eax
        .ELSE
            mov eax, v
            .IF eax > lowerMask
                sub eax, threshold
                mov v, eax
            .ENDIF
        .ENDIF
        mov eax, v
        dec eax
        mov proba, eax                  ; 0 arrives as -1, "less than one"
        mov ecx, eax
        .IF sdword ptr proba < 0
            neg ecx
        .ENDIF
        sub remaining, ecx
        mov ecx, nSym
        mov word ptr g_zsFreq[ecx * 2], ax
        inc nSym
        .IF proba == 0
            invoke ZsFBits, 2
            mov repv, eax
            .WHILE 1
                mov ecx, repv
                .WHILE ecx != 0 && nSym < 256
                    mov eax, nSym
                    mov word ptr g_zsFreq[eax * 2], 0
                    inc nSym
                    dec ecx
                .ENDW
                .BREAK .IF repv != 3
                invoke ZsFBits, 2
                mov repv, eax
            .ENDW
        .ENDIF
    .ENDW
    invoke ZsFAlign
    .IF g_zsErr != 0 || remaining != 0 || nSym >= 256
        mov g_zsErr, 4
        xor eax, eax
        ret
    .ENDIF
    invoke ZsFseBuild, pTbl, offset g_zsFreq, nSym, accLog
    ret
ZsFseHeader ENDP

; A table that always yields one symbol and consumes no bits (RLE mode)
ZsFseRle PROC pTbl:DWORD, sym:DWORD
    mov edx, pTbl
    mov eax, sym
    mov byte ptr [edx + FSE_SYM], al
    mov byte ptr [edx + FSE_NB], 0
    mov word ptr [edx + FSE_BASE], 0
    mov dword ptr [edx + FSE_LOG], 0
    mov dword ptr [edx + FSE_OK], 1
    ret
ZsFseRle ENDP

; ---------------------------------------------------------------------------
; Huffman literals
; ---------------------------------------------------------------------------
; Weights -> bit lengths -> canonical table (RFC 8878 4.2.1)
ZsHufBuild PROC USES esi edi ebx nSym:DWORD
    LOCAL sum:DWORD
    LOCAL maxBits:DWORD
    LOCAL leftOver:DWORD
    LOCAL lastW:DWORD
    LOCAL i:DWORD
    LOCAL tsize:DWORD
    mov sum, 0
    mov i, 0
    .WHILE 1
        mov ecx, nSym
        .BREAK .IF i >= ecx
        mov ecx, i
        movzx eax, byte ptr g_zsWeights[ecx]
        .IF eax > ZS_HUF_MAXBITS
            mov g_zsErr, 5
            xor eax, eax
            ret
        .ENDIF
        .IF eax != 0
            mov ecx, eax
            dec ecx
            mov eax, 1
            shl eax, cl
            add sum, eax
        .ENDIF
        inc i
    .ENDW
    bsr eax, sum
    inc eax
    mov maxBits, eax
    .IF eax > ZS_HUF_MAXBITS || sum == 0
        mov g_zsErr, 6
        xor eax, eax
        ret
    .ENDIF
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    sub eax, sum
    mov leftOver, eax
    mov ecx, eax
    dec ecx
    test eax, ecx
    .IF !ZERO?                          ; the remainder must be a power of two
        mov g_zsErr, 7
        xor eax, eax
        ret
    .ENDIF
    bsr eax, leftOver
    inc eax
    mov lastW, eax
    ; bits per symbol, the last one inferred
    mov i, 0
    .WHILE 1
        mov ecx, nSym
        .BREAK .IF i >= ecx
        mov ecx, i
        movzx eax, byte ptr g_zsWeights[ecx]
        .IF eax != 0
            mov edx, maxBits
            inc edx
            sub edx, eax
            mov eax, edx
        .ENDIF
        mov byte ptr g_zsBits[ecx], al
        inc i
    .ENDW
    mov eax, maxBits
    inc eax
    sub eax, lastW
    mov ecx, nSym
    mov byte ptr g_zsBits[ecx], al
    inc nSym
    ; canonical assignment: count per length, then ranges from the longest up
    mov edi, offset g_zsRankCnt
    xor eax, eax
    mov ecx, 16
    rep stosd
    mov i, 0
    .WHILE 1
        mov ecx, nSym
        .BREAK .IF i >= ecx
        mov ecx, i
        movzx eax, byte ptr g_zsBits[ecx]
        inc dword ptr g_zsRankCnt[eax * 4]
        inc i
    .ENDW
    mov ecx, maxBits
    mov eax, 1
    shl eax, cl
    mov tsize, eax
    mov dword ptr g_zsRankIdx[ecx * 4], 0
    mov i, ecx
    .WHILE i >= 1
        mov ebx, i
        mov eax, dword ptr g_zsRankCnt[ebx * 4]
        mov ecx, maxBits
        sub ecx, ebx
        shl eax, cl                     ; cells per code of this length
        add eax, dword ptr g_zsRankIdx[ebx * 4]
        mov dword ptr g_zsRankIdx[ebx * 4 - 4], eax
        ; every state in this rank's range reads the same number of bits
        mov edi, dword ptr g_zsRankIdx[ebx * 4]
        mov ecx, eax
        sub ecx, edi
        add edi, offset g_zsHufNb
        mov eax, ebx
        rep stosb
        dec i
    .ENDW
    mov eax, dword ptr g_zsRankIdx[0]
    .IF eax != tsize
        mov g_zsErr, 8
        xor eax, eax
        ret
    .ENDIF
    mov i, 0
    .WHILE 1
        mov ecx, nSym
        .BREAK .IF i >= ecx
        mov ecx, i
        movzx ebx, byte ptr g_zsBits[ecx]
        .IF ebx != 0
            mov edi, dword ptr g_zsRankIdx[ebx * 4]
            mov ecx, maxBits
            sub ecx, ebx
            mov edx, 1
            shl edx, cl
            add dword ptr g_zsRankIdx[ebx * 4], edx
            mov ecx, edx
            add edi, offset g_zsHufSym
            mov eax, i
            rep stosb
        .ENDIF
        inc i
    .ENDW
    mov eax, maxBits
    mov g_zsHufMax, eax
    mov g_zsHufOk, 1
    mov eax, TRUE
    ret
ZsHufBuild ENDP

; Tree description at the forward cursor: direct 4-bit weights, or an FSE
; header followed by two interleaved backward streams of weights
ZsHufTable PROC USES esi edi ebx
    LOCAL hdr:DWORD
    LOCAL nSym:DWORD
    LOCAL i:DWORD
    LOCAL pEnd:DWORD
    LOCAL st1:DWORD
    LOCAL st2:DWORD
    invoke ZsFBits, 8
    mov hdr, eax
    mov edi, offset g_zsWeights
    xor eax, eax
    mov ecx, 64
    rep stosd
    .IF hdr >= 128
        mov eax, hdr
        sub eax, 127
        mov nSym, eax
        inc eax
        shr eax, 1                      ; bytes holding two weights each
        mov esi, g_zsP
        add eax, esi
        .IF eax > g_zsEnd
            mov g_zsErr, 9
            xor eax, eax
            ret
        .ENDIF
        mov g_zsP, eax
        mov i, 0
        .WHILE 1
            mov ecx, nSym
            .BREAK .IF i >= ecx
            mov ecx, i
            mov eax, ecx
            shr eax, 1
            movzx eax, byte ptr [esi + eax]
            test ecx, 1
            .IF ZERO?
                shr eax, 4
            .ELSE
                and eax, 0Fh
            .ENDIF
            mov byte ptr g_zsWeights[ecx], al
            inc i
        .ENDW
    .ELSE
        ; the next hdr bytes hold an FSE-coded weight list
        mov eax, g_zsP
        add eax, hdr
        mov pEnd, eax
        .IF eax > g_zsEnd || hdr == 0
            mov g_zsErr, 10
            xor eax, eax
            ret
        .ENDIF
        push g_zsEnd
        mov g_zsEnd, eax                ; confine the forward cursor to the sub-stream
        invoke ZsFseHeader, offset g_zsTblW, 7
        pop g_zsEnd
        .IF eax == 0
            xor eax, eax
            ret
        .ENDIF
        ; what remains of the sub-stream is read backwards, two states in turn
        mov esi, g_zsP
        mov g_zsBSrc, esi
        mov eax, pEnd
        sub eax, esi
        .IF eax == 0 || (eax & 80000000h)
            mov g_zsErr, 11
            xor eax, eax
            ret
        .ENDIF
        mov ecx, eax
        movzx eax, byte ptr [esi + ecx - 1]
        push ecx
        bsr eax, eax
        pop ecx
        mov edx, 8
        sub edx, eax                    ; padding: bits above the marker
        shl ecx, 3
        sub ecx, edx
        mov g_zsBOff, ecx
        mov edi, offset g_zsTblW
        invoke ZsBBits, dword ptr [edi + FSE_LOG]
        mov st1, eax
        invoke ZsBBits, dword ptr [edi + FSE_LOG]
        mov st2, eax
        mov nSym, 0
        .WHILE g_zsErr == 0 && nSym < 255
            ; state 1
            mov ecx, st1
            movzx eax, byte ptr [edi + FSE_SYM + ecx]
            mov ebx, nSym
            mov byte ptr g_zsWeights[ebx], al
            inc nSym
            movzx eax, byte ptr [edi + FSE_NB + ecx]
            invoke ZsBBits, eax
            mov ecx, st1
            movzx edx, word ptr [edi + FSE_BASE + ecx * 2]
            add eax, edx
            mov st1, eax
            .IF sdword ptr g_zsBOff < 0
                mov ecx, st2            ; one symbol left in the other state
                movzx eax, byte ptr [edi + FSE_SYM + ecx]
                mov ebx, nSym
                mov byte ptr g_zsWeights[ebx], al
                inc nSym
                .BREAK
            .ENDIF
            ; state 2
            mov ecx, st2
            movzx eax, byte ptr [edi + FSE_SYM + ecx]
            mov ebx, nSym
            mov byte ptr g_zsWeights[ebx], al
            inc nSym
            movzx eax, byte ptr [edi + FSE_NB + ecx]
            invoke ZsBBits, eax
            mov ecx, st2
            movzx edx, word ptr [edi + FSE_BASE + ecx * 2]
            add eax, edx
            mov st2, eax
            .IF sdword ptr g_zsBOff < 0
                mov ecx, st1
                movzx eax, byte ptr [edi + FSE_SYM + ecx]
                mov ebx, nSym
                mov byte ptr g_zsWeights[ebx], al
                inc nSym
                .BREAK
            .ENDIF
        .ENDW
        mov eax, pEnd
        mov g_zsP, eax
        mov g_zsFBit, 0
    .ENDIF
    .IF g_zsErr != 0
        xor eax, eax
        ret
    .ENDIF
    invoke ZsHufBuild, nSym
    ret
ZsHufTable ENDP

; One Huffman bitstream of cb bytes at pSrc into pDst; returns symbols written
ZsHufStream PROC USES esi edi ebx pSrc:DWORD, cb:DWORD, pDst:DWORD
    LOCAL state_:DWORD
    LOCAL n:DWORD
    LOCAL maxBits:DWORD
    .IF cb == 0
        mov g_zsErr, 12
        xor eax, eax
        ret
    .ENDIF
    mov esi, pSrc
    mov g_zsBSrc, esi
    mov ecx, cb
    movzx eax, byte ptr [esi + ecx - 1]
    .IF eax == 0
        mov g_zsErr, 13                  ; a final byte without its marker bit
        xor eax, eax
        ret
    .ENDIF
    bsr eax, eax
    mov edx, 8
    sub edx, eax
    mov ecx, cb
    shl ecx, 3
    sub ecx, edx
    mov g_zsBOff, ecx
    mov eax, g_zsHufMax
    mov maxBits, eax
    invoke ZsBBits, maxBits
    mov state_, eax
    mov edi, pDst
    mov n, 0
    mov ebx, maxBits
    neg ebx                             ; the stream is spent when the offset reaches -maxBits
    .WHILE g_zsErr == 0
        .BREAK .IF sdword ptr g_zsBOff <= ebx
        mov ecx, state_
        movzx eax, byte ptr g_zsHufSym[ecx]
        mov byte ptr [edi], al
        inc edi
        inc n
        .IF n > ZS_BLOCK_MAX
            mov g_zsErr, 14
            .BREAK
        .ENDIF
        movzx eax, byte ptr g_zsHufNb[ecx]
        push ecx
        invoke ZsBBits, eax
        pop ecx
        ; state = ((state << nb) + rest) & (2^maxBits - 1)
        mov edx, ecx
        movzx ecx, byte ptr g_zsHufNb[ecx]
        shl edx, cl
        add edx, eax
        mov ecx, maxBits
        mov eax, 1
        shl eax, cl
        dec eax
        and edx, eax
        mov state_, edx
    .ENDW
    .IF g_zsErr != 0 || g_zsBOff != ebx
        mov g_zsErr, 15                  ; a stream must end exactly on its first bit
        xor eax, eax
        ret
    .ENDIF
    mov eax, n
    ret
ZsHufStream ENDP

; Literals section: raw, RLE, or Huffman in one or four streams (RFC 8878 3.1.1.3.1)
ZsLiterals PROC USES esi edi ebx
    LOCAL btype:DWORD
    LOCAL sform:DWORD
    LOCAL regen:DWORD
    LOCAL csize:DWORD
    LOCAL nStreams:DWORD
    LOCAL pHuf:DWORD
    LOCAL pHufEnd:DWORD
    LOCAL s1:DWORD
    LOCAL s2:DWORD
    LOCAL s3:DWORD
    LOCAL got:DWORD
    invoke ZsFBits, 2
    mov btype, eax
    invoke ZsFBits, 2
    mov sform, eax
    .IF btype <= 1
        ; sizes only
        mov eax, sform
        .IF eax == 0 || eax == 2
            invoke ZsFRewind, 1         ; the low size-format bit is part of the size
            invoke ZsFBits, 5
        .ELSEIF eax == 1
            invoke ZsFBits, 12
        .ELSE
            invoke ZsFBits, 20
        .ENDIF
        mov regen, eax
        .IF eax > ZS_BLOCK_MAX || g_zsErr != 0
            mov g_zsErr, 16
            xor eax, eax
            ret
        .ENDIF
        mov edi, offset g_zsLit
        mov ecx, regen
        .IF btype == 0
            mov esi, g_zsP
            lea eax, [esi + ecx]
            .IF eax > g_zsEnd
                mov g_zsErr, 17
                xor eax, eax
                ret
            .ENDIF
            mov g_zsP, eax
            rep movsb
        .ELSE
            mov esi, g_zsP
            .IF esi >= g_zsEnd
                mov g_zsErr, 18
                xor eax, eax
                ret
            .ENDIF
            movzx eax, byte ptr [esi]
            inc g_zsP
            rep stosb
        .ENDIF
        mov eax, regen
        mov g_zsLitLen, eax
        mov eax, TRUE
        ret
    .ENDIF
    ; compressed (2) or treeless (3)
    mov nStreams, 4
    mov eax, sform
    .IF eax == 0
        mov nStreams, 1
        invoke ZsFBits, 10
        mov regen, eax
        invoke ZsFBits, 10
        mov csize, eax
    .ELSEIF eax == 1
        invoke ZsFBits, 10
        mov regen, eax
        invoke ZsFBits, 10
        mov csize, eax
    .ELSEIF eax == 2
        invoke ZsFBits, 14
        mov regen, eax
        invoke ZsFBits, 14
        mov csize, eax
    .ELSE
        invoke ZsFBits, 18
        mov regen, eax
        invoke ZsFBits, 18
        mov csize, eax
    .ENDIF
    .IF g_zsErr != 0 || regen > ZS_BLOCK_MAX
        mov g_zsErr, 19
        xor eax, eax
        ret
    .ENDIF
    mov eax, g_zsP
    mov pHuf, eax
    add eax, csize
    mov pHufEnd, eax
    .IF eax > g_zsEnd
        mov g_zsErr, 20
        xor eax, eax
        ret
    .ENDIF
    mov g_zsP, eax                      ; the block continues after the literal streams
    mov g_zsFBit, 0
    .IF btype == 2
        push g_zsP
        push g_zsEnd
        mov eax, pHuf
        mov g_zsP, eax
        mov eax, pHufEnd
        mov g_zsEnd, eax
        invoke ZsHufTable
        mov ecx, g_zsP
        mov pHuf, ecx                   ; streams follow the tree description
        pop g_zsEnd
        pop g_zsP
        .IF eax == 0
            xor eax, eax
            ret
        .ENDIF
    .ELSEIF g_zsHufOk == 0
        mov g_zsErr, 21                  ; treeless with no tree to reuse
        xor eax, eax
        ret
    .ENDIF
    mov edi, offset g_zsLit
    .IF nStreams == 1
        mov eax, pHufEnd
        sub eax, pHuf
        invoke ZsHufStream, pHuf, eax, edi
        mov got, eax
    .ELSE
        mov esi, pHuf
        lea eax, [esi + 6]
        .IF eax > pHufEnd
            mov g_zsErr, 22
            xor eax, eax
            ret
        .ENDIF
        movzx eax, word ptr [esi]
        mov s1, eax
        movzx eax, word ptr [esi + 2]
        mov s2, eax
        movzx eax, word ptr [esi + 4]
        mov s3, eax
        add esi, 6
        mov eax, esi
        add eax, s1
        add eax, s2
        add eax, s3
        .IF eax > pHufEnd
            mov g_zsErr, 23
            xor eax, eax
            ret
        .ENDIF
        mov got, 0
        invoke ZsHufStream, esi, s1, edi
        add got, eax
        add edi, eax
        add esi, s1
        invoke ZsHufStream, esi, s2, edi
        add got, eax
        add edi, eax
        add esi, s2
        invoke ZsHufStream, esi, s3, edi
        add got, eax
        add edi, eax
        add esi, s3
        mov eax, pHufEnd
        sub eax, esi
        invoke ZsHufStream, esi, eax, edi
        add got, eax
    .ENDIF
    mov eax, got
    .IF g_zsErr != 0 || eax != regen
        mov g_zsErr, 24
        xor eax, eax
        ret
    .ENDIF
    mov g_zsLitLen, eax
    mov eax, TRUE
    ret
ZsLiterals ENDP

; ---------------------------------------------------------------------------
; Sequences
; ---------------------------------------------------------------------------
; Set up one of the three tables for the mode given (RFC 8878 3.1.1.3.2.1)
ZsSeqTable PROC pTbl:DWORD, mode_:DWORD, pDef:DWORD, nDef:DWORD, logDef:DWORD, maxLog:DWORD
    mov eax, mode_
    .IF eax == 0
        invoke ZsFseBuild, pTbl, pDef, nDef, logDef
        ret
    .ELSEIF eax == 1
        mov ecx, g_zsP
        .IF ecx >= g_zsEnd
            mov g_zsErr, 25
            xor eax, eax
            ret
        .ENDIF
        movzx eax, byte ptr [ecx]
        inc g_zsP
        invoke ZsFseRle, pTbl, eax
        mov eax, TRUE
        ret
    .ELSEIF eax == 2
        invoke ZsFseHeader, pTbl, maxLog
        ret
    .ENDIF
    mov ecx, pTbl
    .IF dword ptr [ecx + FSE_OK] == 0
        mov g_zsErr, 26                  ; repeat with nothing to repeat
        xor eax, eax
        ret
    .ENDIF
    mov eax, TRUE
    ret
ZsSeqTable ENDP

; Emit cb literals from the literal buffer at position pLit
ZsCopyLit PROC USES esi edi pLit:DWORD, cb:DWORD
    mov eax, g_zsOutPos
    add eax, cb
    .IF eax > g_zsOutMax
        mov g_zsErr, 27
        ret
    .ENDIF
    mov esi, pLit
    mov edi, g_zsOut
    add edi, g_zsOutPos
    mov ecx, cb
    rep movsb
    mov eax, cb
    add g_zsOutPos, eax
    ret
ZsCopyLit ENDP

; Sequences section and execution (RFC 8878 3.1.1.3.2 and 3.1.1.4)
ZsSequences PROC USES esi edi ebx
    LOCAL nSeq:DWORD
    LOCAL modes:DWORD
    LOCAL litPos:DWORD
    LOCAL stLL:DWORD
    LOCAL stOF:DWORD
    LOCAL stML:DWORD
    LOCAL ofCode:DWORD
    LOCAL llCode:DWORD
    LOCAL mlCode:DWORD
    LOCAL offv:DWORD
    LOCAL mlen:DWORD
    LOCAL llen:DWORD
    LOCAL i:DWORD
    LOCAL idx:DWORD
    mov litPos, 0
    mov esi, g_zsP
    .IF esi >= g_zsEnd
        mov g_zsErr, 28
        xor eax, eax
        ret
    .ENDIF
    movzx eax, byte ptr [esi]
    inc esi
    .IF eax < 128
        mov nSeq, eax
    .ELSEIF eax < 255
        sub eax, 128
        shl eax, 8
        .IF esi >= g_zsEnd
            mov g_zsErr, 29
            xor eax, eax
            ret
        .ENDIF
        movzx ecx, byte ptr [esi]
        inc esi
        add eax, ecx
        mov nSeq, eax
    .ELSE
        lea eax, [esi + 2]
        .IF eax > g_zsEnd
            mov g_zsErr, 30
            xor eax, eax
            ret
        .ENDIF
        movzx eax, word ptr [esi]
        add esi, 2
        add eax, 7F00h
        mov nSeq, eax
    .ENDIF
    mov g_zsP, esi
    mov g_zsFBit, 0
    .IF nSeq == 0
        ; nothing but literals
        invoke ZsCopyLit, offset g_zsLit, g_zsLitLen
        .IF g_zsErr != 0
            xor eax, eax
            ret
        .ENDIF
        mov eax, TRUE
        ret
    .ENDIF
    .IF esi >= g_zsEnd
        mov g_zsErr, 31
        xor eax, eax
        ret
    .ENDIF
    movzx eax, byte ptr [esi]
    inc g_zsP
    mov modes, eax
    test eax, 3
    .IF !ZERO?
        mov g_zsErr, 32                  ; reserved bits
        xor eax, eax
        ret
    .ENDIF
    mov eax, modes
    shr eax, 6
    and eax, 3
    invoke ZsSeqTable, offset g_zsTblLL, eax, offset g_zsLLDef, 36, 6, 9
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, modes
    shr eax, 4
    and eax, 3
    invoke ZsSeqTable, offset g_zsTblOF, eax, offset g_zsOFDef, 29, 5, 8
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, modes
    shr eax, 2
    and eax, 3
    invoke ZsSeqTable, offset g_zsTblML, eax, offset g_zsMLDef, 53, 6, 9
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    ; the rest of the block is one bitstream read backwards
    mov esi, g_zsP
    mov g_zsBSrc, esi
    mov ecx, g_zsEnd
    sub ecx, esi
    .IF ecx == 0 || (ecx & 80000000h)
        mov g_zsErr, 33
        xor eax, eax
        ret
    .ENDIF
    movzx eax, byte ptr [esi + ecx - 1]
    .IF eax == 0
        mov g_zsErr, 34
        xor eax, eax
        ret
    .ENDIF
    push ecx
    bsr eax, eax
    pop ecx
    mov edx, 8
    sub edx, eax
    shl ecx, 3
    sub ecx, edx
    mov g_zsBOff, ecx
    invoke ZsBBits, dword ptr g_zsTblLL[FSE_LOG]
    mov stLL, eax
    invoke ZsBBits, dword ptr g_zsTblOF[FSE_LOG]
    mov stOF, eax
    invoke ZsBBits, dword ptr g_zsTblML[FSE_LOG]
    mov stML, eax
    mov i, 0
    .WHILE g_zsErr == 0
        mov ecx, nSeq
        .BREAK .IF i >= ecx
        mov ecx, stOF
        movzx eax, byte ptr g_zsTblOF[FSE_SYM + ecx]
        mov ofCode, eax
        mov ecx, stLL
        movzx eax, byte ptr g_zsTblLL[FSE_SYM + ecx]
        mov llCode, eax
        mov ecx, stML
        movzx eax, byte ptr g_zsTblML[FSE_SYM + ecx]
        mov mlCode, eax
        .IF llCode > 35 || mlCode > 52 || ofCode > 31
            mov g_zsErr, 35
            .BREAK
        .ENDIF
        ; offset bits, then match length bits, then literal length bits
        invoke ZsBBits, ofCode
        mov ecx, ofCode
        mov edx, 1
        shl edx, cl
        add eax, edx
        mov offv, eax
        mov ecx, mlCode
        movzx eax, byte ptr g_zsMLExtra[ecx]
        invoke ZsBBits, eax
        mov ecx, mlCode
        movzx edx, word ptr g_zsMLBase[ecx * 2]
        add eax, edx
        .IF ecx == 52
            add eax, 10000h
        .ENDIF
        mov mlen, eax
        mov ecx, llCode
        movzx eax, byte ptr g_zsLLExtra[ecx]
        invoke ZsBBits, eax
        mov ecx, llCode
        movzx edx, word ptr g_zsLLBase[ecx * 2]
        add eax, edx
        .IF ecx == 35
            add eax, 10000h
        .ENDIF
        mov llen, eax
        ; state updates, skipped after the last sequence: LL, ML, OF
        mov eax, i
        inc eax
        .IF eax < nSeq
            mov ecx, stLL
            movzx eax, byte ptr g_zsTblLL[FSE_NB + ecx]
            invoke ZsBBits, eax
            mov ecx, stLL
            movzx edx, word ptr g_zsTblLL[FSE_BASE + ecx * 2]
            add eax, edx
            mov stLL, eax
            mov ecx, stML
            movzx eax, byte ptr g_zsTblML[FSE_NB + ecx]
            invoke ZsBBits, eax
            mov ecx, stML
            movzx edx, word ptr g_zsTblML[FSE_BASE + ecx * 2]
            add eax, edx
            mov stML, eax
            mov ecx, stOF
            movzx eax, byte ptr g_zsTblOF[FSE_NB + ecx]
            invoke ZsBBits, eax
            mov ecx, stOF
            movzx edx, word ptr g_zsTblOF[FSE_BASE + ecx * 2]
            add eax, edx
            mov stOF, eax
        .ENDIF
        ; --- execute: literals ---
        mov eax, litPos
        add eax, llen
        .IF eax > g_zsLitLen
            mov g_zsErr, 36
            .BREAK
        .ENDIF
        mov eax, offset g_zsLit
        add eax, litPos
        invoke ZsCopyLit, eax, llen
        .BREAK .IF g_zsErr != 0
        mov eax, llen
        add litPos, eax
        ; --- the offset, with the three repeat slots ---
        mov eax, offv
        .IF eax <= 3
            dec eax
            .IF llen == 0
                inc eax                 ; zero literals shift the repeat slots by one
            .ENDIF
            mov idx, eax
            .IF eax == 0
                mov eax, g_zsRep[0]
            .ELSE
                .IF eax < 3
                    mov eax, dword ptr g_zsRep[eax * 4]
                .ELSE
                    mov eax, g_zsRep[0]
                    dec eax
                .ENDIF
                mov edx, eax
                .IF idx > 1
                    mov ecx, g_zsRep[4]
                    mov g_zsRep[8], ecx
                .ENDIF
                mov ecx, g_zsRep[0]
                mov g_zsRep[4], ecx
                mov g_zsRep[0], edx
                mov eax, edx
            .ENDIF
        .ELSE
            sub eax, 3
            mov ecx, g_zsRep[4]
            mov g_zsRep[8], ecx
            mov ecx, g_zsRep[0]
            mov g_zsRep[4], ecx
            mov g_zsRep[0], eax
        .ENDIF
        mov offv, eax
        ; --- match copy, byte by byte so the length may exceed the offset ---
        .IF eax == 0 || eax > g_zsOutPos
            mov g_zsErr, 37
            .BREAK
        .ENDIF
        mov eax, g_zsOutPos
        add eax, mlen
        .IF eax > g_zsOutMax
            mov g_zsErr, 38
            .BREAK
        .ENDIF
        mov edi, g_zsOut
        add edi, g_zsOutPos
        mov esi, edi
        sub esi, offv
        mov ecx, mlen
        rep movsb
        mov eax, mlen
        add g_zsOutPos, eax
        inc i
    .ENDW
    .IF g_zsErr != 0 || g_zsBOff != 0
        mov g_zsErr, 39                  ; the bitstream must be consumed exactly
        xor eax, eax
        ret
    .ENDIF
    ; leftover literals
    mov eax, g_zsLitLen
    sub eax, litPos
    mov ecx, offset g_zsLit
    add ecx, litPos
    invoke ZsCopyLit, ecx, eax
    .IF g_zsErr != 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, TRUE
    ret
ZsSequences ENDP

; One compressed block: literals then sequences, cursor bounded to the block
ZsBlock PROC
    invoke ZsLiterals
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    invoke ZsSequences
    ret
ZsBlock ENDP

; ---------------------------------------------------------------------------
; Frame
; ---------------------------------------------------------------------------
; Decode one frame at pIn (cbIn bytes) into pOut (cbOutMax bytes). Returns the
; number of bytes produced, or 0 with g_zsErr set. Zero-length content is not
; a case RVZ produces, so 0 is unambiguous here.
ZsDecode PROC USES esi edi ebx pIn:DWORD, cbIn:DWORD, pOut:DWORD, cbOutMax:DWORD
    LOCAL fhd:DWORD
    LOCAL fcsFlag:DWORD
    LOCAL single:DWORD
    LOCAL checksum:DWORD
    LOCAL dictFlag:DWORD
    LOCAL fcs:DWORD
    LOCAL lastBlk:DWORD
    LOCAL btype:DWORD
    LOCAL bsize:DWORD
    LOCAL blkEnd:DWORD
    mov g_zsErr, 0
    mov g_zsHufOk, 0
    mov dword ptr g_zsTblLL[FSE_OK], 0
    mov dword ptr g_zsTblOF[FSE_OK], 0
    mov dword ptr g_zsTblML[FSE_OK], 0
    mov g_zsRep[0], 1
    mov g_zsRep[4], 4
    mov g_zsRep[8], 8
    mov eax, pOut
    mov g_zsOut, eax
    mov g_zsOutPos, 0
    mov eax, cbOutMax
    mov g_zsOutMax, eax
    mov esi, pIn
    mov g_zsP, esi
    mov g_zsFBit, 0
    mov eax, esi
    add eax, cbIn
    mov g_zsEnd, eax
    .IF cbIn < 6 || dword ptr [esi] != ZS_MAGIC
        mov g_zsErr, 40
        xor eax, eax
        ret
    .ENDIF
    movzx eax, byte ptr [esi + 4]
    mov fhd, eax
    mov ecx, eax
    shr ecx, 6
    mov fcsFlag, ecx
    mov ecx, eax
    shr ecx, 5
    and ecx, 1
    mov single, ecx
    test eax, 8
    .IF !ZERO?
        mov g_zsErr, 41                  ; reserved bit
        xor eax, eax
        ret
    .ENDIF
    mov ecx, eax
    shr ecx, 2
    and ecx, 1
    mov checksum, ecx
    and eax, 3
    mov dictFlag, eax
    .IF eax != 0
        mov g_zsErr, 42                  ; dictionaries are declined
        xor eax, eax
        ret
    .ENDIF
    add esi, 5
    .IF single == 0
        inc esi                         ; window descriptor: the whole output is the window here
    .ENDIF
    mov fcs, 0
    .IF single != 0 || fcsFlag != 0
        mov eax, fcsFlag
        .IF eax == 0
            movzx eax, byte ptr [esi]
            inc esi
        .ELSEIF eax == 1
            movzx eax, word ptr [esi]
            add eax, 256
            add esi, 2
        .ELSEIF eax == 2
            mov eax, dword ptr [esi]
            add esi, 4
        .ELSE
            mov eax, dword ptr [esi]
            .IF dword ptr [esi + 4] != 0
                mov g_zsErr, 43          ; beyond anything a 32-bit buffer holds
                xor eax, eax
                ret
            .ENDIF
            add esi, 8
        .ENDIF
        mov fcs, eax
    .ENDIF
    .IF esi > g_zsEnd
        mov g_zsErr, 44
        xor eax, eax
        ret
    .ENDIF
    mov g_zsP, esi
    ; blocks
    .WHILE g_zsErr == 0
        mov esi, g_zsP
        lea eax, [esi + 3]
        .IF eax > g_zsEnd
            mov g_zsErr, 45
            .BREAK
        .ENDIF
        movzx eax, byte ptr [esi]
        movzx ecx, byte ptr [esi + 1]
        shl ecx, 8
        or eax, ecx
        movzx ecx, byte ptr [esi + 2]
        shl ecx, 16
        or eax, ecx
        add esi, 3
        mov ecx, eax
        and ecx, 1
        mov lastBlk, ecx
        mov ecx, eax
        shr ecx, 1
        and ecx, 3
        mov btype, ecx
        shr eax, 3
        mov bsize, eax
        .IF ecx == 3 || eax > ZS_BLOCK_MAX
            mov g_zsErr, 46
            .BREAK
        .ENDIF
        .IF btype == 0
            lea eax, [esi + eax]
            .IF eax > g_zsEnd
                mov g_zsErr, 47
                .BREAK
            .ENDIF
            mov g_zsP, eax
            invoke ZsCopyLit, esi, bsize
        .ELSEIF btype == 1
            .IF esi >= g_zsEnd
                mov g_zsErr, 48
                .BREAK
            .ENDIF
            mov eax, g_zsOutPos
            add eax, bsize
            .IF eax > g_zsOutMax
                mov g_zsErr, 49
                .BREAK
            .ENDIF
            movzx eax, byte ptr [esi]
            inc esi
            mov g_zsP, esi
            mov edi, g_zsOut
            add edi, g_zsOutPos
            mov ecx, bsize
            rep stosb
            mov eax, bsize
            add g_zsOutPos, eax
        .ELSE
            lea eax, [esi + eax]
            mov blkEnd, eax
            .IF eax > g_zsEnd
                mov g_zsErr, 50
                .BREAK
            .ENDIF
            push g_zsEnd
            mov g_zsP, esi
            mov g_zsFBit, 0
            mov g_zsEnd, eax
            invoke ZsBlock
            pop g_zsEnd
            mov eax, blkEnd
            mov g_zsP, eax
            mov g_zsFBit, 0
        .ENDIF
        .BREAK .IF lastBlk != 0
    .ENDW
    .IF g_zsErr != 0
        xor eax, eax
        ret
    .ENDIF
    .IF checksum != 0
        add g_zsP, 4                    ; XXH64 low half, stepped over
    .ENDIF
    mov eax, g_zsOutPos
    .IF fcs != 0 && eax != fcs
        mov g_zsErr, 51                  ; the frame promised a different size
        xor eax, eax
        ret
    .ENDIF
    ret
ZsDecode ENDP

END
