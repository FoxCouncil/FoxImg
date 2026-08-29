; FoxImg - XDVDFS reader (Xbox, Xbox 360 game discs and extracted XISO files)
;
; Volume descriptor at partition sector 32: "MICROSOFT*XBOX*MEDIA", root directory sector and size.
; Directory entries form a binary tree: left(2) right(2) startSector(4) fileSize(4) attributes(1) nameLen(1) name.
; Redump discs carry the game partition at a fixed byte offset; extracted images start at 0.
include foximg.inc

XD_ATTR_DIR     equ 10h

.data
g_bXdvdfs       dd 0
g_xdBase        dd 0            ; partition start, in 2048-byte blocks
g_xdRootSector  dd 0
g_xdRootSize    dd 0
szXdMagic       db 'MICROSOFT*XBOX*MEDIA'
g_xdBases       dd 0, 0FD90000h, 18300000h, 2080000h, 0FFFFFFFFh   ; XISO, XGD1, XGD2, XGD3
WSTR szXdName, <XDVDFS>
WSTR szXdRoot, <XBOX>

.code

XdWalkDir PROTO :DWORD,:DWORD,:DWORD,:DWORD

XdvdfsDetect PROC USES esi edi ebx
    xor ebx, ebx
    .WHILE g_xdBases[ebx * 4] != 0FFFFFFFFh
        mov eax, g_xdBases[ebx * 4]
        shr eax, 11
        mov edi, eax
        add eax, 32
        invoke IsoSectorPtr, eax
        .IF eax != 0
            mov esi, eax
            push esi
            mov edi, offset szXdMagic
            mov ecx, 20
            repe cmpsb
            pop esi
            .IF ZERO?
                mov eax, g_xdBases[ebx * 4]
                shr eax, 11
                mov g_xdBase, eax
                mov eax, [esi + 20]
                mov g_xdRootSector, eax
                mov eax, [esi + 24]
                mov g_xdRootSize, eax
                mov g_bXdvdfs, TRUE
                mov eax, TRUE
                ret
            .ENDIF
        .ENDIF
        inc ebx
    .ENDW
    xor eax, eax
    ret
XdvdfsDetect ENDP

; Visit the entry at 4-byte offset entOff of the directory table (sector, cb); recurses left / right / into subdirs
XdWalkDir PROC USES esi edi ebx pParent:DWORD, sector:DWORD, cb:DWORD, entOff:DWORD
    LOCAL ent[280]:BYTE
    LOCAL szName[NODE_NAME_MAX]:WORD
    LOCAL pNode:DWORD
    LOCAL nflags:DWORD
    LOCAL leftOff:DWORD
    LOCAL rightOff:DWORD

    mov eax, entOff
    shl eax, 2
    add eax, 14
    .IF eax > cb
        ret
    .ENDIF
    ; entry bytes: block = base + sector + off/2048, inside-block offset = off % 2048; copy out at once
    mov eax, entOff
    shl eax, 2
    mov ecx, eax
    shr eax, 11
    and ecx, 2047
    add eax, g_xdBase
    add eax, sector
    push ecx
    invoke IsoSectorPtr, eax
    pop ecx
    .IF eax == 0
        ret
    .ENDIF
    add eax, ecx
    mov edx, 2048
    sub edx, ecx
    .IF edx > 280
        mov edx, 280
    .ENDIF
    invoke RtlMoveMemory, addr ent, eax, edx
    lea esi, ent
    movzx eax, word ptr [esi]
    .IF eax == 0FFFFh
        ret                                 ; empty directory marker
    .ENDIF
    mov leftOff, eax
    movzx eax, word ptr [esi + 2]
    mov rightOff, eax

    ; name (ASCII/Latin-1) -> UTF-16
    movzx ecx, byte ptr [esi + 13]
    lea edi, szName
    lea ebx, [esi + 14]
    .WHILE ecx != 0
        movzx eax, byte ptr [ebx]
        stosw
        inc ebx
        dec ecx
    .ENDW
    xor eax, eax
    stosw

    mov nflags, NF_ISO
    test byte ptr [esi + 12], XD_ATTR_DIR
    .IF !ZERO?
        or nflags, NF_DIR
    .ENDIF
    invoke VfsNew, pParent, addr szName, nflags
    .IF eax != 0
        mov pNode, eax
        mov edi, eax
        mov eax, [esi + 4]
        add eax, g_xdBase
        mov [edi].NODE.isoExtent, eax
        mov eax, [esi + 8]
        mov [edi].NODE.dataSize, eax
        invoke VfsDateNow, edi
        test nflags, NF_DIR
        .IF !ZERO?
            mov eax, [esi + 8]
            .IF eax != 0
                mov ecx, [esi + 4]
                invoke XdWalkDir, edi, ecx, eax, 0
            .ENDIF
        .ENDIF
    .ENDIF
    .IF leftOff != 0
        invoke XdWalkDir, pParent, sector, cb, leftOff
    .ENDIF
    .IF rightOff != 0
        invoke XdWalkDir, pParent, sector, cb, rightOff
    .ENDIF
    ret
XdWalkDir ENDP

XdvdfsBuild PROC pRoot:DWORD
    mov eax, pRoot
    lea eax, [eax].NODE.szName
    invoke lstrcpynW, eax, offset szXdRoot, NODE_NAME_MAX
    invoke XdWalkDir, pRoot, g_xdRootSector, g_xdRootSize, 0
    mov eax, TRUE
    ret
XdvdfsBuild ENDP

XdvdfsClose PROC
    mov g_bXdvdfs, 0
    ret
XdvdfsClose ENDP

END
