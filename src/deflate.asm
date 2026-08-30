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
ZF_KEEP         equ 32768               ; window bytes kept across flushes
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

.code

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
ZfBits PROC USES ebx n:DWORD
    .WHILE TRUE
        mov eax, g_zfBitCnt
        .BREAK .IF eax >= n
        invoke ZfInByte
        mov ecx, g_zfBitCnt
        shl eax, cl
        or g_zfBitBuf, eax
        add g_zfBitCnt, 8
    .ENDW
    mov ecx, n
    mov ebx, g_zfBitBuf
    mov eax, ebx
    mov edx, 1
    shl edx, cl
    dec edx
    and eax, edx
    shr ebx, cl
    mov g_zfBitBuf, ebx
    sub g_zfBitCnt, ecx
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
ZfBuild PROC USES esi edi ebx pCnt:DWORD, pSym:DWORD, pLens:DWORD, n:DWORD
    LOCAL offs[16]:WORD
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
    xor eax, eax
    ret
ZfBuild ENDP

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

; ---------------------------------------------------------------------------
; Block types
; ---------------------------------------------------------------------------
; The literal/length/distance loop shared by fixed and dynamic blocks
ZfCodes PROC USES esi edi ebx pLC:DWORD, pLS:DWORD, pDC:DWORD, pDS:DWORD
    LOCAL mlen:DWORD
    LOCAL mdist:DWORD
    .WHILE g_zfErr == 0
        invoke ZfDecode, pLC, pLS
        .IF eax < 256
            invoke ZfPutB, eax
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
            invoke ZfDecode, pDC, pDS
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
    mov ebx, lenv
    .WHILE ebx != 0 && g_zfErr == 0
        invoke ZfBits, 8
        invoke ZfPutB, eax
        dec ebx
    .ENDW
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
    invoke ZfBuild, offset g_zfFixLC, offset g_zfFixLS, offset g_zfLens, 288
    mov edi, offset g_zfLens
    mov al, 5
    mov ecx, 30
    rep stosb
    invoke ZfBuild, offset g_zfFixDC, offset g_zfFixDS, offset g_zfLens, 30
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
    invoke ZfBuild, offset g_zfDC, offset g_zfDS, offset g_zfLens, 19
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
    invoke ZfBuild, offset g_zfLC, offset g_zfLS, offset g_zfLens, hlit
    .IF eax != 0
        mov g_zfErr, 1
        ret
    .ENDIF
    mov eax, offset g_zfLens
    add eax, hlit
    invoke ZfBuild, offset g_zfDC, offset g_zfDS, eax, hdist
    .IF eax != 0
        mov g_zfErr, 1
        ret
    .ENDIF
    invoke ZfCodes, offset g_zfLC, offset g_zfLS, offset g_zfDC, offset g_zfDS
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
            invoke ZfCodes, offset g_zfFixLC, offset g_zfFixLS, offset g_zfFixDC, offset g_zfFixDS
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
    invoke ZfSetInput, 0, 0
    mov eax, TRUE
    ret
ZfExpandInit ENDP

ZfExpandFree PROC
    invoke VfsFreeMem, g_zfIn
    invoke VfsFreeMem, g_zfOut
    mov g_zfIn, 0
    mov g_zfOut, 0
    ret
ZfExpandFree ENDP

; ---------------------------------------------------------------------------
; gzip (RFC 1952): header, one deflate stream, CRC-32 + size trailer
; ---------------------------------------------------------------------------
GzExpandFile PROC USES ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL flg:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    invoke CreateFileW, pszSrc, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
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
    invoke CloseHandle, hIn
    invoke CloseHandle, hOut
    .IF ok == 0
        invoke DeleteFileW, pszDst
    .ENDIF
    mov eax, ok
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
    invoke CreateFileW, pszSrc, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
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
    invoke CreateFileW, pszDst, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        jmp close_in
    .ENDIF
    mov hOut, eax
    invoke ZfExpandInit, hIn, hOut
    .IF eax == 0
        jmp close_in
    .ENDIF
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
    invoke CloseHandle, hIn
    .IF hOut != INVALID_HANDLE_VALUE
        invoke CloseHandle, hOut
        .IF ok == 0
            invoke DeleteFileW, pszDst
        .ENDIF
    .ENDIF
    mov eax, ok
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
    LOCAL offLo:DWORD
    LOCAL offHi:DWORD
    LOCAL ok:DWORD

    mov ok, FALSE
    mov hOut, INVALID_HANDLE_VALUE
    mov pIdx, 0
    invoke CreateFileW, pszSrc, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hIn, eax
    invoke FileReadAt, hIn, 0, 0, addr hdr, 24
    .IF eax != 24 || dword ptr hdr[0] != 4F534943h      ; "CISO"
        jmp done
    .ENDIF
    movzx eax, byte ptr hdr[20]
    .IF eax > 1                             ; v2 changes the index semantics
        jmp done
    .ENDIF
    mov eax, dword ptr hdr[16]
    mov blkSize, eax
    .IF eax < 512 || eax > 1024 * 1024
        jmp done
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
    invoke CreateFileW, pszDst, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        jmp done
    .ENDIF
    mov hOut, eax
    invoke ZfExpandInit, hIn, hOut
    .IF eax == 0
        jmp done
    .ENDIF
    mov i, 0
    .WHILE g_zfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        mov ecx, pIdx
        mov eax, dword ptr [ecx + eax * 4]
        mov e0, eax
        and eax, 7FFFFFFFh
        mov ecx, alignSh
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
        mov eax, e0
        .IF eax & 80000000h
            invoke ZfRawCopy, thisCb
        .ELSE
            invoke ZfInflate
        .ENDIF
        mov eax, thisCb
        sub remLo, eax
        sbb remHi, 0
        inc i
    .ENDW
    invoke ZfOutFinal
    ; success when everything the header promised came out
    .IF g_zfErr == 0
        mov eax, g_zfTotHi
        .IF eax > totHi
            mov ok, TRUE
        .ELSEIF eax == totHi
            mov eax, g_zfTotLo
            .IF eax >= totLo
                mov ok, TRUE
            .ENDIF
        .ENDIF
    .ENDIF
    invoke ZfExpandFree
done:
    invoke VfsFreeMem, pIdx
    invoke CloseHandle, hIn
    .IF hOut != INVALID_HANDLE_VALUE
        invoke CloseHandle, hOut
        .IF ok == 0
            invoke DeleteFileW, pszDst
        .ENDIF
    .ENDIF
    mov eax, ok
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

; hash of the 3 bytes at pos, in eax; only valid when pos + 2 < chunk length
DfHashAt PROC pos:DWORD
    mov ecx, g_dfChunkPtr
    add ecx, pos
    movzx eax, byte ptr [ecx]
    shl eax, 10
    movzx edx, byte ptr [ecx + 1]
    shl edx, 5
    xor eax, edx
    movzx edx, byte ptr [ecx + 2]
    xor eax, edx
    and eax, DF_HASHSZ - 1
    ret
DfHashAt ENDP

DfInsert PROC pos:DWORD
    mov eax, pos
    add eax, 2
    .IF eax >= g_dfChunkLen
        ret
    .ENDIF
    invoke DfHashAt, pos
    mov ecx, g_dfHead
    mov edx, dword ptr [ecx + eax * 4]
    push edx
    mov edx, pos
    inc edx
    mov dword ptr [ecx + eax * 4], edx
    pop edx
    mov ecx, g_dfPrev
    mov eax, pos
    mov dword ptr [ecx + eax * 4], edx
    ret
DfInsert ENDP

; longest match at pos; length in eax (0 when none), distance in g_dfMDist
DfLongestMatch PROC USES esi edi ebx pos:DWORD
    LOCAL best:DWORD
    LOCAL maxLen:DWORD
    LOCAL cand:DWORD
    LOCAL depth:DWORD
    mov best, 0
    mov g_dfMDist, 0
    mov eax, g_dfChunkLen
    sub eax, pos
    .IF eax > DF_MAXMATCH
        mov eax, DF_MAXMATCH
    .ENDIF
    mov maxLen, eax
    .IF eax < 3
        xor eax, eax
        ret
    .ENDIF
    invoke DfHashAt, pos
    mov ecx, g_dfHead
    mov eax, dword ptr [ecx + eax * 4]
    mov cand, eax
    mov depth, DF_DEPTH
    .WHILE cand != 0 && depth != 0
        mov ebx, cand
        dec ebx                             ; candidate position
        mov eax, pos
        sub eax, ebx
        .BREAK .IF eax > DF_MAXDIST
        ; compare
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
DfLongestMatch ENDP

; one chunk as one fixed-Huffman block
DfCompressChunk PROC USES esi edi ebx last:DWORD
    LOCAL pos:DWORD
    LOCAL mlen:DWORD
    mov edi, g_dfHead
    xor eax, eax
    mov ecx, DF_HASHSZ
    rep stosd
    ; 3-bit block header: BFINAL then BTYPE = 01
    mov eax, last
    and eax, 1
    or eax, 2
    invoke DfEmit, eax, 3
    mov pos, 0
    .WHILE g_dfErr == 0
        mov eax, pos
        .BREAK .IF eax >= g_dfChunkLen
        invoke DfLongestMatch, pos
        mov mlen, eax
        mov ecx, g_dfMDist
        .IF eax > 3 || (eax == 3 && ecx <= 4096)
            invoke DfPutMatch, mlen, g_dfMDist
            mov eax, pos
            add eax, mlen
            mov ebx, pos
            .WHILE ebx < eax
                push eax
                invoke DfInsert, ebx
                pop eax
                inc ebx
            .ENDW
            mov pos, eax
        .ELSE
            mov ecx, g_dfChunkPtr
            mov eax, pos
            movzx eax, byte ptr [ecx + eax]
            invoke DfPutLit, eax
            invoke DfInsert, pos
            inc pos
        .ENDIF
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
    invoke CreateFileW, pszSrc, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
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

END
