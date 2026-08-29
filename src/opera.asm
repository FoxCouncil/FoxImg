; FoxImg - Opera filesystem reader (3DO discs)
;
; Block 0 is the volume header (big-endian): record type 1, five 5Ah sync bytes, label at 40, block size at 76,
; root directory block count at 88, root copies at 96 and the copy block list at 100. Directories are chains of
; blocks with a 20-byte header (next block at 0, first free byte at 12, first entry at 16); entries carry flags,
; type, sizes, a 32-byte name, the last copy index at 64 and one start block per copy from 68.
include foximg.inc

OP_ENTRY_FIXED  equ 72
OP_TYPE_DIR     equ 07h

.data
g_bOpera        dd 0
g_opRootBlock   dd 0
WSTR szOpName, <Opera (3DO)>

.code

OpWalkDir PROTO :DWORD,:DWORD

BE32 PROC pSrc:DWORD
    mov eax, pSrc
    mov eax, [eax]
    bswap eax
    ret
BE32 ENDP

OperaDetect PROC USES esi
    invoke IsoSectorPtr, 0
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov esi, eax
    .IF byte ptr [esi] != 1 || byte ptr [esi + 1] != 5Ah || byte ptr [esi + 2] != 5Ah || byte ptr [esi + 5] != 5Ah
        xor eax, eax
        ret
    .ENDIF
    lea eax, [esi + 76]
    invoke BE32, eax
    .IF eax != ISO_SECTOR
        xor eax, eax
        ret
    .ENDIF
    lea eax, [esi + 100]
    invoke BE32, eax
    mov g_opRootBlock, eax
    mov g_bOpera, TRUE
    mov eax, TRUE
    ret
OperaDetect ENDP

; Directory chain starting at block; entries become children of pParent
OpWalkDir PROC USES esi edi ebx pParent:DWORD, block:DWORD
    LOCAL blk[ISO_SECTOR]:BYTE
    LOCAL szName[40]:WORD
    LOCAL pos:DWORD
    LOCAL freeAt:DWORD
    LOCAL nextBlk:DWORD
    LOCAL nflags:DWORD
    LOCAL pNode:DWORD
    LOCAL entLen:DWORD
    LOCAL cur:DWORD
    LOCAL depth:DWORD

    mov eax, block
    mov cur, eax
    mov depth, 0
    .WHILE cur != 0FFFFFFFFh && depth < 4096
        inc depth
        invoke IsoReadExtent, cur, ISO_SECTOR, addr blk
        .BREAK .IF eax == 0
        invoke BE32, addr blk[0]
        mov nextBlk, eax
        invoke BE32, addr blk[12]
        mov freeAt, eax
        .IF eax > ISO_SECTOR
            mov freeAt, ISO_SECTOR
        .ENDIF
        invoke BE32, addr blk[16]
        mov pos, eax
        .WHILE TRUE
            mov eax, pos
            add eax, OP_ENTRY_FIXED
            .BREAK .IF eax > freeAt
            lea esi, blk
            add esi, pos
            lea eax, [esi + 64]
            invoke BE32, eax
            lea ecx, [eax + 1]                  ; copies = last copy index + 1
            shl ecx, 2
            add ecx, 68                         ; fixed part is 68 bytes, then one block number per copy
            mov entLen, ecx
            mov eax, pos
            add eax, ecx
            .BREAK .IF eax > freeAt
            ; name: 32 bytes, NUL padded
            lea ebx, [esi + 32]
            lea edi, szName
            mov ecx, 32
            .WHILE ecx != 0 && byte ptr [ebx] != 0
                movzx eax, byte ptr [ebx]
                stosw
                inc ebx
                dec ecx
            .ENDW
            xor eax, eax
            stosw
            invoke BE32, esi
            mov nflags, NF_ISO
            and eax, 0FFh
            .IF eax == OP_TYPE_DIR
                or nflags, NF_DIR
            .ENDIF
            .IF szName[0] != 0
                invoke VfsNew, pParent, addr szName, nflags
                .IF eax != 0
                    mov pNode, eax
                    mov edi, eax
                    lea eax, [esi + 68]
                    invoke BE32, eax
                    mov [edi].NODE.isoExtent, eax
                    lea eax, [esi + 16]
                    invoke BE32, eax
                    mov [edi].NODE.dataSize, eax
                    invoke VfsDateNow, edi
                    test nflags, NF_DIR
                    .IF !ZERO?
                        invoke OpWalkDir, edi, [edi].NODE.isoExtent
                        ; the walk read other blocks; reload this one
                        invoke IsoReadExtent, cur, ISO_SECTOR, addr blk
                    .ENDIF
                .ENDIF
            .ENDIF
            mov eax, entLen
            add pos, eax
        .ENDW
        mov eax, nextBlk
        mov cur, eax
    .ENDW
    ret
OpWalkDir ENDP

OperaBuild PROC USES esi edi pRoot:DWORD
    LOCAL szLabel[34]:WORD
    ; volume label from the header
    invoke IsoSectorPtr, 0
    .IF eax != 0
        lea esi, [eax + 40]
        lea edi, szLabel
        mov ecx, 32
        .WHILE ecx != 0 && byte ptr [esi] != 0
            movzx eax, byte ptr [esi]
            stosw
            inc esi
            dec ecx
        .ENDW
        xor eax, eax
        stosw
        .IF szLabel[0] != 0
            mov edx, pRoot
            lea edx, [edx].NODE.szName
            invoke lstrcpynW, edx, addr szLabel, NODE_NAME_MAX
        .ENDIF
    .ENDIF
    invoke OpWalkDir, pRoot, g_opRootBlock
    mov eax, TRUE
    ret
OperaBuild ENDP

OperaClose PROC
    mov g_bOpera, 0
    ret
OperaClose ENDP

END
