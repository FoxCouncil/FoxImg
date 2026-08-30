; FoxImg - GameCube disc reader (.gcm / .iso dumps, and GCZ once expanded)
;
; Header at byte 0: game code, then the 0xC2339F3D magic word at 0x1C and the game title at 0x20.
; The file system table lives at the byte offset in 0x424 (all header fields are big-endian).
; FST entries are 12 bytes: flags(1) nameOffset(3) fileOffset/parent(4) length/nextIndex(4).
; Entry 0 is the root; a directory entry's length field is the index just past its subtree,
; which drives the iterative walk below. File offsets are byte-granular, not block-aligned.
include foximg.inc

GC_MAGIC        equ 3D9F33C2h           ; bytes C2 33 9F 3D read as a little-endian dword
GC_FST_MAX      equ 16 * 1024 * 1024
GC_STACK_MAX    equ 64

.data
g_bGcm          dd 0
g_gcFstOff      dd 0
g_gcFstSize     dd 0
WSTR szGcRoot, <GAMECUBE>

.code

GcBswap PROC val:DWORD
    mov eax, val
    bswap eax
    ret
GcBswap ENDP

GcDetect PROC
    invoke IsoSectorPtr, 0
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov ecx, eax
    .IF dword ptr [ecx + 1Ch] != GC_MAGIC
        xor eax, eax
        ret
    .ENDIF
    push ecx
    invoke GcBswap, dword ptr [ecx + 424h]
    pop ecx
    mov g_gcFstOff, eax
    push ecx
    invoke GcBswap, dword ptr [ecx + 428h]
    pop ecx
    mov g_gcFstSize, eax
    .IF g_gcFstOff == 0 || eax < 12 || eax > GC_FST_MAX
        xor eax, eax
        ret
    .ENDIF
    mov g_bGcm, TRUE
    mov eax, TRUE
    ret
GcDetect ENDP

; ASCII at pSrc (NUL-terminated, at most cbMax bytes) into the UTF-16 buffer pszOut
GcName PROC USES esi edi pszOut:DWORD, pSrc:DWORD, cbMax:DWORD
    mov esi, pSrc
    mov edi, pszOut
    mov ecx, cbMax
    .WHILE ecx != 0
        movzx eax, byte ptr [esi]
        .BREAK .IF eax == 0
        stosw
        inc esi
        dec ecx
    .ENDW
    xor eax, eax
    stosw
    ret
GcName ENDP

GcBuild PROC USES esi edi ebx pRoot:DWORD
    LOCAL pFst:DWORD
    LOCAL nEnt:DWORD
    LOCAL pStr:DWORD
    LOCAL cbStr:DWORD
    LOCAL i:DWORD
    LOCAL nStk:DWORD
    LOCAL cur:DWORD
    LOCAL nameOff:DWORD
    LOCAL fileOff:DWORD
    LOCAL fileLen:DWORD
    LOCAL pNode:DWORD
    LOCAL szName[NODE_NAME_MAX]:WORD
    LOCAL stkNode[GC_STACK_MAX]:DWORD
    LOCAL stkEnd[GC_STACK_MAX]:DWORD

    ; root name: the game title from the header
    invoke IsoSectorPtr, 0
    .IF eax != 0
        add eax, 20h
        invoke GcName, addr szName, eax, 48
        mov eax, pRoot
        lea edi, [eax].NODE.szName
        invoke lstrcpynW, edi, addr szName, NODE_NAME_MAX
        mov eax, pRoot
        .IF word ptr [eax].NODE.szName == 0
            lea eax, [eax].NODE.szName
            invoke lstrcpynW, eax, offset szGcRoot, NODE_NAME_MAX
        .ENDIF
    .ENDIF

    mov eax, g_gcFstSize
    add eax, 2
    invoke VfsAlloc, eax
    mov pFst, eax
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, g_gcFstOff
    mov ecx, eax
    shr eax, 11
    and ecx, 2047
    invoke IsoReadBytes, eax, ecx, g_gcFstSize, pFst
    .IF eax == 0
        jmp fail
    .ENDIF
    mov ecx, pFst
    invoke GcBswap, dword ptr [ecx + 8]
    mov nEnt, eax
    .IF eax < 1 || eax > 100000h
        jmp fail
    .ENDIF
    mov ecx, eax
    lea eax, [ecx + ecx * 2]            ; entries * 12
    shl eax, 2
    .IF eax > g_gcFstSize
        jmp fail
    .ENDIF
    mov ecx, pFst
    add ecx, eax
    mov pStr, ecx
    mov ecx, g_gcFstSize
    sub ecx, eax
    mov cbStr, ecx

    mov i, 1
    mov nStk, 0
    mov eax, pRoot
    mov cur, eax
    .WHILE TRUE
        mov eax, i
        .BREAK .IF eax >= nEnt
        ; leave finished directories
        .WHILE nStk != 0
            mov ecx, nStk
            mov eax, stkEnd[ecx * 4 - 4]
            mov edx, i
            .BREAK .IF edx < eax
            dec nStk
            mov ecx, nStk
            .IF ecx == 0
                mov eax, pRoot
            .ELSE
                mov eax, stkNode[ecx * 4 - 4]
            .ENDIF
            mov cur, eax
        .ENDW
        ; entry fields (big-endian)
        mov esi, i
        lea esi, [esi + esi * 2]
        shl esi, 2
        add esi, pFst
        movzx eax, byte ptr [esi + 1]
        shl eax, 16
        movzx ecx, byte ptr [esi + 2]
        shl ecx, 8
        or eax, ecx
        movzx ecx, byte ptr [esi + 3]
        or eax, ecx
        mov nameOff, eax
        .IF eax >= cbStr
            jmp fail
        .ENDIF
        invoke GcBswap, dword ptr [esi + 4]
        mov fileOff, eax
        invoke GcBswap, dword ptr [esi + 8]
        mov fileLen, eax
        mov eax, pStr
        add eax, nameOff
        invoke GcName, addr szName, eax, NODE_NAME_MAX - 1
        movzx eax, byte ptr [esi]
        .IF eax != 0
            ; directory: length is the first index past its contents
            mov eax, fileLen
            .IF eax > nEnt
                jmp fail
            .ENDIF
            invoke VfsNew, cur, addr szName, NF_ISO or NF_DIR
            .IF eax != 0
                mov pNode, eax
                invoke VfsDateNow, pNode
                mov ecx, nStk
                .IF ecx < GC_STACK_MAX
                    mov eax, pNode
                    mov stkNode[ecx * 4], eax
                    mov eax, fileLen
                    mov stkEnd[ecx * 4], eax
                    inc nStk
                    mov eax, pNode
                    mov cur, eax
                .ENDIF
            .ENDIF
        .ELSE
            invoke VfsNew, cur, addr szName, NF_ISO
            .IF eax != 0
                mov pNode, eax
                mov edi, eax
                mov eax, fileOff
                mov ecx, eax
                shr eax, 11
                and ecx, 2047
                mov [edi].NODE.isoExtent, eax
                mov [edi].NODE.isoByteRem, ecx
                mov eax, fileLen
                mov [edi].NODE.dataSize, eax
                invoke VfsDateNow, edi
            .ENDIF
        .ENDIF
        inc i
    .ENDW
    invoke VfsFreeMem, pFst
    mov eax, TRUE
    ret
fail:
    invoke VfsFreeMem, pFst
    xor eax, eax
    ret
GcBuild ENDP

GcClose PROC
    mov g_bGcm, 0
    ret
GcClose ENDP

END
