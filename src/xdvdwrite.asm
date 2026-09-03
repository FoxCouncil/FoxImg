; FoxImg - XDVDFS writer (Xbox XISO)
;
; Layout produced:
;   0-31   zero
;   32     volume descriptor: "MICROSOFT*XBOX*MEDIA", root table sector and size,
;          a FILETIME, the magic again at the end of the sector
;   33..   directory tables, root first then breadth-first, each whole sectors
;   ..     file data, depth-first in directory order, each padded to a sector
;
; A directory table is a binary search tree of entries: left(2) right(2) in
; 4-byte units from the table start, sector(4), size(4), attributes(1),
; name length(1), the ASCII name, padded to 4 bytes. An entry never crosses a
; sector; the gap and the tail of the table are FFh. The tree is balanced
; over the names sorted without case, which is how the console looks them up.
; An empty directory is one sector of FFh. Sizes are 32-bit, so files stop
; at 4 GB. The sector staging, layout and file copying are isowrite.asm's.
include foximg.inc

XW_ATTR_DIR     equ 10h
XW_ATTR_FILE    equ 20h
XW_DESC_SECTOR  equ 32
XW_ENTRY_MAX    equ 272                 ; 14 + 255, padded

.data
szXwMagic       db 'MICROSOFT*XBOX*MEDIA'
g_xwBuf         dd 0                    ; the table being built
g_xwBufCb       dd 0
g_xwSorted      dd 0                    ; the directory's children, sorted
g_xwCount       dd 0
.code

; The node's name as ASCII at pDst (at most 255 bytes); length in eax
XwName PROC USES esi edi pNode:DWORD, pDst:DWORD
    mov esi, pNode
    lea esi, [esi].NODE.szName
    mov edi, pDst
    xor ecx, ecx
    .WHILE ecx < 255
        movzx eax, word ptr [esi]
        .BREAK .IF eax == 0
        .IF eax > 255
            mov eax, '_'
        .ENDIF
        mov byte ptr [edi], al
        inc edi
        add esi, 2
        inc ecx
    .ENDW
    mov eax, ecx
    ret
XwName ENDP

; Names of two nodes compared without case: eax below, equal or above zero
XwCompare PROC USES esi edi a:DWORD, b:DWORD
    mov esi, a
    lea esi, [esi].NODE.szName
    mov edi, b
    lea edi, [edi].NODE.szName
    .WHILE 1
        movzx eax, word ptr [esi]
        movzx ecx, word ptr [edi]
        .IF eax >= 'a' && eax <= 'z'
            sub eax, 32
        .ENDIF
        .IF ecx >= 'a' && ecx <= 'z'
            sub ecx, 32
        .ENDIF
        .IF eax < ecx
            mov eax, -1
            ret
        .ELSEIF eax > ecx
            mov eax, 1
            ret
        .ELSEIF eax == 0
            xor eax, eax
            ret
        .ENDIF
        add esi, 2
        add edi, 2
    .ENDW
XwCompare ENDP

; The children of pDir into g_xwSorted, in name order; FALSE when out of memory
XwCollect PROC USES esi edi ebx pDir:DWORD
    LOCAL n:DWORD
    mov esi, pDir
    mov esi, [esi].NODE.pFirstChild
    xor ecx, ecx
    .WHILE esi != 0
        inc ecx
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    mov g_xwCount, ecx
    invoke VfsFreeMem, g_xwSorted
    mov eax, g_xwCount
    lea eax, [eax * 4 + 4]
    invoke VfsAlloc, eax
    mov g_xwSorted, eax
    .IF eax == 0
        ret
    .ENDIF
    mov edi, eax
    mov n, 0
    mov esi, pDir
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        ; insertion: slide the larger names up
        mov ebx, n
        .WHILE ebx > 0
            mov eax, [edi + ebx * 4 - 4]
            push ebx
            invoke XwCompare, eax, esi
            pop ebx
            .BREAK .IF eax != 1                 ; -1 or 0: in place (the compare is signed, .IF is not)
            mov eax, [edi + ebx * 4 - 4]
            mov [edi + ebx * 4], eax
            dec ebx
        .ENDW
        mov [edi + ebx * 4], esi
        inc n
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    mov eax, TRUE
    ret
XwCollect ENDP

; The entries for sorted[lo..hi) as a balanced subtree, the root first, into
; g_xwBuf; the root entry's offset in 4-byte units in eax, 0 for none
XwEmit PROC USES esi edi ebx lo:DWORD, hi:DWORD
    LOCAL mid:DWORD
    LOCAL pos:DWORD
    LOCAL nameLen:DWORD
    LOCAL entryCb:DWORD
    LOCAL leftOff:DWORD
    LOCAL szName[256]:BYTE
    mov eax, lo
    .IF eax >= hi
        xor eax, eax
        ret
    .ENDIF
    add eax, hi
    shr eax, 1
    mov mid, eax
    mov ecx, g_xwSorted
    mov ebx, [ecx + eax * 4]                ; the node
    invoke XwName, ebx, addr szName
    mov nameLen, eax
    add eax, 14 + 3
    and eax, -4
    mov entryCb, eax
    ; never across a sector: pad the rest of this one with FFh
    mov eax, g_xwBufCb
    and eax, ISO_SECTOR - 1
    add eax, entryCb
    .IF eax > ISO_SECTOR
        mov eax, g_xwBufCb
        neg eax
        and eax, ISO_SECTOR - 1
        mov edi, g_xwBuf
        add edi, g_xwBufCb
        mov ecx, eax
        add g_xwBufCb, eax
        mov al, 0FFh
        rep stosb
    .ENDIF
    mov eax, g_xwBufCb
    mov pos, eax
    mov edi, g_xwBuf
    add edi, eax
    mov ecx, entryCb
    xor eax, eax
    push edi
    rep stosb
    pop edi
    mov eax, [ebx].NODE.wExtent
    mov dword ptr [edi + 4], eax
    test [ebx].NODE.nflags, NF_DIR
    .IF !ZERO?
        mov eax, [ebx].NODE.wDirSize
        mov dword ptr [edi + 8], eax
        mov byte ptr [edi + 12], XW_ATTR_DIR
    .ELSE
        mov eax, [ebx].NODE.dataSize
        mov dword ptr [edi + 8], eax
        mov byte ptr [edi + 12], XW_ATTR_FILE
        .IF [ebx].NODE.dataSizeHi != 0
            mov g_fail, TRUE                ; past 4 GB: the size field cannot hold it
        .ENDIF
    .ENDIF
    mov eax, nameLen
    mov byte ptr [edi + 13], al
    lea edi, [edi + 14]
    lea esi, szName
    mov ecx, nameLen
    rep movsb
    mov eax, entryCb
    add g_xwBufCb, eax
    ; the subtrees, then their offsets into this entry
    invoke XwEmit, lo, mid
    mov leftOff, eax
    mov eax, mid
    inc eax
    invoke XwEmit, eax, hi
    mov edi, g_xwBuf
    add edi, pos
    mov word ptr [edi + 2], ax
    mov eax, leftOff
    mov word ptr [edi], ax
    mov eax, pos
    shr eax, 2
    ret
XwEmit ENDP

; The whole table for pDir into g_xwBuf; its size in whole sectors (bytes)
; in eax, 0 on failure. The children's wExtent / wDirSize must be set when
; the table is for writing; the sizing pass runs before they are.
XwBuildTable PROC USES edi pDir:DWORD
    invoke XwCollect, pDir
    .IF eax == 0
        ret
    .ENDIF
    invoke VfsFreeMem, g_xwBuf
    mov eax, g_xwCount
    imul eax, XW_ENTRY_MAX
    add eax, 2 * ISO_SECTOR
    invoke VfsAlloc, eax
    mov g_xwBuf, eax
    .IF eax == 0
        ret
    .ENDIF
    mov g_xwBufCb, 0
    invoke XwEmit, 0, g_xwCount
    ; round up to a sector, the rest FFh; an empty directory is a full sector of it
    mov eax, g_xwBufCb
    add eax, ISO_SECTOR - 1
    and eax, -ISO_SECTOR
    .IF eax == 0
        mov eax, ISO_SECTOR
    .ENDIF
    mov edi, g_xwBuf
    add edi, g_xwBufCb
    mov ecx, eax
    sub ecx, g_xwBufCb
    push eax
    mov al, 0FFh
    rep stosb
    pop eax
    ret
XwBuildTable ENDP

XdvdfsWrite PROC USES esi ebx pszOutPath:DWORD
    LOCAL ft[2]:DWORD
    mov g_fail, FALSE
    mov g_hOut, 0
    mov g_pDirs, 0
    mov g_xwBuf, 0
    mov g_xwSorted, 0
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
    invoke BuildDirArray
    .IF eax == 0
        jmp cleanup_fail
    .ENDIF
    ; table sizes, then the layout: tables from sector 33, files after them
    xor ebx, ebx
    .WHILE ebx < g_nDirs
        mov eax, g_pDirs
        mov esi, [eax + ebx * 4]
        invoke XwBuildTable, esi
        .IF eax == 0
            jmp cleanup_fail
        .ENDIF
        mov [esi].NODE.wDirSize, eax
        inc ebx
    .ENDW
    mov g_lba, XW_DESC_SECTOR + 1
    xor ebx, ebx
    .WHILE ebx < g_nDirs
        mov eax, g_pDirs
        mov esi, [eax + ebx * 4]
        mov eax, g_lba
        mov [esi].NODE.wExtent, eax
        mov eax, [esi].NODE.wDirSize
        shr eax, 11
        add g_lba, eax
        inc ebx
    .ENDW
    invoke AssignFileExtents, g_pRootNode
    mov eax, g_lba
    mov g_totalSectors, eax
    mov ecx, ISO_SECTOR
    mul ecx
    mov g_progTotal, eax
    mov g_progTotalHi, edx
    invoke CreateFileW, pszOutPath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        jmp cleanup_fail
    .ENDIF
    mov g_hOut, eax
    invoke FilePresize, g_hOut, g_progTotal, g_progTotalHi
    mov g_lba, 0
    invoke WriteZeroSectors, XW_DESC_SECTOR
    ; the descriptor
    invoke SecBegin
    invoke RtlMoveMemory, g_pSec, offset szXwMagic, 20
    mov ecx, g_pSec
    mov eax, g_pRootNode
    mov edx, [eax].NODE.wExtent
    mov dword ptr [ecx + 20], edx
    mov edx, [eax].NODE.wDirSize
    mov dword ptr [ecx + 24], edx
    invoke GetSystemTimeAsFileTime, addr ft
    mov ecx, g_pSec
    mov eax, ft[0]
    mov dword ptr [ecx + 28], eax
    mov eax, ft[4]
    mov dword ptr [ecx + 32], eax
    add ecx, ISO_SECTOR - 20
    invoke RtlMoveMemory, ecx, offset szXwMagic, 20
    invoke SecWrite
    ; the tables, now with every sector known
    xor ebx, ebx
    .WHILE ebx < g_nDirs
        .BREAK .IF g_fail != 0
        mov eax, g_pDirs
        mov esi, [eax + ebx * 4]
        invoke XwBuildTable, esi
        .IF eax == 0 || eax != [esi].NODE.wDirSize
            mov g_fail, TRUE
            .BREAK
        .ENDIF
        invoke WriteAll, g_hOut, g_xwBuf, eax
        .IF eax == 0
            mov g_fail, TRUE
            .BREAK
        .ENDIF
        mov eax, [esi].NODE.wDirSize
        shr eax, 11
        add g_lba, eax
        inc ebx
    .ENDW
    .IF g_fail == 0
        invoke WriteFiles, g_pRootNode
    .ENDIF
    invoke CloseHandle, g_hOut
    mov g_hOut, 0
    .IF g_fail != 0
        invoke DeleteFileW, pszOutPath
        jmp cleanup_fail
    .ENDIF
    invoke VfsFreeMem, g_xwBuf
    invoke VfsFreeMem, g_xwSorted
    invoke VfsFreeMem, g_pDirs
    invoke VfsFreeMem, g_pSec
    mov eax, TRUE
    ret
cleanup_fail:
    .IF g_hOut != 0
        invoke CloseHandle, g_hOut
    .ENDIF
    invoke VfsFreeMem, g_xwBuf
    invoke VfsFreeMem, g_xwSorted
    invoke VfsFreeMem, g_pDirs
    invoke VfsFreeMem, g_pSec
    xor eax, eax
    ret
XdvdfsWrite ENDP

END
