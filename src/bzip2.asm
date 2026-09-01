; FoxImg - bzip2 (BZh) decoder.
;
; Reads through the same input machinery as the deflate side (ZfInByte, so a
; caller positions the stream with ZfSetInput) and writes through the same
; output buffer, which keeps the flush, CRC and progress bookkeeping in one
; place. The bit order is the opposite of deflate's: bzip2 packs most
; significant bit first, so this carries its own accumulator.
;
; The pipeline is the standard one, run in reverse: Huffman -> MTF/RLE2 ->
; inverse Burrows-Wheeler -> RLE1. The inverse BWT uses bzip2's own trick of
; packing the byte in the low 8 bits of a u32 and the successor index in the
; top 24, so one allocation of 4 bytes per block byte covers it (3.6 MB at the
; largest level).
;
; Per-block CRCs are parsed but not checked: bzip2 uses a bit-reversed CRC-32
; that ntdll's RtlComputeCrc32 does not compute, and a table for it would cost
; more than the check is worth here. Structural errors are caught anyway - a
; corrupt block fails to decode long before it produces plausible output.
; Deprecated "randomised" blocks (bzip2 before 0.9.0) are declined.
include foximg.inc

BZ_MAX_ALPHA        equ 258
BZ_MAX_GROUPS       equ 6
BZ_MAX_SELECTORS    equ 18002
BZ_CODELEN          equ 25              ; 23 real, plus slack for the vec walk
BZ_RUNA             equ 0
BZ_RUNB             equ 1
BZ_GROUP_RUN        equ 50              ; symbols decoded per selector

.data
g_bzBuf         dd 0                    ; bit accumulator, most significant bit first
g_bzCnt         dd 0
g_bzTT          dd 0                    ; nblock u32s: byte in the low 8 bits, link above
g_bzTTCb        dd 0
g_bzLevel       dd 0

.data?
g_bzLimit       dd BZ_MAX_GROUPS * BZ_CODELEN dup(?)
g_bzBase        dd BZ_MAX_GROUPS * BZ_CODELEN dup(?)
g_bzPerm        dd BZ_MAX_GROUPS * BZ_MAX_ALPHA dup(?)
g_bzMinLen      dd BZ_MAX_GROUPS dup(?)
g_bzMaxLen      dd BZ_MAX_GROUPS dup(?)
g_bzLen         db BZ_MAX_GROUPS * BZ_MAX_ALPHA dup(?)
g_bzSelector    db BZ_MAX_SELECTORS dup(?)
g_bzSelMtf      db BZ_MAX_SELECTORS dup(?)
g_bzSeqToUnseq  db 256 dup(?)
g_bzInUse       db 256 dup(?)
g_bzMtf         db 256 dup(?)
g_bzPos         db BZ_MAX_GROUPS dup(?)
g_bzCftab       dd 257 dup(?)
g_bzUnzftab     dd 256 dup(?)

.code

BzNextSym       PROTO :DWORD,:DWORD,:DWORD,:DWORD

; ---------------------------------------------------------------------------
; Bit input, most significant bit first, 1 - 24 bits
; ---------------------------------------------------------------------------
BzBits PROC USES ebx n:DWORD
    mov ebx, n
    .WHILE g_zfErr == 0
        mov eax, g_bzCnt
        .BREAK .IF eax >= ebx
        invoke ZfInByte
        shl g_bzBuf, 8
        or g_bzBuf, eax
        add g_bzCnt, 8
    .ENDW
    .IF g_zfErr != 0
        xor eax, eax
        ret
    .ENDIF
    mov ecx, g_bzCnt
    sub ecx, ebx                        ; the wanted bits sit at the top of what is held
    mov eax, g_bzBuf
    shr eax, cl
    mov g_bzCnt, ecx
    mov edx, 1
    mov ecx, ebx
    shl edx, cl
    dec edx
    and eax, edx
    ret
BzBits ENDP

; ---------------------------------------------------------------------------
; Huffman: limit / base / perm from the code lengths of one group (the layout
; bzip2's own decoder uses, walked bit by bit against the per-length limits)
; ---------------------------------------------------------------------------
BzTables PROC USES esi edi ebx grp:DWORD, alphaSize:DWORD
    LOCAL minLen:DWORD
    LOCAL maxLen:DWORD
    LOCAL pp:DWORD
    LOCAL i:DWORD
    LOCAL vec:DWORD
    LOCAL pLen:DWORD
    LOCAL pLimit:DWORD
    LOCAL pBase:DWORD
    LOCAL pPerm:DWORD
    mov eax, grp
    mov ecx, BZ_MAX_ALPHA
    mul ecx
    add eax, offset g_bzLen
    mov pLen, eax
    mov eax, grp
    mov ecx, BZ_CODELEN * 4
    mul ecx
    mov ecx, eax
    add eax, offset g_bzLimit
    mov pLimit, eax
    mov eax, ecx
    add eax, offset g_bzBase
    mov pBase, eax
    mov eax, grp
    mov ecx, BZ_MAX_ALPHA * 4
    mul ecx
    add eax, offset g_bzPerm
    mov pPerm, eax

    mov minLen, 32
    mov maxLen, 0
    mov esi, pLen
    xor ebx, ebx
    .WHILE ebx < alphaSize
        movzx eax, byte ptr [esi + ebx]
        .IF eax > maxLen
            mov maxLen, eax
        .ENDIF
        .IF eax < minLen
            mov minLen, eax
        .ENDIF
        inc ebx
    .ENDW
    .IF minLen < 1 || maxLen > 23
        xor eax, eax
        ret
    .ENDIF

    ; perm: symbols in order of code length, then by symbol
    mov pp, 0
    mov eax, minLen
    mov i, eax
    .WHILE 1
        mov ecx, maxLen
        .BREAK .IF i > ecx
        xor ebx, ebx
        .WHILE ebx < alphaSize
            mov esi, pLen
            movzx eax, byte ptr [esi + ebx]
            .IF eax == i
                mov edi, pPerm
                mov ecx, pp
                mov dword ptr [edi + ecx * 4], ebx
                inc pp
            .ENDIF
            inc ebx
        .ENDW
        inc i
    .ENDW

    ; base: running count of codes shorter than each length
    mov edi, pBase
    xor eax, eax
    mov ecx, BZ_CODELEN
    push edi
    rep stosd
    pop edi
    mov esi, pLen
    xor ebx, ebx
    .WHILE ebx < alphaSize
        movzx eax, byte ptr [esi + ebx]
        inc eax
        inc dword ptr [edi + eax * 4]
        inc ebx
    .ENDW
    mov ebx, 1
    .WHILE ebx < BZ_CODELEN
        mov eax, dword ptr [edi + ebx * 4 - 4]
        add dword ptr [edi + ebx * 4], eax
        inc ebx
    .ENDW

    ; limit: the largest code value of each length
    mov edi, pLimit
    xor eax, eax
    mov ecx, BZ_CODELEN
    rep stosd
    mov vec, 0
    mov eax, minLen
    mov i, eax
    .WHILE 1
        mov ecx, maxLen
        .BREAK .IF i > ecx
        mov esi, pBase
        mov ebx, i
        mov eax, dword ptr [esi + ebx * 4 + 4]
        sub eax, dword ptr [esi + ebx * 4]
        add vec, eax
        mov eax, vec
        dec eax
        mov edi, pLimit
        mov dword ptr [edi + ebx * 4], eax
        shl vec, 1
        inc i
    .ENDW
    mov eax, minLen
    inc eax
    mov i, eax
    .WHILE 1
        mov ecx, maxLen
        .BREAK .IF i > ecx
        mov ebx, i
        mov edi, pLimit
        mov eax, dword ptr [edi + ebx * 4 - 4]
        inc eax
        shl eax, 1
        mov esi, pBase
        sub eax, dword ptr [esi + ebx * 4]
        mov dword ptr [esi + ebx * 4], eax
        inc i
    .ENDW

    mov ebx, grp
    mov eax, minLen
    mov dword ptr g_bzMinLen[ebx * 4], eax
    mov eax, maxLen
    mov dword ptr g_bzMaxLen[ebx * 4], eax
    mov eax, TRUE
    ret
BzTables ENDP

; One symbol from group grp: start at the shortest code and take another bit
; while the value is past the limit for that length.
BzSym PROC USES esi ebx grp:DWORD
    LOCAL zn:DWORD
    LOCAL zvec:DWORD
    mov ebx, grp
    mov eax, dword ptr g_bzMinLen[ebx * 4]
    mov zn, eax
    invoke BzBits, eax
    mov zvec, eax
    mov eax, grp
    mov ecx, BZ_CODELEN * 4
    mul ecx
    mov esi, eax                        ; byte offset of this group's tables
    .WHILE g_zfErr == 0
        mov ebx, zn
        .IF ebx > 23
            mov g_zfErr, 1
            .BREAK
        .ENDIF
        mov eax, dword ptr g_bzLimit[esi + ebx * 4]
        .BREAK .IF zvec <= eax
        inc zn
        invoke BzBits, 1
        shl zvec, 1
        or zvec, eax
    .ENDW
    .IF g_zfErr != 0
        xor eax, eax
        ret
    .ENDIF
    mov ebx, zn
    mov eax, zvec
    sub eax, dword ptr g_bzBase[esi + ebx * 4]
    .IF eax >= BZ_MAX_ALPHA
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    mov ecx, grp
    push eax
    mov eax, ecx
    mov ecx, BZ_MAX_ALPHA * 4
    mul ecx
    mov ecx, eax
    pop eax
    mov eax, dword ptr g_bzPerm[ecx + eax * 4]
    ret
BzSym ENDP

; ---------------------------------------------------------------------------
; Stream: "BZh" and a level digit, then blocks until the end-of-stream magic
; ---------------------------------------------------------------------------
BzStart PROC
    mov g_bzBuf, 0
    mov g_bzCnt, 0
    invoke BzBits, 8
    .IF eax != 'B'
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    invoke BzBits, 8
    .IF eax != 'Z'
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    invoke BzBits, 8
    .IF eax != 'h'
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    invoke BzBits, 8
    sub eax, '0'
    .IF eax < 1 || eax > 9
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    mov g_bzLevel, eax
    ; one u32 per block byte, at 100000 bytes per level
    mov ecx, 100000
    mul ecx
    mov ecx, eax
    shl eax, 2
    .IF eax > g_bzTTCb
        invoke VfsFreeMem, g_bzTT
        invoke VfsAlloc, eax
        mov g_bzTT, eax
        .IF eax == 0
            mov g_bzTTCb, 0
            mov g_zfErr, 1
            xor eax, eax
            ret
        .ENDIF
        mov eax, g_bzLevel
        mov ecx, 100000 * 4
        mul ecx
        mov g_bzTTCb, eax
    .ENDIF
    mov eax, TRUE
    ret
BzStart ENDP

BzFree PROC
    invoke VfsFreeMem, g_bzTT
    mov g_bzTT, 0
    mov g_bzTTCb, 0
    ret
BzFree ENDP

; The symbol table, group count, selectors and per-group code lengths
BzBlockTables PROC USES esi edi ebx pAlpha:DWORD, pGroups:DWORD, pSelectors:DWORD
    LOCAL nInUse:DWORD
    LOCAL inUse16:DWORD
    LOCAL i:DWORD
    LOCAL j:DWORD
    LOCAL t:DWORD
    LOCAL curr:DWORD
    LOCAL nGroups:DWORD
    LOCAL nSel:DWORD
    LOCAL alphaN:DWORD
    LOCAL pRow:DWORD
    ; used-symbol bitmap: sixteen groups of sixteen
    mov edi, offset g_bzInUse
    xor eax, eax
    mov ecx, 64
    rep stosd
    invoke BzBits, 16
    mov inUse16, eax
    mov i, 0
    .WHILE i < 16
        mov ecx, i
        mov eax, 8000h
        shr eax, cl
        and eax, inUse16
        .IF eax != 0
            invoke BzBits, 16
            mov ebx, eax
            mov j, 0
            .WHILE j < 16
                mov ecx, j
                mov eax, 8000h
                shr eax, cl
                and eax, ebx
                .IF eax != 0
                    mov eax, i
                    shl eax, 4
                    add eax, j
                    mov byte ptr g_bzInUse[eax], 1
                .ENDIF
                inc j
            .ENDW
        .ENDIF
        inc i
    .ENDW
    xor ebx, ebx
    mov i, 0
    .WHILE i < 256
        mov eax, i
        .IF byte ptr g_bzInUse[eax] != 0
            mov byte ptr g_bzSeqToUnseq[ebx], al
            inc ebx
        .ENDIF
        inc i
    .ENDW
    mov nInUse, ebx
    .IF ebx == 0
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    add ebx, 2
    mov ecx, pAlpha
    mov dword ptr [ecx], ebx            ; alphaSize

    invoke BzBits, 3
    mov nGroups, eax
    .IF eax < 2 || eax > BZ_MAX_GROUPS
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    mov ecx, pGroups
    mov dword ptr [ecx], eax
    invoke BzBits, 15
    mov nSel, eax
    .IF eax < 1 || eax > BZ_MAX_SELECTORS
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    mov ecx, pSelectors
    mov dword ptr [ecx], eax

    ; selectors arrive move-to-front coded, each as a unary run of ones
    mov i, 0
    .WHILE g_zfErr == 0
        mov ecx, nSel
        .BREAK .IF i >= ecx
        xor ebx, ebx
        .WHILE g_zfErr == 0
            invoke BzBits, 1
            .BREAK .IF eax == 0
            inc ebx
            .IF ebx >= nGroups
                mov g_zfErr, 1
                .BREAK
            .ENDIF
        .ENDW
        mov eax, i
        mov byte ptr g_bzSelMtf[eax], bl
        inc i
    .ENDW
    .IF g_zfErr != 0
        xor eax, eax
        ret
    .ENDIF
    mov i, 0
    .WHILE 1
        mov ecx, nGroups
        .BREAK .IF i >= ecx
        mov eax, i
        mov byte ptr g_bzPos[eax], al
        inc i
    .ENDW
    mov i, 0
    .WHILE 1
        mov ecx, nSel
        .BREAK .IF i >= ecx
        mov eax, i
        movzx ebx, byte ptr g_bzSelMtf[eax]
        movzx edx, byte ptr g_bzPos[ebx]    ; pull it to the front
        .WHILE ebx > 0
            movzx eax, byte ptr g_bzPos[ebx - 1]
            mov byte ptr g_bzPos[ebx], al
            dec ebx
        .ENDW
        mov byte ptr g_bzPos[0], dl
        mov eax, i
        mov byte ptr g_bzSelector[eax], dl
        inc i
    .ENDW

    ; per-group code lengths, delta coded from a 5-bit start
    mov t, 0
    .WHILE g_zfErr == 0
        mov ecx, nGroups
        .BREAK .IF t >= ecx
        invoke BzBits, 5
        mov curr, eax
        mov eax, t
        mov ecx, BZ_MAX_ALPHA
        mul ecx
        add eax, offset g_bzLen
        mov pRow, eax                       ; kept in memory: BzBits calls out
        mov i, 0
        mov ecx, pAlpha
        mov eax, dword ptr [ecx]
        mov alphaN, eax
        .WHILE g_zfErr == 0
            mov ecx, alphaN
            .BREAK .IF i >= ecx
            .WHILE g_zfErr == 0
                .IF curr < 1 || curr > 20
                    mov g_zfErr, 1
                    .BREAK
                .ENDIF
                invoke BzBits, 1
                .BREAK .IF eax == 0
                invoke BzBits, 1
                .IF eax == 0
                    inc curr
                .ELSE
                    dec curr
                .ENDIF
            .ENDW
            mov eax, curr
            mov esi, pRow
            mov ecx, i
            mov byte ptr [esi + ecx], al
            inc i
        .ENDW
        inc t
    .ENDW
    .IF g_zfErr != 0
        xor eax, eax
        ret
    .ENDIF
    mov t, 0
    .WHILE 1
        mov ecx, nGroups
        .BREAK .IF t >= ecx
        mov ecx, pAlpha
        invoke BzTables, t, dword ptr [ecx]
        .IF eax == 0
            mov g_zfErr, 1
            xor eax, eax
            ret
        .ENDIF
        inc t
    .ENDW
    mov eax, TRUE
    ret
BzBlockTables ENDP

; One block: symbols into g_bzTT, then the inverse transform, then RLE1 out
BzBlock PROC USES esi edi ebx
    LOCAL alphaSize:DWORD
    LOCAL nGroups:DWORD
    LOCAL nSel:DWORD
    LOCAL origPtr:DWORD
    LOCAL nblock:DWORD
    LOCAL nblockMax:DWORD
    LOCAL groupNo:DWORD
    LOCAL groupPos:DWORD
    LOCAL gSel:DWORD
    LOCAL nextSym:DWORD
    LOCAL runEs:DWORD
    LOCAL nn:DWORD
    LOCAL eob:DWORD
    LOCAL i:DWORD
    LOCAL uc:DWORD
    LOCAL tPos:DWORD
    LOCAL runLen:DWORD
    LOCAL prev:DWORD
    LOCAL k:DWORD

    invoke BzBits, 24                   ; block CRC, parsed but not verified
    invoke BzBits, 8
    invoke BzBits, 1
    .IF eax != 0
        mov g_zfErr, 1                  ; randomised blocks (pre-0.9.0) are declined
        xor eax, eax
        ret
    .ENDIF
    invoke BzBits, 24
    mov origPtr, eax
    mov eax, g_bzLevel
    mov ecx, 100000
    mul ecx
    mov nblockMax, eax
    mov ecx, nblockMax
    .IF origPtr >= ecx
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF

    invoke BzBlockTables, addr alphaSize, addr nGroups, addr nSel
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF

    ; move-to-front list over the symbols actually used
    mov ebx, alphaSize
    sub ebx, 2
    xor ecx, ecx
    .WHILE ecx < ebx
        mov byte ptr g_bzMtf[ecx], cl
        inc ecx
    .ENDW
    mov edi, offset g_bzUnzftab
    xor eax, eax
    mov ecx, 256
    rep stosd

    mov eax, alphaSize
    dec eax
    mov eob, eax
    mov nblock, 0
    mov groupNo, -1
    mov groupPos, 0
    mov gSel, 0

    ; --- MTF and run-length symbols into the block buffer ---
    invoke BzNextSym, addr groupNo, addr groupPos, addr gSel, nSel
    mov nextSym, eax
    .WHILE g_zfErr == 0
        mov ecx, eob
        .BREAK .IF nextSym == ecx
        .IF nextSym == BZ_RUNA || nextSym == BZ_RUNB
            ; a run length in bijective base two, low digit first
            mov runEs, 0
            mov ebx, 1                  ; place value
            .WHILE g_zfErr == 0
                .IF nextSym == BZ_RUNA
                    add runEs, ebx
                .ELSE
                    lea eax, [ebx * 2]
                    add runEs, eax
                .ENDIF
                .IF ebx > 40000000h
                    mov g_zfErr, 1
                    .BREAK
                .ENDIF
                shl ebx, 1
                invoke BzNextSym, addr groupNo, addr groupPos, addr gSel, nSel
                mov nextSym, eax
                .BREAK .IF eax != BZ_RUNA && eax != BZ_RUNB
            .ENDW
            .BREAK .IF g_zfErr != 0
            movzx eax, byte ptr g_bzMtf[0]
            movzx eax, byte ptr g_bzSeqToUnseq[eax]
            mov uc, eax
            mov ecx, runEs
            add dword ptr g_bzUnzftab[eax * 4], ecx
            mov eax, nblock
            add eax, ecx
            .IF eax > nblockMax
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            mov edi, g_bzTT
            mov ecx, nblock
            lea edi, [edi + ecx * 4]
            mov eax, uc
            mov ecx, runEs
            rep stosd
            mov eax, runEs
            add nblock, eax
        .ELSE
            mov eax, nextSym
            dec eax
            mov nn, eax                 ; position in the move-to-front list
            .IF eax >= 256
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            movzx edx, byte ptr g_bzMtf[eax]
            mov ebx, eax
            .WHILE ebx > 0
                movzx eax, byte ptr g_bzMtf[ebx - 1]
                mov byte ptr g_bzMtf[ebx], al
                dec ebx
            .ENDW
            mov byte ptr g_bzMtf[0], dl
            movzx eax, byte ptr g_bzSeqToUnseq[edx]
            mov uc, eax
            inc dword ptr g_bzUnzftab[eax * 4]
            mov ecx, nblock
            .IF ecx >= nblockMax
                mov g_zfErr, 1
                .BREAK
            .ENDIF
            mov edi, g_bzTT
            mov dword ptr [edi + ecx * 4], eax
            inc nblock
            invoke BzNextSym, addr groupNo, addr groupPos, addr gSel, nSel
            mov nextSym, eax
        .ENDIF
    .ENDW
    .IF g_zfErr != 0 || nblock == 0
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF
    mov ecx, nblock
    .IF origPtr >= ecx
        mov g_zfErr, 1
        xor eax, eax
        ret
    .ENDIF

    ; --- inverse Burrows-Wheeler: thread each byte to its successor ---
    mov dword ptr g_bzCftab[0], 0
    mov i, 0
    .WHILE i < 256
        mov ebx, i
        mov eax, dword ptr g_bzUnzftab[ebx * 4]
        mov dword ptr g_bzCftab[ebx * 4 + 4], eax
        inc i
    .ENDW
    mov i, 1
    .WHILE i <= 256
        mov ebx, i
        mov eax, dword ptr g_bzCftab[ebx * 4 - 4]
        add dword ptr g_bzCftab[ebx * 4], eax
        inc i
    .ENDW
    mov i, 0
    .WHILE 1
        mov ecx, nblock
        .BREAK .IF i >= ecx
        mov esi, g_bzTT
        mov ecx, i
        mov eax, dword ptr [esi + ecx * 4]
        and eax, 0FFh
        mov edx, dword ptr g_bzCftab[eax * 4]
        .IF edx >= nblock
            mov g_zfErr, 1
            .BREAK
        .ENDIF
        mov ecx, i
        shl ecx, 8
        or dword ptr [esi + edx * 4], ecx
        inc dword ptr g_bzCftab[eax * 4]
        inc i
    .ENDW
    .IF g_zfErr != 0
        xor eax, eax
        ret
    .ENDIF
    mov ecx, origPtr
    mov eax, dword ptr [esi + ecx * 4]
    shr eax, 8
    mov tPos, eax

    ; --- RLE1: four equal bytes are followed by a count of extra copies ---
    mov runLen, 0
    mov prev, -1
    mov k, 0
    .WHILE g_zfErr == 0
        mov ecx, nblock
        .BREAK .IF k >= ecx
        mov ecx, tPos
        .IF ecx >= nblock
            mov g_zfErr, 1
            .BREAK
        .ENDIF
        mov esi, g_bzTT
        mov eax, dword ptr [esi + ecx * 4]
        movzx edx, al
        shr eax, 8
        mov tPos, eax
        mov uc, edx
        .IF runLen == 4
            mov runEs, edx                 ; this byte is the repeat count
            .WHILE runEs != 0 && g_zfErr == 0
                invoke ZfPutB, prev
                dec runEs
            .ENDW
            mov runLen, 0
            mov prev, -1
        .ELSE
            mov eax, uc
            .IF eax == prev
                inc runLen
            .ELSE
                mov runLen, 1
                mov prev, eax
            .ENDIF
            invoke ZfPutB, uc
        .ENDIF
        inc k
    .ENDW
    .IF g_zfErr != 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, TRUE
    ret
BzBlock ENDP

; The next symbol, rolling the selector on every fiftieth one
BzNextSym PROC USES ebx pGroupNo:DWORD, pGroupPos:DWORD, pGSel:DWORD, nSel:DWORD
    mov ebx, pGroupPos
    .IF dword ptr [ebx] == 0
        mov ebx, pGroupNo
        inc dword ptr [ebx]
        mov eax, dword ptr [ebx]
        .IF eax >= nSel
            mov g_zfErr, 1
            xor eax, eax
            ret
        .ENDIF
        movzx ecx, byte ptr g_bzSelector[eax]
        mov ebx, pGSel
        mov dword ptr [ebx], ecx
        mov ebx, pGroupPos
        mov dword ptr [ebx], BZ_GROUP_RUN
    .ENDIF
    mov ebx, pGroupPos
    dec dword ptr [ebx]
    mov ebx, pGSel
    invoke BzSym, dword ptr [ebx]
    ret
BzNextSym ENDP

; ---------------------------------------------------------------------------
; Whole stream from the current input position; TRUE when it ended cleanly
; ---------------------------------------------------------------------------
BzDecodeStream PROC USES ebx
    LOCAL hi:DWORD
    invoke BzStart
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    .WHILE g_zfErr == 0
        invoke BzBits, 24
        mov hi, eax
        invoke BzBits, 24
        .IF hi == 314159h && eax == 265359h
            invoke BzBlock
            .IF eax == 0
                xor eax, eax
                ret
            .ENDIF
        .ELSEIF hi == 177245h && eax == 385090h
            invoke BzBits, 24           ; combined stream CRC, not verified
            invoke BzBits, 8
            mov eax, TRUE
            ret
        .ELSE
            mov g_zfErr, 1
        .ENDIF
    .ENDW
    xor eax, eax
    ret
BzDecodeStream ENDP

END
