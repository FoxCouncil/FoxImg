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

; ---------------------------------------------------------------------------
; Raw MODE1 sectors (ECMA-130): sync, BCD minute:second:frame header, the
; 2048 bytes, EDC (CRC-32 over polynomial 8001801Bh, reflected), 8 zero bytes,
; then P and Q Reed-Solomon parity over GF(256) with x^8+x^4+x^3+x^2+1. The
; tables are built on first use. Checked byte for byte against a pressed
; disc in build\zraw.py.
; ---------------------------------------------------------------------------
RAW_BATCH       equ 256                 ; sectors per pass: 512 KB in, 588 KB out

.data
g_rawReady      dd 0
.data?
g_rawF          db 256 dup(?)           ; times 2 in GF(256)
g_rawB          db 256 dup(?)           ; inverse of times 3
g_rawEdc        dd 256 dup(?)
.code

RawInitTables PROC
    .IF g_rawReady != 0
        ret
    .ENDIF
    xor ecx, ecx
    .WHILE ecx < 256
        mov eax, ecx
        shl eax, 1
        .IF ecx & 80h
            xor eax, 11Dh
        .ENDIF
        and eax, 0FFh
        mov g_rawF[ecx], al
        xor eax, ecx
        mov g_rawB[eax], cl
        mov eax, ecx
        mov edx, 8
        .WHILE edx != 0
            shr eax, 1
            .IF CARRY?
                xor eax, 0D8018001h
            .ENDIF
            dec edx
        .ENDW
        mov g_rawEdc[ecx * 4], eax
        inc ecx
    .ENDW
    mov g_rawReady, 1
    ret
RawInitTables ENDP

; EDC of cb bytes at pData, continued from seed (0 to start)
RawEdc PROC USES esi seed:DWORD, pData:DWORD, cb:DWORD
    mov esi, pData
    mov ecx, cb
    mov eax, seed
    .WHILE ecx != 0
        movzx edx, byte ptr [esi]
        xor dl, al
        movzx edx, dl
        shr eax, 8
        xor eax, g_rawEdc[edx * 4]
        inc esi
        dec ecx
    .ENDW
    ret
RawEdc ENDP

; One parity pass (P or Q) over the sector body at pSrc into pDst
RawEcc PROC USES esi edi ebx pSrc:DWORD, majorCount:DWORD, minorCount:DWORD, majorMult:DWORD, minorInc:DWORD, pDst:DWORD
    LOCAL total:DWORD
    LOCAL major:DWORD
    mov eax, majorCount
    imul eax, minorCount
    mov total, eax
    mov esi, pSrc
    mov edi, pDst
    mov major, 0
    .WHILE 1
        mov eax, major
        .BREAK .IF eax >= majorCount
        shr eax, 1
        imul eax, majorMult
        mov edx, major
        and edx, 1
        add edx, eax                        ; index
        xor ebx, ebx                        ; bl: ecc_a, bh: ecc_b
        mov ecx, minorCount
        .WHILE ecx != 0
            mov al, byte ptr [esi + edx]
            add edx, minorInc
            .IF edx >= total
                sub edx, total
            .ENDIF
            xor bl, al
            xor bh, al
            movzx eax, bl
            mov bl, g_rawF[eax]
            dec ecx
        .ENDW
        movzx eax, bl
        mov al, g_rawF[eax]
        xor al, bh
        movzx eax, al
        mov al, g_rawB[eax]
        mov ecx, major
        mov byte ptr [edi + ecx], al
        add ecx, majorCount
        xor al, bh
        mov byte ptr [edi + ecx], al
        inc major
    .ENDW
    ret
RawEcc ENDP

RawBcd PROC v:DWORD
    mov eax, v
    xor edx, edx
    mov ecx, 10
    div ecx
    shl eax, 4
    or eax, edx
    ret
RawBcd ENDP

; One MODE1 sector at pDst from the 2048 bytes at pSrc for this LBA
RawBuildSector PROC USES esi edi pDst:DWORD, pSrc:DWORD, lba:DWORD
    mov edi, pDst
    mov byte ptr [edi], 0
    mov dword ptr [edi + 1], 0FFFFFFFFh
    mov dword ptr [edi + 5], 0FFFFFFFFh
    mov word ptr [edi + 9], 0FFFFh
    mov byte ptr [edi + 11], 0
    mov eax, lba
    add eax, 150
    xor edx, edx
    mov ecx, 75
    div ecx
    mov esi, eax                            ; whole seconds
    invoke RawBcd, edx
    mov byte ptr [edi + 14], al
    mov eax, esi
    xor edx, edx
    mov ecx, 60
    div ecx
    mov esi, eax                            ; minutes
    invoke RawBcd, edx
    mov byte ptr [edi + 13], al
    invoke RawBcd, esi
    mov byte ptr [edi + 12], al
    mov byte ptr [edi + 15], 1
    mov esi, pSrc
    add edi, 16
    mov ecx, 512
    rep movsd
    invoke RawFixMode1, pDst
    ret
RawBuildSector ENDP

; Recompute the EDC and parity of a MODE1 sector in place; sync, header and
; data are already there. Also what the ECM and CHD readers call to put back
; what those formats strip.
RawFixMode1 PROC USES edi pSector:DWORD
    invoke RawInitTables
    mov edi, pSector
    invoke RawEdc, 0, edi, 2064
    mov dword ptr [edi + 2064], eax
    mov dword ptr [edi + 2068], 0
    mov dword ptr [edi + 2072], 0
    lea eax, [edi + 12]
    lea ecx, [edi + 2076]
    invoke RawEcc, eax, 86, 24, 2, 86, ecx  ; P
    mov edi, pSector
    lea eax, [edi + 12]
    lea ecx, [edi + 2248]
    invoke RawEcc, eax, 52, 43, 86, 88, ecx ; Q
    ret
RawFixMode1 ENDP

; The open session's input as MODE1/2352 raw sectors to its output; g_dfErr
; on failure. The input must be whole 2048-byte sectors.
RawStream PROC USES esi edi ebx hIn:DWORD
    LOCAL off[2]:DWORD
    LOCAL lba:DWORD
    LOCAL n:DWORD
    LOCAL i:DWORD
    invoke RawInitTables
    mov eax, g_dfSizeLo
    test eax, 2047
    .IF !ZERO?
        mov g_dfErr, 1
        ret
    .ENDIF
    mov off[0], 0
    mov off[4], 0
    mov lba, 0
    .WHILE g_dfErr == 0
        invoke WrReadBlock, hIn, addr off, RAW_BATCH * 2048
        .BREAK .IF eax == 0
        shr eax, 11
        mov n, eax                          ; sectors in this batch
        mov i, 0
        .WHILE 1
            mov eax, i
            .BREAK .IF eax >= n
            imul eax, 2352
            add eax, g_dfOut
            mov ecx, i
            shl ecx, 11
            add ecx, g_dfChunkPtr
            invoke RawBuildSector, eax, ecx, lba
            inc lba
            inc i
        .ENDW
        mov eax, n
        imul eax, 2352
        invoke DfWriteRaw, g_dfOut, eax
    .ENDW
    ret
RawStream ENDP

; Rewrite a 2048-byte-sector image as MODE1/2352 raw sectors
RawWrapFile PROC pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL ok:DWORD
    mov ok, FALSE
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    invoke RawStream, hIn
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
RawWrapFile ENDP

; ---------------------------------------------------------------------------
; NRG (Nero, v2): the raw sectors, then the chunk area (big-endian: CUEX cue
; entries, DAOX with one 2352-byte MODE1 track, SINF, MTYP, END!) and the
; 12-byte "NER5" footer holding the chunk area's offset
; ---------------------------------------------------------------------------
NrgBE32 PROC pDst:DWORD, v:DWORD
    mov eax, v
    bswap eax
    mov ecx, pDst
    mov dword ptr [ecx], eax
    ret
NrgBE32 ENDP

NrgWrapFile PROC USES edi pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL ok:DWORD
    LOCAL sectors:DWORD
    LOCAL chunkLo:DWORD
    LOCAL chunkHi:DWORD
    LOCAL area[160]:BYTE
    mov ok, FALSE
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    invoke RawStream, hIn
    .IF g_dfErr != 0
        jmp done
    .ENDIF
    mov eax, g_dfSizeLo
    mov edx, g_dfSizeHi
    shrd eax, edx, 11
    mov sectors, eax                        ; the chunk area starts where the raw data ends
    mov eax, g_dfCompLo
    mov chunkLo, eax
    mov eax, g_dfCompHi
    mov chunkHi, eax
    lea edi, area
    xor eax, eax
    mov ecx, 40
    rep stosd
    lea edi, area
    ; CUEX: 4 entries of mode, track (BCD), index, 0, LBA
    mov dword ptr [edi], 'XEUC'
    invoke NrgBE32, addr area[4], 32
    mov dword ptr [edi + 8], 00000041h      ; track 0 index 0 at -150
    invoke NrgBE32, addr area[12], -150
    mov dword ptr [edi + 16], 00000141h     ; track 1 index 0 at -150
    invoke NrgBE32, addr area[20], -150
    mov dword ptr [edi + 24], 00010141h     ; track 1 index 1 at 0
    invoke NrgBE32, addr area[28], 0
    mov dword ptr [edi + 32], 0001AA41h     ; lead-out
    invoke NrgBE32, addr area[36], sectors
    ; DAOX at 40: payload at 48 = size, MCN (13) and pad, toc type, first and last track; the track block at 70
    mov dword ptr [edi + 40], 'XOAD'
    invoke NrgBE32, addr area[44], 64
    invoke NrgBE32, addr area[48], 64
    mov byte ptr [edi + 67], 1     ; toc type 0001
    mov byte ptr [edi + 68], 1     ; first track
    mov byte ptr [edi + 69], 1     ; last track
    mov word ptr [edi + 82], 3009h ; sector size 2352, big-endian
    mov byte ptr [edi + 84], 5    ; MODE1 raw
    invoke NrgBE32, addr area[104], g_dfCompHi     ; end offset (pregap and start stay 0)
    invoke NrgBE32, addr area[108], g_dfCompLo
    ; SINF at 112: tracks in the session; MTYP at 124: CD-ROM; END! at 136
    mov dword ptr [edi + 112], 'FNIS'
    invoke NrgBE32, addr area[116], 4
    invoke NrgBE32, addr area[120], 1
    mov dword ptr [edi + 124], 'PYTM'
    invoke NrgBE32, addr area[128], 4
    invoke NrgBE32, addr area[132], 1
    mov dword ptr [edi + 136], '!DNE'
    ; footer at 144
    mov dword ptr [edi + 144], '5REN'
    invoke NrgBE32, addr area[148], chunkHi
    invoke NrgBE32, addr area[152], chunkLo
    invoke DfWriteRaw, addr area, 156
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
NrgWrapFile ENDP

; ---------------------------------------------------------------------------
; ECM (Error Code Modeler): "ECM\0", then records with a varint head (type in
; the low two bits, count - 1 above, bit 7 continues); a MODE1 record holds
; the 3 address bytes and the 2048 data bytes per sector. One record covers
; the image. Then the end marker and the EDC of the whole raw reconstruction,
; which is why each sector is built in full first.
; ---------------------------------------------------------------------------
ECM_SCRATCH     equ 614400              ; a full sector's scratch inside g_dfOut, past the 256 records

EcmWrapFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL off[2]:DWORD
    LOCAL lba:DWORD
    LOCAL n:DWORD
    LOCAL i:DWORD
    LOCAL edc:DWORD
    LOCAL ok:DWORD
    LOCAL hdr[16]:BYTE
    mov ok, FALSE
    invoke RawInitTables
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    mov eax, g_dfSizeLo
    test eax, 2047
    jnz done
    .IF g_dfSizeHi != 0 || eax == 0
        jmp done
    .ENDIF
    ; header and the head of one MODE1 record for every sector
    lea edi, hdr
    mov dword ptr [edi], 004D4345h          ; "ECM\0"
    mov eax, g_dfSizeLo
    shr eax, 11
    dec eax                                 ; the count is stored less one
    mov ecx, eax
    and ecx, 1Fh
    shl ecx, 2
    or ecx, 1                               ; type 1: MODE1
    .IF eax >= 20h
        or ecx, 80h
    .ENDIF
    mov byte ptr [edi + 4], cl
    mov n, 5
    shr eax, 5
    .WHILE eax != 0
        mov ecx, eax
        and ecx, 7Fh
        .IF eax >= 80h
            or ecx, 80h
        .ENDIF
        mov edx, n
        mov byte ptr [edi + edx], cl
        inc n
        shr eax, 7
    .ENDW
    invoke DfWriteRaw, addr hdr, n
    mov edc, 0
    mov lba, 0
    mov off[0], 0
    mov off[4], 0
    .WHILE g_dfErr == 0
        invoke WrReadBlock, hIn, addr off, RAW_BATCH * 2048
        .BREAK .IF eax == 0
        shr eax, 11
        mov n, eax
        mov i, 0
        .WHILE 1
            mov eax, i
            .BREAK .IF eax >= n
            ; the full sector, for the running EDC
            mov eax, g_dfOut
            add eax, ECM_SCRATCH
            mov ecx, i
            shl ecx, 11
            add ecx, g_dfChunkPtr
            invoke RawBuildSector, eax, ecx, lba
            mov esi, g_dfOut
            add esi, ECM_SCRATCH
            invoke RawEdc, edc, esi, 2352
            mov edc, eax
            ; the record body: address then data
            mov edi, i
            imul edi, 2051
            add edi, g_dfOut
            mov esi, g_dfOut
            add esi, ECM_SCRATCH
            mov eax, dword ptr [esi + 12]
            mov byte ptr [edi], al
            shr eax, 8
            mov byte ptr [edi + 1], al
            shr eax, 8
            mov byte ptr [edi + 2], al
            add edi, 3
            add esi, 16
            mov ecx, 512
            rep movsd
            inc lba
            inc i
        .ENDW
        mov eax, n
        imul eax, 2051
        invoke DfWriteRaw, g_dfOut, eax
    .ENDW
    .IF g_dfErr == 0
        lea edi, hdr
        mov dword ptr [edi], 0FFFFFFFCh     ; end marker: type 0, count all ones
        mov byte ptr [edi + 4], 3Fh
        mov eax, edc
        mov dword ptr [edi + 5], eax
        invoke DfWriteRaw, addr hdr, 9
        .IF g_dfErr == 0
            mov ok, TRUE
        .ENDIF
    .ENDIF
done:
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
EcmWrapFile ENDP

; ---------------------------------------------------------------------------
; LZ4 block encoder (ZSO, CISO v2): greedy, one hash-table candidate per
; position, matches of 4 or more within 65535 bytes. The table holds
; positions and is never cleared: a stale entry is just a candidate that the
; byte compare rejects. The last five bytes are always literals and no match
; starts within the last twelve, as the format requires.
; ---------------------------------------------------------------------------
LZ4_HASH_BITS   equ 12

.data?
g_lz4Head       dd (1 shl LZ4_HASH_BITS) dup(?)
.code

; cb bytes at pSrc into pDst (room for cb + cb / 255 + 16); the length in eax
Lz4Compress PROC USES esi edi ebx pSrc:DWORD, cb:DWORD, pDst:DWORD
    LOCAL anchor:DWORD                      ; first byte not yet emitted
    LOCAL ip:DWORD
    LOCAL mlimit:DWORD                      ; matches may start before this
    LOCAL mend:DWORD                        ; and extend up to this
    LOCAL cand:DWORD
    LOCAL mlen:DWORD
    LOCAL pTok:DWORD
    mov esi, pSrc
    mov edi, pDst
    mov anchor, 0
    mov ip, 0
    mov eax, cb
    sub eax, 12
    mov mlimit, eax
    mov eax, cb
    sub eax, 5
    mov mend, eax
    .IF cb >= 13
        .WHILE 1
            mov ebx, ip
            .BREAK .IF ebx >= mlimit
            mov eax, dword ptr [esi + ebx]
            imul eax, -1640531535               ; 9E3779B1h, Knuth's multiplicative hash
            shr eax, 32 - LZ4_HASH_BITS
            mov ecx, g_lz4Head[eax * 4]
            mov g_lz4Head[eax * 4], ebx
            mov cand, ecx
            .IF ecx < ebx
                mov edx, ebx
                sub edx, ecx
                .IF edx <= 65535
                    mov eax, dword ptr [esi + ecx]
                    .IF eax == dword ptr [esi + ebx]
                        ; extend past the four bytes
                        mov mlen, 4
                        .WHILE 1
                            mov eax, ip
                            add eax, mlen
                            .BREAK .IF eax >= mend
                            mov edx, cand
                            add edx, mlen
                            mov cl, byte ptr [esi + edx]
                            .BREAK .IF cl != byte ptr [esi + eax]
                            inc mlen
                        .ENDW
                        ; token, literal length, literals
                        mov pTok, edi
                        inc edi
                        mov eax, ip
                        sub eax, anchor
                        mov ecx, eax                    ; literal count
                        .IF eax >= 15
                            mov byte ptr [edi - 1], 0F0h
                            sub eax, 15
                            .WHILE eax >= 255
                                mov byte ptr [edi], 255
                                inc edi
                                sub eax, 255
                            .ENDW
                            mov byte ptr [edi], al
                            inc edi
                        .ELSE
                            shl eax, 4
                            mov byte ptr [edi - 1], al
                        .ENDIF
                        push esi
                        add esi, anchor
                        rep movsb
                        pop esi
                        ; offset, then the match length past four
                        mov eax, ip
                        sub eax, cand
                        mov word ptr [edi], ax
                        add edi, 2
                        mov eax, mlen
                        sub eax, 4
                        .IF eax >= 15
                            mov ecx, pTok
                            or byte ptr [ecx], 15
                            sub eax, 15
                            .WHILE eax >= 255
                                mov byte ptr [edi], 255
                                inc edi
                                sub eax, 255
                            .ENDW
                            mov byte ptr [edi], al
                            inc edi
                        .ELSE
                            mov ecx, pTok
                            or byte ptr [ecx], al
                        .ENDIF
                        mov eax, ip
                        add eax, mlen
                        mov ip, eax
                        mov anchor, eax
                        .CONTINUE
                    .ENDIF
                .ENDIF
            .ENDIF
            inc ip
        .ENDW
    .ENDIF
    ; the closing literals
    mov eax, cb
    sub eax, anchor
    mov ecx, eax
    .IF eax >= 15
        mov byte ptr [edi], 0F0h
        inc edi
        sub eax, 15
        .WHILE eax >= 255
            mov byte ptr [edi], 255
            inc edi
            sub eax, 255
        .ENDW
        mov byte ptr [edi], al
        inc edi
    .ELSE
        shl eax, 4
        mov byte ptr [edi], al
        inc edi
    .ENDIF
    add esi, anchor
    rep movsb
    mov eax, edi
    sub eax, pDst
    ret
Lz4Compress ENDP

; ---------------------------------------------------------------------------
; CHD v5 (MAME), uncompressed: the 124-byte big-endian header, a map of one
; dword per hunk giving its position in hunk units, then the hunks, the last
; one padded. No metadata, so the combined SHA-1 is the SHA-1 of the raw
; SHA-1 alone. Hashing is the OS's (bcrypt).
; ---------------------------------------------------------------------------
CHD_WR_HUNK     equ 32768               ; 16 sectors
CHD_WR_HDR      equ 124

.data
szBcSha1        dw 'S','H','A','1',0
.code

ChdBE32 PROC pDst:DWORD, v:DWORD
    mov eax, v
    bswap eax
    mov ecx, pDst
    mov dword ptr [ecx], eax
    ret
ChdBE32 ENDP

ChdWriteFile PROC USES esi edi ebx pszSrc:DWORD, pszDst:DWORD
    LOCAL hIn:DWORD
    LOCAL hOut:DWORD
    LOCAL ok:DWORD
    LOCAL hAlg:DWORD
    LOCAL hHash:DWORD
    LOCAL off[2]:DWORD
    LOCAL nHunk:DWORD
    LOCAL mapCb:DWORD
    LOCAL dataStart:DWORD                   ; in hunk units
    LOCAL padCb:DWORD
    LOCAL i:DWORD
    LOCAL n:DWORD
    LOCAL hdr[CHD_WR_HDR]:BYTE
    LOCAL rawSha[20]:BYTE
    mov ok, FALSE
    mov hAlg, 0
    mov hHash, 0
    invoke WrBegin, pszSrc, pszDst
    .IF eax == 0
        ret
    .ENDIF
    mov hIn, eax
    mov hOut, edx
    .IF g_dfSizeLo == 0 && g_dfSizeHi == 0
        jmp done
    .ENDIF
    ; hunks = ceil(size / hunk); the map after the header; data on the first hunk boundary past it
    mov eax, g_dfSizeLo
    mov edx, g_dfSizeHi
    add eax, CHD_WR_HUNK - 1
    adc edx, 0
    shrd eax, edx, 15
    shr edx, 15
    .IF edx != 0 || eax > 100000h
        jmp done                            ; 4 GB of hunks is plenty for a disc
    .ENDIF
    mov nHunk, eax
    shl eax, 2
    mov mapCb, eax
    add eax, CHD_WR_HDR + CHD_WR_HUNK - 1
    shr eax, 15
    mov dataStart, eax
    shl eax, 15
    sub eax, mapCb
    sub eax, CHD_WR_HDR
    mov padCb, eax
    invoke BCryptOpenAlgorithmProvider, addr hAlg, offset szBcSha1, NULL, 0
    .IF eax != 0
        jmp done
    .ENDIF
    invoke BCryptCreateHash, hAlg, addr hHash, NULL, 0, NULL, 0, 0
    .IF eax != 0
        jmp done
    .ENDIF
    ; header placeholder, the map, the padding
    lea edi, hdr
    xor eax, eax
    mov ecx, CHD_WR_HDR / 4
    rep stosd
    invoke DfWriteRaw, addr hdr, CHD_WR_HDR
    mov i, 0
    .WHILE g_dfErr == 0
        mov eax, i
        .BREAK .IF eax >= nHunk
        ; a run of map entries through the output buffer: dataStart + i, big-endian
        mov edi, g_dfOut
        mov n, 0
        .WHILE 1
            mov eax, i
            .BREAK .IF eax >= nHunk
            .BREAK .IF n >= 65536
            add eax, dataStart
            bswap eax
            mov dword ptr [edi], eax
            add edi, 4
            inc i
            inc n
        .ENDW
        mov eax, n
        shl eax, 2
        invoke DfWriteRaw, g_dfOut, eax
    .ENDW
    mov eax, padCb
    .IF eax != 0
        mov edi, g_dfOut
        mov ecx, eax
        xor eax, eax
        rep stosb
        invoke DfWriteRaw, g_dfOut, padCb
    .ENDIF
    ; the hunks, hashed as they go
    mov off[0], 0
    mov off[4], 0
    .WHILE g_dfErr == 0
        invoke WrReadBlock, hIn, addr off, CHD_WR_HUNK * 16
        .BREAK .IF eax == 0
        mov n, eax
        invoke BCryptHashData, hHash, g_dfChunkPtr, n, 0
        .IF eax != 0
            mov g_dfErr, 1
            .BREAK
        .ENDIF
        ; pad a short tail to whole hunks
        mov eax, n
        add eax, CHD_WR_HUNK - 1
        and eax, -CHD_WR_HUNK
        mov ecx, eax
        sub ecx, n
        .IF ecx != 0
            mov edi, g_dfChunkPtr
            add edi, n
            push eax
            xor eax, eax
            rep stosb
            pop eax
        .ENDIF
        invoke DfWriteRaw, g_dfChunkPtr, eax
    .ENDW
    .IF g_dfErr != 0
        jmp done
    .ENDIF
    invoke BCryptFinishHash, hHash, addr rawSha, 20, 0
    .IF eax != 0
        jmp done
    .ENDIF
    ; combined SHA-1 over the raw SHA-1 (no metadata hashes)
    invoke BCryptDestroyHash, hHash
    mov hHash, 0
    invoke BCryptCreateHash, hAlg, addr hHash, NULL, 0, NULL, 0, 0
    .IF eax != 0
        jmp done
    .ENDIF
    invoke BCryptHashData, hHash, addr rawSha, 20, 0
    lea eax, hdr
    add eax, 84
    invoke BCryptFinishHash, hHash, eax, 20, 0
    .IF eax != 0
        jmp done
    .ENDIF
    ; the header: magic, length, version 5, no compressors, sizes, offsets, hashes
    lea edi, hdr
    mov esi, offset szChdMagic
    mov ecx, 8
    rep movsb
    lea edi, hdr
    lea eax, [edi + 8]
    invoke ChdBE32, eax, CHD_WR_HDR
    lea eax, [edi + 12]
    invoke ChdBE32, eax, 5
    lea eax, [edi + 32]
    invoke ChdBE32, eax, g_dfSizeHi         ; logical bytes
    lea eax, [edi + 36]
    invoke ChdBE32, eax, g_dfSizeLo
    lea eax, [edi + 40]
    invoke ChdBE32, eax, 0                  ; map offset
    lea eax, [edi + 44]
    invoke ChdBE32, eax, CHD_WR_HDR
    lea eax, [edi + 56]
    invoke ChdBE32, eax, CHD_WR_HUNK        ; hunk and unit bytes
    lea eax, [edi + 60]
    invoke ChdBE32, eax, 2048
    lea edi, hdr
    add edi, 64
    lea esi, rawSha
    mov ecx, 20
    rep movsb
    invoke SetFilePointerEx, hOut, 0, 0, NULL, FILE_BEGIN
    invoke DfWriteRaw, addr hdr, CHD_WR_HDR
    .IF g_dfErr == 0
        mov ok, TRUE
    .ENDIF
done:
    .IF hHash != 0
        invoke BCryptDestroyHash, hHash
    .ENDIF
    .IF hAlg != 0
        invoke BCryptCloseAlgorithmProvider, hAlg, 0
    .ENDIF
    invoke WrEnd, ok, hIn, hOut, pszDst
    ret
ChdWriteFile ENDP

END
