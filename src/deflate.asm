; FoxImg - DEFLATE (RFC 1951): an inflate decoder and a fixed-Huffman compressor, plus the gzip,
; zip and CSO wrappers built on them. The exe carries its own codec because the Windows compression
; APIs only speak their own framings (MSZIP / XPRESS / LZMS), not the raw deflate streams these
; files hold. CRC-32 comes from ntdll's RtlComputeCrc32, so no table lives in the image.
;
; Inflate streams file-to-file through a 1 MB input buffer and a 1 MB output buffer that keeps the
; last 32 KB after every flush, so back references always land inside the buffer.
include foximg.inc

ZF_INBUF        equ 1024 * 1024
ZF_OUTBUF       equ 1024 * 1024         ; flush threshold; the buffer is larger by keep + overshoot
ZF_KEEP         equ 131072              ; window bytes kept across flushes (LZMA hunks reach past 32 KB)
ZF_OUTALLOC     equ ZF_OUTBUF + ZF_KEEP + 512

.data
; length codes 257-285: first length and extra bits (RFC 1951 3.2.5)
g_zfLenBase     dw 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258
g_zfLenExtra    db 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0
; distance codes 0-29: first distance and extra bits
g_zfDistBase    dw 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577
g_zfDistExtra   db 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13
; order the code-length code lengths arrive in
g_zfClOrder     db 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15

g_zfFile        dd 0                    ; input file and read-ahead buffer
g_zfIn          dd 0
g_zfInPos       dd 0
g_zfInLen       dd 0
g_zfInOffLo     dd 0
g_zfInOffHi     dd 0
g_zfEof         dd 0
g_zfErr         dd 0
g_zfBitBuf      dd 0                    ; bit accumulator, LSB first
g_zfBitCnt      dd 0
g_zfHOut        dd 0                    ; output file, buffer, running CRC and total
g_zfOut         dd 0
g_zfOutPos      dd 0
g_zfOutStart    dd 0                    ; below this the buffer holds the retained window, already written
g_zfCrc         dd 0
g_zfTotLo       dd 0
g_zfTotHi       dd 0
g_zfFixInit     dd 0
g_zfWrapMode    dd 0
g_ctNumTracks   dd 0                    ; container track table (offLo, offHi, pcmBytes, audio)
g_ctAudioSwap   dd 0                    ; audio PCM stored big-endian (CHD)                    ; deflate framing per file: 0 undecided, 1 raw, 2 zlib

.data?
g_zfLC          dw 16 dup(?)            ; dynamic literal/length table: counts per bit length, then symbols
g_zfLS          dw 288 dup(?)
g_zfDC          dw 16 dup(?)            ; dynamic distance table (also borrowed for the code-length code)
g_zfDS          dw 32 dup(?)
g_zfFixLC       dw 16 dup(?)            ; fixed tables, built once
g_zfFixLS       dw 288 dup(?)
g_zfFixDC       dw 16 dup(?)
g_zfFixDS       dw 32 dup(?)
g_zfLens        db 320 dup(?)           ; scratch code lengths (max 286 + 30)
g_zfLLut        dw 512 dup(?)           ; 9-bit fast lookups: dynamic literal, dynamic distance
g_zfDLut        dw 512 dup(?)
g_zfFixLLut     dw 512 dup(?)           ; and the fixed pair, built once
g_zfFixDLut     dw 512 dup(?)
g_ctTracks      dd CT_MAXTRK * 4 dup(?)

.code

ZfSmartInflate  PROTO
Lz4Block        PROTO :DWORD
DfRev           PROTO :DWORD,:DWORD

CtTrackAdd PROC offLo:DWORD, offHi:DWORD, pcmBytes:DWORD, audio:DWORD
    mov eax, g_ctNumTracks
    .IF eax >= CT_MAXTRK
        ret
    .ENDIF
    shl eax, 4
    add eax, offset g_ctTracks
    mov ecx, offLo
    mov dword ptr [eax], ecx
    mov ecx, offHi
    mov dword ptr [eax + 4], ecx
    mov ecx, pcmBytes
    mov dword ptr [eax + 8], ecx
    mov ecx, audio
    mov dword ptr [eax + 12], ecx
    inc g_ctNumTracks
    ret
CtTrackAdd ENDP
FlacAlloc       PROTO
FlacFree        PROTO
FlacStart       PROTO
FlacDecodeStream PROTO :DWORD,:DWORD

; ---------------------------------------------------------------------------
; Input: sequential bytes through FileReadAt so wrappers can seek by resetting the offset
; ---------------------------------------------------------------------------
ZfSetInput PROC offLo:DWORD, offHi:DWORD
    mov eax, offLo
    mov g_zfInOffLo, eax
    mov eax, offHi
    mov g_zfInOffHi, eax
    mov g_zfInPos, 0
    mov g_zfInLen, 0
    mov g_zfEof, 0
    mov g_zfBitBuf, 0
    mov g_zfBitCnt, 0
    ret
ZfSetInput ENDP

; Next byte in eax; sets g_zfErr and returns 0 at end of input
ZfInByte PROC
    mov eax, g_zfInPos
    .IF eax >= g_zfInLen
        .IF g_zfEof != 0
            mov g_zfErr, 1
            xor eax, eax
            ret
        .ENDIF
        invoke FileReadAt, g_zfFile, g_zfInOffLo, g_zfInOffHi, g_zfIn, ZF_INBUF
        .IF eax == 0
            mov g_zfEof, 1
            mov g_zfErr, 1
            xor eax, eax
            ret
        .ENDIF
        mov g_zfInLen, eax
        add g_zfInOffLo, eax
        adc g_zfInOffHi, 0
        mov g_zfInPos, 0
        xor eax, eax
    .ENDIF
    mov ecx, g_zfIn
    movzx eax, byte ptr [ecx + eax]
    inc g_zfInPos
    ret
ZfInByte ENDP

; n bits (0-16), LSB first
ZfBits PROC USES ebx edi n:DWORD
    mov ebx, g_zfBitBuf
    mov edi, g_zfBitCnt
    .WHILE edi < n
        invoke ZfInByte
        mov ecx, edi
        shl eax, cl
        or ebx, eax
        add edi, 8
    .ENDW
    mov ecx, n
    mov eax, ebx
    mov edx, 1
    shl edx, cl
    dec edx
    and eax, edx
    shr ebx, cl
    sub edi, ecx
    mov g_zfBitBuf, ebx
    mov g_zfBitCnt, edi
    ret
ZfBits ENDP

; 4 bytes as a little-endian dword (callers align to a byte first)
ZfDword PROC USES ebx
    invoke ZfBits, 8
    mov ebx, eax
    invoke ZfBits, 8
    shl eax, 8
    or ebx, eax
    invoke ZfBits, 8
    shl eax, 16
    or ebx, eax
    invoke ZfBits, 8
    shl eax, 24
    or eax, ebx
    ret
ZfDword ENDP

; ---------------------------------------------------------------------------
; Output: buffered writes with CRC, keeping the trailing 32 KB as the match window
; ---------------------------------------------------------------------------
ZfWrite PROC USES esi ebx pData:DWORD, cb:DWORD
    LOCAL written:DWORD
    mov esi, pData
    mov ebx, cb
    .WHILE ebx != 0
        invoke WriteFile, g_zfHOut, esi, ebx, addr written, NULL
        .IF eax == 0 || written == 0
            mov g_zfErr, 1
            ret
        .ENDIF
        add esi, written
        sub ebx, written
    .ENDW
    ret
ZfWrite ENDP

ZfOutFlush PROC USES esi edi
    LOCAL cut:DWORD
    LOCAL cb:DWORD
    mov eax, g_zfOutPos
    sub eax, ZF_KEEP
    mov cut, eax                            ; the tail retained below stays a copy of written bytes
    mov eax, g_zfOutPos
    sub eax, g_zfOutStart
    mov cb, eax
    .IF eax != 0
        mov ecx, g_zfOut
        add ecx, g_zfOutStart
        invoke RtlComputeCrc32, g_zfCrc, ecx, cb
        mov g_zfCrc, eax
        mov ecx, g_zfOut
        add ecx, g_zfOutStart
        invoke ZfWrite, ecx, cb
        mov eax, cb
        add g_zfTotLo, eax
        adc g_zfTotHi, 0
    .ENDIF
    mov esi, g_zfOut
    add esi, cut
    mov edi, g_zfOut
    mov ecx, ZF_KEEP
    rep movsb
    mov g_zfOutPos, ZF_KEEP
    mov g_zfOutStart, ZF_KEEP
    ret
ZfOutFlush ENDP

ZfOutFinal PROC
    LOCAL cb:DWORD
    mov eax, g_zfOutPos
    sub eax, g_zfOutStart
    mov cb, eax
    .IF eax != 0
        mov ecx, g_zfOut
        add ecx, g_zfOutStart
        invoke RtlComputeCrc32, g_zfCrc, ecx, cb
        mov g_zfCrc, eax
        mov ecx, g_zfOut
        add ecx, g_zfOutStart
        invoke ZfWrite, ecx, cb
        mov eax, cb
        add g_zfTotLo, eax
        adc g_zfTotHi, 0
        mov eax, g_zfOutPos
        mov g_zfOutStart, eax
    .ENDIF
    ret
ZfOutFinal ENDP

; TRUE when no error struck and at least expHi:expLo bytes came out
ZfCheckTotal PROC expLo:DWORD, expHi:DWORD
    xor eax, eax
    .IF g_zfErr == 0
        mov ecx, g_zfTotLo
        mov edx, g_zfTotHi
        sub ecx, expLo
        sbb edx, expHi
        .IF !CARRY?
            inc eax
        .ENDIF
    .ENDIF
    ret
ZfCheckTotal ENDP

ZfPutB PROC b:DWORD
    mov eax, g_zfOutPos
    .IF eax >= ZF_OUTBUF
        invoke ZfOutFlush
        mov eax, g_zfOutPos
    .ENDIF
    mov ecx, g_zfOut
    mov edx, b
    mov byte ptr [ecx + eax], dl
    inc g_zfOutPos
    ret
ZfPutB ENDP

; Copy cb input bytes to the output unchanged (stored zip entries, plain CSO blocks)
ZfRawCopy PROC USES esi edi ebx cb:DWORD
    mov ebx, cb
    .WHILE ebx != 0 && g_zfErr == 0
        mov eax, g_zfInPos
        .IF eax >= g_zfInLen
            invoke ZfInByte                 ; force a refill
            .BREAK .IF g_zfErr != 0
            dec g_zfInPos
        .ENDIF
        .IF g_zfOutPos >= ZF_OUTBUF
            invoke ZfOutFlush
        .ENDIF
        mov eax, g_zfInLen
        sub eax, g_zfInPos
        .IF eax > ebx
            mov eax, ebx
        .ENDIF
        mov ecx, ZF_OUTBUF
        sub ecx, g_zfOutPos
        .IF eax > ecx
            mov eax, ecx
        .ENDIF
        mov esi, g_zfIn
        add esi, g_zfInPos
        mov edi, g_zfOut
        add edi, g_zfOutPos
        mov ecx, eax
        push eax
        rep movsb
        pop eax
        add g_zfInPos, eax
        add g_zfOutPos, eax
        sub ebx, eax
    .ENDW
    ret
ZfRawCopy ENDP

; ---------------------------------------------------------------------------
; Canonical Huffman: build (counts + symbols sorted by code) and decode bit by bit
; ---------------------------------------------------------------------------
ZfBuild PROC USES esi edi ebx pCnt:DWORD, pSym:DWORD, pLens:DWORD, n:DWORD, pLut:DWORD
    LOCAL offs[16]:WORD
    LOCAL firstc:DWORD
    LOCAL lenv:DWORD
    LOCAL k:DWORD
    mov edi, pCnt
    xor eax, eax
    mov ecx, 16
    rep stosw
    mov esi, pLens
    xor ebx, ebx
    .WHILE ebx < n
        movzx eax, byte ptr [esi + ebx]
        mov ecx, pCnt
        inc word ptr [ecx + eax * 2]
        inc ebx
    .ENDW
    ; over-subscribed set of lengths?
    mov eax, 1
    mov ebx, 1
    .WHILE ebx <= 15
        shl eax, 1
        mov ecx, pCnt
        movzx edx, word ptr [ecx + ebx * 2]
        sub eax, edx
        .IF eax & 80000000h
            mov eax, 1
            ret
        .ENDIF
        inc ebx
    .ENDW
    ; first symbol slot for each length
    mov word ptr offs[2], 0
    mov ebx, 1
    .WHILE ebx < 15
        mov ecx, pCnt
        mov ax, word ptr [ecx + ebx * 2]
        add ax, word ptr offs[ebx * 2]
        mov word ptr offs[ebx * 2 + 2], ax
        inc ebx
    .ENDW
    xor ebx, ebx
    .WHILE ebx < n
        mov esi, pLens
        movzx eax, byte ptr [esi + ebx]
        .IF eax != 0
            movzx ecx, word ptr offs[eax * 2]
            mov edx, pSym
            mov word ptr [edx + ecx * 2], bx
            inc word ptr offs[eax * 2]
        .ENDIF
        inc ebx
    .ENDW
    .IF pLut != 0
        ; every 9-bit pattern that begins a short code maps straight to its symbol
        mov edi, pLut
        xor eax, eax
        mov ecx, 512
        rep stosw
        mov firstc, 0
        mov esi, pSym
        mov lenv, 1
        .WHILE lenv <= 9
            mov eax, lenv
            mov ecx, pCnt
            movzx ebx, word ptr [ecx + eax * 2]
            mov k, 0
            .WHILE k != ebx
                mov eax, firstc
                add eax, k
                invoke DfRev, eax, lenv     ; codes read most-significant bit first
                mov ecx, lenv
                shl ecx, 12
                mov edx, ecx
                movzx ecx, word ptr [esi]
                or edx, ecx                 ; packed length | symbol
                mov ecx, eax
                .WHILE ecx < 512
                    push ecx
                    add ecx, ecx
                    mov edi, pLut
                    mov word ptr [edi + ecx], dx
                    pop ecx
                    push eax
                    mov eax, 1
                    push ecx
                    mov ecx, lenv
                    shl eax, cl
                    pop ecx
                    add ecx, eax
                    pop eax
                .ENDW
                add esi, 2
                inc k
            .ENDW
            mov eax, firstc
            add eax, ebx
            shl eax, 1
            mov firstc, eax
            inc lenv
        .ENDW
        ; symbols with longer codes were consumed above in table order; skip them
        ; (esi walked exactly the short-code symbols, which come first)
    .ENDIF
    xor eax, eax
    ret
ZfBuild ENDP

; Slow path: one bit at a time against the canonical counts. The tables under
; 10 bits go through the lookup fast path in ZfDecodeFast; this remains for
; long codes, starved buffers and the code-length code.
ZfDecode PROC USES ebx pCnt:DWORD, pSym:DWORD
    LOCAL cval:DWORD
    LOCAL first:DWORD
    LOCAL idx:DWORD
    mov cval, 0
    mov first, 0
    mov idx, 0
    mov ebx, 1
    .WHILE ebx <= 15
        .IF g_zfBitCnt == 0
            invoke ZfInByte
            mov g_zfBitBuf, eax
            mov g_zfBitCnt, 8
        .ENDIF
        mov eax, g_zfBitBuf
        and eax, 1
        shr g_zfBitBuf, 1
        dec g_zfBitCnt
        or cval, eax
        mov ecx, pCnt
        movzx edx, word ptr [ecx + ebx * 2]
        mov eax, cval
        sub eax, first
        .IF eax < edx
            add eax, idx
            mov ecx, pSym
            movzx eax, word ptr [ecx + eax * 2]
            ret
        .ENDIF
        add idx, edx
        add first, edx
        shl first, 1
        shl cval, 1
        inc ebx
    .ENDW
    mov g_zfErr, 1
    xor eax, eax
    ret
ZfDecode ENDP

; Fast path: nine bits of lookahead resolve most symbols in one table hit.
; Entries pack length in the top nibble and the symbol below; empty entries
; and codes longer than the lookahead fall back to the bit walk above.
ZfDecodeFast PROC USES ebx pCnt:DWORD, pSym:DWORD, pLut:DWORD
    ; top the accumulator up from the buffered input without erroring at EOF
    mov ecx, g_zfBitCnt
    .WHILE ecx < 9
        mov eax, g_zfInPos
        .BREAK .IF eax >= g_zfInLen         ; a starved buffer takes the slow path
        mov edx, g_zfIn
        movzx eax, byte ptr [edx + eax]
        inc g_zfInPos
        shl eax, cl
        or g_zfBitBuf, eax
        add ecx, 8
        mov g_zfBitCnt, ecx
    .ENDW
    mov eax, g_zfBitBuf
    and eax, 511
    mov ecx, pLut
    movzx eax, word ptr [ecx + eax * 2]
    mov ecx, eax
    shr ecx, 12
    .IF eax == 0 || ecx > g_zfBitCnt
        invoke ZfDecode, pCnt, pSym
        ret
    .ENDIF
    shr g_zfBitBuf, cl
    sub g_zfBitCnt, ecx
    and eax, 0FFFh
    ret
ZfDecodeFast ENDP

; ---------------------------------------------------------------------------
; Block types
; ---------------------------------------------------------------------------
; The literal/length/distance loop shared by fixed and dynamic blocks
ZfCodes PROC USES esi edi ebx pLC:DWORD, pLS:DWORD, pDC:DWORD, pDS:DWORD, pLLut:DWORD, pDLut:DWORD
    LOCAL mlen:DWORD
    LOCAL mdist:DWORD
    .WHILE g_zfErr == 0
        invoke ZfDecodeFast, pLC, pLS, pLLut
        .IF eax < 256
            mov ecx, g_zfOutPos
            .IF ecx >= ZF_OUTBUF
                push eax
                invoke ZfOutFlush
                pop eax
                mov ecx, g_zfOutPos
            .ENDIF
            mov edx, g_zfOut
            mov byte ptr [edx + ecx], al
            inc g_zfOutPos
        .ELSEIF eax == 256
            xor eax, eax
            ret
        .ELSE
            sub eax, 257
            .IF eax >= 29
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            mov ebx, eax
            movzx eax, byte ptr g_zfLenExtra[ebx]
            invoke ZfBits, eax
            movzx ecx, word ptr g_zfLenBase[ebx * 2]
            add eax, ecx
            mov mlen, eax
            invoke ZfDecodeFast, pDC, pDS, pDLut
            .IF eax >= 30
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            mov ebx, eax
            movzx eax, byte ptr g_zfDistExtra[ebx]
            invoke ZfBits, eax
            movzx ecx, word ptr g_zfDistBase[ebx * 2]
            add eax, ecx
            mov mdist, eax
            .IF g_zfOutPos >= ZF_OUTBUF     ; room for the longest match (258) is in the slack
                invoke ZfOutFlush
            .ENDIF
            mov eax, mdist
            .IF eax > g_zfOutPos            ; reaches back past the start of the stream
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            mov edi, g_zfOut
            add edi, g_zfOutPos
            mov esi, edi
            sub esi, mdist
            mov ecx, mlen
            rep movsb                       ; forward copy; overlap repeats the pattern as intended
            mov eax, mlen
            add g_zfOutPos, eax
        .ENDIF
    .ENDW
    mov eax, 1
    ret
ZfCodes ENDP

ZfStored PROC USES ebx
    LOCAL lenv:DWORD
    mov eax, g_zfBitCnt
    and eax, 7
    invoke ZfBits, eax                      ; drop to a byte boundary
    invoke ZfBits, 16
    mov lenv, eax
    invoke ZfBits, 16
    mov ecx, lenv
    xor ecx, 0FFFFh
    .IF eax != ecx
        mov g_zfErr, 1
        ret
    .ENDIF
    ; drain whole bytes still in the accumulator, then move the rest in bulk
    mov ebx, lenv
    .WHILE ebx != 0 && g_zfBitCnt >= 8 && g_zfErr == 0
        invoke ZfBits, 8
        invoke ZfPutB, eax
        dec ebx
    .ENDW
    .IF ebx != 0 && g_zfErr == 0
        invoke ZfRawCopy, ebx
    .ENDIF
    ret
ZfStored ENDP

ZfInitFixed PROC USES edi
    .IF g_zfFixInit != 0
        ret
    .ENDIF
    mov edi, offset g_zfLens
    mov al, 8
    mov ecx, 144
    rep stosb
    mov al, 9
    mov ecx, 112
    rep stosb
    mov al, 7
    mov ecx, 24
    rep stosb
    mov al, 8
    mov ecx, 8
    rep stosb
    invoke ZfBuild, offset g_zfFixLC, offset g_zfFixLS, offset g_zfLens, 288, offset g_zfFixLLut
    mov edi, offset g_zfLens
    mov al, 5
    mov ecx, 30
    rep stosb
    invoke ZfBuild, offset g_zfFixDC, offset g_zfFixDS, offset g_zfLens, 30, offset g_zfFixDLut
    mov g_zfFixInit, 1
    ret
ZfInitFixed ENDP

ZfDynamic PROC USES ebx edi
    LOCAL hlit:DWORD
    LOCAL hdist:DWORD
    LOCAL hclen:DWORD
    LOCAL total:DWORD
    LOCAL i:DWORD
    LOCAL fill:DWORD
    invoke ZfBits, 5
    add eax, 257
    mov hlit, eax
    invoke ZfBits, 5
    inc eax
    mov hdist, eax
    invoke ZfBits, 4
    add eax, 4
    mov hclen, eax
    .IF hlit > 286 || hdist > 30
        mov g_zfErr, 1
        ret
    .ENDIF
    ; code lengths for the code-length code, borrowed into the distance tables
    mov edi, offset g_zfLens
    xor eax, eax
    mov ecx, 19
    rep stosb
    mov i, 0
    .WHILE TRUE
        mov eax, i
        .BREAK .IF eax >= hclen
        invoke ZfBits, 3
        mov ecx, i
        movzx edx, byte ptr g_zfClOrder[ecx]
        mov byte ptr g_zfLens[edx], al
        inc i
    .ENDW
    invoke ZfBuild, offset g_zfDC, offset g_zfDS, offset g_zfLens, 19, 0
    .IF eax != 0 || g_zfErr != 0
        mov g_zfErr, 1
        ret
    .ENDIF
    mov eax, hlit
    add eax, hdist
    mov total, eax
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= total
        invoke ZfDecode, offset g_zfDC, offset g_zfDS
        .IF eax < 16
            mov ecx, i
            mov byte ptr g_zfLens[ecx], al
            inc i
        .ELSE
            mov ebx, eax
            mov fill, 0
            .IF ebx == 16
                .IF i == 0
                    mov g_zfErr, 1
                    .BREAK
                .ENDIF
                mov ecx, i
                movzx edx, byte ptr g_zfLens[ecx - 1]
                mov fill, edx
                invoke ZfBits, 2
                add eax, 3
            .ELSEIF ebx == 17
                invoke ZfBits, 3
                add eax, 3
            .ELSE
                invoke ZfBits, 7
                add eax, 11
            .ENDIF
            mov ebx, eax                    ; repeat count
            mov eax, i
            add eax, ebx
            .IF eax > total
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            .WHILE ebx != 0
                mov ecx, i
                mov edx, fill
                mov byte ptr g_zfLens[ecx], dl
                inc i
                dec ebx
            .ENDW
        .ENDIF
    .ENDW
    .IF g_zfErr != 0
        ret
    .ENDIF
    invoke ZfBuild, offset g_zfLC, offset g_zfLS, offset g_zfLens, hlit, offset g_zfLLut
    .IF eax != 0
        mov g_zfErr, 1
        ret
    .ENDIF
    mov eax, offset g_zfLens
    add eax, hlit
    invoke ZfBuild, offset g_zfDC, offset g_zfDS, eax, hdist, offset g_zfDLut
    .IF eax != 0
        mov g_zfErr, 1
        ret
    .ENDIF
    invoke ZfCodes, offset g_zfLC, offset g_zfLS, offset g_zfDC, offset g_zfDS, offset g_zfLLut, offset g_zfDLut
    ret
ZfDynamic ENDP

; One whole deflate stream from the current input position. TRUE on success.
ZfInflate PROC
    LOCAL bfinal:DWORD
    .WHILE g_zfErr == 0
        invoke ZfBits, 1
        mov bfinal, eax
        invoke ZfBits, 2
        .IF eax == 0
            invoke ZfStored
        .ELSEIF eax == 1
            invoke ZfInitFixed
            invoke ZfCodes, offset g_zfFixLC, offset g_zfFixLS, offset g_zfFixDC, offset g_zfFixDS, offset g_zfFixLLut, offset g_zfFixDLut
        .ELSEIF eax == 2
            invoke ZfDynamic
        .ELSE
            mov g_zfErr, 1
        .ENDIF
        .BREAK .IF bfinal != 0
    .ENDW
    xor eax, eax
    .IF g_zfErr == 0
        inc eax
    .ENDIF
    ret
ZfInflate ENDP

; ---------------------------------------------------------------------------
; Expansion session setup / teardown
; ---------------------------------------------------------------------------
ZfExpandInit PROC hIn:DWORD, hOut:DWORD
    mov eax, hIn
    mov g_zfFile, eax
    mov eax, hOut
    mov g_zfHOut, eax
    invoke VfsAlloc, ZF_INBUF
    mov g_zfIn, eax
    invoke VfsAlloc, ZF_OUTALLOC
    mov g_zfOut, eax
    .IF g_zfIn == 0 || g_zfOut == 0
        invoke VfsFreeMem, g_zfIn
        invoke VfsFreeMem, g_zfOut
        mov g_zfIn, 0
        mov g_zfOut, 0
        xor eax, eax
        ret
    .ENDIF
    mov g_zfCrc, 0
    mov g_zfTotLo, 0
    mov g_zfTotHi, 0
    mov g_zfOutPos, 0
    mov g_zfOutStart, 0
    mov g_zfErr, 0
    mov g_zfWrapMode, 0
    invoke ZfSetInput, 0, 0
    mov eax, TRUE
    ret
ZfExpandInit ENDP

ZfExpandFree PROC
    invoke VfsFreeMem, g_zfIn
    invoke VfsFreeMem, g_zfOut
    mov g_zfIn, 0
    mov g_zfOut, 0
    invoke BzFree                           ; the bzip2 block buffer is the largest of the three
    ret
ZfExpandFree ENDP


; Create the destination and prime an expansion session; INVALID_HANDLE_VALUE on failure.
; cbLo:cbHi is the expanded size when the container header states it, so the extent
; can be reserved in one go instead of grown a megabyte at a time; 0 means unknown.
ZfBeginOut PROC pszDst:DWORD, hIn:DWORD, cbLo:DWORD, cbHi:DWORD
    LOCAL h:DWORD
    invoke CreateFileW, pszDst, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov h, eax
    mov eax, cbLo
    or eax, cbHi
    .IF eax != 0
        invoke FilePresize, h, cbLo, cbHi
    .ENDIF
    invoke ZfExpandInit, hIn, h
    .IF eax == 0
        invoke CloseHandle, h
        invoke DeleteFileW, pszDst
        mov eax, INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov eax, h
    ret
ZfBeginOut ENDP

; Common expander tail: close both files, drop the output when the expansion failed
ZfClosePair PROC okv:DWORD, hIn:DWORD, hOut:DWORD, pszDst:DWORD
    invoke CloseHandle, hIn
    .IF hOut != INVALID_HANDLE_VALUE
        invoke CloseHandle, hOut
        .IF okv == 0
            invoke DeleteFileW, pszDst
        .ENDIF
    .ENDIF
    mov eax, okv
    ret
ZfClosePair ENDP

; ---------------------------------------------------------------------------
; gzip (RFC 1952): header, one deflate stream, CRC-32 + size trailer
; ---------------------------------------------------------------------------
GzExpandFile PROC USES ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL flg:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke CreateFileW, pszDst, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        invoke CloseHandle, hIn
        xor eax, eax
        ret
    .ENDIF
    mov hOut, eax
    invoke ZfExpandInit, hIn, hOut
    .IF eax == 0
        jmp done
    .ENDIF
    invoke ZfBits, 8
    .IF eax != 1Fh
        jmp done
    .ENDIF
    invoke ZfBits, 8
    .IF eax != 8Bh
        jmp done
    .ENDIF
    invoke ZfBits, 8
    .IF eax != 8                            ; deflate is the only defined method
        jmp done
    .ENDIF
    invoke ZfBits, 8
    mov flg, eax
    mov ebx, 6                              ; MTIME, XFL, OS
    .WHILE ebx != 0
        invoke ZfBits, 8
        dec ebx
    .ENDW
    .IF flg & 4                             ; FEXTRA
        invoke ZfBits, 8
        mov ebx, eax
        invoke ZfBits, 8
        shl eax, 8
        or ebx, eax
        .WHILE ebx != 0 && g_zfErr == 0
            invoke ZfBits, 8
            dec ebx
        .ENDW
    .ENDIF
    .IF flg & 8                             ; FNAME
        .WHILE g_zfErr == 0
            invoke ZfBits, 8
            .BREAK .IF eax == 0
        .ENDW
    .ENDIF
    .IF flg & 10h                           ; FCOMMENT
        .WHILE g_zfErr == 0
            invoke ZfBits, 8
            .BREAK .IF eax == 0
        .ENDW
    .ENDIF
    .IF flg & 2                             ; FHCRC
        invoke ZfBits, 8
        invoke ZfBits, 8
    .ENDIF
    .IF g_zfErr != 0
        jmp done
    .ENDIF
    invoke ZfInflate
    .IF eax == 0
        jmp done
    .ENDIF
    invoke ZfOutFinal
    mov eax, g_zfBitCnt
    and eax, 7
    invoke ZfBits, eax
    invoke ZfDword
    .IF eax != g_zfCrc
        jmp done
    .ENDIF
    invoke ZfDword
    .IF eax != g_zfTotLo || g_zfErr != 0
        jmp done
    .ENDIF
    mov ok, TRUE
done:
    invoke ZfExpandFree
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
GzExpandFile ENDP

; ---------------------------------------------------------------------------
; zip: find the end-of-central-directory record, expand the largest stored or deflated entry
; ---------------------------------------------------------------------------
ZIP_TAILMAX     equ 65558               ; EOCD plus the longest possible comment
ZIP_CDMAX       equ 16 * 1024 * 1024

ZipExpandFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL sizeLo:DWORD
    LOCAL sizeHi:DWORD
    LOCAL tailCb:DWORD
    LOCAL pTail:DWORD
    LOCAL cdOff:DWORD
    LOCAL cdSize:DWORD
    LOCAL nEnt:DWORD
    LOCAL pCd:DWORD
    LOCAL bestU:DWORD
    LOCAL bestC:DWORD
    LOCAL bestCrc:DWORD
    LOCAL bestLho:DWORD
    LOCAL bestMeth:DWORD
    LOCAL haveBest:DWORD
    LOCAL dataOff:DWORD
    LOCAL lh[32]:BYTE
    LOCAL ok:DWORD

    mov ok, FALSE
    mov haveBest, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileSize64, hIn, addr sizeLo, addr sizeHi
    mov eax, ZIP_TAILMAX
    .IF sizeHi == 0 && sizeLo < eax
        mov eax, sizeLo
    .ENDIF
    mov tailCb, eax
    .IF eax < 22
        jmp close_in
    .ENDIF
    invoke VfsAlloc, tailCb
    mov pTail, eax
    .IF eax == 0
        jmp close_in
    .ENDIF
    mov eax, sizeLo
    sub eax, tailCb
    mov ecx, sizeHi
    sbb ecx, 0
    invoke FileReadAt, hIn, eax, ecx, pTail, tailCb
    .IF eax != tailCb
        jmp free_tail
    .ENDIF
    ; scan backwards for the PK 05 06 signature
    mov esi, pTail
    mov ebx, tailCb
    sub ebx, 22
    .WHILE TRUE
        .IF dword ptr [esi + ebx] == 06054B50h
            movzx eax, word ptr [esi + ebx + 10]
            mov nEnt, eax
            mov eax, dword ptr [esi + ebx + 12]
            mov cdSize, eax
            mov eax, dword ptr [esi + ebx + 16]
            mov cdOff, eax
            jmp found_eocd
        .ENDIF
        .BREAK .IF ebx == 0
        dec ebx
    .ENDW
    jmp free_tail
found_eocd:
    invoke VfsFreeMem, pTail
    .IF cdOff == 0FFFFFFFFh || cdSize == 0 || cdSize > ZIP_CDMAX
        jmp close_in                        ; zip64 or a hostile record
    .ENDIF
    invoke VfsAlloc, cdSize
    mov pCd, eax
    .IF eax == 0
        jmp close_in
    .ENDIF
    invoke FileReadAt, hIn, cdOff, 0, pCd, cdSize
    .IF eax != cdSize
        jmp free_cd
    .ENDIF
    ; walk the central directory, keep the largest usable entry
    mov esi, pCd
    mov edi, pCd
    add edi, cdSize
    mov ebx, nEnt
    mov bestU, 0
    .WHILE ebx != 0
        lea eax, [esi + 46]
        .BREAK .IF eax > edi
        .BREAK .IF dword ptr [esi] != 02014B50h
        movzx ecx, word ptr [esi + 10]      ; method
        mov eax, dword ptr [esi + 24]       ; uncompressed size
        .IF (ecx == 0 || ecx == 8) && eax != 0 && eax != 0FFFFFFFFh && eax > bestU
            mov edx, dword ptr [esi + 20]   ; compressed size
            .IF edx != 0FFFFFFFFh
                mov bestU, eax
                mov bestC, edx
                mov bestMeth, ecx
                mov eax, dword ptr [esi + 16]
                mov bestCrc, eax
                mov eax, dword ptr [esi + 42]
                mov bestLho, eax
                mov haveBest, TRUE
            .ENDIF
        .ENDIF
        movzx eax, word ptr [esi + 28]      ; name + extra + comment
        movzx ecx, word ptr [esi + 30]
        add eax, ecx
        movzx ecx, word ptr [esi + 32]
        add eax, ecx
        lea esi, [esi + eax + 46]
        dec ebx
    .ENDW
free_cd:
    invoke VfsFreeMem, pCd
    .IF haveBest == FALSE
        jmp close_in
    .ENDIF
    ; the local header carries its own name/extra sizes
    invoke FileReadAt, hIn, bestLho, 0, addr lh, 30
    .IF eax != 30 || dword ptr lh[0] != 04034B50h
        jmp close_in
    .ENDIF
    movzx eax, word ptr lh[26]
    movzx ecx, word ptr lh[28]
    add eax, ecx
    add eax, bestLho
    add eax, 30
    mov dataOff, eax
    invoke ZfBeginOut, pszDst, hIn, bestU, 0
    .IF eax == INVALID_HANDLE_VALUE
        jmp close_in
    .ENDIF
    mov hOut, eax
    invoke ZfSetInput, dataOff, 0
    .IF bestMeth == 8
        invoke ZfInflate
    .ELSE
        invoke ZfRawCopy, bestC
    .ENDIF
    invoke ZfOutFinal
    mov eax, g_zfCrc
    .IF g_zfErr == 0 && eax == bestCrc && g_zfTotHi == 0
        mov eax, g_zfTotLo
        .IF eax == bestU
            mov ok, TRUE
        .ENDIF
    .ENDIF
    invoke ZfExpandFree
close_in:
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
free_tail:
    invoke VfsFreeMem, pTail
    jmp close_in
ZipExpandFile ENDP

; ---------------------------------------------------------------------------
; CSO / CISO v1 (PSP and Dreamcast tooling): 24-byte header, dword index, one raw
; deflate stream per block; index bit 31 marks a block stored as-is
; ---------------------------------------------------------------------------
CSO_IDXMAX      equ 64 * 1024 * 1024

CsoExpandFile PROC USES esi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[24]:BYTE
    LOCAL blkSize:DWORD
    LOCAL alignSh:DWORD
    LOCAL shiftv:DWORD
    LOCAL totLo:DWORD
    LOCAL totHi:DWORD
    LOCAL nBlk:DWORD
    LOCAL pIdx:DWORD
    LOCAL idxCb:DWORD
    LOCAL i:DWORD
    LOCAL remLo:DWORD
    LOCAL remHi:DWORD
    LOCAL thisCb:DWORD
    LOCAL e0:DWORD
    LOCAL csize:DWORD
    LOCAL isZso:DWORD
    LOCAL isV2:DWORD
    LOCAL offLo:DWORD
    LOCAL offHi:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pIdx, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileReadAt, hIn, 0, 0, addr hdr, 24
    .IF eax != 24
        jmp done
    .ENDIF
    mov isZso, 0
    mov isV2, 0
    mov eax, dword ptr hdr[0]
    .IF eax == 4F53495Ah                    ; "ZISO": LZ4 blocks
        mov isZso, 1
    .ELSEIF eax != 4F534943h                ; "CISO"
        jmp done
    .ENDIF
    movzx eax, byte ptr hdr[20]
    .IF eax == 2 && isZso == 0              ; CISO v2 mixes deflate and LZ4 per block
        mov isV2, 1
    .ELSEIF eax > 1
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[16]
    mov blkSize, eax
    .IF eax < 512 || eax > 1024 * 1024
        jmp done
    .ENDIF
    .IF (isZso != 0 || isV2 != 0) && eax > 32768
        jmp done                            ; LZ4 back references must stay inside the kept window
    .ENDIF
    lea ecx, [eax - 1]
    test eax, ecx
    jnz done                                ; block size must be a power of two
    bsf ecx, eax
    mov shiftv, ecx
    movzx eax, byte ptr hdr[21]
    mov alignSh, eax
    .IF eax > 15
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[8]
    mov totLo, eax
    mov remLo, eax
    mov eax, dword ptr hdr[12]
    mov totHi, eax
    mov remHi, eax
    ; blocks = ceil(total / block size)
    mov eax, totLo
    mov edx, totHi
    add eax, blkSize
    adc edx, 0
    sub eax, 1
    sbb edx, 0
    mov ecx, shiftv
    shrd eax, edx, cl
    shr edx, cl
    .IF edx != 0 || eax == 0
        jmp done
    .ENDIF
    mov nBlk, eax
    inc eax
    shl eax, 2
    mov idxCb, eax
    .IF eax > CSO_IDXMAX
        jmp done
    .ENDIF
    invoke VfsAlloc, idxCb
    mov pIdx, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke FileReadAt, hIn, 24, 0, pIdx, idxCb
    .IF eax != idxCb
        jmp done
    .ENDIF
    invoke ZfBeginOut, pszDst, hIn, totLo, totHi
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        mov ecx, pIdx
        mov edx, dword ptr [ecx + eax * 4 + 4]
        and edx, 7FFFFFFFh
        mov eax, dword ptr [ecx + eax * 4]
        mov e0, eax
        and eax, 7FFFFFFFh
        sub edx, eax
        mov ecx, alignSh
        shl edx, cl
        mov csize, edx                      ; compressed span, from the next index entry
        .IF ecx == 0
            mov offLo, eax
            mov offHi, 0
        .ELSE
            mov edx, eax
            shl eax, cl
            mov offLo, eax
            mov eax, edx
            mov edx, ecx
            mov ecx, 32
            sub ecx, edx
            shr eax, cl
            mov offHi, eax
        .ENDIF
        mov eax, blkSize
        .IF remHi == 0 && eax > remLo
            mov eax, remLo
        .ENDIF
        mov thisCb, eax
        invoke ZfSetInput, offLo, offHi
        .IF isV2 != 0
            ; v2: a full-size span is stored; the top bit picks LZ4 over deflate
            mov eax, csize
            .IF eax >= blkSize
                invoke ZfRawCopy, thisCb
            .ELSE
                mov eax, e0
                .IF eax & 80000000h
                    invoke Lz4Block, csize
                .ELSE
                    invoke ZfSmartInflate
                .ENDIF
            .ENDIF
        .ELSEIF isZso != 0
            mov eax, e0
            .IF eax & 80000000h
                invoke ZfRawCopy, thisCb
            .ELSE
                invoke Lz4Block, csize
            .ENDIF
        .ELSE
            mov eax, e0
            .IF eax & 80000000h
                invoke ZfRawCopy, thisCb
            .ELSE
                invoke ZfSmartInflate
            .ENDIF
        .ENDIF
        mov eax, thisCb
        sub remLo, eax
        sbb remHi, 0
        inc i
    .ENDW
    invoke ZfOutFinal
    ; success when everything the header promised came out
    invoke ZfCheckTotal, totLo, totHi
    mov ok, eax
    invoke ZfExpandFree
done:
    invoke VfsFreeMem, pIdx
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
CsoExpandFile ENDP

; ---------------------------------------------------------------------------
; Compressor: greedy LZ77 over a hash chain, fixed-Huffman blocks, gzip framing.
; Each 1 MB chunk becomes one block with its own window, so the tables reset cheaply.
; Runs on the worker thread: feeds the progress counters and honours Cancel.
; ---------------------------------------------------------------------------
DF_CHUNK        equ 1024 * 1024
DF_OUTBUF       equ 1024 * 1024
DF_HASHSZ       equ 32768
DF_MAXDIST      equ 32768
DF_MAXMATCH     equ 258
DF_DEPTH        equ 128                 ; chain probes per position

.data
g_dfInit        dd 0
g_dfBitBuf      dd 0
g_dfBitCnt      dd 0
g_dfHOut        dd 0
g_dfErr         dd 0
g_dfOut         dd 0
g_dfOutPos      dd 0
g_dfChunkPtr    dd 0
g_dfChunkLen    dd 0
g_dfHead        dd 0                    ; hash -> position + 1, 0 when empty
g_dfPrev        dd 0                    ; position -> previous position + 1 on the same chain
g_dfMDist       dd 0                    ; distance of the match DfLongestMatch found

.data?
g_dfLitCode     dw 288 dup(?)           ; fixed literal/length codes, bit-reversed for LSB-first emit
g_dfLitBits     db 288 dup(?)
g_dfDistCode    dw 30 dup(?)

.code

; code with its nbits low bits reversed
DfRev PROC cval:DWORD, nbits:DWORD
    xor eax, eax
    mov ecx, nbits
    mov edx, cval
    .WHILE ecx != 0
        shr edx, 1
        rcl eax, 1
        dec ecx
    .ENDW
    ret
DfRev ENDP

DfInitTables PROC USES ebx
    LOCAL sym:DWORD
    .IF g_dfInit != 0
        ret
    .ENDIF
    mov sym, 0
    .WHILE sym < 288
        mov eax, sym
        .IF eax < 144
            add eax, 30h
            mov ebx, 8
        .ELSEIF eax < 256
            add eax, 190h - 144
            mov ebx, 9
        .ELSEIF eax < 280
            sub eax, 256
            mov ebx, 7
        .ELSE
            add eax, 0C0h - 280
            mov ebx, 8
        .ENDIF
        invoke DfRev, eax, ebx
        mov ecx, sym
        mov word ptr g_dfLitCode[ecx * 2], ax
        mov byte ptr g_dfLitBits[ecx], bl
        inc sym
    .ENDW
    mov sym, 0
    .WHILE sym < 30
        invoke DfRev, sym, 5
        mov ecx, sym
        mov word ptr g_dfDistCode[ecx * 2], ax
        inc sym
    .ENDW
    mov g_dfInit, 1
    ret
DfInitTables ENDP

DfWriteRaw PROC USES esi ebx pData:DWORD, cb:DWORD
    LOCAL written:DWORD
    mov esi, pData
    mov ebx, cb
    .WHILE ebx != 0
        .IF g_jobCancel != 0
            mov g_dfErr, 1
            ret
        .ENDIF
        invoke WriteFile, g_dfHOut, esi, ebx, addr written, NULL
        .IF eax == 0 || written == 0
            mov g_dfErr, 1
            ret
        .ENDIF
        add esi, written
        sub ebx, written
    .ENDW
    ret
DfWriteRaw ENDP

DfFlushOut PROC
    .IF g_dfOutPos != 0
        invoke DfWriteRaw, g_dfOut, g_dfOutPos
        mov g_dfOutPos, 0
    .ENDIF
    ret
DfFlushOut ENDP

; append nbits (0-16) of cval, LSB first
DfEmit PROC cval:DWORD, nbits:DWORD
    mov ecx, g_dfBitCnt
    mov eax, cval
    shl eax, cl
    or g_dfBitBuf, eax
    mov eax, nbits
    add g_dfBitCnt, eax
    .WHILE g_dfBitCnt >= 8
        mov eax, g_dfOutPos
        .IF eax >= DF_OUTBUF - 8
            invoke DfFlushOut
            mov eax, g_dfOutPos
        .ENDIF
        mov ecx, g_dfOut
        mov edx, g_dfBitBuf
        mov byte ptr [ecx + eax], dl
        inc g_dfOutPos
        shr g_dfBitBuf, 8
        sub g_dfBitCnt, 8
    .ENDW
    ret
DfEmit ENDP

DfPutLit PROC sym:DWORD
    mov ecx, sym
    movzx eax, word ptr g_dfLitCode[ecx * 2]
    movzx edx, byte ptr g_dfLitBits[ecx]
    invoke DfEmit, eax, edx
    ret
DfPutLit ENDP

DfPutMatch PROC USES ebx mlen:DWORD, mdist:DWORD
    ; length symbol: highest base not above the length
    mov ebx, 28
    .WHILE TRUE
        movzx eax, word ptr g_zfLenBase[ebx * 2]
        .BREAK .IF eax <= mlen
        dec ebx
    .ENDW
    mov eax, ebx
    add eax, 257
    invoke DfPutLit, eax
    movzx eax, byte ptr g_zfLenExtra[ebx]
    .IF eax != 0
        movzx ecx, word ptr g_zfLenBase[ebx * 2]
        mov edx, mlen
        sub edx, ecx
        invoke DfEmit, edx, eax
    .ENDIF
    ; distance symbol
    mov ebx, 29
    .WHILE TRUE
        movzx eax, word ptr g_zfDistBase[ebx * 2]
        .BREAK .IF eax <= mdist
        dec ebx
    .ENDW
    movzx eax, word ptr g_dfDistCode[ebx * 2]
    invoke DfEmit, eax, 5
    movzx eax, byte ptr g_zfDistExtra[ebx]
    .IF eax != 0
        movzx ecx, word ptr g_zfDistBase[ebx * 2]
        mov edx, mdist
        sub edx, ecx
        invoke DfEmit, edx, eax
    .ENDIF
    ret
DfPutMatch ENDP

; Longest match against a known chain head; length in eax, distance in g_dfMDist
DfMatchAt PROC USES esi edi ebx pos:DWORD, cand:DWORD
    LOCAL best:DWORD
    LOCAL maxLen:DWORD
    LOCAL depth:DWORD
    mov best, 0
    mov g_dfMDist, 0
    mov eax, g_dfChunkLen
    sub eax, pos
    .IF eax > DF_MAXMATCH
        mov eax, DF_MAXMATCH
    .ENDIF
    mov maxLen, eax
    mov depth, DF_DEPTH
    .WHILE cand != 0 && depth != 0
        mov ebx, cand
        dec ebx
        mov eax, pos
        sub eax, ebx
        .BREAK .IF eax > DF_MAXDIST
        mov esi, g_dfChunkPtr
        add esi, ebx
        mov edi, g_dfChunkPtr
        add edi, pos
        xor ecx, ecx
        mov edx, maxLen
        .WHILE ecx < edx
            mov al, byte ptr [esi + ecx]
            .BREAK .IF al != byte ptr [edi + ecx]
            inc ecx
        .ENDW
        .IF ecx > best
            mov best, ecx
            mov eax, pos
            sub eax, ebx
            mov g_dfMDist, eax
            mov eax, maxLen
            .BREAK .IF ecx == eax
        .ENDIF
        mov ecx, g_dfPrev
        mov eax, dword ptr [ecx + ebx * 4]
        mov cand, eax
        dec depth
    .ENDW
    mov eax, best
    ret
DfMatchAt ENDP

; One chunk as one fixed-Huffman block. The per-byte work - hash, chain insert,
; first-byte gate and literal emit - runs inline; procedure calls remain only
; for accepted matches and buffer flushes, which are rare on either extreme.
DfCompressChunk PROC USES esi edi ebx last:DWORD
    LOCAL mlen:DWORD
    LOCAL hashv:DWORD
    LOCAL candv:DWORD
    mov edi, g_dfHead
    xor eax, eax
    mov ecx, DF_HASHSZ
    rep stosd
    mov eax, last
    and eax, 1
    or eax, 2
    invoke DfEmit, eax, 3
    mov esi, g_dfChunkPtr
    xor ebx, ebx                            ; position
    .WHILE g_dfErr == 0
        mov eax, g_dfChunkLen
        .BREAK .IF ebx >= eax
        sub eax, 2
        .IF ebx < eax
            ; hash the three bytes here and fetch the chain head
            movzx eax, byte ptr [esi + ebx]
            shl eax, 10
            movzx ecx, byte ptr [esi + ebx + 1]
            shl ecx, 5
            xor eax, ecx
            movzx ecx, byte ptr [esi + ebx + 2]
            xor eax, ecx
            and eax, DF_HASHSZ - 1
            mov hashv, eax
            mov edi, g_dfHead
            mov edx, dword ptr [edi + eax * 4]
            mov candv, edx
            .IF edx != 0
                ; worth a real search only when the first bytes agree in range
                lea ecx, [edx - 1]
                mov eax, ebx
                sub eax, ecx
                .IF eax <= DF_MAXDIST
                    mov al, byte ptr [esi + ecx]
                    .IF al == byte ptr [esi + ebx]
                        invoke DfMatchAt, ebx, candv
                        mov ecx, g_dfMDist
                        .IF eax > 3 || (eax == 3 && ecx <= 4096)
                            mov mlen, eax
                            invoke DfPutMatch, mlen, g_dfMDist
                            ; insert every covered position, inline
                            mov edx, ebx
                            add edx, mlen
                            mov ecx, g_dfChunkLen
                            sub ecx, 2
                            .WHILE ebx < edx
                                .BREAK .IF ebx >= ecx
                                movzx eax, byte ptr [esi + ebx]
                                shl eax, 10
                                push ecx
                                movzx ecx, byte ptr [esi + ebx + 1]
                                shl ecx, 5
                                xor eax, ecx
                                movzx ecx, byte ptr [esi + ebx + 2]
                                xor eax, ecx
                                and eax, DF_HASHSZ - 1
                                mov edi, g_dfHead
                                mov ecx, dword ptr [edi + eax * 4]
                                lea edi, [ebx + 1]
                                push edx
                                mov edx, g_dfHead
                                mov dword ptr [edx + eax * 4], edi
                                mov edx, g_dfPrev
                                mov dword ptr [edx + ebx * 4], ecx
                                pop edx
                                pop ecx
                                inc ebx
                            .ENDW
                            mov ebx, edx
                            .CONTINUE
                        .ENDIF
                    .ENDIF
                .ENDIF
            .ENDIF
            ; no match: link this position into its chain
            mov eax, hashv
            mov edi, g_dfHead
            mov ecx, candv
            lea edx, [ebx + 1]
            mov dword ptr [edi + eax * 4], edx
            mov edx, g_dfPrev
            mov dword ptr [edx + ebx * 4], ecx
        .ENDIF
        ; literal, emitted inline: code into the accumulator, bytes drained as they fill
        movzx eax, byte ptr [esi + ebx]
        mov ecx, g_dfBitCnt
        movzx edx, word ptr g_dfLitCode[eax * 2]
        shl edx, cl
        or g_dfBitBuf, edx
        movzx edx, byte ptr g_dfLitBits[eax]
        add ecx, edx
        mov g_dfBitCnt, ecx
        .WHILE g_dfBitCnt >= 8
            mov eax, g_dfOutPos
            .IF eax >= DF_OUTBUF - 8
                invoke DfFlushOut
                mov eax, g_dfOutPos
            .ENDIF
            mov ecx, g_dfOut
            mov edx, g_dfBitBuf
            mov byte ptr [ecx + eax], dl
            inc g_dfOutPos
            shr g_dfBitBuf, 8
            sub g_dfBitCnt, 8
        .ENDW
        inc ebx
    .ENDW
    invoke DfPutLit, 256                    ; end of block
    ret
DfCompressChunk ENDP

; gzip pszSrc into pszDst. Worker-thread aware: progress totals and Cancel.
GzCompressFile PROC USES ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL sizeLo:DWORD
    LOCAL sizeHi:DWORD
    LOCAL offLo:DWORD
    LOCAL offHi:DWORD
    LOCAL nRead:DWORD
    LOCAL crc:DWORD
    LOCAL last:DWORD
    LOCAL tail[10]:BYTE
    LOCAL ok:DWORD

    mov ok, FALSE
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke CreateFileW, pszDst, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        invoke CloseHandle, hIn
        xor eax, eax
        ret
    .ENDIF
    mov hOut, eax
    invoke DfInitTables
    invoke VfsAlloc, DF_CHUNK
    mov g_dfChunkPtr, eax
    invoke VfsAlloc, DF_OUTBUF
    mov g_dfOut, eax
    invoke VfsAlloc, DF_HASHSZ * 4
    mov g_dfHead, eax
    invoke VfsAlloc, DF_CHUNK * 4
    mov g_dfPrev, eax
    .IF g_dfChunkPtr == 0 || g_dfOut == 0 || g_dfHead == 0 || g_dfPrev == 0
        jmp cleanup
    .ENDIF
    mov eax, hOut
    mov g_dfHOut, eax
    mov g_dfErr, 0
    mov g_dfBitBuf, 0
    mov g_dfBitCnt, 0
    mov g_dfOutPos, 0
    invoke FileSize64, hIn, addr sizeLo, addr sizeHi
    mov eax, sizeLo
    mov g_progTotal, eax
    mov eax, sizeHi
    mov g_progTotalHi, eax
    mov g_progDone, 0
    mov g_progDoneHi, 0
    ; 10-byte gzip header: magic, deflate, no flags, no mtime, unknown OS
    mov dword ptr tail[0], 00088B1Fh
    mov dword ptr tail[4], 0
    mov byte ptr tail[8], 0
    mov byte ptr tail[9], 0FFh
    lea eax, tail
    invoke DfWriteRaw, eax, 10
    mov crc, 0
    mov offLo, 0
    mov offHi, 0
    .IF sizeLo == 0 && sizeHi == 0
        invoke DfEmit, 3, 3                 ; final empty block for an empty file
        invoke DfPutLit, 256
    .ENDIF
    .WHILE g_dfErr == 0
        mov eax, sizeLo
        or eax, sizeHi
        .BREAK .IF eax == 0                 ; empty file, handled above
        invoke FileReadAt, hIn, offLo, offHi, g_dfChunkPtr, DF_CHUNK
        mov nRead, eax
        .IF eax == 0
            mov g_dfErr, 1
            .BREAK
        .ENDIF
        mov g_dfChunkLen, eax
        add offLo, eax
        adc offHi, 0
        invoke RtlComputeCrc32, crc, g_dfChunkPtr, nRead
        mov crc, eax
        mov last, 0
        mov eax, offLo
        mov ecx, offHi
        .IF eax == sizeLo && ecx == sizeHi
            mov last, 1
        .ENDIF
        invoke DfCompressChunk, last
        mov eax, nRead
        add g_progDone, eax
        adc g_progDoneHi, 0
        .IF g_jobCancel != 0
            mov g_dfErr, 1
        .ENDIF
        .BREAK .IF last != 0
    .ENDW
    .IF g_dfErr != 0
        jmp cleanup
    .ENDIF
    ; pad the last bits out, then CRC-32 and size mod 2^32
    .IF g_dfBitCnt != 0
        invoke DfEmit, 0, 7
        mov g_dfBitCnt, 0
        mov g_dfBitBuf, 0
    .ENDIF
    invoke DfFlushOut
    mov eax, crc
    mov dword ptr tail[0], eax
    mov eax, sizeLo
    mov dword ptr tail[4], eax
    lea eax, tail
    invoke DfWriteRaw, eax, 8
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
cleanup:
    invoke VfsFreeMem, g_dfChunkPtr
    invoke VfsFreeMem, g_dfOut
    invoke VfsFreeMem, g_dfHead
    invoke VfsFreeMem, g_dfPrev
    mov g_dfChunkPtr, 0
    mov g_dfOut, 0
    mov g_dfHead, 0
    mov g_dfPrev, 0
    invoke CloseHandle, hIn
    invoke CloseHandle, hOut
    .IF ok == 0
        invoke DeleteFileW, pszDst
    .ENDIF
    mov eax, ok
    ret
GzCompressFile ENDP

; ---------------------------------------------------------------------------
; zlib wrapper (RFC 1950): 2-byte header, deflate stream, Adler-32 (not verified)
; ---------------------------------------------------------------------------
ZfZlibInflate PROC
    invoke ZfBits, 8                        ; CMF: low nibble must be deflate
    mov ecx, eax
    and ecx, 0Fh
    .IF ecx != 8
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    invoke ZfBits, 8                        ; FLG: no preset dictionary
    .IF eax & 20h
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    invoke ZfInflate
    ret
ZfZlibInflate ENDP

; Deflate stream that may or may not carry a zlib wrapper (writers differ). The
; first compressed block of a file decides, and every later block follows suit -
; a per-block sniff would eventually mistake raw data for a zlib header.
ZfSmartInflate PROC USES ebx
    LOCAL b1:DWORD
    invoke ZfBits, 8
    mov ebx, eax
    invoke ZfBits, 8
    mov b1, eax
    .IF g_zfWrapMode == 2                   ; known zlib: the two bytes were the header
        invoke ZfInflate
        ret
    .ENDIF
    .IF g_zfWrapMode == 0
        mov ecx, ebx
        shl ecx, 8
        or ecx, b1                          ; CMF*256 + FLG
        mov edx, ebx
        and edx, 0Fh
        .IF edx == 8 && ebx < 80h
            push ecx
            xor edx, edx
            mov eax, ecx
            mov ecx, 31
            div ecx
            pop ecx
            .IF edx == 0                    ; valid zlib check bits
                .IF ecx & 20h               ; FDICT (bit 5 of FLG) unsupported
                    mov g_zfErr, 1
                    xor eax, eax
                    ret
                .ENDIF
                mov g_zfWrapMode, 2
                invoke ZfInflate
                ret
            .ENDIF
        .ENDIF
        mov g_zfWrapMode, 1
    .ENDIF
    mov eax, b1                             ; raw: replay both bytes, LSB first
    shl eax, 8
    or eax, ebx
    mov g_zfBitBuf, eax
    mov g_zfBitCnt, 16
    invoke ZfInflate
    ret
ZfSmartInflate ENDP

; cb zero bytes to the output
ZfPutZeros PROC USES edi ebx cb:DWORD
    mov ebx, cb
    .WHILE ebx != 0 && g_zfErr == 0
        .IF g_zfOutPos >= ZF_OUTBUF
            invoke ZfOutFlush
        .ENDIF
        mov eax, ZF_OUTBUF
        sub eax, g_zfOutPos
        .IF eax > ebx
            mov eax, ebx
        .ENDIF
        mov edi, g_zfOut
        add edi, g_zfOutPos
        mov ecx, eax
        push eax
        xor eax, eax
        rep stosb
        pop eax
        add g_zfOutPos, eax
        sub ebx, eax
    .ENDW
    ret
ZfPutZeros ENDP

; ---------------------------------------------------------------------------
; LZ4 raw block (as ZSO / CISO v2 store them): token, literals, then matches of
; up to 65535 back. Blocks stay far below the 32 KB retained window, so back
; references always land inside the output buffer.
; ---------------------------------------------------------------------------
Lz4Block PROC USES esi edi ebx inLen:DWORD
    LOCAL consumed:DWORD
    LOCAL tok:DWORD
    LOCAL litLen:DWORD
    LOCAL mLen:DWORD
    LOCAL dist:DWORD
    mov consumed, 0
    .WHILE g_zfErr == 0
        invoke ZfInByte
        inc consumed
        mov tok, eax
        shr eax, 4
        mov litLen, eax
        .IF eax == 15
            .WHILE g_zfErr == 0
                invoke ZfInByte
                inc consumed
                add litLen, eax
                .BREAK .IF eax != 255
            .ENDW
        .ENDIF
        mov eax, litLen
        add consumed, eax
        .WHILE litLen != 0 && g_zfErr == 0
            invoke ZfInByte
            invoke ZfPutB, eax
            dec litLen
        .ENDW
        mov eax, consumed
        .BREAK .IF eax >= inLen             ; the last sequence ends after its literals
        invoke ZfInByte
        mov ebx, eax
        invoke ZfInByte
        shl eax, 8
        or ebx, eax
        add consumed, 2
        .IF ebx == 0
            mov g_zfErr, 1
            .BREAK
        .ENDIF
        mov dist, ebx
        mov eax, tok
        and eax, 15
        add eax, 4
        mov mLen, eax
        .IF eax == 19                       ; 15 + 4: extension bytes follow
            .WHILE g_zfErr == 0
                invoke ZfInByte
                inc consumed
                add mLen, eax
                .BREAK .IF eax != 255
            .ENDW
        .ENDIF
        .WHILE mLen != 0 && g_zfErr == 0
            .IF g_zfOutPos >= ZF_OUTBUF
                invoke ZfOutFlush
            .ENDIF
            mov eax, dist
            .IF eax > g_zfOutPos
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            mov ecx, mLen
            .IF ecx > 512
                mov ecx, 512
            .ENDIF
            sub mLen, ecx
            mov edi, g_zfOut
            add edi, g_zfOutPos
            mov esi, edi
            sub esi, dist
            add g_zfOutPos, ecx
            rep movsb                       ; forward copy repeats the pattern for short distances
        .ENDW
    .ENDW
    ret
Lz4Block ENDP

; ---------------------------------------------------------------------------
; LZO1X block (JISO method 0). Opcode ranges per the kernel's lzo.rst: literal
; runs and matches carry a 2-bit state of trailing literals that disambiguates
; the 0..15 opcodes; the stream ends on the 16..31 opcode with distance 16384.
; ---------------------------------------------------------------------------
.data
g_lzoUsed       dd 0                    ; input bytes consumed by the current LZO block

.code

; base plus the 255-run extension encoding, counting consumed bytes
LzoExt PROC base:DWORD
    mov eax, base
    .WHILE g_zfErr == 0
        push eax
        invoke ZfInByte
        inc g_lzoUsed
        mov ecx, eax
        pop eax
        .IF ecx == 0
            add eax, 255
        .ELSE
            add eax, ecx
            .BREAK
        .ENDIF
    .ENDW
    ret
LzoExt ENDP

LzoBlock PROC USES esi edi ebx inLen:DWORD
        LOCAL lstate:DWORD
    LOCAL tv:DWORD
    LOCAL mlen:DWORD
    LOCAL dist:DWORD
    LOCAL haveOp:DWORD
    mov g_lzoUsed, 0
    mov lstate, 0
    mov haveOp, 0
    invoke ZfInByte
    inc g_lzoUsed
    .IF eax > 17
        sub eax, 17
        mov ebx, eax                        ; leading literal run
        .IF eax < 4
            mov lstate, eax
        .ELSE
            mov lstate, 4
        .ENDIF
        add g_lzoUsed, ebx
        .WHILE ebx != 0 && g_zfErr == 0
            invoke ZfInByte
            invoke ZfPutB, eax
            dec ebx
        .ENDW
    .ELSEIF eax == 17
        mov g_zfErr, 1                      ; version-1 bitstream marker
        ret
    .ELSE
        mov tv, eax
        mov haveOp, 1
    .ENDIF
    .WHILE g_zfErr == 0
        mov eax, g_lzoUsed
        .IF eax > inLen
            mov g_zfErr, 1                  ; ran past the block with no end marker
            .BREAK
        .ENDIF
        .IF haveOp == 0
            invoke ZfInByte
            inc g_lzoUsed
            mov tv, eax
        .ENDIF
        mov haveOp, 0
        mov eax, tv
        .IF eax >= 128
            ; 1 L L D D D S S: 5-8 bytes from up to 2 kB back
            mov ecx, eax
            shr ecx, 5
            and ecx, 3
            add ecx, 5
            mov mlen, ecx
            mov ecx, eax
            shr ecx, 2
            and ecx, 7
            mov ebx, ecx
            invoke ZfInByte
            inc g_lzoUsed
            shl eax, 3
            add eax, ebx
            inc eax
            mov dist, eax
        .ELSEIF eax >= 64
            ; 0 1 L D D D S S: 3-4 bytes from up to 2 kB back
            mov ecx, eax
            shr ecx, 5
            and ecx, 1
            add ecx, 3
            mov mlen, ecx
            mov ecx, eax
            shr ecx, 2
            and ecx, 7
            mov ebx, ecx
            invoke ZfInByte
            inc g_lzoUsed
            shl eax, 3
            add eax, ebx
            inc eax
            mov dist, eax
        .ELSEIF eax >= 32
            ; 0 0 1 L L L L L: within 16 kB, LE16 distance+state
            and eax, 31
            .IF eax == 0
                invoke LzoExt, 31
            .ENDIF
            add eax, 2
            mov mlen, eax
            invoke ZfInByte
            inc g_lzoUsed
            mov ebx, eax
            invoke ZfInByte
            inc g_lzoUsed
            shl eax, 8
            or ebx, eax                     ; LE16: D D D D D D D D | D D D D D D S S
            mov eax, ebx
            and eax, 3
            mov lstate, eax
            mov eax, ebx
            shr eax, 2
            inc eax
            mov dist, eax
        .ELSEIF eax >= 16
            ; 0 0 0 1 H L L L: 16..48 kB back, or the end marker
            mov ebx, eax
            and eax, 7
            .IF eax == 0
                invoke LzoExt, 7
            .ENDIF
            add eax, 2
            mov mlen, eax
            mov eax, ebx
            and eax, 8
            shl eax, 11                     ; H << 14
            mov ebx, eax
            invoke ZfInByte
            inc g_lzoUsed
            push eax
            invoke ZfInByte
            inc g_lzoUsed
            mov ecx, eax
            pop eax
            shl ecx, 8
            or eax, ecx
            mov ecx, eax
            and ecx, 3
            mov lstate, ecx
            shr eax, 2
            add eax, ebx
            add eax, 16384
            mov dist, eax
            .IF eax == 16384
                xor eax, eax                ; end of stream
                ret
            .ENDIF
        .ELSE
            ; 0..15: meaning depends on the pending state
            .IF lstate == 0
                ; long literal run
                .IF eax == 0
                    invoke LzoExt, 15
                .ENDIF
                add eax, 3
                mov ebx, eax
                add g_lzoUsed, eax
                .WHILE ebx != 0 && g_zfErr == 0
                    invoke ZfInByte
                    invoke ZfPutB, eax
                    dec ebx
                .ENDW
                mov lstate, 4
                .CONTINUE
            .ELSEIF lstate == 4
                ; 3 bytes from 2..3 kB back
                mov mlen, 3
                mov ecx, eax
                shr ecx, 2
                and ecx, 3
                mov ebx, ecx
                mov ecx, eax
                and ecx, 3
                mov lstate, ecx
                invoke ZfInByte
                inc g_lzoUsed
                shl eax, 2
                add eax, ebx
                add eax, 2049
                mov dist, eax
            .ELSE
                ; 2 bytes from up to 1 kB back
                mov mlen, 2
                mov ecx, eax
                shr ecx, 2
                and ecx, 3
                mov ebx, ecx
                mov ecx, eax
                and ecx, 3
                mov lstate, ecx
                invoke ZfInByte
                inc g_lzoUsed
                shl eax, 2
                add eax, ebx
                inc eax
                mov dist, eax
            .ENDIF
        .ENDIF
        ; every path reaching here (the literal run used .CONTINUE) has a match to copy
        .WHILE mlen != 0 && g_zfErr == 0
            .IF g_zfOutPos >= ZF_OUTBUF
                invoke ZfOutFlush
            .ENDIF
            mov eax, dist
            .IF eax > g_zfOutPos
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            mov ecx, mlen
            .IF ecx > 512
                mov ecx, 512
            .ENDIF
            sub mlen, ecx
            mov edi, g_zfOut
            add edi, g_zfOutPos
            mov esi, edi
            sub esi, dist
            add g_zfOutPos, ecx
            rep movsb
        .ENDW
        ; trailing literals for the next opcode
        mov ebx, lstate
        add g_lzoUsed, ebx
        .WHILE ebx != 0 && g_zfErr == 0
            invoke ZfInByte
            invoke ZfPutB, eax
            dec ebx
        .ENDW
    .ENDW
    ret
LzoBlock ENDP

; ---------------------------------------------------------------------------
; GCZ (Dolphin): 32-byte header, 64-bit block pointers (bit 63 = stored raw),
; Adler hashes (skipped), one zlib stream per block
; ---------------------------------------------------------------------------
GCZ_IDXMAX      equ 64 * 1024 * 1024

GczExpandFile PROC USES esi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[32]:BYTE
    LOCAL blkSize:DWORD
    LOCAL nBlk:DWORD
    LOCAL compLo:DWORD
    LOCAL compHi:DWORD
    LOCAL totLo:DWORD
    LOCAL totHi:DWORD
    LOCAL pIdx:DWORD
    LOCAL idxCb:DWORD
    LOCAL dataStart:DWORD
    LOCAL i:DWORD
    LOCAL remLo:DWORD
    LOCAL remHi:DWORD
    LOCAL thisCb:DWORD
    LOCAL pLo:DWORD
    LOCAL pHi:DWORD
    LOCAL offLo:DWORD
    LOCAL offHi:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pIdx, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileReadAt, hIn, 0, 0, addr hdr, 32
    .IF eax != 32 || dword ptr hdr[0] != 0B10BC001h
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[8]
    mov compLo, eax
    mov eax, dword ptr hdr[12]
    mov compHi, eax
    mov eax, dword ptr hdr[16]
    mov totLo, eax
    mov remLo, eax
    mov eax, dword ptr hdr[20]
    mov totHi, eax
    mov remHi, eax
    mov eax, dword ptr hdr[24]
    mov blkSize, eax
    .IF eax < 512 || eax > 4 * 1024 * 1024
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[28]
    mov nBlk, eax
    .IF eax == 0
        jmp done
    .ENDIF
    ; pointers (8 bytes each) then hashes (4 each, skipped); data follows both
    mov ecx, eax
    shl ecx, 3
    mov idxCb, ecx
    .IF ecx > GCZ_IDXMAX
        jmp done
    .ENDIF
    lea edx, [eax + eax * 2]
    shl edx, 2                              ; blocks * 12
    add edx, 32
    mov dataStart, edx
    invoke VfsAlloc, idxCb
    mov pIdx, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke FileReadAt, hIn, 32, 0, pIdx, idxCb
    .IF eax != idxCb
        jmp done
    .ENDIF
    invoke ZfBeginOut, pszDst, hIn, totLo, totHi
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        mov esi, pIdx
        mov ecx, eax
        shl ecx, 3
        add esi, ecx
        mov eax, dword ptr [esi]
        mov pLo, eax
        mov eax, dword ptr [esi + 4]
        mov pHi, eax
        and eax, 7FFFFFFFh
        mov ecx, pLo
        add ecx, dataStart
        adc eax, 0
        mov offLo, ecx
        mov offHi, eax
        mov eax, blkSize
        .IF remHi == 0 && eax > remLo
            mov eax, remLo
        .ENDIF
        mov thisCb, eax
        invoke ZfSetInput, offLo, offHi
        mov eax, pHi
        .IF eax & 80000000h                 ; stored block
            invoke ZfRawCopy, thisCb
        .ELSE
            invoke ZfZlibInflate
        .ENDIF
        mov eax, thisCb
        sub remLo, eax
        sbb remHi, 0
        inc i
    .ENDW
    invoke ZfOutFinal
    invoke ZfCheckTotal, totLo, totHi
    mov ok, eax
    invoke ZfExpandFree
done:
    invoke VfsFreeMem, pIdx
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
GczExpandFile ENDP

; ---------------------------------------------------------------------------
; DAX (PSP): 32-byte header, dword frame offsets, word frame sizes, then the
; non-compressed area table; 8 KB frames as zlib streams or raw in NC areas
; ---------------------------------------------------------------------------
DAX_FRAME       equ 2000h
DAX_IDXMAX      equ 32 * 1024 * 1024

DaxExpandFile PROC USES esi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[32]:BYTE
    LOCAL totCb:DWORD
    LOCAL nNc:DWORD
    LOCAL nFrames:DWORD
    LOCAL pOffs:DWORD
    LOCAL pNc:DWORD
    LOCAL cbOffs:DWORD
    LOCAL cbNc:DWORD
    LOCAL i:DWORD
    LOCAL remCb:DWORD
    LOCAL thisCb:DWORD
    LOCAL isRaw:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pOffs, 0
    mov pNc, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileReadAt, hIn, 0, 0, addr hdr, 32
    .IF eax != 32 || dword ptr hdr[0] != 00584144h      ; "DAX\0"
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[4]
    mov totCb, eax
    mov remCb, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[12]
    mov nNc, eax
    .IF eax > 10000h
        jmp done
    .ENDIF
    mov eax, totCb
    add eax, DAX_FRAME - 1
    shr eax, 13
    mov nFrames, eax
    ; frame offsets (4 each) and sizes (2 each) in one read
    lea ecx, [eax + eax * 2]
    shl ecx, 1                              ; frames * 6
    mov cbOffs, ecx
    .IF ecx > DAX_IDXMAX
        jmp done
    .ENDIF
    invoke VfsAlloc, cbOffs
    mov pOffs, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke FileReadAt, hIn, 32, 0, pOffs, cbOffs
    .IF eax != cbOffs
        jmp done
    .ENDIF
    .IF nNc != 0
        mov eax, nNc
        shl eax, 3
        mov cbNc, eax
        invoke VfsAlloc, eax
        mov pNc, eax
        .IF eax == 0
            jmp done
        .ENDIF
        mov eax, cbOffs
        add eax, 32
        invoke FileReadAt, hIn, eax, 0, pNc, cbNc
        .IF eax != cbNc
            jmp done
        .ENDIF
    .ENDIF
    invoke ZfBeginOut, pszDst, hIn, totCb, 0
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nFrames
        ; inside a non-compressed area?
        mov isRaw, 0
        mov esi, pNc
        mov ebx, nNc
        .WHILE ebx != 0 && esi != 0
            mov eax, dword ptr [esi]        ; first frame
            mov ecx, i
            .IF ecx >= eax
                add eax, dword ptr [esi + 4]
                .IF ecx < eax
                    mov isRaw, 1
                    .BREAK
                .ENDIF
            .ENDIF
            add esi, 8
            dec ebx
        .ENDW
        mov eax, DAX_FRAME
        .IF eax > remCb
            mov eax, remCb
        .ENDIF
        mov thisCb, eax
        mov esi, pOffs
        mov eax, i
        mov ecx, dword ptr [esi + eax * 4]  ; absolute file offset of the frame
        invoke ZfSetInput, ecx, 0
        .IF isRaw != 0
            invoke ZfRawCopy, thisCb
        .ELSE
            invoke ZfZlibInflate
        .ENDIF
        mov eax, thisCb
        sub remCb, eax
        inc i
    .ENDW
    invoke ZfOutFinal
    invoke ZfCheckTotal, totCb, 0
    mov ok, eax
    invoke ZfExpandFree
done:
    invoke VfsFreeMem, pOffs
    invoke VfsFreeMem, pNc
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
DaxExpandFile ENDP

; ---------------------------------------------------------------------------
; JSO / JISO (PSP): 48-byte header, CISO-style dword index, optional 4-byte
; per-block headers; deflate blocks (method 1), stored when span == block size.
; Method 0 is LZO, which this build does not carry yet.
; ---------------------------------------------------------------------------
JSO_IDXMAX      equ 32 * 1024 * 1024

JsoExpandFile PROC USES esi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[48]:BYTE
    LOCAL blkSize:DWORD
    LOCAL bhBytes:DWORD
    LOCAL method:DWORD
    LOCAL totCb:DWORD
    LOCAL nBlk:DWORD
    LOCAL pIdx:DWORD
    LOCAL idxCb:DWORD
    LOCAL i:DWORD
    LOCAL remCb:DWORD
    LOCAL thisCb:DWORD
    LOCAL csize:DWORD
    LOCAL dataOff:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pIdx, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileReadAt, hIn, 0, 0, addr hdr, 48
    .IF eax != 48 || dword ptr hdr[0] != 4F53494Ah      ; "JISO"
        jmp done
    .ENDIF
    movzx eax, byte ptr hdr[10]
    mov method, eax                         ; 0 = LZO, 1 = deflate
    .IF eax > 1
        jmp done
    .ENDIF
    movzx eax, word ptr hdr[6]
    mov blkSize, eax
    .IF eax < 512 || eax > 32768
        jmp done
    .ENDIF
    movzx eax, byte ptr hdr[8]
    shl eax, 2
    mov bhBytes, eax
    mov eax, dword ptr hdr[12]
    mov totCb, eax
    mov remCb, eax
    .IF eax == 0
        jmp done
    .ENDIF
    xor edx, edx
    add eax, blkSize
    dec eax
    div blkSize
    mov nBlk, eax
    inc eax
    shl eax, 2
    mov idxCb, eax
    .IF eax > JSO_IDXMAX
        jmp done
    .ENDIF
    invoke VfsAlloc, idxCb
    mov pIdx, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke FileReadAt, hIn, 48, 0, pIdx, idxCb
    .IF eax != idxCb
        jmp done
    .ENDIF
    invoke ZfBeginOut, pszDst, hIn, totCb, 0
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        mov ecx, pIdx
        mov edx, dword ptr [ecx + eax * 4 + 4]
        and edx, 7FFFFFFFh
        mov eax, dword ptr [ecx + eax * 4]
        and eax, 7FFFFFFFh
        add eax, bhBytes                    ; data begins past the per-block header
        mov dataOff, eax
        sub edx, eax
        mov csize, edx
        mov eax, blkSize
        .IF eax > remCb
            mov eax, remCb
        .ENDIF
        mov thisCb, eax
        invoke ZfSetInput, dataOff, 0
        mov eax, csize
        .IF eax >= blkSize                  ; stored block
            invoke ZfRawCopy, thisCb
        .ELSEIF method == 0
            invoke LzoBlock, csize
        .ELSE
            invoke ZfSmartInflate
        .ENDIF
        mov eax, thisCb
        sub remCb, eax
        inc i
    .ENDW
    invoke ZfOutFinal
    invoke ZfCheckTotal, totCb, 0
    mov ok, eax
    invoke ZfExpandFree
done:
    invoke VfsFreeMem, pIdx
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
JsoExpandFile ENDP

; ---------------------------------------------------------------------------
; ISZ (UltraISO): 48-byte packed header, chunk pointers of ptr_len bytes with
; the type in the top two bits (zero / raw / zlib / bzip2), chunks packed from
; data_offs. Passworded, segmented and bzip2 images are declined.
; ---------------------------------------------------------------------------
ISZ_IDXMAX      equ 64 * 1024 * 1024

IszExpandFile PROC USES esi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[48]:BYTE
    LOCAL blkSize:DWORD
    LOCAL nBlk:DWORD
    LOCAL ptrLen:DWORD
    LOCAL flagShift:DWORD
    LOCAL lenMask:DWORD
    LOCAL ptrOffs:DWORD
    LOCAL totLo:DWORD
    LOCAL totHi:DWORD
    LOCAL pIdx:DWORD
    LOCAL idxCb:DWORD
    LOCAL i:DWORD
    LOCAL remLo:DWORD
    LOCAL remHi:DWORD
    LOCAL thisCb:DWORD
    LOCAL chunkLen:DWORD
    LOCAL dataLo:DWORD
    LOCAL dataHi:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pIdx, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileReadAt, hIn, 0, 0, addr hdr, 48
    .IF eax != 48 || dword ptr hdr[0] != 215A7349h      ; "IsZ!"
        jmp done
    .ENDIF
    .IF byte ptr hdr[16] != 0               ; passworded
        jmp done
    .ENDIF
    .IF dword ptr hdr[39] != 0 || byte ptr hdr[34] != 0 ; segmented
        jmp done
    .ENDIF
    ; total bytes = sector size * total sectors
    movzx eax, word ptr hdr[10]
    mov ecx, dword ptr hdr[12]
    mul ecx
    mov totLo, eax
    mov totHi, edx
    mov remLo, eax
    mov remHi, edx
    .IF eax == 0 && edx == 0
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[25]
    mov nBlk, eax
    mov eax, dword ptr hdr[29]
    mov blkSize, eax
    .IF eax < 512 || eax > 1024 * 1024
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[43]
    mov dataLo, eax
    mov dataHi, 0
    mov eax, dword ptr hdr[35]
    mov ptrOffs, eax
    .IF eax == 0
        ; no chunk table: the image is stored raw at the data offset
        .IF remHi != 0
            jmp done
        .ENDIF
        invoke ZfBeginOut, pszDst, hIn, totLo, totHi
        .IF eax == INVALID_HANDLE_VALUE
            jmp done
        .ENDIF
        mov hOut, eax
        invoke ZfSetInput, dataLo, 0
        invoke ZfRawCopy, remLo
        jmp finish
    .ENDIF
    movzx eax, byte ptr hdr[33]
    mov ptrLen, eax
    .IF eax < 2 || eax > 4
        jmp done
    .ENDIF
    shl eax, 3
    sub eax, 2
    mov flagShift, eax
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    dec eax
    mov lenMask, eax
    .IF nBlk == 0
        jmp done
    .ENDIF
    mov eax, nBlk
    mul ptrLen
    .IF edx != 0 || eax > ISZ_IDXMAX
        jmp done
    .ENDIF
    mov idxCb, eax
    add eax, 4                              ; slack so the last pointer reads as a dword
    invoke VfsAlloc, eax
    mov pIdx, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke FileReadAt, hIn, ptrOffs, 0, pIdx, idxCb
    .IF eax != idxCb
        jmp done
    .ENDIF
    invoke ZfBeginOut, pszDst, hIn, totLo, totHi
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        mul ptrLen
        mov esi, pIdx
        add esi, eax
        mov eax, dword ptr [esi]            ; over-read is inside the slack
        mov ecx, flagShift
        mov ebx, eax
        shr ebx, cl
        and ebx, 3                          ; chunk type
        and eax, lenMask
        mov chunkLen, eax
        mov eax, blkSize
        .IF remHi == 0 && eax > remLo
            mov eax, remLo
        .ENDIF
        mov thisCb, eax
        .IF ebx == 0                        ; zeros
            invoke ZfPutZeros, thisCb
        .ELSEIF ebx == 1                    ; raw
            invoke ZfSetInput, dataLo, dataHi
            invoke ZfRawCopy, thisCb
        .ELSEIF ebx == 2                    ; zlib
            invoke ZfSetInput, dataLo, dataHi
            invoke ZfSmartInflate
        .ELSE                               ; bzip2
            invoke ZfSetInput, dataLo, dataHi
            invoke BzDecodeStream
        .ENDIF
        mov eax, chunkLen
        add dataLo, eax
        adc dataHi, 0
        mov eax, thisCb
        sub remLo, eax
        sbb remHi, 0
        inc i
    .ENDW
finish:
    invoke ZfOutFinal
    invoke ZfCheckTotal, totLo, totHi
    mov ok, eax
    invoke ZfExpandFree
done:
    invoke VfsFreeMem, pIdx
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
IszExpandFile ENDP

; ---------------------------------------------------------------------------
; DAA v0x100 (PowerISO): 76-byte header, 3-byte chunk lengths stored as
; high, low, middle; consecutive deflate chunks of chunksize output each.
; v0x110, encrypted and multipart images are declined.
; ---------------------------------------------------------------------------
DAA_IDXMAX      equ 16 * 1024 * 1024

DaaExpandFile PROC USES esi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[76]:BYTE
    LOCAL chunkSize:DWORD
    LOCAL nChunks:DWORD
    LOCAL totLo:DWORD
    LOCAL totHi:DWORD
    LOCAL pIdx:DWORD
    LOCAL idxCb:DWORD
    LOCAL i:DWORD
    LOCAL dataLo:DWORD
    LOCAL dataHi:DWORD
    LOCAL clen:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pIdx, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileReadAt, hIn, 0, 0, addr hdr, 76
    .IF eax != 76 || dword ptr hdr[0] != 00414144h      ; "DAA\0" (rejects DAA VOL parts)
        jmp done
    .ENDIF
    .IF dword ptr hdr[20] != 100h || dword ptr hdr[28] != 1
        jmp done                            ; only the classic version
    .ENDIF
    mov eax, dword ptr hdr[36]
    mov chunkSize, eax
    .IF eax < 512 || eax > 8 * 1024 * 1024
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[40]
    mov totLo, eax
    mov eax, dword ptr hdr[44]
    mov totHi, eax
    mov eax, totLo
    or eax, totHi
    .IF eax == 0
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[24]              ; data offset
    mov dataLo, eax
    mov dataHi, 0
    mov ecx, dword ptr hdr[16]              ; chunk length table offset
    sub eax, ecx
    .IF eax == 0 || eax > DAA_IDXMAX
        jmp done
    .ENDIF
    mov idxCb, eax
    xor edx, edx
    mov ecx, 3
    div ecx
    mov nChunks, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov eax, idxCb
    add eax, 4
    invoke VfsAlloc, eax
    mov pIdx, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke FileReadAt, hIn, dword ptr hdr[16], 0, pIdx, idxCb
    .IF eax != idxCb
        jmp done
    .ENDIF
    invoke ZfBeginOut, pszDst, hIn, totLo, totHi
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nChunks
        lea esi, [eax + eax * 2]
        add esi, pIdx
        movzx eax, byte ptr [esi]           ; high, low, middle
        shl eax, 16
        movzx ecx, byte ptr [esi + 2]
        shl ecx, 8
        or eax, ecx
        movzx ecx, byte ptr [esi + 1]
        or eax, ecx
        mov clen, eax
        invoke ZfSetInput, dataLo, dataHi
        invoke ZfSmartInflate
        mov eax, clen
        add dataLo, eax
        adc dataHi, 0
        inc i
    .ENDW
    invoke ZfOutFinal
    invoke ZfCheckTotal, totLo, totHi
    mov ok, eax
    invoke ZfExpandFree
done:
    invoke VfsFreeMem, pIdx
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
DaaExpandFile ENDP


; ---------------------------------------------------------------------------
; LZMA1 decoder (raw streams: CHD hunks, DAA v0x110 chunks). One probability
; array laid out as in LzmaDec, adaptive bits through a binary range coder.
; Streams read from the shared input, bytes land in the shared output window,
; so back references use the same 128 KB retained buffer as everything else.
; ---------------------------------------------------------------------------
LZ_ISMATCH      equ 0                   ; [state][posState], 12 * 16
LZ_ISREP        equ 192
LZ_ISREPG0      equ 204
LZ_ISREPG1      equ 216
LZ_ISREPG2      equ 228
LZ_ISREP0L      equ 240                 ; [state][posState]
LZ_POSSLOT      equ 432                 ; 4 categories * 64
LZ_SPECPOS      equ 688
LZ_ALIGN        equ 803
LZ_LEN          equ 819                 ; choice, choice2, low 16*8, mid 16*8, high 256
LZ_REPLEN       equ 1333
LZ_LIT          equ 1847
LZ_FIXED        equ 1847

.data
g_lzProbs       dd 0
g_lzNumProbs    dd 0
g_lzRange       dd 0
g_lzCode        dd 0
g_lzState       dd 0
g_lzRep0        dd 0
g_lzRep1        dd 0
g_lzRep2        dd 0
g_lzRep3        dd 0
g_lzLc          dd 0
g_lzLpMask      dd 0
g_lzPbMask      dd 0
g_lzPos         dd 0                    ; bytes produced in the current stream

.code

; Probability array for the given literal-context parameters
LzmaAlloc PROC lc:DWORD, lp:DWORD, pb:DWORD
    mov eax, lc
    mov g_lzLc, eax
    mov ecx, lp
    mov eax, 1
    shl eax, cl
    dec eax
    mov g_lzLpMask, eax
    mov ecx, pb
    mov eax, 1
    shl eax, cl
    dec eax
    mov g_lzPbMask, eax
    mov ecx, lc
    add ecx, lp
    .IF ecx > 8
        xor eax, eax
        ret
    .ENDIF
    mov eax, 300h
    shl eax, cl
    add eax, LZ_FIXED
    mov g_lzNumProbs, eax
    shl eax, 1
    invoke VfsAlloc, eax
    mov g_lzProbs, eax
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, TRUE
    ret
LzmaAlloc ENDP

LzmaFree PROC
    invoke VfsFreeMem, g_lzProbs
    mov g_lzProbs, 0
    ret
LzmaFree ENDP

; Reset probabilities and prime the range coder for a fresh stream
LzmaStart PROC USES edi
    mov edi, g_lzProbs
    mov eax, 1024
    mov ecx, g_lzNumProbs
    rep stosw
    mov g_lzState, 0
    mov g_lzRep0, 0
    mov g_lzRep1, 0
    mov g_lzRep2, 0
    mov g_lzRep3, 0
    mov g_lzPos, 0
    mov g_lzRange, 0FFFFFFFFh
    invoke ZfInByte                     ; leading zero byte
    xor ecx, ecx
    push ecx
    invoke ZfInByte
    pop ecx
    shl ecx, 8
    or ecx, eax
    push ecx
    invoke ZfInByte
    pop ecx
    shl ecx, 8
    or ecx, eax
    push ecx
    invoke ZfInByte
    pop ecx
    shl ecx, 8
    or ecx, eax
    push ecx
    invoke ZfInByte
    pop ecx
    shl ecx, 8
    or ecx, eax
    mov g_lzCode, ecx
    ret
LzmaStart ENDP

; One adaptive bit; probability word at index idx
LzBit PROC idx:DWORD
    mov ecx, g_lzProbs
    mov edx, idx
    movzx eax, word ptr [ecx + edx * 2]
    mov ecx, g_lzRange
    shr ecx, 11
    imul ecx, eax                       ; bound
    .IF g_lzCode < ecx
        mov g_lzRange, ecx
        mov ecx, 2048
        sub ecx, eax
        shr ecx, 5
        add eax, ecx
        mov ecx, g_lzProbs
        mov edx, idx
        mov word ptr [ecx + edx * 2], ax
        xor eax, eax
    .ELSE
        sub g_lzRange, ecx
        sub g_lzCode, ecx
        mov ecx, eax
        shr ecx, 5
        sub eax, ecx
        mov ecx, g_lzProbs
        mov edx, idx
        mov word ptr [ecx + edx * 2], ax
        mov eax, 1
    .ENDIF
    .IF g_lzRange < 1000000h
        shl g_lzRange, 8
        push eax
        invoke ZfInByte
        mov ecx, g_lzCode
        shl ecx, 8
        or ecx, eax
        mov g_lzCode, ecx
        pop eax
    .ENDIF
    ret
LzBit ENDP

; Forward bit tree of n bits at base; returns the symbol
LzTree PROC USES ebx pbase:DWORD, n:DWORD
    LOCAL m:DWORD
    mov m, 1
    mov ebx, n
    .WHILE ebx != 0
        mov eax, pbase
        add eax, m
        invoke LzBit, eax
        mov ecx, m
        lea ecx, [ecx * 2 + eax]
        mov m, ecx
        dec ebx
    .ENDW
    mov ecx, n
    mov eax, 1
    shl eax, cl
    mov ecx, m
    sub ecx, eax
    mov eax, ecx
    ret
LzTree ENDP

; Reverse bit tree of n bits at base
LzTreeRev PROC USES ebx esi pbase:DWORD, n:DWORD
    LOCAL m:DWORD
    LOCAL sym:DWORD
    mov m, 1
    mov sym, 0
    xor esi, esi                        ; bit position
    mov ebx, n
    .WHILE ebx != 0
        mov eax, pbase
        add eax, m
        invoke LzBit, eax
        mov ecx, m
        lea ecx, [ecx * 2 + eax]
        mov m, ecx
        mov ecx, esi
        shl eax, cl
        or sym, eax
        inc esi
        dec ebx
    .ENDW
    mov eax, sym
    ret
LzTreeRev ENDP

; n bits at probability one half
LzDirect PROC USES ebx esi n:DWORD
    xor esi, esi                        ; result
    mov ebx, n
    .WHILE ebx != 0
        shr g_lzRange, 1
        mov eax, g_lzCode
        sub eax, g_lzRange
        mov g_lzCode, eax
        mov ecx, eax
        sar ecx, 31                     ; all ones when the subtraction went negative
        mov eax, g_lzRange
        and eax, ecx
        add g_lzCode, eax
        lea esi, [esi * 2 + ecx + 1]
        .IF g_lzRange < 1000000h
            shl g_lzRange, 8
            invoke ZfInByte
            mov ecx, g_lzCode
            shl ecx, 8
            or ecx, eax
            mov g_lzCode, ecx
        .ENDIF
        dec ebx
    .ENDW
    mov eax, esi
    ret
LzDirect ENDP

; Length decoder at base (LZ_LEN or LZ_REPLEN); returns the 0-based symbol 0..271
LzLenDec PROC pbase:DWORD, posState:DWORD
    LOCAL b:DWORD
    invoke LzBit, pbase
    .IF eax == 0
        mov eax, posState
        shl eax, 3
        add eax, pbase
        add eax, 2
        invoke LzTree, eax, 3
        ret
    .ENDIF
    mov eax, pbase
    inc eax
    invoke LzBit, eax
    .IF eax == 0
        mov eax, posState
        shl eax, 3
        add eax, pbase
        add eax, 2 + 128
        invoke LzTree, eax, 3
        add eax, 8
        ret
    .ENDIF
    mov eax, pbase
    add eax, 2 + 256
    invoke LzTree, eax, 8
    add eax, 16
    ret
LzLenDec ENDP

; Byte at back distance dist (0 = the previous byte); assumes the caller checked bounds
LzWinByte PROC dist:DWORD
    mov ecx, g_zfOut
    mov edx, g_zfOutPos
    sub edx, dist
    dec edx
    movzx eax, byte ptr [ecx + edx]
    ret
LzWinByte ENDP

; Decode outCb bytes of one raw LZMA stream from the current input position
LzmaDecode PROC USES esi edi ebx outCb:DWORD
    LOCAL posState:DWORD
    LOCAL sym:DWORD
    LOCAL mlen:DWORD
    LOCAL mdist:DWORD
    LOCAL litIdx:DWORD
    LOCAL matchByte:DWORD
    LOCAL offs:DWORD
    LOCAL mbit:DWORD
    LOCAL slot:DWORD
    LOCAL nd:DWORD

    .WHILE g_zfErr == 0
        mov eax, g_lzPos
        .BREAK .IF eax >= outCb
        and eax, g_lzPbMask
        mov posState, eax
        mov eax, g_lzState
        shl eax, 4
        add eax, posState
        invoke LzBit, eax               ; IsMatch
        .IF eax == 0
            ; ---- literal ----
            mov eax, g_lzPos
            and eax, g_lzLpMask
            mov ecx, g_lzLc
            shl eax, cl
            xor edx, edx
            .IF g_lzPos != 0
                push eax
                invoke LzWinByte, 0
                mov edx, eax
                pop eax
            .ENDIF
            mov ecx, 8
            sub ecx, g_lzLc
            shr edx, cl
            add eax, edx
            mov ecx, eax
            shl ecx, 8
            lea ecx, [ecx + ecx * 2]    ; context * 0x300
            add ecx, LZ_LIT
            mov litIdx, ecx
            mov sym, 1
            .IF g_lzState < 7
                .WHILE sym < 100h && g_zfErr == 0
                    mov eax, litIdx
                    add eax, sym
                    invoke LzBit, eax
                    mov ecx, sym
                    lea ecx, [ecx * 2 + eax]
                    mov sym, ecx
                .ENDW
            .ELSE
                mov eax, g_lzRep0
                .IF eax >= g_lzPos
                    mov g_zfErr, 1
                    .BREAK
                .ENDIF
                invoke LzWinByte, g_lzRep0
                mov matchByte, eax
                mov offs, 100h
                .WHILE sym < 100h && g_zfErr == 0
                    shl matchByte, 1
                    mov eax, matchByte
                    and eax, offs
                    mov mbit, eax
                    mov ecx, litIdx
                    add ecx, offs
                    add ecx, eax
                    add ecx, sym
                    invoke LzBit, ecx
                    mov ecx, sym
                    lea ecx, [ecx * 2 + eax]
                    mov sym, ecx
                    .IF eax == 0
                        mov ecx, mbit
                        not ecx
                        and offs, ecx
                    .ELSE
                        mov ecx, mbit
                        and offs, ecx
                    .ENDIF
                .ENDW
            .ENDIF
            mov eax, sym
            and eax, 0FFh
            invoke ZfPutB, eax
            inc g_lzPos
            mov eax, g_lzState
            .IF eax < 4
                mov g_lzState, 0
            .ELSEIF eax < 10
                sub eax, 3
                mov g_lzState, eax
            .ELSE
                sub eax, 6
                mov g_lzState, eax
            .ENDIF
            .CONTINUE
        .ENDIF
        ; ---- match family ----
        mov eax, g_lzState
        add eax, LZ_ISREP
        invoke LzBit, eax
        .IF eax == 0
            ; new match: length, then distance
            invoke LzLenDec, LZ_LEN, posState
            mov mlen, eax
            .IF eax > 3
                mov eax, 3
            .ENDIF
            shl eax, 6
            add eax, LZ_POSSLOT
            invoke LzTree, eax, 6
            mov slot, eax
            .IF eax < 4
                mov mdist, eax
            .ELSE
                mov ecx, eax
                shr ecx, 1
                dec ecx
                mov nd, ecx
                mov eax, slot
                and eax, 1
                or eax, 2
                shl eax, cl
                mov mdist, eax
                .IF slot < 14
                    mov eax, mdist
                    sub eax, slot
                    dec eax
                    add eax, LZ_SPECPOS
                    invoke LzTreeRev, eax, nd
                    add mdist, eax
                .ELSE
                    mov eax, nd
                    sub eax, 4
                    invoke LzDirect, eax
                    shl eax, 4
                    add mdist, eax
                    invoke LzTreeRev, LZ_ALIGN, 4
                    add mdist, eax
                .ENDIF
            .ENDIF
            .IF mdist == 0FFFFFFFFh
                .BREAK                  ; end marker
            .ENDIF
            mov eax, g_lzRep2
            mov g_lzRep3, eax
            mov eax, g_lzRep1
            mov g_lzRep2, eax
            mov eax, g_lzRep0
            mov g_lzRep1, eax
            mov eax, mdist
            mov g_lzRep0, eax
            mov eax, 10
            .IF g_lzState < 7
                mov eax, 7
            .ENDIF
            mov g_lzState, eax
            mov eax, mlen
            add eax, 2
            mov mlen, eax
        .ELSE
            ; repeated distances
            mov eax, g_lzState
            add eax, LZ_ISREPG0
            invoke LzBit, eax
            .IF eax == 0
                mov eax, g_lzState
                shl eax, 4
                add eax, posState
                add eax, LZ_ISREP0L
                invoke LzBit, eax
                .IF eax == 0
                    ; short rep: one byte from rep0
                    mov eax, g_lzRep0
                    .IF eax >= g_lzPos
                        mov g_zfErr, 1
                        .BREAK
                    .ENDIF
                    invoke LzWinByte, g_lzRep0
                    invoke ZfPutB, eax
                    inc g_lzPos
                    mov eax, 9
                    .IF g_lzState >= 7
                        mov eax, 11
                    .ENDIF
                    mov g_lzState, eax
                    .CONTINUE
                .ENDIF
            .ELSE
                mov eax, g_lzState
                add eax, LZ_ISREPG1
                invoke LzBit, eax
                .IF eax == 0
                    mov eax, g_lzRep1
                    mov mdist, eax
                .ELSE
                    mov eax, g_lzState
                    add eax, LZ_ISREPG2
                    invoke LzBit, eax
                    .IF eax == 0
                        mov eax, g_lzRep2
                        mov mdist, eax
                    .ELSE
                        mov eax, g_lzRep3
                        mov mdist, eax
                        mov eax, g_lzRep2
                        mov g_lzRep3, eax
                    .ENDIF
                    mov eax, g_lzRep1
                    mov g_lzRep2, eax
                .ENDIF
                mov eax, g_lzRep0
                mov g_lzRep1, eax
                mov eax, mdist
                mov g_lzRep0, eax
            .ENDIF
            invoke LzLenDec, LZ_REPLEN, posState
            add eax, 2
            mov mlen, eax
            mov eax, 8
            .IF g_lzState >= 7
                mov eax, 11
            .ENDIF
            mov g_lzState, eax
        .ENDIF
        ; ---- copy mlen bytes from distance rep0 ----
        mov eax, g_lzRep0
        .IF eax >= g_lzPos
            mov g_zfErr, 1
            .BREAK
        .ENDIF
        mov eax, g_lzPos
        add eax, mlen
        .IF eax > outCb
            mov g_zfErr, 1
            .BREAK
        .ENDIF
        mov eax, mlen
        add g_lzPos, eax
        mov edx, g_lzRep0
        inc edx
        mov mdist, edx
        .WHILE mlen != 0 && g_zfErr == 0
            .IF g_zfOutPos >= ZF_OUTBUF
                invoke ZfOutFlush
            .ENDIF
            mov eax, mdist
            .IF eax > g_zfOutPos
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            mov ecx, mlen
            .IF ecx > 512
                mov ecx, 512
            .ENDIF
            sub mlen, ecx
            mov edi, g_zfOut
            add edi, g_zfOutPos
            mov esi, edi
            sub esi, mdist
            add g_zfOutPos, ecx
            rep movsb
        .ENDW
    .ENDW
    xor eax, eax
    .IF g_zfErr == 0
        mov eax, g_lzPos
        .IF eax == outCb
            mov eax, TRUE
        .ELSE
            xor eax, eax
        .ENDIF
    .ENDIF
    ret
LzmaDecode ENDP


; ---------------------------------------------------------------------------
; CHD v5 (MAME): big-endian 124-byte header, a Huffman-RLE compressed hunk map,
; then hunks compressed with up to four codecs. This build carries zlib (raw
; deflate) and lzma hunks plus stored and self-referencing ones; FLAC, custom
; Huffman hunks, CD-specialised codecs and parented CHDs are declined.
; ---------------------------------------------------------------------------
CHD_HUNKMAX     equ 131072
CHD_MAPMAX      equ 64 * 1024 * 1024
CHD_COUNTMAX    equ 800000h

.data
szChdMagic      db 'MComprHD'
g_chBitsPtr     dd 0                    ; map bitstream, MSB first
g_chBitPos      dd 0
g_chBitMax      dd 0
g_chLens        db 16 dup(0)
g_chCodes       dw 16 dup(0)

.code

ChBits PROC USES ebx esi n:DWORD
    xor esi, esi
    mov ebx, n
    .WHILE ebx != 0
        mov eax, g_chBitPos
        .IF eax >= g_chBitMax
            mov g_zfErr, 1
            .BREAK
        .ENDIF
        mov ecx, eax
        shr eax, 3
        mov edx, g_chBitsPtr
        movzx eax, byte ptr [edx + eax]
        and ecx, 7
        xor ecx, 7                      ; bit 7 first
        shr eax, cl
        and eax, 1
        shl esi, 1
        or esi, eax
        inc g_chBitPos
        dec ebx
    .ENDW
    mov eax, esi
    ret
ChBits ENDP

; Import the 16-symbol RLE-coded tree, then assign MAME's canonical codes
ChTreeImport PROC USES ebx edi
    LOCAL histo[33]:DWORD
    LOCAL curstart:DWORD
    xor ebx, ebx
    .WHILE ebx < 16 && g_zfErr == 0
        invoke ChBits, 4
        .IF eax != 1
            mov byte ptr g_chLens[ebx], al
            inc ebx
        .ELSE
            invoke ChBits, 4
            .IF eax == 1
                mov byte ptr g_chLens[ebx], 1
                inc ebx
            .ELSE
                mov edi, eax            ; repeated length value
                invoke ChBits, 4
                add eax, 3
                .WHILE eax != 0 && ebx < 16
                    mov ecx, edi
                    mov byte ptr g_chLens[ebx], cl
                    inc ebx
                    dec eax
                .ENDW
            .ENDIF
        .ENDIF
    .ENDW
    .IF g_zfErr != 0
        mov eax, 1
        ret
    .ENDIF
    lea edi, histo
    xor eax, eax
    mov ecx, 33
    rep stosd
    xor ebx, ebx
    .WHILE ebx < 16
        movzx eax, byte ptr g_chLens[ebx]
        .IF eax > 8
            mov eax, 1
            ret
        .ENDIF
        .IF eax != 0
            inc dword ptr histo[eax * 4]
        .ENDIF
        inc ebx
    .ENDW
    mov curstart, 0
    mov ebx, 32
    .WHILE ebx > 0
        mov eax, curstart
        add eax, dword ptr histo[ebx * 4]
        mov ecx, eax
        shr eax, 1
        .IF ebx != 1
            mov edx, eax
            shl edx, 1
            .IF edx != ecx              ; tree is not exactly full
                mov eax, 1
                ret
            .ENDIF
        .ENDIF
        mov ecx, curstart
        mov dword ptr histo[ebx * 4], ecx
        mov curstart, eax
        dec ebx
    .ENDW
    xor ebx, ebx
    .WHILE ebx < 16
        movzx eax, byte ptr g_chLens[ebx]
        .IF eax != 0
            mov ecx, dword ptr histo[eax * 4]
            mov word ptr g_chCodes[ebx * 2], cx
            inc ecx
            mov dword ptr histo[eax * 4], ecx
        .ENDIF
        inc ebx
    .ENDW
    xor eax, eax
    ret
ChTreeImport ENDP

; One symbol, bit by bit against the canonical table
ChTreeDecode PROC USES ebx esi
    xor esi, esi
    xor ebx, ebx
    .WHILE ebx < 8 && g_zfErr == 0
        invoke ChBits, 1
        shl esi, 1
        or esi, eax
        inc ebx
        xor ecx, ecx
        .WHILE ecx < 16
            movzx eax, byte ptr g_chLens[ecx]
            .IF eax == ebx
                movzx edx, word ptr g_chCodes[ecx * 2]
                .IF edx == esi
                    mov eax, ecx
                    ret
                .ENDIF
            .ENDIF
            inc ecx
        .ENDW
    .ENDW
    mov g_zfErr, 1
    xor eax, eax
    ret
ChTreeDecode ENDP

; Append cb bytes from memory to the output, honouring flush boundaries
ZfPutMem PROC USES esi edi ebx pSrc:DWORD, cb:DWORD
    mov esi, pSrc
    mov ebx, cb
    .WHILE ebx != 0 && g_zfErr == 0
        .IF g_zfOutPos >= ZF_OUTBUF
            invoke ZfOutFlush
        .ENDIF
        mov eax, ZF_OUTBUF
        sub eax, g_zfOutPos
        .IF eax > ebx
            mov eax, ebx
        .ENDIF
        mov edi, g_zfOut
        add edi, g_zfOutPos
        mov ecx, eax
        push eax
        rep movsb
        pop eax
        add g_zfOutPos, eax
        sub ebx, eax
    .ENDW
    ret
ZfPutMem ENDP


; One CD hunk (cdzl or cdlz): ecc bitmap and base-length header, then the sector
; halves (2352 bytes each) as one stream. The subcode stream that follows is of
; no use for browsing, so it stays in the file untouched; the output is a plain
; 2352-byte raw image. Flagged frames get their sync pattern back; the stripped
; ECC parity stays zero, which no reader here ever checks (as with ECM).
ChdCdHunk PROC USES esi edi ebx offLo:DWORD, offHi:DWORD, cb:DWORD, isLzma:DWORD
    LOCAL frames:DWORD
    LOCAL eccBytes:DWORD
    LOCAL clBytes:DWORD
    LOCAL save0:DWORD
    LOCAL baseLo:DWORD
    LOCAL baseHi:DWORD
    LOCAL i:DWORD
    LOCAL hdrbuf[24]:BYTE

    mov eax, cb
    xor edx, edx
    mov ecx, 2352
    div ecx
    .IF edx != 0 || eax == 0
        mov g_zfErr, 1
        ret
    .ENDIF
    mov frames, eax
    mov ecx, eax
    add eax, 7
    shr eax, 3
    mov eccBytes, eax
    .IF eax > 20
        mov g_zfErr, 1
        ret
    .ENDIF
    imul ecx, 2448                      ; the length header width follows the stored hunk size
    mov eax, 2
    .IF ecx >= 65536
        inc eax
    .ENDIF
    mov clBytes, eax
    mov eax, eccBytes
    add eax, clBytes
    push eax
    invoke FileReadAt, g_zfFile, offLo, offHi, addr hdrbuf, eax
    pop ecx
    .IF eax != ecx
        mov g_zfErr, 1
        ret
    .ENDIF
    ; the whole hunk must stay in the buffer so sync patching can reach it
    mov eax, g_zfOutPos
    add eax, cb
    add eax, 1024
    .IF eax > ZF_OUTBUF
        invoke ZfOutFlush
    .ENDIF
    mov eax, g_zfOutPos
    mov save0, eax
    mov eax, eccBytes
    add eax, clBytes
    add eax, offLo
    mov baseLo, eax
    mov eax, offHi
    adc eax, 0
    mov baseHi, eax
    invoke ZfSetInput, baseLo, baseHi
    .IF isLzma != 0
        invoke LzmaStart
        invoke LzmaDecode, cb
    .ELSE
        invoke ZfInflate
    .ENDIF
    mov eax, g_zfOutPos
    sub eax, save0
    .IF eax != cb || g_zfErr != 0
        mov g_zfErr, 1
        ret
    .ENDIF
    ; restore sync for the frames the compressor stripped
    mov i, 0
    .WHILE TRUE
        mov eax, i
        .BREAK .IF eax >= frames
        mov ecx, eax
        shr eax, 3
        and ecx, 7
        movzx eax, byte ptr hdrbuf[eax]
        mov edx, 80h
        shr edx, cl
        test eax, edx
        .IF !ZERO?
            mov edi, g_zfOut
            add edi, save0
            mov ecx, i
            imul ecx, 2352
            add edi, ecx
            mov esi, offset szSync
            mov ecx, 12
            rep movsb
        .ENDIF
        inc i
    .ENDW
    ret
ChdCdHunk ENDP

; Walk the CHD metadata chain for CHT2/CHTR entries: "TRACK:n TYPE:t ... FRAMES:f".
; Tracks land in the shared table with byte ranges into the expanded 2352 image;
; each track's stored frames pad to a multiple of four in CHD, so track starts do too.
szChtFrames     db 'FRAMES:', 0
szChtAudio      db 'TYPE:AUDIO', 0

ChdCdTracks PROC USES esi edi ebx hIn:DWORD, pHdr:DWORD
    LOCAL metaLo:DWORD
    LOCAL metaHi:DWORD
    LOCAL nextLo:DWORD
    LOCAL nextHi:DWORD
    LOCAL mlen:DWORD
    LOCAL tag:DWORD
    LOCAL pText:DWORD
    LOCAL frames:DWORD
    LOCAL curFrame:DWORD
    LOCAL isAud:DWORD
    LOCAL mhdr[16]:BYTE

    mov ecx, pHdr
    invoke BSwap32, dword ptr [ecx + 48]
    mov metaHi, eax
    mov ecx, pHdr
    invoke BSwap32, dword ptr [ecx + 52]
    mov metaLo, eax
    mov curFrame, 0
    mov ebx, 0                              ; guard against looping chains
    .WHILE ebx < 256
        mov eax, metaLo
        or eax, metaHi
        .BREAK .IF eax == 0
        invoke FileReadAt, hIn, metaLo, metaHi, addr mhdr, 16
        .BREAK .IF eax != 16
        mov eax, dword ptr mhdr[0]
        mov tag, eax
        invoke BSwap32, dword ptr mhdr[4]
        and eax, 0FFFFFFh
        mov mlen, eax
        invoke BSwap32, dword ptr mhdr[8]
        mov nextHi, eax
        invoke BSwap32, dword ptr mhdr[12]
        mov nextLo, eax
        mov eax, tag
        .IF (eax == 32544843h || eax == 52544843h) && mlen != 0 && mlen < 512
            ; "CHT2" / "CHTR"
            mov eax, mlen
            inc eax
            invoke VfsAlloc, eax
            mov pText, eax
            .IF eax != 0
                mov eax, metaLo
                add eax, 16
                mov ecx, metaHi
                adc ecx, 0
                invoke FileReadAt, hIn, eax, ecx, pText, mlen
                .IF eax == mlen
                    invoke FindKeyword, pText, mlen, offset szChtFrames
                    .IF eax != 0
                        invoke ParseUint, eax
                        mov frames, eax
                        invoke FindKeyword, pText, mlen, offset szChtAudio
                        mov isAud, 0
                        .IF eax != 0
                            mov isAud, 1
                        .ENDIF
                        ; byte range in the subcode-stripped output
                        mov eax, curFrame
                        mov ecx, 2352
                        mul ecx
                        push edx
                        push eax
                        mov eax, frames
                        mov ecx, 2352
                        mul ecx
                        mov ecx, eax                    ; pcm bytes (tracks < 4 GB)
                        pop eax
                        pop edx
                        invoke CtTrackAdd, eax, edx, ecx, isAud
                        ; the next track starts on a four-frame boundary
                        mov eax, frames
                        add eax, 3
                        and eax, 0FFFFFFFCh
                        add curFrame, eax
                    .ENDIF
                .ENDIF
                invoke VfsFreeMem, pText
            .ENDIF
        .ENDIF
        mov eax, nextLo
        mov metaLo, eax
        mov eax, nextHi
        mov metaHi, eax
        inc ebx
    .ENDW
    .IF g_ctNumTracks != 0
        mov g_ctAudioSwap, 1                ; CHD audio frames are big-endian
    .ENDIF
    ret
ChdCdTracks ENDP

ChdExpandFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[124]:BYTE
    LOCAL comps[4]:DWORD
    LOCAL totLo:DWORD
    LOCAL totHi:DWORD
    LOCAL mapLo:DWORD
    LOCAL mapHi:DWORD
    LOCAL hunkBytes:DWORD
    LOCAL hunkOut:DWORD
    LOCAL isCd:DWORD
    LOCAL nHunks:DWORD
    LOCAL mapLen:DWORD
    LOCAL dsLo:DWORD
    LOCAL dsHi:DWORD
    LOCAL lenBits:DWORD
    LOCAL selfBits:DWORD
    LOCAL pBits:DWORD
    LOCAL pMap:DWORD
    LOCAL pScratch:DWORD
    LOCAL haveLzma:DWORD
    LOCAL haveFlac:DWORD
    LOCAL lastComp:DWORD
    LOCAL repCount:DWORD
    LOCAL curLo:DWORD
    LOCAL curHi:DWORD
    LOCAL i:DWORD
    LOCAL remLo:DWORD
    LOCAL remHi:DWORD
    LOCAL thisCb:DWORD
    LOCAL mhdr[16]:BYTE
    LOCAL fourcc:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pBits, 0
    mov pMap, 0
    mov pScratch, 0
    mov haveLzma, 0
    mov haveFlac, 0
    mov isCd, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileReadAt, hIn, 0, 0, addr hdr, 124
    .IF eax != 124
        jmp done
    .ENDIF
    lea esi, hdr
    mov edi, offset szChdMagic
    mov ecx, 8
    repe cmpsb
    jne done
    invoke BSwap32, dword ptr hdr[12]
    .IF eax != 5                        ; only v5
        jmp done
    .ENDIF
    ; codecs: only raw deflate and lzma hunks are decodable here
    xor ebx, ebx
    .WHILE ebx < 4
        mov eax, dword ptr hdr[ebx * 4 + 16]
        mov dword ptr comps[ebx * 4], eax
        .IF eax == 616D7A6Ch                ; "lzma"
            mov haveLzma, 1
        .ELSEIF eax == 7A6C6463h            ; "cdlz"
            mov haveLzma, 1
            mov isCd, 1
        .ELSEIF eax == 6C7A6463h            ; "cdzl"
            mov isCd, 1
        .ELSEIF eax == 6C666463h            ; "cdfl"
            mov isCd, 1
            mov haveFlac, 1
        .ELSEIF eax == 63616C66h            ; "flac"
            mov haveFlac, 1
        .ELSEIF eax != 0 && eax != 62696C7Ah    ; "zlib"
            jmp done
        .ENDIF
        inc ebx
    .ENDW
    ; no deltas from a parent image
    mov ecx, 104
    xor eax, eax
    .WHILE ecx < 124
        or al, byte ptr hdr[ecx]
        inc ecx
    .ENDW
    .IF eax != 0
        jmp done
    .ENDIF
    invoke BSwap32, dword ptr hdr[32]
    mov totHi, eax
    invoke BSwap32, dword ptr hdr[36]
    mov totLo, eax
    mov eax, totLo
    or eax, totHi
    .IF eax == 0
        jmp done
    .ENDIF
    mov eax, totLo
    mov remLo, eax
    mov eax, totHi
    mov remHi, eax
    invoke BSwap32, dword ptr hdr[40]
    mov mapHi, eax
    invoke BSwap32, dword ptr hdr[44]
    mov mapLo, eax
    invoke BSwap32, dword ptr hdr[56]
    mov hunkBytes, eax
    mov hunkOut, eax
    .IF eax < 512 || eax > CHD_HUNKMAX
        jmp done
    .ENDIF
    .IF isCd != 0
        ; output drops the 96 subcode bytes per frame: rescale hunk and totals
        xor edx, edx
        mov ecx, 2448
        div ecx
        .IF edx != 0 || eax == 0
            jmp done
        .ENDIF
        imul eax, 2352
        mov hunkOut, eax
        mov eax, totLo
        mov edx, totHi
        mov ecx, 2448
        mov ebx, eax
        mov eax, edx
        xor edx, edx
        div ecx
        push eax
        mov eax, ebx
        div ecx
        pop ebx                             ; quotient high dword
        .IF edx != 0 || ebx != 0
            jmp done
        .ENDIF
        mov ecx, 2352
        mul ecx
        mov totLo, eax
        mov totHi, edx
        mov remLo, eax
        mov remHi, edx
    .ENDIF
    ; hunk count = ceil(total / hunk size)
    mov eax, totLo
    mov edx, totHi
    add eax, hunkBytes
    adc edx, 0
    sub eax, 1
    sbb edx, 0
    mov ecx, eax                        ; 64/32 divide, quotient must fit 32 bits
    mov eax, edx
    xor edx, edx
    div hunkBytes
    .IF eax != 0
        jmp done
    .ENDIF
    mov eax, ecx
    div hunkBytes
    mov nHunks, eax
    .IF eax == 0 || eax > CHD_COUNTMAX
        jmp done
    .ENDIF
    shl eax, 4
    invoke VfsAlloc, eax                ; per hunk: comp, length, offset lo, offset hi
    mov pMap, eax
    .IF eax == 0
        jmp done
    .ENDIF

    .IF dword ptr comps[0] == 0
        ; uncompressed: the map is one big-endian dword per hunk, in hunk units
        mov eax, nHunks
        shl eax, 2
        invoke VfsAlloc, eax
        mov pBits, eax
        .IF eax == 0
            jmp done
        .ENDIF
        mov eax, nHunks
        shl eax, 2
        invoke FileReadAt, hIn, mapLo, mapHi, pBits, eax
        mov ecx, nHunks
        shl ecx, 2
        .IF eax != ecx
            jmp done
        .ENDIF
        mov i, 0
        .WHILE TRUE
            mov eax, i
            .BREAK .IF eax >= nHunks
            mov ecx, pBits
            invoke BSwap32, dword ptr [ecx + eax * 4]
            mul hunkBytes               ; entry * hunkbytes = byte offset
            mov esi, pMap
            mov ecx, i
            shl ecx, 4
            mov dword ptr [esi + ecx], 4        ; treat as stored
            mov ebx, hunkBytes
            mov dword ptr [esi + ecx + 4], ebx
            mov dword ptr [esi + ecx + 8], eax
            mov dword ptr [esi + ecx + 12], edx
            inc i
        .ENDW
    .ELSE
        ; compressed map: 16-byte header then the Huffman-RLE bitstream
        invoke FileReadAt, hIn, mapLo, mapHi, addr mhdr, 16
        .IF eax != 16
            jmp done
        .ENDIF
        invoke BSwap32, dword ptr mhdr[0]
        mov mapLen, eax
        .IF eax == 0 || eax > CHD_MAPMAX
            jmp done
        .ENDIF
        movzx eax, byte ptr mhdr[4]
        shl eax, 8
        movzx ecx, byte ptr mhdr[5]
        or eax, ecx
        mov dsHi, eax
        invoke BSwap32, dword ptr mhdr[6]
        mov dsLo, eax
        movzx eax, byte ptr mhdr[12]
        mov lenBits, eax
        .IF eax == 0 || eax > 31
            jmp done
        .ENDIF
        movzx eax, byte ptr mhdr[13]
        mov selfBits, eax
        .IF eax > 31
            jmp done
        .ENDIF
        invoke VfsAlloc, mapLen
        mov pBits, eax
        .IF eax == 0
            jmp done
        .ENDIF
        mov eax, mapLo
        add eax, 16
        mov ecx, mapHi
        adc ecx, 0
        invoke FileReadAt, hIn, eax, ecx, pBits, mapLen
        .IF eax != mapLen
            jmp done
        .ENDIF
        mov eax, pBits
        mov g_chBitsPtr, eax
        mov g_chBitPos, 0
        mov eax, mapLen
        shl eax, 3
        mov g_chBitMax, eax
        mov g_zfErr, 0
        invoke ChTreeImport
        .IF eax != 0 || g_zfErr != 0
            jmp done
        .ENDIF
        ; pass 1: compression type per hunk, with the RLE escapes
        mov lastComp, 0
        mov repCount, 0
        mov i, 0
        .WHILE g_zfErr == 0
            mov eax, i
            .BREAK .IF eax >= nHunks
            .IF repCount != 0
                dec repCount
                mov eax, lastComp
            .ELSE
                invoke ChTreeDecode
                .IF eax == 7            ; small repeat
                    invoke ChTreeDecode
                    add eax, 2
                    mov repCount, eax
                    mov eax, lastComp
                .ELSEIF eax == 8        ; large repeat
                    invoke ChTreeDecode
                    shl eax, 4
                    add eax, 2 + 16
                    push eax
                    invoke ChTreeDecode
                    pop ecx
                    add eax, ecx
                    mov repCount, eax
                    mov eax, lastComp
                .ELSE
                    mov lastComp, eax
                .ENDIF
            .ENDIF
            .IF eax > 5                 ; parent references and junk
                jmp done
            .ENDIF
            mov esi, pMap
            mov ecx, i
            shl ecx, 4
            mov dword ptr [esi + ecx], eax
            inc i
        .ENDW
        .IF g_zfErr != 0
            jmp done
        .ENDIF
        ; pass 2: lengths and offsets
        mov eax, dsLo
        mov curLo, eax
        mov eax, dsHi
        mov curHi, eax
        mov i, 0
        .WHILE g_zfErr == 0
            mov eax, i
            .BREAK .IF eax >= nHunks
            mov esi, pMap
            mov ecx, i
            shl ecx, 4
            add esi, ecx
            mov eax, dword ptr [esi]
            .IF eax <= 3
                invoke ChBits, lenBits
                mov dword ptr [esi + 4], eax
                mov ecx, curLo
                mov dword ptr [esi + 8], ecx
                mov ecx, curHi
                mov dword ptr [esi + 12], ecx
                add curLo, eax
                adc curHi, 0
            .ELSEIF eax == 4
                mov eax, hunkBytes
                mov dword ptr [esi + 4], eax
                mov ecx, curLo
                mov dword ptr [esi + 8], ecx
                mov ecx, curHi
                mov dword ptr [esi + 12], ecx
                add curLo, eax
                adc curHi, 0
            .ELSE                       ; self reference: hunk number
                invoke ChBits, selfBits
                mov dword ptr [esi + 4], 0
                mov dword ptr [esi + 8], eax
                mov dword ptr [esi + 12], 0
            .ENDIF
            inc i
        .ENDW
        .IF g_zfErr != 0
            jmp done
        .ENDIF
    .ENDIF

    .IF isCd != 0
        invoke ChdCdTracks, hIn, addr hdr
    .ENDIF
    invoke CreateFileW, pszDst, GENERIC_READ or GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    invoke FilePresize, hOut, totLo, totHi   ; the CHD header states the full logical size
    invoke ZfExpandInit, hIn, hOut
    .IF eax == 0
        jmp done
    .ENDIF
    .IF haveLzma != 0
        invoke LzmaAlloc, 3, 0, 2       ; chdman's fixed literal/position parameters
        .IF eax == 0
            jmp done
        .ENDIF
    .ENDIF
    .IF haveFlac != 0
        invoke FlacAlloc
        .IF eax == 0
            jmp done
        .ENDIF
    .ENDIF
    invoke VfsAlloc, hunkBytes
    mov pScratch, eax
    .IF eax == 0
        jmp done
    .ENDIF

    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nHunks
        mov esi, pMap
        mov ecx, i
        shl ecx, 4
        add esi, ecx
        mov eax, hunkOut
        .IF remHi == 0 && eax > remLo
            mov eax, remLo
        .ENDIF
        mov thisCb, eax
        mov eax, dword ptr [esi]
        .IF eax <= 3
            mov ecx, dword ptr comps[eax * 4]
            mov fourcc, ecx
            .IF fourcc == 6C7A6463h || fourcc == 7A6C6463h      ; cdzl / cdlz
                xor eax, eax
                .IF fourcc == 7A6C6463h
                    inc eax
                .ENDIF
                invoke ChdCdHunk, dword ptr [esi + 8], dword ptr [esi + 12], thisCb, eax
            .ELSEIF fourcc == 6C666463h ; cdfl: bare FLAC frames, byte-swapped samples
                invoke ZfSetInput, dword ptr [esi + 8], dword ptr [esi + 12]
                invoke FlacStart
                mov eax, thisCb
                shr eax, 2
                invoke FlacDecodeStream, eax, 1
            .ELSEIF fourcc == 63616C66h ; flac: leading endianness byte
                invoke ZfSetInput, dword ptr [esi + 8], dword ptr [esi + 12]
                invoke FlacStart
                invoke ZfInByte
                .IF eax == 4Ch          ; 'L': stored little-endian, ours already
                    xor ecx, ecx
                .ELSEIF eax == 42h      ; 'B'
                    mov ecx, 1
                .ELSE
                    mov g_zfErr, 1
                    .BREAK
                .ENDIF
                mov eax, thisCb
                shr eax, 2
                invoke FlacDecodeStream, eax, ecx
            .ELSE
                invoke ZfSetInput, dword ptr [esi + 8], dword ptr [esi + 12]
                .IF fourcc == 62696C7Ah ; zlib: raw deflate
                    invoke ZfInflate
                .ELSE                   ; lzma
                    invoke LzmaStart
                    invoke LzmaDecode, thisCb
                .ENDIF
            .ENDIF
        .ELSEIF eax == 4                ; stored
            .IF isCd != 0
                mov eax, thisCb
                xor edx, edx
                mov ecx, 2352
                div ecx
                push eax                    ; frame count
                mov ecx, 2448
                mul ecx
                push eax
                invoke FileReadAt, hIn, dword ptr [esi + 8], dword ptr [esi + 12], pScratch, eax
                pop ecx
                .IF eax != ecx
                    pop eax
                    mov g_zfErr, 1
                    .BREAK
                .ENDIF
                pop ecx
                xor edi, edi
                .WHILE edi < ecx && g_zfErr == 0
                    push ecx
                    mov eax, edi
                    imul eax, 2448
                    add eax, pScratch
                    invoke ZfPutMem, eax, 2352
                    pop ecx
                    inc edi
                .ENDW
            .ELSE
                invoke ZfSetInput, dword ptr [esi + 8], dword ptr [esi + 12]
                invoke ZfRawCopy, thisCb
            .ENDIF
        .ELSE                           ; self: re-emit an earlier hunk
            mov eax, dword ptr [esi + 8]
            .IF eax >= i
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            invoke ZfOutFinal           ; everything so far must be on disk
            mov eax, dword ptr [esi + 8]
            mul hunkOut
            invoke FileReadAt, hOut, eax, edx, pScratch, thisCb
            .IF eax != thisCb
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            invoke SetFilePointerEx, hOut, 0, 0, NULL, FILE_END
            mov ebx, 0
            .WHILE ebx < thisCb && g_zfErr == 0
                mov ecx, pScratch
                movzx eax, byte ptr [ecx + ebx]
                invoke ZfPutB, eax
                inc ebx
            .ENDW
        .ENDIF
        mov eax, thisCb
        sub remLo, eax
        sbb remHi, 0
        inc i
    .ENDW
    invoke ZfOutFinal
    invoke ZfCheckTotal, totLo, totHi
    mov ok, eax
    invoke ZfExpandFree
done:
    .IF haveLzma != 0
        invoke LzmaFree
    .ENDIF
    .IF haveFlac != 0
        invoke FlacFree
    .ENDIF
    invoke VfsFreeMem, pBits
    invoke VfsFreeMem, pMap
    invoke VfsFreeMem, pScratch
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
ChdExpandFile ENDP


; ---------------------------------------------------------------------------
; FLAC decoder (CHD 'cdfl' and 'flac' hunks): bare frame sequences, always
; 2 channels of 16-bit samples here. Subframes cover constant, verbatim,
; fixed orders 0-4 and LPC with Rice-coded residuals; stereo decorrelation
; undoes left/side, right/side and mid/side. CRCs pass through unchecked.
; ---------------------------------------------------------------------------
FL_MAXBLK       equ 8192

.data
g_flBitBuf      dd 0                    ; MSB-first accumulator
g_flBitCnt      dd 0
g_flSampL       dd 0                    ; per-channel sample buffers (dwords)
g_flSampR       dd 0
g_flBlk         dd 0                    ; block size of the current frame
g_flChan        dd 0                    ; channel assignment code

.code

FlacAlloc PROC
    invoke VfsAlloc, FL_MAXBLK * 4
    mov g_flSampL, eax
    invoke VfsAlloc, FL_MAXBLK * 4
    mov g_flSampR, eax
    mov eax, g_flSampL
    .IF eax == 0 || g_flSampR == 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, TRUE
    ret
FlacAlloc ENDP

FlacFree PROC
    invoke VfsFreeMem, g_flSampL
    invoke VfsFreeMem, g_flSampR
    mov g_flSampL, 0
    mov g_flSampR, 0
    ret
FlacFree ENDP

FlacStart PROC
    mov g_flBitBuf, 0
    mov g_flBitCnt, 0
    ret
FlacStart ENDP

; n bits (0-24), MSB first
FlBits PROC USES ebx n:DWORD
    .WHILE TRUE
        mov eax, g_flBitCnt
        .BREAK .IF eax >= n
        invoke ZfInByte
        mov ecx, g_flBitBuf
        shl ecx, 8
        or ecx, eax
        mov g_flBitBuf, ecx
        add g_flBitCnt, 8
    .ENDW
    mov ecx, g_flBitCnt
    sub ecx, n
    mov g_flBitCnt, ecx
    mov eax, g_flBitBuf
    shr eax, cl
    mov ecx, n
    .IF ecx == 0
        xor eax, eax
        ret
    .ENDIF
    mov edx, 1
    shl edx, cl
    dec edx
    and eax, edx
    ret
FlBits ENDP

; n bits (0-32), MSB first
FlBitsL PROC USES ebx n:DWORD
    .IF n <= 24
        invoke FlBits, n
        ret
    .ENDIF
    mov eax, n
    sub eax, 16
    push eax
    invoke FlBits, 16
    mov ebx, eax
    pop eax
    push ebx
    invoke FlBits, eax
    pop ebx
    mov ecx, n
    sub ecx, 16
    shl ebx, cl
    or eax, ebx
    ret
FlBitsL ENDP

; n bits sign-extended
FlSigned PROC n:DWORD
    invoke FlBitsL, n
    mov ecx, 32
    sub ecx, n
    shl eax, cl
    sar eax, cl
    ret
FlSigned ENDP

; zero run then a one bit
FlUnary PROC USES ebx
    xor ebx, ebx
    .WHILE g_zfErr == 0
        invoke FlBits, 1
        .BREAK .IF eax != 0
        inc ebx
        .IF ebx > 1000000h                  ; runaway stream
            mov g_zfErr, 1
            .BREAK
        .ENDIF
    .ENDW
    mov eax, ebx
    ret
FlUnary ENDP

; Rice-coded residuals into pBuf + order*4, blocksize total slots
FlResiduals PROC USES esi edi ebx pBuf:DWORD, order:DWORD
    LOCAL method:DWORD
    LOCAL nparts:DWORD
    LOCAL part:DWORD
    LOCAL cnt:DWORD
    LOCAL param:DWORD
    LOCAL escv:DWORD
    LOCAL pbits:DWORD
    invoke FlBits, 2
    .IF eax >= 2
        mov g_zfErr, 1
        ret
    .ENDIF
    mov ecx, 4
    mov edx, 15
    .IF eax == 1
        mov ecx, 5
        mov edx, 31
    .ENDIF
    mov pbits, ecx
    mov escv, edx
    invoke FlBits, 4
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    mov nparts, eax
    mov eax, g_flBlk
    shr eax, cl
    mov cnt, eax                            ; samples per partition
    .IF eax == 0 || eax > g_flBlk
        mov g_zfErr, 1
        ret
    .ENDIF
    mov edi, pBuf
    mov eax, order
    lea edi, [edi + eax * 4]
    mov part, 0
    .WHILE g_zfErr == 0
        mov eax, part
        .BREAK .IF eax >= nparts
        mov ebx, cnt
        .IF part == 0
            sub ebx, order                  ; the warmup samples came earlier
            .IF ebx & 80000000h
                mov g_zfErr, 1
                .BREAK
            .ENDIF
        .ENDIF
        invoke FlBits, pbits
        mov param, eax
        .IF eax == escv
            ; escape: raw n-bit residuals
            invoke FlBits, 5
            mov param, eax
            .WHILE ebx != 0 && g_zfErr == 0
                .IF param == 0
                    xor eax, eax
                .ELSE
                    invoke FlSigned, param
                .ENDIF
                mov dword ptr [edi], eax
                add edi, 4
                dec ebx
            .ENDW
        .ELSE
            .WHILE ebx != 0 && g_zfErr == 0
                invoke FlUnary
                mov esi, eax
                .IF param != 0
                    mov ecx, param
                    shl esi, cl
                    invoke FlBits, param
                    or esi, eax
                .ENDIF
                mov eax, esi
                shr eax, 1
                and esi, 1
                neg esi
                xor eax, esi
                mov dword ptr [edi], eax
                add edi, 4
                dec ebx
            .ENDW
        .ENDIF
        inc part
    .ENDW
    ret
FlResiduals ENDP

; One subframe into pBuf; bps includes any side-channel extra bit
FlSubframe PROC USES esi edi ebx pBuf:DWORD, bps:DWORD
    LOCAL ftype:DWORD
    LOCAL wasted:DWORD
    LOCAL order:DWORD
    LOCAL prec:DWORD
    LOCAL shiftv:DWORD
    LOCAL i:DWORD
    LOCAL ebps:DWORD
    LOCAL coefs[32]:DWORD
    invoke FlBits, 1
    .IF eax != 0
        mov g_zfErr, 1
        ret
    .ENDIF
    invoke FlBits, 6
    mov ftype, eax
    mov wasted, 0
    invoke FlBits, 1
    .IF eax != 0
        invoke FlUnary
        inc eax
        mov wasted, eax
    .ENDIF
    mov eax, bps
    sub eax, wasted
    mov ebps, eax
    .IF eax == 0 || eax > 32
        mov g_zfErr, 1
        ret
    .ENDIF
    mov eax, ftype
    .IF eax == 0
        ; constant
        invoke FlSigned, ebps
        mov edi, pBuf
        mov ecx, g_flBlk
        rep stosd
    .ELSEIF eax == 1
        ; verbatim
        mov edi, pBuf
        mov ebx, g_flBlk
        .WHILE ebx != 0 && g_zfErr == 0
            invoke FlSigned, ebps
            mov dword ptr [edi], eax
            add edi, 4
            dec ebx
        .ENDW
    .ELSEIF eax >= 8 && eax <= 12
        ; fixed prediction
        sub eax, 8
        mov order, eax
        mov edi, pBuf
        mov ebx, eax
        .WHILE ebx != 0 && g_zfErr == 0
            invoke FlSigned, ebps
            mov dword ptr [edi], eax
            add edi, 4
            dec ebx
        .ENDW
        invoke FlResiduals, pBuf, order
        .IF g_zfErr != 0
            ret
        .ENDIF
        mov esi, pBuf
        mov eax, order
        mov i, eax
        .WHILE TRUE
            mov eax, i
            .BREAK .IF eax >= g_flBlk
            mov edi, eax
            shl edi, 2
            add edi, esi                    ; &s[i]
            mov eax, dword ptr [edi]        ; residual
            mov ecx, order
            .IF ecx == 1
                add eax, dword ptr [edi - 4]
            .ELSEIF ecx == 2
                mov edx, dword ptr [edi - 4]
                add edx, edx
                sub edx, dword ptr [edi - 8]
                add eax, edx
            .ELSEIF ecx == 3
                mov edx, dword ptr [edi - 4]
                sub edx, dword ptr [edi - 8]
                lea edx, [edx + edx * 2]
                add edx, dword ptr [edi - 12]
                add eax, edx
            .ELSEIF ecx == 4
                mov edx, dword ptr [edi - 4]
                add edx, dword ptr [edi - 12]
                shl edx, 2
                mov ecx, dword ptr [edi - 8]
                lea ecx, [ecx * 2 + ecx]
                shl ecx, 1                  ; 6 * s2
                sub edx, ecx
                sub edx, dword ptr [edi - 16]
                add eax, edx
            .ENDIF
            mov dword ptr [edi], eax
            inc i
        .ENDW
    .ELSEIF eax >= 32
        ; LPC
        sub eax, 31
        mov order, eax
        mov edi, pBuf
        mov ebx, eax
        .WHILE ebx != 0 && g_zfErr == 0
            invoke FlSigned, ebps
            mov dword ptr [edi], eax
            add edi, 4
            dec ebx
        .ENDW
        invoke FlBits, 4
        inc eax
        .IF eax >= 16
            mov g_zfErr, 1
            ret
        .ENDIF
        mov prec, eax
        invoke FlSigned, 5
        .IF eax & 80000000h
            mov g_zfErr, 1                  ; negative shifts do not occur
            ret
        .ENDIF
        mov shiftv, eax
        mov i, 0
        .WHILE g_zfErr == 0
            mov eax, i
            .BREAK .IF eax >= order
            invoke FlSigned, prec
            mov ecx, i
            mov dword ptr coefs[ecx * 4], eax
            inc i
        .ENDW
        invoke FlResiduals, pBuf, order
        .IF g_zfErr != 0
            ret
        .ENDIF
        mov esi, pBuf
        mov eax, order
        mov i, eax
        .WHILE TRUE
            mov eax, i
            .BREAK .IF eax >= g_flBlk
            ; 64-bit dot product of coefs and history
            push 0
            push 0                          ; [esp] = sum lo, [esp+4] = sum hi
            xor ebx, ebx
            .WHILE ebx < order
                mov eax, i
                sub eax, ebx
                dec eax
                mov eax, dword ptr [esi + eax * 4]
                imul dword ptr coefs[ebx * 4]
                add dword ptr [esp], eax
                adc dword ptr [esp + 4], edx
                inc ebx
            .ENDW
            pop edx
            pop eax
            xchg eax, edx                   ; undo push order: eax = lo, edx = hi
            mov ecx, shiftv
            .IF ecx != 0
                shrd eax, edx, cl
                sar edx, cl
            .ENDIF
            mov ecx, i
            mov edx, dword ptr [esi + ecx * 4]
            add eax, edx
            mov dword ptr [esi + ecx * 4], eax
            inc i
        .ENDW
    .ELSE
        mov g_zfErr, 1
        ret
    .ENDIF
    ; wasted bits shift everything back up
    mov ecx, wasted
    .IF ecx != 0
        mov edi, pBuf
        mov ebx, g_flBlk
        .WHILE ebx != 0
            mov eax, dword ptr [edi]
            shl eax, cl
            mov dword ptr [edi], eax
            add edi, 4
            dec ebx
        .ENDW
    .ENDIF
    ret
FlSubframe ENDP

; One frame: header, two subframes, stereo undo, samples out as 16-bit pairs
FlacFrame PROC USES esi edi ebx swapEnd:DWORD
    LOCAL bsCode:DWORD
    LOCAL srCode:DWORD
    LOCAL sL:DWORD
    LOCAL sR:DWORD
    LOCAL i:DWORD
    invoke FlBits, 16
    mov ecx, eax
    and ecx, 0FFFCh
    .IF ecx != 0FFF8h
        mov g_zfErr, 1
        ret
    .ENDIF
    invoke FlBits, 4
    mov bsCode, eax
    invoke FlBits, 4
    mov srCode, eax
    invoke FlBits, 4
    mov g_flChan, eax
    invoke FlBits, 3
    .IF eax != 4                            ; only 16-bit here
        mov g_zfErr, 1
        ret
    .ENDIF
    invoke FlBits, 1
    ; coded frame number, UTF-8 style
    invoke FlBits, 8
    mov ebx, 0
    .IF eax >= 0F0h
        mov ebx, 3
    .ELSEIF eax >= 0E0h
        mov ebx, 2
    .ELSEIF eax >= 0C0h
        mov ebx, 1
    .ELSEIF eax >= 80h
        mov g_zfErr, 1
        ret
    .ENDIF
    .WHILE ebx != 0
        invoke FlBits, 8
        dec ebx
    .ENDW
    ; block size
    mov eax, bsCode
    .IF eax == 0
        mov g_zfErr, 1
        ret
    .ELSEIF eax == 1
        mov g_flBlk, 192
    .ELSEIF eax <= 5
        mov ecx, eax
        sub ecx, 2
        mov eax, 576
        shl eax, cl
        mov g_flBlk, eax
    .ELSEIF eax == 6
        invoke FlBits, 8
        inc eax
        mov g_flBlk, eax
    .ELSEIF eax == 7
        invoke FlBits, 16
        inc eax
        mov g_flBlk, eax
    .ELSE
        mov ecx, eax
        sub ecx, 8
        mov eax, 256
        shl eax, cl
        mov g_flBlk, eax
    .ENDIF
    .IF g_flBlk > FL_MAXBLK
        mov g_zfErr, 1
        ret
    .ENDIF
    mov eax, srCode
    .IF eax == 12
        invoke FlBits, 8
    .ELSEIF eax == 13 || eax == 14
        invoke FlBits, 16
    .ENDIF
    invoke FlBits, 8                        ; header CRC
    ; channel setup: which side carries the extra bit
    mov eax, g_flChan
    mov ecx, 16
    mov edx, 16
    .IF eax == 1
    .ELSEIF eax == 8 || eax == 10           ; left/side, mid/side: side is channel 1
        inc edx
    .ELSEIF eax == 9                        ; right/side: side is channel 0
        inc ecx
    .ELSE
        mov g_zfErr, 1
        ret
    .ENDIF
    push edx
    invoke FlSubframe, g_flSampL, ecx
    pop edx
    .IF g_zfErr != 0
        ret
    .ENDIF
    invoke FlSubframe, g_flSampR, edx
    .IF g_zfErr != 0
        ret
    .ENDIF
    ; undo decorrelation
    mov esi, g_flSampL
    mov edi, g_flSampR
    mov eax, g_flChan
    .IF eax == 8
        ; right = left - side
        xor ebx, ebx
        .WHILE ebx < g_flBlk
            mov eax, dword ptr [esi + ebx * 4]
            sub eax, dword ptr [edi + ebx * 4]
            mov dword ptr [edi + ebx * 4], eax
            inc ebx
        .ENDW
    .ELSEIF eax == 9
        ; channel 0 held side, channel 1 right: left = right + side
        xor ebx, ebx
        .WHILE ebx < g_flBlk
            mov eax, dword ptr [edi + ebx * 4]
            add dword ptr [esi + ebx * 4], eax
            inc ebx
        .ENDW
    .ELSEIF eax == 10
        ; mid/side
        xor ebx, ebx
        .WHILE ebx < g_flBlk
            mov eax, dword ptr [esi + ebx * 4] ; mid
            mov ecx, dword ptr [edi + ebx * 4] ; side
            shl eax, 1
            mov edx, ecx
            and edx, 1
            or eax, edx
            mov edx, eax
            add edx, ecx
            sar edx, 1
            sub eax, ecx
            sar eax, 1
            mov dword ptr [esi + ebx * 4], edx ; left
            mov dword ptr [edi + ebx * 4], eax ; right
            inc ebx
        .ENDW
    .ENDIF
    ; byte-align, then the frame CRC-16
    mov eax, g_flBitCnt
    and eax, 7
    invoke FlBits, eax
    invoke FlBits, 16
    ; emit interleaved 16-bit pairs
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= g_flBlk
        mov esi, g_flSampL
        mov ecx, dword ptr [esi + eax * 4]
        mov sL, ecx
        mov esi, g_flSampR
        mov ecx, dword ptr [esi + eax * 4]
        mov sR, ecx
        .IF swapEnd != 0
            mov eax, sL
            shr eax, 8
            and eax, 0FFh
            invoke ZfPutB, eax
            mov eax, sL
            and eax, 0FFh
            invoke ZfPutB, eax
            mov eax, sR
            shr eax, 8
            and eax, 0FFh
            invoke ZfPutB, eax
            mov eax, sR
            and eax, 0FFh
            invoke ZfPutB, eax
        .ELSE
            mov eax, sL
            and eax, 0FFh
            invoke ZfPutB, eax
            mov eax, sL
            shr eax, 8
            and eax, 0FFh
            invoke ZfPutB, eax
            mov eax, sR
            and eax, 0FFh
            invoke ZfPutB, eax
            mov eax, sR
            shr eax, 8
            and eax, 0FFh
            invoke ZfPutB, eax
        .ENDIF
        inc i
    .ENDW
    ret
FlacFrame ENDP

; Decode stereo frames until sampPerChan samples per channel came out
FlacDecodeStream PROC USES ebx sampPerChan:DWORD, swapEnd:DWORD
    xor ebx, ebx
    .WHILE ebx < sampPerChan && g_zfErr == 0
        invoke FlacFrame, swapEnd
        add ebx, g_flBlk
    .ENDW
    .IF ebx != sampPerChan
        mov g_zfErr, 1
    .ENDIF
    ret
FlacDecodeStream ENDP


; ---------------------------------------------------------------------------
; UIF (MagicISO): "bbis" footer, a zlib-packed table of blocks, then per block
; raw data, implicit zeros, or a zlib stream, placed by output sector. Blocks
; arrive in disc order in every image seen; anything else is declined, as are
; password-protected images (their headers arrive DES-scrambled).
; ---------------------------------------------------------------------------
UIF_BLKMAX      equ 40000

UifExpandFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL sizeLo:DWORD
    LOCAL sizeHi:DWORD
    LOCAL bbis[64]:BYTE
    LOCAL secSize:DWORD
    LOCAL totLo:DWORD
    LOCAL totHi:DWORD
    LOCAL nBlk:DWORD
    LOCAL pTbl:DWORD
    LOCAL i:DWORD
    LOCAL nextSec:DWORD
    LOCAL outCb:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pTbl, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileSize64, hIn, addr sizeLo, addr sizeHi
    mov eax, sizeLo
    sub eax, 64
    mov ecx, sizeHi
    sbb ecx, 0
    mov totLo, eax
    mov totHi, ecx
    invoke FileReadAt, hIn, totLo, totHi, addr bbis, 64
    .IF eax != 64 || dword ptr bbis[0] != 73696262h     ; "bbis"
        jmp done
    .ENDIF
    mov eax, dword ptr bbis[20]
    mov secSize, eax
    .IF eax < 512 || eax > 2448
        jmp done
    .ENDIF
    mov ecx, dword ptr bbis[16]             ; sector count
    mul ecx
    mov totLo, eax
    mov totHi, edx
    invoke ZfBeginOut, pszDst, hIn, totLo, totHi
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    ; the block table sits zlib-packed behind a small header
    invoke FileReadAt, hIn, dword ptr bbis[28], dword ptr bbis[32], addr bbis, 16
    .IF eax != 16 || dword ptr bbis[0] != 72686C62h     ; "blhr" (a bsdr here means a password)
        jmp done
    .ENDIF
    mov eax, dword ptr bbis[12]
    mov nBlk, eax
    .IF eax == 0 || eax > UIF_BLKMAX
        jmp done
    .ENDIF
    ; the 16-byte header read only touched the front of the buffer, so the
    ; footer's table offset at 28 is still intact
    mov eax, dword ptr bbis[28]
    add eax, 16
    mov ecx, dword ptr bbis[32]
    adc ecx, 0
    invoke ZfSetInput, eax, ecx
    invoke ZfZlibInflate                    ; the table lands at the front of the output buffer
    mov eax, nBlk
    lea eax, [eax + eax * 2]
    shl eax, 3                              ; entries are 24 bytes
    .IF g_zfErr != 0 || eax != g_zfOutPos
        jmp done
    .ENDIF
    push eax
    invoke VfsAlloc, eax
    mov pTbl, eax
    pop ecx
    .IF eax == 0
        jmp done
    .ENDIF
    mov esi, g_zfOut
    mov edi, eax
    rep movsb
    mov g_zfOutPos, 0                       ; nothing was flushed; restart the real output
    ; blocks: offset(8) zsize(4) sector(4) sizeInSectors(4) type(4)
    mov nextSec, 0
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        mov esi, i
        lea esi, [esi + esi * 2]
        shl esi, 3
        add esi, pTbl
        mov eax, dword ptr [esi + 12]       ; output sector
        mov ecx, nextSec
        .IF eax < ecx
            mov g_zfErr, 1                  ; out-of-order images are not handled
            .BREAK
        .ELSEIF eax > ecx
            sub eax, ecx
            mul secSize
            .IF edx != 0
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            invoke ZfPutZeros, eax
        .ENDIF
        mov eax, dword ptr [esi + 16]
        mul secSize
        .IF edx != 0
            mov g_zfErr, 1
            .BREAK
        .ENDIF
        mov outCb, eax
        mov eax, dword ptr [esi + 20]       ; type
        .IF eax == 3                        ; zeros
            invoke ZfPutZeros, outCb
        .ELSE
            push eax
            invoke ZfSetInput, dword ptr [esi], dword ptr [esi + 4]
            pop eax
            .IF eax == 1                    ; stored, zero-padded to full size
                mov ebx, dword ptr [esi + 8]
                .IF ebx > outCb
                    mov g_zfErr, 1
                    .BREAK
                .ENDIF
                invoke ZfRawCopy, ebx
                mov eax, outCb
                sub eax, ebx
                invoke ZfPutZeros, eax
            .ELSEIF eax == 5                ; zlib
                invoke ZfZlibInflate
            .ELSE
                mov g_zfErr, 1
                .BREAK
            .ENDIF
        .ENDIF
        mov eax, dword ptr [esi + 12]
        add eax, dword ptr [esi + 16]
        mov nextSec, eax
        inc i
    .ENDW
    invoke ZfOutFinal
    invoke ZfCheckTotal, totLo, totHi
    mov ok, eax
    invoke ZfExpandFree
done:
    invoke VfsFreeMem, pTbl
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
UifExpandFile ENDP

; ---------------------------------------------------------------------------
; DMG (Apple UDIF): 512-byte big-endian koly trailer names an XML property
; list; every base64 <data> blob that decodes to a "mish" table describes the
; chunks of one partition. Zlib, raw and zero chunks are enough for the
; common UDZO/UDRO images; ADC, bzip2 and lzfse decline.
; ---------------------------------------------------------------------------
DMG_XMLMAX      equ 16 * 1024 * 1024
DMG_MISHMAX     equ 8 * 1024 * 1024

; base64 into pDst (at most cbMax); returns byte count (whitespace tolerated, stops at '<')
DmgB64 PROC USES esi edi ebx pSrc:DWORD, cbSrc:DWORD, pDst:DWORD, cbMax:DWORD
    LOCAL acc:DWORD
    LOCAL nbits:DWORD
    LOCAL pEnd:DWORD
    mov eax, pDst
    add eax, cbMax
    mov pEnd, eax
    mov esi, pSrc
    mov edi, pDst
    mov ebx, cbSrc
    mov acc, 0
    mov nbits, 0
    .WHILE ebx != 0 && edi < pEnd
        movzx eax, byte ptr [esi]
        inc esi
        dec ebx
        .BREAK .IF eax == '<'
        .IF eax >= 'A' && eax <= 'Z'
            sub eax, 'A'
        .ELSEIF eax >= 'a' && eax <= 'z'
            sub eax, 'a' - 26
        .ELSEIF eax >= '0' && eax <= '9'
            add eax, 52 - '0'
        .ELSEIF eax == '+'
            mov eax, 62
        .ELSEIF eax == '/'
            mov eax, 63
        .ELSE
            .CONTINUE                       ; padding, whitespace, anything else
        .ENDIF
        mov ecx, acc
        shl ecx, 6
        or ecx, eax
        mov acc, ecx
        add nbits, 6
        .IF nbits >= 8
            mov ecx, nbits
            sub ecx, 8
            mov nbits, ecx
            mov eax, acc
            shr eax, cl
            mov byte ptr [edi], al
            inc edi
        .ENDIF
    .ENDW
    mov eax, edi
    sub eax, pDst
    ret
DmgB64 ENDP

DmgExpandFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL sizeLo:DWORD
    LOCAL sizeHi:DWORD
    LOCAL koly[64]:BYTE
    LOCAL forkLo:DWORD
    LOCAL forkHi:DWORD
    LOCAL xmlLo:DWORD
    LOCAL xmlHi:DWORD
    LOCAL xmlLen:DWORD
    LOCAL pXml:DWORD
    LOCAL pMish:DWORD
    LOCAL scanPos:DWORD
    LOCAL mishCb:DWORD
    LOCAL nChunks:DWORD
    LOCAL firstLo:DWORD
    LOCAL firstHi:DWORD
    LOCAL i:DWORD
    LOCAL nextLo:DWORD
    LOCAL nextHi:DWORD
    LOCAL secLo:DWORD
    LOCAL secHi:DWORD
    LOCAL cntCb:DWORD
    LOCAL ctype:DWORD
    LOCAL produced:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pXml, 0
    mov pMish, 0
    mov produced, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileSize64, hIn, addr sizeLo, addr sizeHi
    mov eax, sizeLo
    sub eax, 512
    mov ecx, sizeHi
    sbb ecx, 0
    mov xmlLo, eax
    mov xmlHi, ecx
    invoke FileReadAt, hIn, xmlLo, xmlHi, addr koly, 64
    .IF eax != 64 || dword ptr koly[0] != 796C6F6Bh     ; "koly"
        jmp done
    .ENDIF
    invoke BSwap32, dword ptr koly[24]
    mov forkHi, eax
    invoke BSwap32, dword ptr koly[28]
    mov forkLo, eax
    ; xml offset and length live at 216 within the trailer
    mov eax, xmlLo
    add eax, 216
    mov ecx, xmlHi
    adc ecx, 0
    mov xmlLo, eax
    mov xmlHi, ecx
    invoke FileReadAt, hIn, xmlLo, xmlHi, addr koly, 16
    .IF eax != 16
        jmp done
    .ENDIF
    invoke BSwap32, dword ptr koly[0]
    mov xmlHi, eax
    invoke BSwap32, dword ptr koly[4]
    mov xmlLo, eax
    invoke BSwap32, dword ptr koly[8]
    .IF eax != 0
        jmp done
    .ENDIF
    invoke BSwap32, dword ptr koly[12]
    mov xmlLen, eax
    .IF eax == 0 || eax > DMG_XMLMAX
        jmp done
    .ENDIF
    invoke VfsAlloc, xmlLen
    mov pXml, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke FileReadAt, hIn, xmlLo, xmlHi, pXml, xmlLen
    .IF eax != xmlLen
        jmp done
    .ENDIF
    invoke VfsAlloc, DMG_MISHMAX
    mov pMish, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke ZfBeginOut, pszDst, hIn, 0, 0
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    mov nextLo, 0
    mov nextHi, 0
    ; every <data> blob that decodes to a mish table is one partition's chunks
    mov scanPos, 0
    .WHILE g_zfErr == 0
        mov eax, scanPos
        mov ecx, xmlLen
        sub ecx, 6
        .BREAK .IF eax >= ecx
        mov esi, pXml
        add esi, eax
        .IF dword ptr [esi] == 7461643Ch && word ptr [esi + 4] == 3E61h     ; "<data>"
            add eax, 6
            mov scanPos, eax
            mov esi, pXml
            add esi, eax
            mov ecx, xmlLen
            sub ecx, eax
            invoke DmgB64, esi, ecx, pMish, DMG_MISHMAX
            mov mishCb, eax
            .IF eax >= 204
                mov esi, pMish
                .IF dword ptr [esi] == 6873696Dh    ; "mish"
                    invoke BSwap32, dword ptr [esi + 8]
                    mov firstHi, eax
                    invoke BSwap32, dword ptr [esi + 12]
                    mov firstLo, eax
                    invoke BSwap32, dword ptr [esi + 200]
                    mov nChunks, eax
                    mov ecx, eax
                    shl ecx, 5
                    lea ecx, [ecx + eax * 8]        ; chunks * 40
                    add ecx, 204
                    .IF ecx > mishCb
                        mov g_zfErr, 1
                        .BREAK
                    .ENDIF
                    mov i, 0
                    .WHILE g_zfErr == 0
                        mov eax, i
                        .BREAK .IF eax >= nChunks
                        mov esi, pMish
                        mov ecx, eax
                        shl ecx, 5
                        lea ecx, [ecx + eax * 8]
                        lea esi, [esi + ecx + 204]
                        invoke BSwap32, dword ptr [esi]
                        mov ctype, eax
                        .BREAK .IF eax == 0FFFFFFFFh        ; terminator
                        .IF eax == 7FFFFFFEh                ; comment
                            inc i
                            .CONTINUE
                        .ENDIF
                        ; absolute output sector = partition first + chunk sector
                        invoke BSwap32, dword ptr [esi + 8]
                        mov secHi, eax
                        invoke BSwap32, dword ptr [esi + 12]
                        mov secLo, eax
                        mov eax, secLo
                        add eax, firstLo
                        mov secLo, eax
                        mov eax, secHi
                        adc eax, firstHi
                        mov secHi, eax
                        ; catch up with zeros when the chunk starts further out
                        mov eax, secLo
                        sub eax, nextLo
                        mov ecx, secHi
                        sbb ecx, nextHi
                        .IF ecx != 0 && ecx != 0FFFFFFFFh
                            mov g_zfErr, 1
                            .BREAK
                        .ENDIF
                        .IF ecx == 0FFFFFFFFh || (ecx == 0 && eax & 80000000h)
                            mov g_zfErr, 1                  ; overlapping chunks
                            .BREAK
                        .ENDIF
                        .IF eax != 0
                            shl eax, 9
                            invoke ZfPutZeros, eax
                        .ENDIF
                        invoke BSwap32, dword ptr [esi + 20]
                        shl eax, 9                          ; sectors to bytes
                        mov cntCb, eax
                        invoke BSwap32, dword ptr [esi + 16]
                        .IF eax != 0
                            mov g_zfErr, 1
                            .BREAK
                        .ENDIF
                        mov eax, ctype
                        .IF eax == 0 || eax == 2            ; zero fill / ignore
                            invoke ZfPutZeros, cntCb
                        .ELSE
                            ; chunk data lives in the data fork
                            invoke BSwap32, dword ptr [esi + 24]
                            mov edx, eax
                            invoke BSwap32, dword ptr [esi + 28]
                            add eax, forkLo
                            adc edx, forkHi
                            invoke ZfSetInput, eax, edx
                            mov eax, ctype
                            .IF eax == 1                    ; raw
                                invoke ZfRawCopy, cntCb
                            .ELSEIF eax == 80000005h        ; zlib
                                invoke ZfZlibInflate
                            .ELSE                           ; ADC, bzip2, lzfse
                                mov g_zfErr, 1
                                .BREAK
                            .ENDIF
                        .ENDIF
                        mov eax, cntCb
                        shr eax, 9
                        add nextLo, eax
                        adc nextHi, 0
                        mov produced, 1
                        inc i
                    .ENDW
                .ENDIF
            .ENDIF
        .ELSE
            inc scanPos
        .ENDIF
    .ENDW
    invoke ZfOutFinal
    .IF g_zfErr == 0 && produced != 0
        mov ok, TRUE
    .ENDIF
    invoke ZfExpandFree
done:
    invoke VfsFreeMem, pXml
    invoke VfsFreeMem, pMish
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
DmgExpandFile ENDP

; ---------------------------------------------------------------------------
; bzip2 (.bz2): one stream, whole file, the sibling of the gzip path
; ---------------------------------------------------------------------------
; The stream carries no uncompressed size, so the output cannot be reserved
; up front the way the indexed containers do.
BzExpandFile PROC USES ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke ZfBeginOut, pszDst, hIn, 0, 0
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    invoke ZfSetInput, 0, 0
    invoke BzDecodeStream
    .IF eax == 0
        jmp done
    .ENDIF
    invoke ZfOutFinal
    .IF g_zfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke ZfExpandFree
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
BzExpandFile ENDP

; ---------------------------------------------------------------------------
; PBP (PSP EBOOT): a PlayStation disc inside DATA.PSAR
; ---------------------------------------------------------------------------
; A PBP header is eight file offsets; only DATA.PSAR at 0x24 matters here. Sony's
; PSP UMD dumps put an AES-encrypted NPUMDIMG there and are declined - what this
; reads is the PS1 Classics layout, PSISOIMG0000, which is plain zlib.
;
; Inside one disc image: 32-byte index entries at 0x4000 give an offset and a
; compressed length, and the data they point into begins at 0x100000. Each entry
; covers sixteen raw 2352-byte sectors; a length equal to that full block means
; the block was stored rather than deflated. The result is a raw MODE2/2352
; image, which the sector sniffer then opens like any other raw dump.
;
; Multi-disc EBOOTs wrap the discs in PSTITLEIMG000000 and list five disc
; offsets at 0x200. Only the first is taken, matching how the .mds and .b6t
; readers here take the first data track.
PBP_MAGIC       equ 50425000h           ; 00 'P' 'B' 'P'
PBP_IDX_OFF     equ 4000h
PBP_ISO_OFF     equ 100000h
PBP_IDX_CB      equ PBP_ISO_OFF - PBP_IDX_OFF
PBP_BLOCK       equ 16 * 930h           ; sixteen raw sectors, 0x9300
PBP_MAXIDX      equ PBP_IDX_CB / 32

; One index entry: seek to its data and append that block to the output.
PbpBlock PROC USES esi pIdx:DWORD, disc:DWORD, idx:DWORD
    LOCAL offLo:DWORD
    LOCAL offHi:DWORD
    mov esi, idx
    shl esi, 5
    add esi, pIdx
    mov eax, dword ptr [esi]                ; offset from the start of the ISO data
    add eax, disc
    mov edx, 0
    adc edx, 0
    add eax, PBP_ISO_OFF
    adc edx, 0
    mov offLo, eax
    mov offHi, edx
    invoke ZfSetInput, offLo, offHi
    mov eax, dword ptr [esi + 4]            ; compressed length
    .IF eax == PBP_BLOCK
        invoke ZfRawCopy, PBP_BLOCK
    .ELSE
        invoke ZfSmartInflate
    .ENDIF
    ret
PbpBlock ENDP

PbpExpandFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[40]:BYTE
    LOCAL pos[5]:DWORD
    LOCAL psar:DWORD
    LOCAL disc:DWORD
    LOCAL pIdx:DWORD
    LOCAL nBlk:DWORD
    LOCAL i:DWORD
    LOCAL totLo:DWORD
    LOCAL totHi:DWORD
    LOCAL capLo:DWORD
    LOCAL capHi:DWORD
    LOCAL tmp:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pIdx, 0
    invoke FileOpenReadSeq, pszSrc
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileReadAt, hIn, 0, 0, addr hdr, 40
    .IF eax != 40 || dword ptr hdr[0] != PBP_MAGIC
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[36]              ; 0x24: offset of DATA.PSAR
    .IF eax == 0
        jmp done
    .ENDIF
    mov psar, eax
    mov disc, eax

    invoke FileReadAt, hIn, disc, 0, addr hdr, 16
    .IF eax != 16
        jmp done
    .ENDIF
    .IF dword ptr hdr[0] != 53495350h || dword ptr hdr[4] != 474D494Fh || dword ptr hdr[8] != 30303030h
        ; not "PSISOIMG0000" - the only other layout worth trying is the
        ; multi-disc wrapper; an encrypted NPUMDIMG stops here
        .IF dword ptr hdr[0] != 49545350h || dword ptr hdr[4] != 49454C54h || dword ptr hdr[8] != 3030474Dh || dword ptr hdr[12] != 30303030h
            jmp done
        .ENDIF
        mov eax, psar
        add eax, 200h
        mov tmp, eax
        invoke FileReadAt, hIn, tmp, 0, addr pos, 20
        .IF eax != 20
            jmp done
        .ENDIF
        xor ebx, ebx
        .WHILE ebx < 5
            mov eax, dword ptr pos[ebx * 4]
            .BREAK .IF eax != 0
            inc ebx
        .ENDW
        .IF ebx >= 5
            jmp done
        .ENDIF
        mov ecx, psar
        add eax, ecx
        mov disc, eax
        invoke FileReadAt, hIn, disc, 0, addr hdr, 16
        .IF eax != 16
            jmp done
        .ENDIF
        .IF dword ptr hdr[0] != 53495350h || dword ptr hdr[4] != 474D494Fh || dword ptr hdr[8] != 30303030h
            jmp done
        .ENDIF
    .ENDIF

    ; The index region always ends where the data begins, so a whole-region read
    ; is in range for any file that got this far.
    invoke VfsAlloc, PBP_IDX_CB
    mov pIdx, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov eax, disc
    add eax, PBP_IDX_OFF
    mov tmp, eax
    invoke FileReadAt, hIn, tmp, 0, pIdx, PBP_IDX_CB
    .IF eax != PBP_IDX_CB
        jmp done
    .ENDIF
    xor ebx, ebx
    mov esi, pIdx
    .WHILE ebx < PBP_MAXIDX
        mov eax, dword ptr [esi]
        or eax, dword ptr [esi + 4]
        .BREAK .IF eax == 0                 ; the table is zero-filled past the last block
        add esi, 32
        inc ebx
    .ENDW
    mov nBlk, ebx
    .IF ebx == 0
        jmp done
    .ENDIF
    mov eax, ebx
    mov ecx, PBP_BLOCK
    mul ecx
    mov capLo, eax
    mov capHi, edx                          ; everything the index can possibly hold

    invoke ZfBeginOut, pszDst, hIn, 0, 0
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax

    ; The last block is padded, so take the real length from the volume itself.
    ; Block 1 covers sectors 16-31, so the primary descriptor sits at its front:
    ; 24 bytes of raw sector header, then the volume space size at 80.
    mov eax, capLo
    mov totLo, eax
    mov eax, capHi
    mov totHi, eax
    .IF nBlk > 1
        invoke PbpBlock, pIdx, disc, 1
        .IF g_zfErr == 0 && g_zfOutPos >= 108
            mov esi, g_zfOut
            mov eax, dword ptr [esi + 104]
            mov ecx, 930h
            mul ecx
            or eax, eax
            jnz pbp_haveLo
            or edx, edx
            jz pbp_keepCap
pbp_haveLo:
            cmp edx, capHi                  ; a size past the blocks we hold is junk
            ja pbp_keepCap
            jb pbp_takeIt
            cmp eax, capLo
            ja pbp_keepCap
pbp_takeIt:
            mov totLo, eax
            mov totHi, edx
pbp_keepCap:
        .ENDIF
        mov g_zfOutPos, 0                   ; discard the probe; nothing was flushed
        mov g_zfErr, 0
    .ENDIF
    invoke FilePresize, hOut, totLo, totHi

    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        invoke PbpBlock, pIdx, disc, i
        inc i
    .ENDW
    .IF g_zfErr != 0
        jmp done
    .ENDIF
    invoke ZfOutFinal
    .IF g_zfErr != 0
        jmp done
    .ENDIF
    ; drop the padding the final block carried past the end of the volume
    invoke SetFilePointerEx, hOut, totLo, totHi, NULL, FILE_BEGIN
    .IF eax != 0
        invoke SetEndOfFile, hOut
    .ENDIF
    mov ok, TRUE
done:
    invoke ZfExpandFree
    invoke VfsFreeMem, pIdx
    invoke ZfClosePair, ok, hIn, hOut, pszDst
    ret
PbpExpandFile ENDP

END
