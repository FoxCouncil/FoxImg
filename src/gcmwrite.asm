; FoxImg - GameCube disc writer (.gcm)
;
; Layout produced:
;   0x0000  boot.bin (0x440): game code, the C2339F3D magic, the title, and
;           at 0x420 the DOL offset, FST offset, FST size and largest FST size
;   0x0440  bi2.bin (0x2000)
;   0x2440  the apploader, when the source had one
;   ..      main.dol, when the source had one; each region padded to 32 bytes
;   ..      the FST: 12-byte entries (type, name offset, offset or parent,
;           length or next index) in preorder, then the name strings
;   ..      file data, in FST order, each padded to 32 bytes
;
; The reader exposes the source's system files under "sys"; they are taken
; from there and left out of the FST. Without them the header is made up:
; the disc will browse but not boot. Offsets are 32-bit, as the format's.
; Sorting and the sector staging come from xdvdwrite.asm and isowrite.asm.
include foximg.inc

GCM_BOOT        equ 440h
GCM_BI2         equ 2000h
GCM_APPLOADER   equ 2440h
GCM_ALIGN       equ 32
GC_WR_MAGIC     equ 3D9F33C2h           ; C2 33 9F 3D as a little-endian dword

.data
WSTR szGcSys, <sys>
WSTR szGcBoot, <boot.bin>
WSTR szGcBi2, <bi2.bin>
WSTR szGcApp, <apploader.img>
WSTR szGcDol, <main.dol>
szGcCode        db 'GFOX01'
g_gwFst         dd 0                    ; the FST being built
g_gwFstCb       dd 0                    ; entries and strings so far
g_gwStrPos      dd 0                    ; next string byte, from the table start
g_gwIndex       dd 0                    ; next entry index
g_gwEntries     dd 0
g_gwSys         dd 0                    ; the sys node, skipped in the FST
g_gwDataPos     dd 0                    ; next file data offset
.code

; The child of pDir named pszName, or 0
GwChild PROC USES esi pDir:DWORD, pszName:DWORD
    mov esi, pDir
    .IF esi == 0
        xor eax, eax
        ret
    .ENDIF
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        lea eax, [esi].NODE.szName
        invoke lstrcmpiW, eax, pszName
        .IF eax == 0
            mov eax, esi
            ret
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    xor eax, eax
    ret
GwChild ENDP

; Entries under pDir, sys excluded: 1 per node
GwCount PROC USES esi pDir:DWORD
    LOCAL n:DWORD
    mov n, 0
    mov esi, pDir
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        .IF esi != g_gwSys
            inc n
            test [esi].NODE.nflags, NF_DIR
            .IF !ZERO?
                invoke GwCount, esi
                add n, eax
            .ENDIF
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    mov eax, n
    ret
GwCount ENDP

; pDir's children into the FST in name order, recursing; parentIdx names
; the directory's own entry. File offsets are handed out from g_gwDataPos.
GwEmitDir PROC USES esi edi ebx pDir:DWORD, parentIdx:DWORD
    LOCAL i:DWORD
    LOCAL pSorted:DWORD
    LOCAL count:DWORD
    LOCAL myIdx:DWORD
    LOCAL szName[256]:BYTE
    invoke XwCollect, pDir                  ; sorted children in g_xwSorted; the array is taken over here
    .IF eax == 0
        ret
    .ENDIF
    mov eax, g_xwSorted
    mov pSorted, eax
    mov g_xwSorted, 0
    mov eax, g_xwCount
    mov count, eax
    mov i, 0
    .WHILE 1
        mov ecx, i
        .BREAK .IF ecx >= count
        mov eax, pSorted
        mov ebx, [eax + ecx * 4]
        inc i
        .CONTINUE .IF ebx == g_gwSys
        ; the entry
        mov eax, g_gwIndex
        mov myIdx, eax
        inc g_gwIndex
        mov edi, g_gwFst
        lea edi, [edi + eax * 4]
        lea edi, [edi + eax * 8]            ; entry * 12
        mov eax, g_gwStrPos
        bswap eax
        mov dword ptr [edi], eax            ; name offset, big-endian, in the top three bytes
        invoke XwName, ebx, addr szName
        mov ecx, eax
        push ecx
        push edi
        mov edi, g_gwEntries
        lea edi, [edi + edi * 2]
        shl edi, 2                          ; the string table starts after entries * 12
        add edi, g_gwFst
        add edi, g_gwStrPos
        lea esi, szName
        rep movsb
        mov byte ptr [edi], 0
        pop edi
        pop ecx
        inc ecx
        add g_gwStrPos, ecx
        test [ebx].NODE.nflags, NF_DIR
        .IF !ZERO?
            mov byte ptr [edi], 1
            mov eax, parentIdx
            bswap eax
            mov dword ptr [edi + 4], eax
            invoke GwEmitDir, ebx, myIdx
            .IF eax == 0
                invoke VfsFreeMem, pSorted
                xor eax, eax
                ret
            .ENDIF
            mov eax, g_gwIndex              ; next index past the subtree
            bswap eax
            mov dword ptr [edi + 8], eax
        .ELSE
            .IF [ebx].NODE.dataSizeHi != 0
                invoke VfsFreeMem, pSorted
                xor eax, eax
                ret
            .ENDIF
            mov eax, g_gwDataPos
            mov [ebx].NODE.wExtent, eax     ; byte offset on the disc
            bswap eax
            mov dword ptr [edi + 4], eax
            mov eax, [ebx].NODE.dataSize
            bswap eax
            mov dword ptr [edi + 8], eax
            mov eax, [ebx].NODE.dataSize
            add eax, GCM_ALIGN - 1
            and eax, -GCM_ALIGN
            add g_gwDataPos, eax
            .IF CARRY?
                invoke VfsFreeMem, pSorted
                xor eax, eax
                ret
            .ENDIF
        .ENDIF
    .ENDW
    invoke VfsFreeMem, pSorted
    mov eax, TRUE
    ret
GwEmitDir ENDP

; cb zero bytes to the output
GwZeros PROC USES ebx cb:DWORD
    mov ebx, cb
    .WHILE ebx != 0 && g_fail == 0
        mov ecx, ebx
        .IF ecx > ISO_SECTOR
            mov ecx, ISO_SECTOR
        .ENDIF
        push ecx
        invoke WriteAll, g_hOut, g_pSec, ecx
        pop ecx
        .IF eax == 0
            mov g_fail, TRUE
        .ENDIF
        sub ebx, ecx
    .ENDW
    ret
GwZeros ENDP

; A system region: the node's data (or nothing), padded out to regionCb
GwRegion PROC pNode:DWORD, regionCb:DWORD
    LOCAL have:DWORD
    mov have, 0
    .IF pNode != 0
        invoke VfsCopyData, pNode, g_hOut
        .IF eax == 0
            mov g_fail, TRUE
            ret
        .ENDIF
        mov eax, pNode
        mov eax, [eax].NODE.dataSize
        mov have, eax
    .ENDIF
    mov eax, regionCb
    sub eax, have
    invoke GwZeros, eax
    ret
GwRegion ENDP

; Files under pDir in FST order (the same sort), each padded to 32 bytes
GwWriteFiles PROC USES esi ebx pDir:DWORD
    LOCAL i:DWORD
    LOCAL pSorted:DWORD
    LOCAL count:DWORD
    invoke XwCollect, pDir
    .IF eax == 0
        mov g_fail, TRUE
        ret
    .ENDIF
    mov eax, g_xwSorted
    mov pSorted, eax
    mov g_xwSorted, 0
    mov eax, g_xwCount
    mov count, eax
    mov i, 0
    .WHILE g_fail == 0
        mov ecx, i
        .BREAK .IF ecx >= count
        mov eax, pSorted
        mov ebx, [eax + ecx * 4]
        inc i
        .CONTINUE .IF ebx == g_gwSys
        test [ebx].NODE.nflags, NF_DIR
        .IF !ZERO?
            invoke GwWriteFiles, ebx
        .ELSE
            .IF [ebx].NODE.dataSize != 0
                invoke VfsCopyData, ebx, g_hOut
                .IF eax == 0
                    mov g_fail, TRUE
                    .BREAK
                .ENDIF
            .ENDIF
            mov eax, [ebx].NODE.dataSize
            neg eax
            and eax, GCM_ALIGN - 1
            invoke GwZeros, eax
        .ENDIF
    .ENDW
    invoke VfsFreeMem, pSorted
    ret
GwWriteFiles ENDP

GcmWrite PROC USES esi edi ebx pszOutPath:DWORD
    LOCAL pBoot:DWORD
    LOCAL pBi2:DWORD
    LOCAL pApp:DWORD
    LOCAL pDol:DWORD
    LOCAL dolOff:DWORD
    LOCAL fstOff:DWORD
    LOCAL fstCb:DWORD
    LOCAL dataOff:DWORD
    LOCAL hdr[GCM_BOOT]:BYTE
    LOCAL fields[4]:DWORD
    mov g_fail, FALSE
    mov g_hOut, 0
    mov g_gwFst, 0
    .IF g_pRootNode == 0
        xor eax, eax
        ret
    .ENDIF
    invoke VfsAlloc, ISO_SECTOR
    mov g_pSec, eax
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    invoke GwChild, g_pRootNode, offset szGcSys
    mov g_gwSys, eax
    invoke GwChild, g_gwSys, offset szGcBoot
    mov pBoot, eax
    invoke GwChild, g_gwSys, offset szGcBi2
    mov pBi2, eax
    invoke GwChild, g_gwSys, offset szGcApp
    mov pApp, eax
    invoke GwChild, g_gwSys, offset szGcDol
    mov pDol, eax
    .IF pBoot != 0
        mov eax, pBoot
        .IF [eax].NODE.dataSize != GCM_BOOT
            mov pBoot, 0                    ; not a boot block after all
        .ENDIF
    .ENDIF
    ; the layout: apploader, DOL, FST, data
    mov dolOff, 0
    mov eax, GCM_APPLOADER
    .IF pApp != 0
        mov ecx, pApp
        add eax, [ecx].NODE.dataSize
        add eax, GCM_ALIGN - 1
        and eax, -GCM_ALIGN
    .ENDIF
    .IF pDol != 0
        mov dolOff, eax
        mov ecx, pDol
        add eax, [ecx].NODE.dataSize
        add eax, GCM_ALIGN - 1
        and eax, -GCM_ALIGN
    .ENDIF
    mov fstOff, eax
    invoke GwCount, g_pRootNode
    inc eax                                 ; the root entry
    mov g_gwEntries, eax
    mov ecx, eax
    lea eax, [eax + eax * 2]
    shl eax, 2                              ; entries * 12
    mov edx, ecx
    shl edx, 8                              ; and up to 256 name bytes each
    add eax, edx
    add eax, 16
    invoke VfsAlloc, eax
    mov g_gwFst, eax
    .IF eax == 0
        jmp cleanup_fail
    .ENDIF
    ; the root entry: a directory whose length is the entry count
    mov edi, eax
    mov byte ptr [edi], 1
    mov eax, g_gwEntries
    bswap eax
    mov dword ptr [edi + 8], eax
    mov g_gwIndex, 1
    mov g_gwStrPos, 1                       ; the root's empty name
    mov eax, g_gwEntries
    lea eax, [eax + eax * 2]
    shl eax, 2
    mov ecx, g_gwFst
    mov byte ptr [ecx + eax], 0
    ; data starts after the FST; its size is known once the names are counted
    ; so first lay the entries out with a provisional start, then shift
    mov g_gwDataPos, 0
    invoke GwEmitDir, g_pRootNode, 0
    .IF eax == 0
        jmp cleanup_fail
    .ENDIF
    mov eax, g_gwEntries
    lea eax, [eax + eax * 2]
    shl eax, 2
    add eax, g_gwStrPos
    mov fstCb, eax
    add eax, fstOff
    add eax, GCM_ALIGN - 1
    and eax, -GCM_ALIGN
    mov dataOff, eax
    ; shift every file offset by the data start
    mov esi, g_gwFst
    mov ecx, 1
    .WHILE ecx < g_gwEntries
        lea edi, [ecx + ecx * 2]
        shl edi, 2
        add edi, esi
        .IF byte ptr [edi] == 0
            mov eax, dword ptr [edi + 4]
            bswap eax
            add eax, dataOff
            bswap eax
            mov dword ptr [edi + 4], eax
        .ENDIF
        inc ecx
    .ENDW
    mov eax, dataOff
    add eax, g_gwDataPos
    .IF CARRY?
        jmp cleanup_fail                    ; past 4 GB
    .ENDIF
    add eax, ISO_SECTOR - 1
    and eax, -ISO_SECTOR
    mov g_progTotal, eax
    mov g_progTotalHi, 0
    invoke CreateFileW, pszOutPath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        jmp cleanup_fail
    .ENDIF
    mov g_hOut, eax
    invoke FilePresize, g_hOut, g_progTotal, 0
    invoke FillBytes, g_pSec, 0, ISO_SECTOR
    ; boot.bin: the source's, or a bare one with the magic and the title
    .IF pBoot != 0
        invoke GwRegion, pBoot, GCM_BOOT
    .ELSE
        lea edi, hdr
        invoke FillBytes, edi, 0, GCM_BOOT
        invoke RtlMoveMemory, edi, offset szGcCode, 6
        mov dword ptr [edi + 1Ch], GC_WR_MAGIC
        mov esi, g_pRootNode
        lea esi, [esi].NODE.szName
        lea edi, hdr[20h]
        xor ecx, ecx
        .WHILE ecx < 63
            movzx eax, word ptr [esi]
            .BREAK .IF eax == 0
            .IF eax > 127
                mov eax, '_'
            .ENDIF
            mov byte ptr [edi], al
            inc edi
            add esi, 2
            inc ecx
        .ENDW
        invoke WriteAll, g_hOut, addr hdr, GCM_BOOT
        .IF eax == 0
            mov g_fail, TRUE
        .ENDIF
    .ENDIF
    invoke GwRegion, pBi2, GCM_BI2
    .IF pApp != 0
        mov eax, pApp
        mov eax, [eax].NODE.dataSize
        add eax, GCM_ALIGN - 1
        and eax, -GCM_ALIGN
        invoke GwRegion, pApp, eax
    .ENDIF
    .IF pDol != 0
        mov eax, pDol
        mov eax, [eax].NODE.dataSize
        add eax, GCM_ALIGN - 1
        and eax, -GCM_ALIGN
        invoke GwRegion, pDol, eax
    .ENDIF
    invoke WriteAll, g_hOut, g_gwFst, fstCb
    .IF eax == 0
        mov g_fail, TRUE
    .ENDIF
    mov eax, dataOff
    sub eax, fstOff
    sub eax, fstCb
    invoke GwZeros, eax
    .IF g_fail == 0
        invoke GwWriteFiles, g_pRootNode
    .ENDIF
    ; the disc ends on a 2048-byte block, as readers that map blocks expect
    mov eax, dataOff
    add eax, g_gwDataPos
    neg eax
    and eax, ISO_SECTOR - 1
    invoke GwZeros, eax
    ; the header fields at 0x420
    .IF g_fail == 0
        mov eax, dolOff
        bswap eax
        mov fields[0], eax
        mov eax, fstOff
        bswap eax
        mov fields[4], eax
        mov eax, fstCb
        bswap eax
        mov fields[8], eax
        mov fields[12], eax
        invoke SetFilePointerEx, g_hOut, 420h, 0, NULL, FILE_BEGIN
        invoke WriteAll, g_hOut, addr fields, 16
        .IF eax == 0
            mov g_fail, TRUE
        .ENDIF
    .ENDIF
    invoke CloseHandle, g_hOut
    mov g_hOut, 0
    .IF g_fail != 0
        invoke DeleteFileW, pszOutPath
        jmp cleanup_fail
    .ENDIF
    invoke VfsFreeMem, g_gwFst
    invoke VfsFreeMem, g_pSec
    mov eax, TRUE
    ret
cleanup_fail:
    .IF g_hOut != 0
        invoke CloseHandle, g_hOut
    .ENDIF
    invoke VfsFreeMem, g_gwFst
    invoke VfsFreeMem, g_pSec
    xor eax, eax
    ret
GcmWrite ENDP

END
