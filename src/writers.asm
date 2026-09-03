; FoxImg - writers for the deflate-based block containers: ISZ, DAX, JSO, GCZ,
; UIF, DAA and DMG. Each one walks the finished image in blocks, deflates every
; block into the compressor's buffer through DfBlockDeflate, and lays the
; container's own header, index and trailer around the results. The layouts
; come from the matching readers in deflate.asm, which are the spec for what
; this program accepts; each writer's output goes back through that reader
; and through an independent Python parser in build\zwriters.py.
;
; Sizes that a format keeps in 32 bits (DAX, JSO) bound the image at 4 GB;
; the writer declines anything larger rather than wrap.
include foximg.inc

WR_ISZ_BLOCK    equ 65536
WR_DAX_FRAME    equ 8192
WR_JSO_BLOCK    equ 2048
WR_GCZ_BLOCK    equ 32768
WR_UIF_SECTORS  equ 8                   ; 16 KB blocks of 2048-byte sectors
WR_DAA_CHUNK    equ 16384
WR_DMG_CHUNK    equ 524288              ; one mish entry per chunk; 512-byte sectors; under DF_OUTBUF with room to expand

.data
szDmgXmlHead    db '<?xml version="1.0" encoding="UTF-8"?>', 10
                db '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">', 10
                db '<plist version="1.0">', 10, '<dict>', 10, 9, '<key>resource-fork</key>', 10, 9, '<dict>', 10, 9, 9, '<key>blkx</key>', 10, 9, 9, '<array>', 10, 9, 9, 9, '<dict>', 10
                db 9, 9, 9, 9, '<key>Attributes</key>', 10, 9, 9, 9, 9, '<string>0x0050</string>', 10
                db 9, 9, 9, 9, '<key>CFName</key>', 10, 9, 9, 9, 9, '<string>whole disk (unknown partition : 0)</string>', 10
                db 9, 9, 9, 9, '<key>Data</key>', 10, 9, 9, 9, 9, '<data>', 13, 10, 0
szDmgXmlTail    db 9, 9, 9, 9, '</data>', 10, 9, 9, 9, 9, '<key>ID</key>', 10, 9, 9, 9, 9, '<string>-1</string>', 10
                db 9, 9, 9, 9, '<key>Name</key>', 10, 9, 9, 9, 9, '<string>whole disk (unknown partition : 0)</string>', 10
                db 9, 9, 9, '</dict>', 10, 9, 9, '</array>', 10, 9, '</dict>', 10, '</dict>', 10, '</plist>', 10, 0

.code

; ---------------------------------------------------------------------------
; Shared: a session, a block read, a 64-bit counter
; ---------------------------------------------------------------------------
; Open both files and set the compressor up; hIn in eax, hOut in edx, or 0
WrBegin PROC pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    invoke DfOpenPair, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    invoke DfSetup, hOut
    .IF eax == 0
        invoke DfClosePair, 0, hIn, hOut, pszDst
        xor eax, eax
        ret
    .ENDIF
    invoke FileSize64, hIn, offset g_dfSizeLo, offset g_dfSizeHi
    mov eax, g_dfSizeLo
    mov g_progTotal, eax
    mov eax, g_dfSizeHi
    mov g_progTotalHi, eax
    mov g_progDone, 0
    mov g_progDoneHi, 0
    mov edx, hOut
    mov eax, hIn
    ret
WrBegin ENDP

; Tear the session down and close; returns ok
WrEnd PROC okv:DWORD, hIn:DWORD, hOut:DWORD, pszDst:DWORD
    invoke DfTeardown
    invoke DfClosePair, okv, hIn, hOut, pszDst
    ret
WrEnd ENDP

; Read the next block of the image into the compressor's chunk buffer; bytes
; read in eax (0 at the end), progress and Cancel handled. pOff is a qword.
WrReadBlock PROC hIn:DWORD, pOff:DWORD, cb:DWORD
    LOCAL n:DWORD
    mov ecx, pOff
    invoke FileReadAt, hIn, dword ptr [ecx], dword ptr [ecx + 4], g_dfChunkPtr, cb
    mov n, eax
    mov ecx, pOff
    add dword ptr [ecx], eax
    adc dword ptr [ecx + 4], 0
    add g_progDone, eax
    adc g_progDoneHi, 0
    .IF g_jobCancel != 0
        mov g_dfErr, 1
        xor eax, eax
        ret
    .ENDIF
    mov eax, n
    ret
WrReadBlock ENDP

; TRUE when the chunk buffer's first cb bytes are all zero
WrIsZero PROC USES edi cb:DWORD
    mov edi, g_dfChunkPtr
    mov ecx, cb
    shr ecx, 2
    xor eax, eax
    repe scasd
    .IF !ZERO?
        xor eax, eax
        ret
    .ENDIF
    mov ecx, cb
    and ecx, 3
    repe scasb
    .IF !ZERO?
        xor eax, eax
        ret
    .ENDIF
    mov eax, TRUE
    ret
WrIsZero ENDP

; ---------------------------------------------------------------------------
; ISZ (UltraISO): 48-byte header, 3-byte chunk pointers (type in the top two
; bits: 0 zeros, 1 raw, 2 zlib), then the chunks
; ---------------------------------------------------------------------------
IszCompressFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[48]:BYTE
    LOCAL off[2]:DWORD
    LOCAL nBlk:DWORD
    LOCAL pIdx:DWORD
    LOCAL idxCb:DWORD
    LOCAL i:DWORD
    LOCAL n:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    mov pIdx, 0
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    ; total must be whole 2048-byte sectors; blocks = ceil(total / 64 KB)
    mov eax, g_dfSizeLo
    test eax, 2047
    jnz done
    mov edx, g_dfSizeHi
    add eax, WR_ISZ_BLOCK - 1
    adc edx, 0
    shrd eax, edx, 16
    shr edx, 16
    .IF edx != 0 || eax == 0
        jmp done
    .ENDIF
    mov nBlk, eax
    lea eax, [eax + eax * 2]
    mov idxCb, eax
    invoke VfsAlloc, eax
    mov pIdx, eax
    .IF eax == 0
        jmp done
    .ENDIF
    lea edi, hdr
    xor eax, eax
    mov ecx, 12
    rep stosd
    lea edi, hdr
    mov dword ptr [edi], 215A7349h          ; "IsZ!"
    mov byte ptr [edi + 4], 48
    mov byte ptr [edi + 5], 1
    mov dword ptr [edi + 6], 1234h          ; volume serial
    mov word ptr [edi + 10], 2048
    mov eax, g_dfSizeLo
    mov edx, g_dfSizeHi
    shrd eax, edx, 11
    mov dword ptr [edi + 12], eax           ; total sectors
    mov eax, nBlk
    mov dword ptr [edi + 25], eax
    mov dword ptr [edi + 29], WR_ISZ_BLOCK
    mov byte ptr [edi + 33], 3              ; pointer length
    mov dword ptr [edi + 35], 48            ; pointer table offset
    mov eax, idxCb
    add eax, 48
    mov dword ptr [edi + 43], eax           ; data offset
    invoke DfWriteRaw, edi, 48
    invoke DfWriteRaw, pIdx, idxCb          ; placeholder, rewritten at the end
    mov off[0], 0
    mov off[4], 0
    mov i, 0
    .WHILE g_dfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        invoke WrReadBlock, hIn, addr off, WR_ISZ_BLOCK
        mov n, eax
        .BREAK .IF eax == 0
        invoke WrIsZero, n
        .IF eax != 0
            xor eax, eax                    ; type 0, length 0
        .ELSE
            invoke DfBlockDeflate, n, 1
            .IF eax < n
                mov n, eax
                invoke DfWriteRaw, g_dfOut, n
                mov eax, n
                or eax, 2 shl 22            ; zlib
            .ELSE
                invoke DfWriteRaw, g_dfChunkPtr, n
                mov eax, n
                or eax, 1 shl 22            ; raw
            .ENDIF
        .ENDIF
        mov esi, pIdx
        mov ecx, i
        lea ecx, [ecx + ecx * 2]
        mov byte ptr [esi + ecx], al
        shr eax, 8
        mov byte ptr [esi + ecx + 1], al
        shr eax, 8
        mov byte ptr [esi + ecx + 2], al
        inc i
    .ENDW
    .IF g_dfErr != 0
        jmp done
    .ENDIF
    invoke SetFilePointerEx, hOut, 48, 0, NULL, FILE_BEGIN
    invoke DfWriteRaw, pIdx, idxCb
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke VfsFreeMem, pIdx
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
IszCompressFile ENDP

; ---------------------------------------------------------------------------
; DAX (PSP): 32-byte header, frame offsets (u32) and sizes (u16), zlib frames
; of 8 KB; no NC areas. Sizes are 32-bit, so the image stops at 4 GB.
; ---------------------------------------------------------------------------
DaxCompressFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[32]:BYTE
    LOCAL off[2]:DWORD
    LOCAL nFrames:DWORD
    LOCAL pTbl:DWORD
    LOCAL tblCb:DWORD
    LOCAL pos:DWORD
    LOCAL i:DWORD
    LOCAL n:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    mov pTbl, 0
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    .IF g_dfSizeHi != 0 || g_dfSizeLo == 0
        jmp done
    .ENDIF
    mov eax, g_dfSizeLo
    add eax, WR_DAX_FRAME - 1
    shr eax, 13
    mov nFrames, eax
    lea eax, [eax + eax * 2]
    shl eax, 1                              ; 6 bytes per frame
    mov tblCb, eax
    invoke VfsAlloc, eax
    mov pTbl, eax
    .IF eax == 0
        jmp done
    .ENDIF
    lea edi, hdr
    xor eax, eax
    mov ecx, 8
    rep stosd
    lea edi, hdr
    mov dword ptr [edi], 00584144h          ; "DAX", 0
    mov eax, g_dfSizeLo
    mov dword ptr [edi + 4], eax
    invoke DfWriteRaw, edi, 32
    invoke DfWriteRaw, pTbl, tblCb
    mov eax, tblCb
    add eax, 32
    mov pos, eax
    mov off[0], 0
    mov off[4], 0
    mov i, 0
    .WHILE g_dfErr == 0
        mov eax, i
        .BREAK .IF eax >= nFrames
        invoke WrReadBlock, hIn, addr off, WR_DAX_FRAME
        mov n, eax
        .BREAK .IF eax == 0
        invoke DfBlockDeflate, n, 1
        mov n, eax
        .IF eax > 0FFFFh
            mov g_dfErr, 1                  ; a frame size has to fit its 16-bit slot
            .BREAK
        .ENDIF
        invoke DfWriteRaw, g_dfOut, n
        mov esi, pTbl
        mov ecx, i
        mov eax, pos
        mov dword ptr [esi + ecx * 4], eax
        mov eax, nFrames
        shl eax, 2
        add esi, eax
        mov eax, n
        mov word ptr [esi + ecx * 2], ax
        add pos, eax
        inc i
    .ENDW
    .IF g_dfErr != 0
        jmp done
    .ENDIF
    invoke SetFilePointerEx, hOut, 32, 0, NULL, FILE_BEGIN
    invoke DfWriteRaw, pTbl, tblCb
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke VfsFreeMem, pTbl
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
DaxCompressFile ENDP

; ---------------------------------------------------------------------------
; JSO (PSP): 48-byte header, absolute block offsets (u32, one more than the
; blocks), raw deflate blocks, stored when deflate would not shrink one
; ---------------------------------------------------------------------------
JsoCompressFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[48]:BYTE
    LOCAL off[2]:DWORD
    LOCAL nBlk:DWORD
    LOCAL pIdx:DWORD
    LOCAL idxCb:DWORD
    LOCAL pos:DWORD
    LOCAL i:DWORD
    LOCAL n:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    mov pIdx, 0
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    .IF g_dfSizeHi != 0 || g_dfSizeLo == 0
        jmp done
    .ENDIF
    mov eax, g_dfSizeLo
    add eax, WR_JSO_BLOCK - 1
    shr eax, 11
    mov nBlk, eax
    inc eax
    shl eax, 2
    mov idxCb, eax
    invoke VfsAlloc, eax
    mov pIdx, eax
    .IF eax == 0
        jmp done
    .ENDIF
    lea edi, hdr
    xor eax, eax
    mov ecx, 12
    rep stosd
    lea edi, hdr
    mov dword ptr [edi], 4F53494Ah          ; "JISO"
    mov byte ptr [edi + 4], 3
    mov byte ptr [edi + 5], 1
    mov word ptr [edi + 6], WR_JSO_BLOCK
    mov byte ptr [edi + 8], 0               ; no per-block headers
    mov byte ptr [edi + 10], 1              ; deflate
    mov eax, g_dfSizeLo
    mov dword ptr [edi + 12], eax
    mov dword ptr [edi + 32], 48
    invoke DfWriteRaw, edi, 48
    invoke DfWriteRaw, pIdx, idxCb
    mov eax, idxCb
    add eax, 48
    mov pos, eax
    mov off[0], 0
    mov off[4], 0
    mov i, 0
    .WHILE g_dfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        mov esi, pIdx
        mov ecx, i
        mov eax, pos
        mov dword ptr [esi + ecx * 4], eax
        invoke WrReadBlock, hIn, addr off, WR_JSO_BLOCK
        mov n, eax
        .BREAK .IF eax == 0
        invoke DfBlockDeflate, n, 0
        .IF eax < n && eax < WR_JSO_BLOCK
            mov n, eax
            invoke DfWriteRaw, g_dfOut, n
            mov eax, n
        .ELSE
            ; stored: the reader takes a span of the block size as raw
            mov edi, g_dfChunkPtr
            add edi, n
            mov ecx, WR_JSO_BLOCK
            sub ecx, n
            xor eax, eax
            rep stosb                       ; a short last block is padded to full size
            invoke DfWriteRaw, g_dfChunkPtr, WR_JSO_BLOCK
            mov eax, WR_JSO_BLOCK
        .ENDIF
        add pos, eax
        inc i
    .ENDW
    .IF g_dfErr != 0
        jmp done
    .ENDIF
    mov esi, pIdx
    mov ecx, nBlk
    mov eax, pos
    mov dword ptr [esi + ecx * 4], eax
    invoke SetFilePointerEx, hOut, 48, 0, NULL, FILE_BEGIN
    invoke DfWriteRaw, pIdx, idxCb
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke VfsFreeMem, pIdx
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
JsoCompressFile ENDP

; ---------------------------------------------------------------------------
; GCZ (Dolphin): 32-byte header, u64 pointers relative to the data (top bit:
; stored), an Adler-32 of every stored block's bytes - Dolphin checks them -
; then zlib blocks
; ---------------------------------------------------------------------------
GczCompressFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[32]:BYTE
    LOCAL off[2]:DWORD
    LOCAL nBlk:DWORD
    LOCAL pTbl:DWORD
    LOCAL tblCb:DWORD
    LOCAL posLo:DWORD                       ; within the data
    LOCAL posHi:DWORD
    LOCAL i:DWORD
    LOCAL n:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    mov pTbl, 0
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    mov eax, g_dfSizeLo
    mov edx, g_dfSizeHi
    add eax, WR_GCZ_BLOCK - 1
    adc edx, 0
    shrd eax, edx, 15
    shr edx, 15
    .IF edx != 0 || eax == 0
        jmp done
    .ENDIF
    mov nBlk, eax
    lea eax, [eax + eax * 2]
    shl eax, 2                              ; 8 + 4 bytes per block
    mov tblCb, eax
    invoke VfsAlloc, eax
    mov pTbl, eax
    .IF eax == 0
        jmp done
    .ENDIF
    lea edi, hdr
    mov dword ptr [edi], 0B10BC001h
    mov dword ptr [edi + 4], 0              ; GameCube
    mov dword ptr [edi + 8], 0              ; compressed data size, filled at the end
    mov dword ptr [edi + 12], 0
    mov eax, g_dfSizeLo
    mov dword ptr [edi + 16], eax
    mov eax, g_dfSizeHi
    mov dword ptr [edi + 20], eax
    mov dword ptr [edi + 24], WR_GCZ_BLOCK
    mov eax, nBlk
    mov dword ptr [edi + 28], eax
    invoke DfWriteRaw, edi, 32
    invoke DfWriteRaw, pTbl, tblCb
    mov posLo, 0
    mov posHi, 0
    mov off[0], 0
    mov off[4], 0
    mov i, 0
    .WHILE g_dfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        invoke WrReadBlock, hIn, addr off, WR_GCZ_BLOCK
        mov n, eax
        .BREAK .IF eax == 0
        ; a short last block is padded to the block size, as Dolphin expects
        .IF eax < WR_GCZ_BLOCK
            mov edi, g_dfChunkPtr
            add edi, eax
            mov ecx, WR_GCZ_BLOCK
            sub ecx, eax
            xor eax, eax
            rep stosb
        .ENDIF
        mov esi, pTbl
        mov ecx, i
        mov eax, posLo
        mov dword ptr [esi + ecx * 8], eax
        mov eax, posHi
        mov dword ptr [esi + ecx * 8 + 4], eax
        invoke DfBlockDeflate, WR_GCZ_BLOCK, 1
        .IF eax < WR_GCZ_BLOCK
            mov n, eax
            invoke DfAdler32, g_dfOut, n
            mov ebx, eax
            invoke DfWriteRaw, g_dfOut, n
        .ELSE
            mov esi, pTbl
            mov ecx, i
            or dword ptr [esi + ecx * 8 + 4], 80000000h
            mov n, WR_GCZ_BLOCK
            invoke DfAdler32, g_dfChunkPtr, WR_GCZ_BLOCK
            mov ebx, eax
            invoke DfWriteRaw, g_dfChunkPtr, WR_GCZ_BLOCK
        .ENDIF
        mov esi, pTbl
        mov eax, nBlk
        shl eax, 3
        add esi, eax
        mov ecx, i
        mov dword ptr [esi + ecx * 4], ebx  ; the hash
        mov eax, n
        add posLo, eax
        adc posHi, 0
        inc i
    .ENDW
    .IF g_dfErr != 0
        jmp done
    .ENDIF
    lea edi, hdr
    mov eax, posLo
    mov dword ptr [edi + 8], eax
    mov eax, posHi
    mov dword ptr [edi + 12], eax
    invoke SetFilePointerEx, hOut, 0, 0, NULL, FILE_BEGIN
    invoke DfWriteRaw, edi, 32
    invoke DfWriteRaw, pTbl, tblCb
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke VfsFreeMem, pTbl
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
GczCompressFile ENDP

; ---------------------------------------------------------------------------
; UIF (MagicISO): blocks of 8 sectors as zlib (5), raw (1) or zeros (3); a
; zlib-packed table of 24-byte entries behind a "blhr" header; a 64-byte
; "bbis" footer that points at the table
; ---------------------------------------------------------------------------
UifCompressFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL off[2]:DWORD
    LOCAL nBlk:DWORD
    LOCAL pTbl:DWORD
    LOCAL tblCb:DWORD
    LOCAL posLo:DWORD
    LOCAL posHi:DWORD
    LOCAL i:DWORD
    LOCAL n:DWORD
    LOCAL sector:DWORD
    LOCAL blhr[16]:BYTE
    LOCAL bbis[64]:BYTE
    LOCAL ztab:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    mov pTbl, 0
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    mov eax, g_dfSizeLo
    test eax, 2047
    jnz done
    mov edx, g_dfSizeHi
    add eax, WR_UIF_SECTORS * 2048 - 1
    adc edx, 0
    shrd eax, edx, 14
    shr edx, 14
    .IF edx != 0 || eax == 0
        jmp done
    .ENDIF
    mov nBlk, eax
    lea eax, [eax + eax * 2]
    shl eax, 3                              ; 24 bytes per entry
    mov tblCb, eax
    invoke VfsAlloc, eax
    mov pTbl, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov posLo, 0
    mov posHi, 0
    mov sector, 0
    mov off[0], 0
    mov off[4], 0
    mov i, 0
    .WHILE g_dfErr == 0
        mov eax, i
        .BREAK .IF eax >= nBlk
        invoke WrReadBlock, hIn, addr off, WR_UIF_SECTORS * 2048
        mov n, eax
        .BREAK .IF eax == 0
        ; entry: offset (8), zsize, sector, size in sectors, type
        mov esi, pTbl
        mov ecx, i
        lea ecx, [ecx + ecx * 2]
        shl ecx, 3
        add esi, ecx
        mov eax, posLo
        mov dword ptr [esi], eax
        mov eax, posHi
        mov dword ptr [esi + 4], eax
        mov eax, sector
        mov dword ptr [esi + 12], eax
        mov eax, n
        shr eax, 11
        mov dword ptr [esi + 16], eax
        add sector, eax
        invoke WrIsZero, n
        .IF eax != 0
            mov dword ptr [esi + 8], 0
            mov dword ptr [esi + 20], 3     ; zeros
        .ELSE
            push esi
            invoke DfBlockDeflate, n, 1
            pop esi
            .IF eax < n
                mov dword ptr [esi + 8], eax
                mov dword ptr [esi + 20], 5 ; zlib
                push eax
                invoke DfWriteRaw, g_dfOut, eax
                pop eax
            .ELSE
                mov eax, n
                mov dword ptr [esi + 8], eax
                mov dword ptr [esi + 20], 1 ; raw
                invoke DfWriteRaw, g_dfChunkPtr, n
                mov eax, n
            .ENDIF
            add posLo, eax
            adc posHi, 0
        .ENDIF
        inc i
    .ENDW
    .IF g_dfErr != 0
        jmp done
    .ENDIF
    ; the table, zlib-packed, behind its header; then the footer
    mov esi, pTbl
    mov edi, g_dfChunkPtr
    mov ecx, tblCb
    rep movsb
    invoke DfBlockDeflate, tblCb, 1
    mov ztab, eax
    lea edi, blhr
    mov dword ptr [edi], 72686C62h          ; "blhr"
    mov eax, ztab
    add eax, 8
    mov dword ptr [edi + 4], eax
    mov dword ptr [edi + 8], 1
    mov eax, nBlk
    mov dword ptr [edi + 12], eax
    invoke DfWriteRaw, edi, 16
    invoke DfWriteRaw, g_dfOut, ztab
    lea edi, bbis
    xor eax, eax
    mov ecx, 16
    rep stosd
    lea edi, bbis
    mov dword ptr [edi], 73696262h          ; "bbis"
    mov dword ptr [edi + 4], 64
    mov word ptr [edi + 8], 1
    mov word ptr [edi + 10], 8
    mov eax, sector
    mov dword ptr [edi + 16], eax
    mov dword ptr [edi + 20], 2048
    mov eax, posLo
    mov dword ptr [edi + 28], eax
    mov eax, posHi
    mov dword ptr [edi + 32], eax           ; where the table header sits
    mov eax, ztab
    add eax, 16 + 64
    mov dword ptr [edi + 36], eax
    invoke DfWriteRaw, edi, 64
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke VfsFreeMem, pTbl
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
UifCompressFile ENDP

; ---------------------------------------------------------------------------
; DAA v0x100 (PowerISO): 76-byte header, 3-byte chunk lengths stored as high,
; low, middle, then raw deflate chunks of 16 KB, the last one short
; ---------------------------------------------------------------------------
DaaCompressFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL hdr[76]:BYTE
    LOCAL off[2]:DWORD
    LOCAL nChunks:DWORD
    LOCAL pTbl:DWORD
    LOCAL tblCb:DWORD
    LOCAL i:DWORD
    LOCAL n:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    mov pTbl, 0
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    mov eax, g_dfSizeLo
    mov edx, g_dfSizeHi
    add eax, WR_DAA_CHUNK - 1
    adc edx, 0
    shrd eax, edx, 14
    shr edx, 14
    .IF edx != 0 || eax == 0
        jmp done
    .ENDIF
    mov nChunks, eax
    lea eax, [eax + eax * 2]
    mov tblCb, eax
    invoke VfsAlloc, eax
    mov pTbl, eax
    .IF eax == 0
        jmp done
    .ENDIF
    lea edi, hdr
    xor eax, eax
    mov ecx, 19
    rep stosd
    lea edi, hdr
    mov dword ptr [edi], 00414144h          ; "DAA", 0
    mov dword ptr [edi + 16], 76            ; chunk length table offset
    mov dword ptr [edi + 20], 100h
    mov eax, tblCb
    add eax, 76
    mov dword ptr [edi + 24], eax           ; data offset
    mov dword ptr [edi + 28], 1
    mov dword ptr [edi + 36], WR_DAA_CHUNK
    mov eax, g_dfSizeLo
    mov dword ptr [edi + 40], eax
    mov eax, g_dfSizeHi
    mov dword ptr [edi + 44], eax
    invoke DfWriteRaw, edi, 76
    invoke DfWriteRaw, pTbl, tblCb
    mov off[0], 0
    mov off[4], 0
    mov i, 0
    .WHILE g_dfErr == 0
        mov eax, i
        .BREAK .IF eax >= nChunks
        invoke WrReadBlock, hIn, addr off, WR_DAA_CHUNK
        mov n, eax
        .BREAK .IF eax == 0
        invoke DfBlockDeflate, n, 0
        mov n, eax
        invoke DfWriteRaw, g_dfOut, n
        mov esi, pTbl
        mov ecx, i
        lea ecx, [ecx + ecx * 2]
        mov eax, n
        mov byte ptr [esi + ecx + 1], al    ; low
        shr eax, 8
        mov byte ptr [esi + ecx + 2], al    ; middle
        shr eax, 8
        mov byte ptr [esi + ecx], al        ; high
        inc i
    .ENDW
    .IF g_dfErr != 0
        jmp done
    .ENDIF
    invoke SetFilePointerEx, hOut, 76, 0, NULL, FILE_BEGIN
    invoke DfWriteRaw, pTbl, tblCb
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke VfsFreeMem, pTbl
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
DaaCompressFile ENDP

; ---------------------------------------------------------------------------
; DMG (Apple UDIF): the data fork of zlib chunks, then an XML plist holding
; one base64 "mish" block, then the 512-byte "koly" trailer. All big-endian.
; ---------------------------------------------------------------------------
DmgBE32 PROC pDst:DWORD, v:DWORD
    mov eax, v
    bswap eax
    mov ecx, pDst
    mov dword ptr [ecx], eax
    ret
DmgBE32 ENDP

DmgCompressFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL off[2]:DWORD
    LOCAL nChunks:DWORD
    LOCAL pMish:DWORD
    LOCAL mishCb:DWORD
    LOCAL posLo:DWORD
    LOCAL posHi:DWORD
    LOCAL i:DWORD
    LOCAL n:DWORD
    LOCAL secLo:DWORD
    LOCAL secHi:DWORD
    LOCAL cnt:DWORD
    LOCAL pB64:DWORD
    LOCAL b64Cb:DWORD
    LOCAL xmlLo:DWORD
    LOCAL xmlHi:DWORD
    LOCAL xmlLen:DWORD
    LOCAL koly[512]:BYTE
    LOCAL ok:DWORD
    mov ok, FALSE
    mov pMish, 0
    mov pB64, 0
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    mov eax, g_dfSizeLo
    test eax, 511
    jnz done                                ; 512-byte sectors
    mov edx, g_dfSizeHi
    add eax, WR_DMG_CHUNK - 1
    adc edx, 0
    shrd eax, edx, 19
    shr edx, 19
    .IF edx != 0 || eax == 0
        jmp done
    .ENDIF
    mov nChunks, eax
    ; mish: 204-byte head, 40 bytes per entry, one terminator entry
    inc eax
    lea eax, [eax + eax * 4]
    shl eax, 3
    add eax, 204
    mov mishCb, eax
    invoke VfsAlloc, eax
    mov pMish, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov edi, eax
    mov dword ptr [edi], 6873696Dh          ; "mish"
    lea eax, [edi + 4]
    invoke DmgBE32, eax, 1                  ; version
    mov eax, g_dfSizeLo
    mov edx, g_dfSizeHi
    shrd eax, edx, 9
    shr edx, 9
    mov secLo, eax
    mov secHi, edx
    lea ecx, [edi + 16]
    invoke DmgBE32, ecx, secHi              ; sector count
    lea ecx, [edi + 20]
    invoke DmgBE32, ecx, secLo
    lea eax, [edi + 32]
    invoke DmgBE32, eax, (WR_DMG_CHUNK / 512) + 8   ; decompress buffer, as hdiutil asks
    lea eax, [edi + 36]
    invoke DmgBE32, eax, 0FFFFFFFFh         ; whole disk
    mov eax, nChunks
    inc eax
    lea ecx, [edi + 200]
    invoke DmgBE32, ecx, eax                ; entries, terminator included
    mov posLo, 0
    mov posHi, 0
    mov secLo, 0
    mov secHi, 0
    mov off[0], 0
    mov off[4], 0
    mov i, 0
    .WHILE g_dfErr == 0
        mov eax, i
        .BREAK .IF eax >= nChunks
        invoke WrReadBlock, hIn, addr off, WR_DMG_CHUNK
        mov n, eax
        .BREAK .IF eax == 0
        ; entry: type, comment, sector, count, offset, length (all big-endian)
        mov esi, pMish
        mov ecx, i
        lea ecx, [ecx + ecx * 4]
        shl ecx, 3
        lea esi, [esi + ecx + 204]
        lea eax, [esi + 4]
        invoke DmgBE32, eax, 0
        lea eax, [esi + 8]
        invoke DmgBE32, eax, secHi
        lea eax, [esi + 12]
        invoke DmgBE32, eax, secLo
        mov eax, n
        shr eax, 9
        mov cnt, eax
        lea ecx, [esi + 16]
        invoke DmgBE32, ecx, 0
        lea ecx, [esi + 20]
        invoke DmgBE32, ecx, cnt
        mov eax, cnt
        add secLo, eax
        adc secHi, 0
        lea eax, [esi + 24]
        invoke DmgBE32, eax, posHi
        lea eax, [esi + 28]
        invoke DmgBE32, eax, posLo
        invoke WrIsZero, n
        .IF eax != 0
            invoke DmgBE32, esi, 0          ; zero fill, no data
            lea eax, [esi + 32]
            invoke DmgBE32, eax, 0
            lea eax, [esi + 36]
            invoke DmgBE32, eax, 0
        .ELSE
            invoke DfBlockDeflate, n, 1
            mov n, eax
            invoke DmgBE32, esi, 80000005h  ; zlib
            lea eax, [esi + 32]
            invoke DmgBE32, eax, 0
            lea eax, [esi + 36]
            invoke DmgBE32, eax, n
            invoke DfWriteRaw, g_dfOut, n
            mov eax, n
            add posLo, eax
            adc posHi, 0
        .ENDIF
        inc i
    .ENDW
    .IF g_dfErr != 0
        jmp done
    .ENDIF
    ; terminator entry
    mov esi, pMish
    mov ecx, nChunks
    lea ecx, [ecx + ecx * 4]
    shl ecx, 3
    lea esi, [esi + ecx + 204]
    invoke DmgBE32, esi, 0FFFFFFFFh
    lea eax, [esi + 8]
    invoke DmgBE32, eax, secHi              ; the terminator sits at the end: total sectors, fork end
    lea eax, [esi + 12]
    invoke DmgBE32, eax, secLo
    lea eax, [esi + 24]
    invoke DmgBE32, eax, posHi
    lea eax, [esi + 28]
    invoke DmgBE32, eax, posLo
    ; plist: head, base64 of the mish (crypt32 does the encoding), tail
    invoke CryptBinaryToStringA, pMish, mishCb, CRYPT_STRING_BASE64, NULL, addr b64Cb
    .IF eax == 0
        jmp done
    .ENDIF
    invoke VfsAlloc, b64Cb
    mov pB64, eax
    .IF eax == 0
        jmp done
    .ENDIF
    invoke CryptBinaryToStringA, pMish, mishCb, CRYPT_STRING_BASE64, pB64, addr b64Cb
    .IF eax == 0
        jmp done
    .ENDIF
    mov eax, posLo
    mov xmlLo, eax
    mov eax, posHi
    mov xmlHi, eax
    invoke lstrlenA, offset szDmgXmlHead
    mov xmlLen, eax
    invoke DfWriteRaw, offset szDmgXmlHead, eax
    mov eax, b64Cb
    add xmlLen, eax
    invoke DfWriteRaw, pB64, b64Cb
    invoke lstrlenA, offset szDmgXmlTail
    add xmlLen, eax
    invoke DfWriteRaw, offset szDmgXmlTail, eax
    ; koly
    lea edi, koly
    xor eax, eax
    mov ecx, 128
    rep stosd
    lea edi, koly
    mov dword ptr [edi], 796C6F6Bh          ; "koly"
    lea eax, [edi + 4]
    invoke DmgBE32, eax, 4                  ; version
    lea eax, [edi + 8]
    invoke DmgBE32, eax, 512
    lea eax, [edi + 12]
    invoke DmgBE32, eax, 1                  ; flags
    lea eax, [edi + 24]
    invoke DmgBE32, eax, 0                  ; data fork offset (hi, lo)
    lea eax, [edi + 28]
    invoke DmgBE32, eax, 0
    lea eax, [edi + 32]
    invoke DmgBE32, eax, posHi              ; data fork length
    lea eax, [edi + 36]
    invoke DmgBE32, eax, posLo
    lea eax, [edi + 216]
    invoke DmgBE32, eax, xmlHi
    lea eax, [edi + 220]
    invoke DmgBE32, eax, xmlLo
    lea eax, [edi + 224]
    invoke DmgBE32, eax, 0
    lea eax, [edi + 228]
    invoke DmgBE32, eax, xmlLen
    lea eax, [edi + 492]
    invoke DmgBE32, eax, secHi              ; sector count
    lea eax, [edi + 496]
    invoke DmgBE32, eax, secLo
    invoke DfWriteRaw, edi, 512
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke VfsFreeMem, pMish
    invoke VfsFreeMem, pB64
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
DmgCompressFile ENDP

END
