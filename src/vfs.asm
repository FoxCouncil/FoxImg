; FoxImg - in-memory image model
; A tree of NODEs. Each file's bytes come from the mapped ISO (NF_ISO), a host file (NF_HOST), or nowhere (empty).
include foximg.inc

COPY_BUF_SIZE   equ 1024 * 1024

.data
g_pRootNode     dd 0
g_bModified     dd 0
g_hHeap         dd 0

WSTR szNewVolume, <NEW_VOLUME>
WSTR szVolume, <VOLUME>
WSTR szWildcard, <\*>
WSTR szBackslash, <\>
szDotName       dw '.', 0
szDotDotName    dw '.', '.', 0
szUniqueFmt     dw '%','s',' ','(','%','u',')',0
szJoinFmt       dw '%','s','\','%','s',0

.code

VfsFree         PROTO :DWORD
VfsPopulateIso  PROTO :DWORD
VfsSetDate      PROTO :DWORD,:DWORD
VfsDateFromFileTime PROTO :DWORD,:DWORD

; ---------------------------------------------------------------------------
; Heap helpers
; ---------------------------------------------------------------------------
VfsInit PROC
    invoke GetProcessHeap
    mov g_hHeap, eax
    ret
VfsInit ENDP

VfsAlloc PROC cb:DWORD
    invoke HeapAlloc, g_hHeap, HEAP_ZERO_MEMORY, cb
    ret
VfsAlloc ENDP

VfsFreeMem PROC p:DWORD
    .IF p != 0
        invoke HeapFree, g_hHeap, 0, p
    .ENDIF
    ret
VfsFreeMem ENDP

; ---------------------------------------------------------------------------
; Ordering: directories first, then case-insensitive name
; ---------------------------------------------------------------------------
VfsCompareNodes PROC USES esi edi pA:DWORD, pB:DWORD
    mov esi, pA
    mov edi, pB
    mov eax, [esi].NODE.nflags
    and eax, NF_DIR
    mov ecx, [edi].NODE.nflags
    and ecx, NF_DIR
    .IF eax != ecx
        .IF eax != 0
            mov eax, -1
        .ELSE
            mov eax, 1
        .ENDIF
        ret
    .ENDIF
    lea eax, [esi].NODE.szName
    lea ecx, [edi].NODE.szName
    invoke lstrcmpiW, eax, ecx
    ret
VfsCompareNodes ENDP

; Insert pNode into pParent's child list at its sorted position
VfsLink PROC USES esi edi ebx pParent:DWORD, pNode:DWORD
    mov esi, pParent
    mov edi, pNode
    mov [edi].NODE.pParent, esi
    xor ebx, ebx                            ; previous sibling
    mov ecx, [esi].NODE.pFirstChild
link_loop:
    test ecx, ecx
    jz link_here
    push ecx
    invoke VfsCompareNodes, edi, ecx
    pop ecx
    test eax, eax
    js link_here                            ; new < current
    mov ebx, ecx
    mov ecx, [ecx].NODE.pNextSibling
    jmp link_loop
link_here:
    mov [edi].NODE.pNextSibling, ecx
    .IF ebx == 0
        mov [esi].NODE.pFirstChild, edi
    .ELSE
        mov [ebx].NODE.pNextSibling, edi
    .ENDIF
    ret
VfsLink ENDP

VfsUnlink PROC USES esi edi pNode:DWORD
    mov edi, pNode
    mov esi, [edi].NODE.pParent
    .IF esi == 0
        ret
    .ENDIF
    mov ecx, [esi].NODE.pFirstChild
    .IF ecx == edi
        mov eax, [edi].NODE.pNextSibling
        mov [esi].NODE.pFirstChild, eax
    .ELSE
        .WHILE ecx != 0
            mov eax, [ecx].NODE.pNextSibling
            .IF eax == edi
                mov eax, [edi].NODE.pNextSibling
                mov [ecx].NODE.pNextSibling, eax
                .BREAK
            .ENDIF
            mov ecx, eax
        .ENDW
    .ENDIF
    mov [edi].NODE.pParent, 0
    mov [edi].NODE.pNextSibling, 0
    ret
VfsUnlink ENDP

; ---------------------------------------------------------------------------
; Node lifetime
; ---------------------------------------------------------------------------
VfsNew PROC USES esi edi pParent:DWORD, pszName:DWORD, nflags:DWORD
    invoke VfsAlloc, sizeof NODE
    .IF eax == 0
        ret
    .ENDIF
    mov esi, eax
    mov eax, nflags
    mov [esi].NODE.nflags, eax
    lea edi, [esi].NODE.szName
    invoke lstrcpynW, edi, pszName, NODE_NAME_MAX
    .IF pParent != 0
        invoke VfsLink, pParent, esi
    .ENDIF
    mov eax, esi
    ret
VfsNew ENDP

VfsFree PROC USES esi edi ebx pNode:DWORD
    mov esi, pNode
    mov ebx, [esi].NODE.pFirstChild
    .WHILE ebx != 0
        mov edi, [ebx].NODE.pNextSibling
        invoke VfsFree, ebx
        mov ebx, edi
    .ENDW
    invoke VfsFreeMem, [esi].NODE.pszHost
    invoke VfsFreeMem, esi
    ret
VfsFree ENDP

VfsDelete PROC pNode:DWORD
    mov eax, pNode
    .IF eax == 0 || eax == g_pRootNode
        ret
    .ENDIF
    invoke VfsUnlink, pNode
    invoke VfsFree, pNode
    mov g_bModified, TRUE
    ret
VfsDelete ENDP

VfsClear PROC
    .IF g_pRootNode != 0
        invoke VfsFree, g_pRootNode
        mov g_pRootNode, 0
    .ENDIF
    mov g_bModified, FALSE
    ret
VfsClear ENDP

; Rename keeps the sibling list sorted by unlinking and relinking
VfsRename PROC USES esi edi pNode:DWORD, pszName:DWORD
    mov esi, pNode
    mov edi, [esi].NODE.pParent
    lea eax, [esi].NODE.szName
    invoke lstrcpynW, eax, pszName, NODE_NAME_MAX
    .IF edi != 0
        invoke VfsUnlink, esi
        invoke VfsLink, edi, esi
    .ENDIF
    mov g_bModified, TRUE
    ret
VfsRename ENDP

VfsFindChild PROC USES esi pParent:DWORD, pszName:DWORD
    mov esi, pParent
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
VfsFindChild ENDP

; "Base", "Base (2)", "Base (3)" ...
VfsUniqueName PROC USES ebx pParent:DWORD, pszBase:DWORD, pszOut:DWORD
    invoke lstrcpynW, pszOut, pszBase, NODE_NAME_MAX
    mov ebx, 1
    .WHILE TRUE
        invoke VfsFindChild, pParent, pszOut
        .BREAK .IF eax == 0
        inc ebx
        invoke wsprintfW, pszOut, offset szUniqueFmt, pszBase, ebx
    .ENDW
    ret
VfsUniqueName ENDP

; ---------------------------------------------------------------------------
; Dates
; ---------------------------------------------------------------------------
VfsSetDate PROC USES esi edi pNode:DWORD, pSt:DWORD
    mov esi, pSt
    mov edi, pNode
    movzx eax, [esi].SYSTEMTIME.wYear
    sub eax, 1900
    mov [edi].NODE.recDate[0], al
    mov al, byte ptr [esi].SYSTEMTIME.wMonth
    mov [edi].NODE.recDate[1], al
    mov al, byte ptr [esi].SYSTEMTIME.wDay
    mov [edi].NODE.recDate[2], al
    mov al, byte ptr [esi].SYSTEMTIME.wHour
    mov [edi].NODE.recDate[3], al
    mov al, byte ptr [esi].SYSTEMTIME.wMinute
    mov [edi].NODE.recDate[4], al
    mov al, byte ptr [esi].SYSTEMTIME.wSecond
    mov [edi].NODE.recDate[5], al
    mov [edi].NODE.recDate[6], 0
    ret
VfsSetDate ENDP

VfsDateNow PROC pNode:DWORD
    LOCAL stm:SYSTEMTIME
    invoke GetLocalTime, addr stm
    invoke VfsSetDate, pNode, addr stm
    ret
VfsDateNow ENDP

VfsDateFromFileTime PROC pNode:DWORD, pFt:DWORD
    LOCAL lft:FILETIME
    LOCAL stm:SYSTEMTIME
    invoke FileTimeToLocalFileTime, pFt, addr lft
    invoke FileTimeToSystemTime, addr lft, addr stm
    invoke VfsSetDate, pNode, addr stm
    ret
VfsDateFromFileTime ENDP

; ---------------------------------------------------------------------------
; Building from the mapped ISO
; ---------------------------------------------------------------------------
IsoNodeCb PROC USES esi edi ebx pRec:DWORD, lParam:DWORD
    LOCAL szName[NODE_NAME_MAX]:WORD
    LOCAL nflags:DWORD

    invoke IsoRecName, pRec, addr szName, NODE_NAME_MAX
    mov esi, pRec
    mov nflags, NF_ISO
    test [esi].ISO_DIRREC.fileFlags, ISO_FLAG_DIRECTORY
    .IF !ZERO?
        or nflags, NF_DIR
    .ENDIF
    invoke VfsNew, lParam, addr szName, nflags
    .IF eax == 0
        ret
    .ENDIF
    mov edi, eax
    mov [edi].NODE.pRec, esi
    mov eax, [esi].ISO_DIRREC.dataLenLE
    mov [edi].NODE.dataSize, eax
    mov eax, [esi].ISO_DIRREC.extentLE
    mov [edi].NODE.isoExtent, eax
    lea eax, [esi].ISO_DIRREC.recYear
    lea ecx, [edi].NODE.recDate
    invoke RtlMoveMemory, ecx, eax, 7
    .IF nflags & NF_DIR
        invoke VfsPopulateIso, edi
    .ENDIF
    mov eax, TRUE
    ret
IsoNodeCb ENDP

VfsPopulateIso PROC pDirNode:DWORD
    mov eax, pDirNode
    invoke IsoEnumDir, [eax].NODE.isoExtent, [eax].NODE.dataSize, offset IsoNodeCb, pDirNode
    ret
VfsPopulateIso ENDP

VfsBuildFromIso PROC USES esi
    LOCAL szName[64]:WORD
    invoke VfsClear
    invoke IsoVolumeName, addr szName, 64
    .IF szName[0] == 0
        invoke lstrcpyW, addr szName, offset szVolume
    .ENDIF
    invoke VfsNew, 0, addr szName, NF_DIR or NF_ISO
    mov g_pRootNode, eax
    .IF eax == 0
        ret
    .ENDIF
    mov esi, eax
    invoke IsoRootRecord
    .IF eax == 0
        ret
    .ENDIF
    mov ecx, [eax].ISO_DIRREC.extentLE
    mov [esi].NODE.isoExtent, ecx
    mov ecx, [eax].ISO_DIRREC.dataLenLE
    mov [esi].NODE.dataSize, ecx
    invoke VfsDateNow, esi
    invoke VfsPopulateIso, esi
    mov g_bModified, FALSE
    ret
VfsBuildFromIso ENDP

VfsNewImage PROC
    invoke VfsClear
    invoke VfsNew, 0, offset szNewVolume, NF_DIR
    mov g_pRootNode, eax
    invoke VfsDateNow, eax
    mov g_bModified, FALSE
    ret
VfsNewImage ENDP

; ---------------------------------------------------------------------------
; Adding host files / directories
; ---------------------------------------------------------------------------
VfsAddHostPath PROC USES esi edi ebx pParent:DWORD, pszPath:DWORD
    LOCAL fd:WIN32_FIND_DATAW
    LOCAL fd2:WIN32_FIND_DATAW
    LOCAL szPattern[MAX_PATH]:WORD
    LOCAL szChild[MAX_PATH]:WORD
    LOCAL hFind:DWORD
    LOCAL pNode:DWORD

    invoke FindFirstFileW, pszPath, addr fd
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    invoke FindClose, eax

    ; replace an existing entry of the same name
    invoke VfsFindChild, pParent, addr fd.cFileName
    .IF eax != 0
        invoke VfsDelete, eax
    .ENDIF

    test fd.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY
    jz add_file

    invoke VfsNew, pParent, addr fd.cFileName, NF_DIR
    mov pNode, eax
    .IF eax == 0
        ret
    .ENDIF
    invoke VfsDateFromFileTime, pNode, addr fd.ftLastWriteTime

    invoke lstrcpynW, addr szPattern, pszPath, MAX_PATH - 3
    invoke lstrcatW, addr szPattern, offset szWildcard
    invoke FindFirstFileW, addr szPattern, addr fd2
    .IF eax != INVALID_HANDLE_VALUE
        mov hFind, eax
        .WHILE TRUE
            .BREAK .IF g_jobCancel != 0
            invoke lstrcmpW, addr fd2.cFileName, offset szDotName
            .IF eax != 0
                invoke lstrcmpW, addr fd2.cFileName, offset szDotDotName
                .IF eax != 0
                    invoke wsprintfW, addr szChild, offset szJoinFmt, pszPath, addr fd2.cFileName
                    invoke VfsAddHostPath, pNode, addr szChild
                .ENDIF
            .ENDIF
            invoke FindNextFileW, hFind, addr fd2
            .BREAK .IF eax == 0
        .ENDW
        invoke FindClose, hFind
    .ENDIF
    mov g_bModified, TRUE
    mov eax, pNode
    ret

add_file:
    .IF fd.nFileSizeHigh != 0
        xor eax, eax                        ; > 4 GB: not representable in a single ISO 9660 extent
        ret
    .ENDIF
    invoke VfsNew, pParent, addr fd.cFileName, NF_HOST
    mov pNode, eax
    .IF eax == 0
        ret
    .ENDIF
    mov esi, eax
    mov eax, fd.nFileSizeLow
    mov [esi].NODE.dataSize, eax
    invoke VfsDateFromFileTime, esi, addr fd.ftLastWriteTime
    invoke lstrlenW, pszPath
    inc eax
    shl eax, 1
    invoke VfsAlloc, eax
    mov [esi].NODE.pszHost, eax
    .IF eax != 0
        invoke lstrcpyW, eax, pszPath
    .ENDIF
    mov g_bModified, TRUE
    mov eax, esi
    ret
VfsAddHostPath ENDP

; ---------------------------------------------------------------------------
; Lookup / move
; ---------------------------------------------------------------------------
VfsFindByExtent PROC USES esi pDir:DWORD, lba:DWORD
    mov esi, pDir
    .IF esi == 0
        xor eax, eax
        ret
    .ENDIF
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        test [esi].NODE.nflags, NF_DIR
        .IF !ZERO?
            invoke VfsFindByExtent, esi, lba
            .IF eax != 0
                ret
            .ENDIF
        .ELSEIF [esi].NODE.nflags & NF_ISO
            mov eax, [esi].NODE.isoExtent
            .IF eax == lba
                mov eax, esi
                ret
            .ENDIF
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    xor eax, eax
    ret
VfsFindByExtent ENDP

VfsIsAncestor PROC pMaybeAncestor:DWORD, pNode:DWORD
    mov eax, pNode
    .WHILE eax != 0
        .IF eax == pMaybeAncestor
            mov eax, TRUE
            ret
        .ENDIF
        mov eax, [eax].NODE.pParent
    .ENDW
    xor eax, eax
    ret
VfsIsAncestor ENDP

; Re-parent a node; refuses cycles and name clashes
VfsMove PROC USES esi pNode:DWORD, pNewParent:DWORD
    mov esi, pNode
    mov eax, pNewParent
    .IF esi == 0 || eax == 0 || esi == g_pRootNode
        xor eax, eax
        ret
    .ENDIF
    .IF eax == [esi].NODE.pParent
        xor eax, eax
        ret
    .ENDIF
    invoke VfsIsAncestor, esi, pNewParent
    .IF eax != 0
        xor eax, eax
        ret
    .ENDIF
    lea eax, [esi].NODE.szName
    invoke VfsFindChild, pNewParent, eax
    .IF eax != 0
        xor eax, eax
        ret
    .ENDIF
    invoke VfsUnlink, esi
    invoke VfsLink, pNewParent, esi
    mov g_bModified, TRUE
    mov eax, TRUE
    ret
VfsMove ENDP

; ---------------------------------------------------------------------------
; Data access
; ---------------------------------------------------------------------------
WriteAll PROC USES esi ebx hFile:DWORD, pData:DWORD, cb:DWORD
    LOCAL written:DWORD
    mov esi, pData
    mov ebx, cb
    .WHILE ebx != 0
        .IF g_jobCancel != 0
            xor eax, eax
            ret
        .ENDIF
        invoke WriteFile, hFile, esi, ebx, addr written, NULL
        .IF eax == 0 || written == 0
            xor eax, eax
            ret
        .ENDIF
        mov eax, written
        add g_progDone, eax                 ; progress for whoever is watching
        add esi, written
        sub ebx, written
    .ENDW
    mov eax, TRUE
    ret
WriteAll ENDP

VfsCopyData PROC USES esi ebx pNode:DWORD, hOut:DWORD
    LOCAL hIn:DWORD
    LOCAL pBuf:DWORD
    LOCAL nRead:DWORD
    LOCAL ok:DWORD

    mov esi, pNode
    mov eax, [esi].NODE.nflags
    .IF eax & NF_ISO
        invoke IsoCopyExtent, [esi].NODE.isoExtent, [esi].NODE.dataSize, hOut
        ret
    .ELSEIF eax & NF_HOST
        invoke CreateFileW, [esi].NODE.pszHost, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
        .IF eax == INVALID_HANDLE_VALUE
            xor eax, eax
            ret
        .ENDIF
        mov hIn, eax
        invoke VfsAlloc, COPY_BUF_SIZE
        mov pBuf, eax
        mov ok, FALSE
        .IF eax != 0
            mov ok, TRUE
            .WHILE TRUE
                invoke ReadFile, hIn, pBuf, COPY_BUF_SIZE, addr nRead, NULL
                .IF eax == 0
                    mov ok, FALSE
                    .BREAK
                .ENDIF
                .BREAK .IF nRead == 0
                invoke WriteAll, hOut, pBuf, nRead
                .IF eax == 0
                    mov ok, FALSE
                    .BREAK
                .ENDIF
            .ENDW
            invoke VfsFreeMem, pBuf
        .ENDIF
        invoke CloseHandle, hIn
        mov eax, ok
        ret
    .ENDIF
    mov eax, TRUE                           ; empty file
    ret
VfsCopyData ENDP

; Up to cbMax bytes of a file into a fresh heap buffer (caller frees). *pcbOut receives the byte count.
VfsReadAll PROC USES esi edi pNode:DWORD, cbMax:DWORD, pcbOut:DWORD
    LOCAL hIn:DWORD
    LOCAL pBuf:DWORD
    LOCAL cb:DWORD
    LOCAL nRead:DWORD

    mov esi, pNode
    mov eax, pcbOut
    mov dword ptr [eax], 0
    mov eax, [esi].NODE.dataSize
    .IF eax > cbMax
        mov eax, cbMax
    .ENDIF
    mov cb, eax
    inc eax
    inc eax
    invoke VfsAlloc, eax                    ; + 2 bytes so callers may NUL-terminate
    .IF eax == 0
        ret
    .ENDIF
    mov pBuf, eax

    mov eax, [esi].NODE.nflags
    .IF eax & NF_ISO
        invoke IsoReadExtent, [esi].NODE.isoExtent, cb, pBuf
        .IF eax == 0
            jmp fail
        .ENDIF
    .ELSEIF eax & NF_HOST
        invoke CreateFileW, [esi].NODE.pszHost, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
        .IF eax == INVALID_HANDLE_VALUE
            jmp fail
        .ENDIF
        mov hIn, eax
        invoke ReadFile, hIn, pBuf, cb, addr nRead, NULL
        invoke CloseHandle, hIn
        mov eax, nRead
        mov cb, eax
    .ENDIF
    mov eax, pcbOut
    mov ecx, cb
    mov [eax], ecx
    mov eax, pBuf
    ret
fail:
    invoke VfsFreeMem, pBuf
    xor eax, eax
    ret
VfsReadAll ENDP

; ---------------------------------------------------------------------------
; Extract a node (recursively) under a host directory
; ---------------------------------------------------------------------------
VfsExtract PROC USES esi edi pNode:DWORD, pszDir:DWORD
    LOCAL szPath[MAX_PATH]:WORD
    LOCAL hOut:DWORD
    LOCAL ok:DWORD

    mov esi, pNode
    invoke wsprintfW, addr szPath, offset szJoinFmt, pszDir, addr [esi].NODE.szName
    test [esi].NODE.nflags, NF_DIR
    jz ext_file

    invoke CreateDirectoryW, addr szPath, NULL
    mov ok, TRUE
    mov edi, [esi].NODE.pFirstChild
    .WHILE edi != 0
        invoke VfsExtract, edi, addr szPath
        .IF eax == 0
            mov ok, FALSE
        .ENDIF
        mov edi, [edi].NODE.pNextSibling
    .ENDW
    mov eax, ok
    ret

ext_file:
    invoke CreateFileW, addr szPath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hOut, eax
    invoke VfsCopyData, esi, hOut
    mov ok, eax
    invoke CloseHandle, hOut
    mov eax, ok
    ret
VfsExtract ENDP

END
