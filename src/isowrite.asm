; FoxImg - ISO 9660 + Joliet writer
;
; Layout produced:
;   0-15   system area (zero)
;   16     Primary Volume Descriptor
;   17     Supplementary Volume Descriptor (Joliet, UCS-2 level 3)
;   18     terminator
;   19..   path tables: primary L, primary M, Joliet L, Joliet M
;   ..     directory extents: primary set, then Joliet set (both in breadth-first order)
;   ..     file data, depth-first in directory order, each padded to a sector
include foximg.inc

.data
g_hOut          dd 0
g_lba           dd 0
g_pSec          dd 0            ; 2048-byte staging sector
g_secPos        dd 0
g_pDirs         dd 0            ; breadth-first array of directory NODE*
g_nDirs         dd 0
g_ptSize        dd 0            ; primary path table bytes
g_ptSizeJ       dd 0
g_ptL           dd 0
g_ptM           dd 0
g_ptLJ          dd 0
g_ptMJ          dd 0
g_totalSectors  dd 0
g_fail          dd 0

szCD001         db 'CD001'
szAppId         db 'FOXIMG'
szZeroDate      db '0000000000000000', 0
szDateFmtW      dw '%','0','4','u','%','0','2','u','%','0','2','u','%','0','2','u','%','0','2','u','%','0','2','u','0','0',0
szTildeFmtW     dw '~','%','u',0

.code

; ---------------------------------------------------------------------------
; Little helpers
; ---------------------------------------------------------------------------
PutBoth32 PROC pDst:DWORD, val:DWORD
    mov ecx, pDst
    mov eax, val
    mov [ecx], eax
    bswap eax
    mov [ecx + 4], eax
    ret
PutBoth32 ENDP

PutBoth16 PROC pDst:DWORD, val:DWORD
    mov ecx, pDst
    mov eax, val
    mov [ecx], ax
    xchg al, ah
    mov [ecx + 2], ax
    ret
PutBoth16 ENDP

FillBytes PROC USES edi pDst:DWORD, val:DWORD, cb:DWORD
    mov edi, pDst
    mov eax, val
    mov ecx, cb
    rep stosb
    ret
FillBytes ENDP

; UCS-2 big-endian spaces
FillWideSpaces PROC USES edi pDst:DWORD, cch:DWORD
    mov edi, pDst
    mov ecx, cch
    mov ax, 2000h                           ; bytes 00 20
    rep stosw
    ret
FillWideSpaces ENDP

SectorsFor PROC cb:DWORD
    mov eax, cb
    add eax, ISO_SECTOR - 1
    shr eax, 11
    ret
SectorsFor ENDP

SectorsFor64 PROC lo:DWORD, hi:DWORD
    mov eax, lo
    mov edx, hi
    add eax, ISO_SECTOR - 1
    adc edx, 0
    shrd eax, edx, 11
    ret
SectorsFor64 ENDP

; Files the ISO 9660 half cannot describe (over 4 GB) are left to UDF
IsoSkips PROC pNode:DWORD
    mov eax, pNode
    mov eax, [eax].NODE.nflags
    and eax, NF_UDFONLY
    ret
IsoSkips ENDP

; ---------------------------------------------------------------------------
; Output staging
; ---------------------------------------------------------------------------
SecWrite PROC
    .IF g_fail == 0
        invoke WriteAll, g_hOut, g_pSec, ISO_SECTOR
        .IF eax == 0
            mov g_fail, TRUE
        .ENDIF
    .ENDIF
    inc g_lba
    invoke FillBytes, g_pSec, 0, ISO_SECTOR
    mov g_secPos, 0
    ret
SecWrite ENDP

SecBegin PROC
    invoke FillBytes, g_pSec, 0, ISO_SECTOR
    mov g_secPos, 0
    ret
SecBegin ENDP

SecFlush PROC
    .IF g_secPos != 0
        invoke SecWrite
    .ENDIF
    ret
SecFlush ENDP

; Directory record rule: a record never crosses a sector boundary
SecPutRecord PROC pData:DWORD, cb:DWORD
    mov eax, g_secPos
    add eax, cb
    .IF eax > ISO_SECTOR
        invoke SecWrite
    .ENDIF
    mov eax, g_pSec
    add eax, g_secPos
    invoke RtlMoveMemory, eax, pData, cb
    mov eax, cb
    add g_secPos, eax
    ret
SecPutRecord ENDP

; Byte stream (path tables): may span sectors
SecPutBytes PROC USES esi ebx pData:DWORD, cb:DWORD
    mov esi, pData
    mov ebx, cb
    .WHILE ebx != 0
        mov ecx, ISO_SECTOR
        sub ecx, g_secPos
        .IF ecx > ebx
            mov ecx, ebx
        .ENDIF
        mov eax, g_pSec
        add eax, g_secPos
        push ecx
        invoke RtlMoveMemory, eax, esi, ecx
        pop ecx
        add esi, ecx
        sub ebx, ecx
        add g_secPos, ecx
        .IF g_secPos == ISO_SECTOR
            invoke SecWrite
        .ENDIF
    .ENDW
    ret
SecPutBytes ENDP

WriteZeroSectors PROC USES ebx n:DWORD
    invoke SecBegin
    mov ebx, n
    .WHILE ebx != 0
        invoke SecWrite
        dec ebx
    .ENDW
    ret
WriteZeroSectors ENDP

; ---------------------------------------------------------------------------
; Names
; ---------------------------------------------------------------------------
; ASCII primary identifier generation: 8.3 upper-case d-characters, ";1" on files, ~N de-duplication
IsoCharOk PROC chr:DWORD
    mov eax, chr
    .IF eax >= 'A' && eax <= 'Z'
        mov eax, TRUE
    .ELSEIF eax >= '0' && eax <= '9'
        mov eax, TRUE
    .ELSEIF eax == '_'
        mov eax, TRUE
    .ELSE
        xor eax, eax
    .ENDIF
    ret
IsoCharOk ENDP

; Split szName into base (<= 8) and ext (<= 3), mapped to d-characters. pBase/pExtn are 16-byte ASCII buffers.
IsoSplitName PROC USES esi edi ebx pNode:DWORD, pBase:DWORD, pExtn:DWORD
    LOCAL pLastDot:DWORD
    LOCAL isDir:DWORD

    mov esi, pNode
    mov eax, [esi].NODE.nflags
    and eax, NF_DIR
    mov isDir, eax
    lea esi, [esi].NODE.szName

    ; find last '.' (files only)
    mov pLastDot, 0
    .IF isDir == 0
        mov ecx, esi
        .WHILE word ptr [ecx] != 0
            .IF word ptr [ecx] == '.'
                mov pLastDot, ecx
            .ENDIF
            add ecx, 2
        .ENDW
        .IF pLastDot == esi
            mov pLastDot, 0                 ; leading dot: treat whole name as base
        .ENDIF
    .ENDIF

    ; base
    mov edi, pBase
    xor ebx, ebx
    mov ecx, esi
    .WHILE word ptr [ecx] != 0 && ecx != pLastDot && ebx < 8
        movzx eax, word ptr [ecx]
        .IF eax >= 'a' && eax <= 'z'
            sub eax, 20h
        .ENDIF
        push ecx
        push eax
        invoke IsoCharOk, eax
        .IF eax == 0
            mov dword ptr [esp], '_'
        .ENDIF
        pop eax
        pop ecx
        mov [edi], al
        inc edi
        inc ebx
        add ecx, 2
    .ENDW
    .IF ebx == 0
        mov byte ptr [edi], '_'
        inc edi
    .ENDIF
    mov byte ptr [edi], 0

    ; ext
    mov edi, pExtn
    mov byte ptr [edi], 0
    .IF pLastDot != 0
        mov ecx, pLastDot
        add ecx, 2
        xor ebx, ebx
        .WHILE word ptr [ecx] != 0 && ebx < 3
            movzx eax, word ptr [ecx]
            .IF eax >= 'a' && eax <= 'z'
                sub eax, 20h
            .ENDIF
            push ecx
            push eax
            invoke IsoCharOk, eax
            .IF eax == 0
                mov dword ptr [esp], '_'
            .ENDIF
            pop eax
            pop ecx
            mov [edi], al
            inc edi
            inc ebx
            add ecx, 2
        .ENDW
        mov byte ptr [edi], 0
    .ENDIF
    ret
IsoSplitName ENDP

lstrcmpA PROTO :DWORD,:DWORD
lstrlenA PROTO :DWORD
lstrcpyA PROTO :DWORD,:DWORD
lstrcatA PROTO :DWORD,:DWORD

; TRUE if another sibling already carries this primary identifier
IsoNameTaken PROC USES esi pNode:DWORD, pszName:DWORD
    mov esi, pNode
    mov esi, [esi].NODE.pParent
    .IF esi == 0
        xor eax, eax
        ret
    .ENDIF
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        .IF esi != pNode && [esi].NODE.isoName[0] != 0
            lea eax, [esi].NODE.isoName
            invoke lstrcmpA, eax, pszName
            .IF eax == 0
                mov eax, TRUE
                ret
            .ENDIF
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    xor eax, eax
    ret
IsoNameTaken ENDP

; Compose "BASE.EXT;1" (file) or "BASE" (dir) into pNode.isoName
IsoComposeName PROC USES esi pNode:DWORD, pBase:DWORD, pExtn:DWORD
    mov esi, pNode
    lea eax, [esi].NODE.isoName
    invoke lstrcpyA, eax, pBase
    test [esi].NODE.nflags, NF_DIR
    .IF ZERO?
        lea eax, [esi].NODE.isoName
        invoke lstrlenA, eax
        lea ecx, [esi].NODE.isoName
        add ecx, eax
        mov byte ptr [ecx], '.'
        mov byte ptr [ecx + 1], 0
        lea eax, [esi].NODE.isoName
        invoke lstrcatA, eax, pExtn
        lea eax, [esi].NODE.isoName
        invoke lstrlenA, eax
        lea ecx, [esi].NODE.isoName
        add ecx, eax
        mov byte ptr [ecx], ';'
        mov byte ptr [ecx + 1], '1'
        mov byte ptr [ecx + 2], 0
    .ENDIF
    ret
IsoComposeName ENDP

IsoGenName PROC USES esi ebx pNode:DWORD
    LOCAL szBase[16]:BYTE
    LOCAL szExt[16]:BYTE
    LOCAL szTry[16]:BYTE
    LOCAL szSuffixW[8]:WORD
    LOCAL szSuffix[8]:BYTE
    LOCAL cut:DWORD

    mov esi, pNode
    invoke IsoSplitName, esi, addr szBase, addr szExt
    invoke IsoComposeName, esi, addr szBase, addr szExt
    lea eax, [esi].NODE.isoName
    invoke IsoNameTaken, esi, eax
    .IF eax == 0
        ret
    .ENDIF

    mov ebx, 1
    .WHILE ebx < 1000
        invoke wsprintfW, addr szSuffixW, offset szTildeFmtW, ebx
        ; narrow "~N"
        lea ecx, szSuffixW
        lea edx, szSuffix
        .WHILE word ptr [ecx] != 0
            mov al, [ecx]
            mov [edx], al
            add ecx, 2
            inc edx
        .ENDW
        mov byte ptr [edx], 0
        invoke lstrlenA, addr szSuffix
        mov ecx, 8
        sub ecx, eax
        mov cut, ecx
        invoke lstrcpyA, addr szTry, addr szBase
        invoke lstrlenA, addr szTry
        .IF eax > cut
            lea ecx, szTry
            add ecx, cut
            mov byte ptr [ecx], 0
        .ENDIF
        invoke lstrcatA, addr szTry, addr szSuffix
        invoke IsoComposeName, esi, addr szTry, addr szExt
        lea eax, [esi].NODE.isoName
        invoke IsoNameTaken, esi, eax
        .BREAK .IF eax == 0
        inc ebx
    .ENDW
    ret
IsoGenName ENDP

; Assign primary identifiers for every node below pDir (pDir itself keeps whatever it has)
IsoGenNames PROC USES esi pDir:DWORD
    mov esi, pDir
    ; clear first so de-duplication only sees siblings processed so far
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        mov [esi].NODE.isoName[0], 0
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    mov esi, pDir
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        invoke IsoGenName, esi
        test [esi].NODE.nflags, NF_DIR
        .IF !ZERO?
            invoke IsoGenNames, esi
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    ret
IsoGenNames ENDP

; Joliet identifier: UCS-2 big-endian, up to 64 characters, files get ";1". Returns byte length.
JolietName PROC USES esi edi ebx pNode:DWORD, pDst:DWORD
    mov esi, pNode
    mov edi, pDst
    mov ecx, 64
    test [esi].NODE.nflags, NF_DIR
    .IF ZERO?
        mov ecx, 62
    .ENDIF
    lea esi, [esi].NODE.szName
    xor ebx, ebx
    .WHILE ebx < ecx && word ptr [esi] != 0
        lodsw
        xchg al, ah
        stosw
        inc ebx
    .ENDW
    mov esi, pNode
    test [esi].NODE.nflags, NF_DIR
    .IF ZERO?
        mov ax, 3B00h                       ; ';' big-endian
        stosw
        mov ax, 3100h                       ; '1'
        stosw
        add ebx, 2
    .ENDIF
    mov eax, ebx
    shl eax, 1
    ret
JolietName ENDP

; Primary identifier length (bytes)
PrimaryNameLen PROC pNode:DWORD
    mov eax, pNode
    lea eax, [eax].NODE.isoName
    invoke lstrlenA, eax
    ret
PrimaryNameLen ENDP

JolietNameLen PROC pNode:DWORD
    LOCAL buf[140]:BYTE
    invoke JolietName, pNode, addr buf
    ret
JolietNameLen ENDP

; ---------------------------------------------------------------------------
; Record builders
; ---------------------------------------------------------------------------
; Directory record into pBuf; returns length
BuildDirRecord PROC USES edi pBuf:DWORD, pNode:DWORD, extent:DWORD, dataLen:DWORD, fileFlags:DWORD, pName:DWORD, nameLen:DWORD
    LOCAL total:DWORD
    mov eax, nameLen
    add eax, 33
    .IF eax & 1
        inc eax
    .ENDIF
    mov total, eax
    invoke FillBytes, pBuf, 0, eax
    mov edi, pBuf
    mov eax, total
    mov [edi], al
    lea eax, [edi + 2]
    invoke PutBoth32, eax, extent
    lea eax, [edi + 10]
    invoke PutBoth32, eax, dataLen
    mov eax, pNode
    lea eax, [eax].NODE.recDate
    lea ecx, [edi + 18]
    invoke RtlMoveMemory, ecx, eax, 7
    mov eax, fileFlags
    mov [edi + 25], al
    lea eax, [edi + 28]
    invoke PutBoth16, eax, 1
    mov eax, nameLen
    mov [edi + 32], al
    lea eax, [edi + 33]
    invoke RtlMoveMemory, eax, pName, nameLen
    mov eax, total
    ret
BuildDirRecord ENDP

; Path table record into pBuf; returns length
BuildPathRecord PROC USES edi pBuf:DWORD, extent:DWORD, parentIdx:DWORD, pName:DWORD, nameLen:DWORD, bBigEndian:DWORD
    LOCAL total:DWORD
    mov eax, nameLen
    add eax, 8
    .IF eax & 1
        inc eax
    .ENDIF
    mov total, eax
    invoke FillBytes, pBuf, 0, eax
    mov edi, pBuf
    mov eax, nameLen
    mov [edi], al
    mov eax, extent
    mov ecx, parentIdx
    .IF bBigEndian != 0
        bswap eax
        xchg cl, ch
    .ENDIF
    mov [edi + 2], eax
    mov [edi + 6], cx
    lea eax, [edi + 8]
    invoke RtlMoveMemory, eax, pName, nameLen
    mov eax, total
    ret
BuildPathRecord ENDP

; ---------------------------------------------------------------------------
; Sizing
; ---------------------------------------------------------------------------
; Add a record of cb bytes to a running directory size honouring the sector rule
AddRecordSize PROC pSize:DWORD, cb:DWORD
    mov ecx, pSize
    mov eax, [ecx]
    mov edx, eax
    and edx, ISO_SECTOR - 1
    add edx, cb
    .IF edx > ISO_SECTOR
        add eax, ISO_SECTOR - 1
        and eax, not (ISO_SECTOR - 1)
    .ENDIF
    add eax, cb
    mov [ecx], eax
    ret
AddRecordSize ENDP

ComputeDirSizes PROC USES esi edi pDir:DWORD
    LOCAL sz:DWORD
    LOCAL szJ:DWORD
    mov sz, 68                              ; "." and ".."
    mov szJ, 68
    mov esi, pDir
    mov edi, [esi].NODE.pFirstChild
    .WHILE edi != 0
        invoke IsoSkips, edi
        .IF eax == 0
            invoke PrimaryNameLen, edi
            add eax, 33
            .IF eax & 1
                inc eax
            .ENDIF
            invoke AddRecordSize, addr sz, eax
            invoke JolietNameLen, edi
            add eax, 33
            .IF eax & 1
                inc eax
            .ENDIF
            invoke AddRecordSize, addr szJ, eax
            test [edi].NODE.nflags, NF_DIR
            .IF !ZERO?
                invoke ComputeDirSizes, edi
            .ENDIF
        .ENDIF
        mov edi, [edi].NODE.pNextSibling
    .ENDW
    invoke SectorsFor, sz
    shl eax, 11
    mov [esi].NODE.wDirSize, eax
    invoke SectorsFor, szJ
    shl eax, 11
    mov [esi].NODE.wDirSizeJ, eax
    ret
ComputeDirSizes ENDP

CountDirs PROC USES esi pDir:DWORD
    LOCAL n:DWORD
    mov n, 1
    mov esi, pDir
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        test [esi].NODE.nflags, NF_DIR
        .IF !ZERO?
            invoke CountDirs, esi
            add n, eax
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    mov eax, n
    ret
CountDirs ENDP

; Breadth-first directory array; assigns path table indices and sizes
BuildDirArray PROC USES esi edi ebx
    LOCAL head:DWORD
    LOCAL tail:DWORD

    invoke CountDirs, g_pRootNode
    mov g_nDirs, eax
    shl eax, 2
    invoke VfsAlloc, eax
    mov g_pDirs, eax
    .IF eax == 0
        ret
    .ENDIF
    mov edi, eax
    mov eax, g_pRootNode
    mov [edi], eax
    mov head, 0
    mov tail, 1
    mov g_ptSize, 10                        ; root entry: 8 + 1 name byte, padded
    mov g_ptSizeJ, 10
    mov esi, g_pRootNode
    mov [esi].NODE.wPathIdx, 1
    mov [esi].NODE.wPathIdxJ, 1

bfs_loop:
    mov eax, head
    cmp eax, tail
    jae bfs_done
    .IF TRUE
        mov esi, [edi + eax * 4]
        inc head
        mov ebx, [esi].NODE.pFirstChild
        .WHILE ebx != 0
            test [ebx].NODE.nflags, NF_DIR
            .IF !ZERO?
                mov eax, tail
                mov [edi + eax * 4], ebx
                inc tail
                mov eax, tail
                mov [ebx].NODE.wPathIdx, eax
                mov [ebx].NODE.wPathIdxJ, eax
                invoke PrimaryNameLen, ebx
                add eax, 8
                .IF eax & 1
                    inc eax
                .ENDIF
                add g_ptSize, eax
                invoke JolietNameLen, ebx
                add eax, 8
                .IF eax & 1
                    inc eax
                .ENDIF
                add g_ptSizeJ, eax
            .ENDIF
            mov ebx, [ebx].NODE.pNextSibling
        .ENDW
    .ENDIF
    jmp bfs_loop
bfs_done:
    mov eax, TRUE
    ret
BuildDirArray ENDP

; Depth-first: files get extents in the order WriteFiles will emit them
AssignFileExtents PROC USES esi pDir:DWORD
    mov esi, pDir
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        test [esi].NODE.nflags, NF_DIR
        .IF !ZERO?
            invoke AssignFileExtents, esi
        .ELSE
            mov eax, g_lba
            mov [esi].NODE.wExtent, eax
            invoke SectorsFor64, [esi].NODE.dataSize, [esi].NODE.dataSizeHi
            add g_lba, eax
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    ret
AssignFileExtents ENDP

; Zero padding after cb bytes of data so the next write starts on a block boundary
IsoWritePadTo PROC cb:DWORD
    LOCAL pad:DWORD
    mov eax, cb
    neg eax
    and eax, ISO_SECTOR - 1
    mov pad, eax
    invoke SecBegin
    .IF pad != 0
        invoke WriteAll, g_hOut, g_pSec, pad
    .ENDIF
    invoke SectorsFor, cb
    add g_lba, eax
    ret
IsoWritePadTo ENDP

AssignLayout PROC USES esi ebx
    ; blocks 16..256 hold the ISO and UDF volume descriptors; everything else lives in the UDF partition
    mov g_lba, UDF_PART_START
    invoke UdfLayout
    mov eax, g_lba
    mov g_ptL, eax
    invoke SectorsFor, g_ptSize
    add g_lba, eax
    mov eax, g_lba
    mov g_ptM, eax
    invoke SectorsFor, g_ptSize
    add g_lba, eax
    mov eax, g_lba
    mov g_ptLJ, eax
    invoke SectorsFor, g_ptSizeJ
    add g_lba, eax
    mov eax, g_lba
    mov g_ptMJ, eax
    invoke SectorsFor, g_ptSizeJ
    add g_lba, eax
    .IF g_bootCount != 0
        mov eax, g_lba
        mov g_bootWCatalog, eax             ; one block for the boot catalog
        inc g_lba
    .ENDIF

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
    xor ebx, ebx
    .WHILE ebx < g_nDirs
        mov eax, g_pDirs
        mov esi, [eax + ebx * 4]
        mov eax, g_lba
        mov [esi].NODE.wExtentJ, eax
        mov eax, [esi].NODE.wDirSizeJ
        shr eax, 11
        add g_lba, eax
        inc ebx
    .ENDW
    invoke AssignFileExtents, g_pRootNode
    invoke BootAssignLayout, offset g_lba   ; hidden boot images (entries not backed by a file)
    inc g_lba                               ; closing UDF anchor
    mov eax, g_lba
    mov g_totalSectors, eax
    ret
AssignLayout ENDP

; ---------------------------------------------------------------------------
; Emitters
; ---------------------------------------------------------------------------
; Volume descriptor into the staging sector and write it
WriteVolumeDescriptor PROC USES esi edi ebx bJoliet:DWORD
    LOCAL rec[40]:BYTE
    LOCAL szDateW[24]:WORD
    LOCAL stm:SYSTEMTIME
    LOCAL nul:BYTE

    invoke SecBegin
    mov edi, g_pSec
    mov byte ptr [edi], ISO_VD_PRIMARY
    .IF bJoliet != 0
        mov byte ptr [edi], ISO_VD_SUPPLEMENTARY
    .ENDIF
    lea eax, [edi + 1]
    invoke RtlMoveMemory, eax, offset szCD001, 5
    mov byte ptr [edi + 6], 1

    mov esi, g_pRootNode
    .IF bJoliet == 0
        lea eax, [edi + 8]
        invoke FillBytes, eax, ' ', 32
        lea eax, [edi + 40]
        invoke FillBytes, eax, ' ', 32
        ; volume id: upper-case d-characters of the root name
        lea ecx, [esi].NODE.szName
        lea edx, [edi + 40]
        xor ebx, ebx
        .WHILE ebx < 32 && word ptr [ecx] != 0
            movzx eax, word ptr [ecx]
            .IF eax >= 'a' && eax <= 'z'
                sub eax, 20h
            .ENDIF
            push ecx
            push edx
            push eax
            invoke IsoCharOk, eax
            .IF eax == 0
                mov dword ptr [esp], '_'
            .ENDIF
            pop eax
            pop edx
            pop ecx
            mov [edx], al
            inc edx
            add ecx, 2
            inc ebx
        .ENDW
    .ELSE
        lea eax, [edi + 8]
        invoke FillWideSpaces, eax, 16
        lea eax, [edi + 40]
        invoke FillWideSpaces, eax, 16
        lea ecx, [esi].NODE.szName
        lea edx, [edi + 40]
        xor ebx, ebx
        .WHILE ebx < 16 && word ptr [ecx] != 0
            mov ax, [ecx]
            xchg al, ah
            mov [edx], ax
            add edx, 2
            add ecx, 2
            inc ebx
        .ENDW
        mov byte ptr [edi + 88], 25h        ; "%/E" = UCS-2 level 3
        mov byte ptr [edi + 89], 2Fh
        mov byte ptr [edi + 90], 45h
    .ENDIF

    lea eax, [edi + 80]
    invoke PutBoth32, eax, g_totalSectors
    lea eax, [edi + 120]
    invoke PutBoth16, eax, 1                ; volume set size
    lea eax, [edi + 124]
    invoke PutBoth16, eax, 1                ; volume sequence number
    lea eax, [edi + 128]
    invoke PutBoth16, eax, ISO_SECTOR       ; logical block size

    .IF bJoliet == 0
        lea eax, [edi + 132]
        invoke PutBoth32, eax, g_ptSize
        mov eax, g_ptL
        mov [edi + 140], eax
        mov eax, g_ptM
        bswap eax
        mov [edi + 148], eax
        mov nul, 0
        invoke BuildDirRecord, addr rec, esi, [esi].NODE.wExtent, [esi].NODE.wDirSize, ISO_FLAG_DIRECTORY, addr nul, 1
    .ELSE
        lea eax, [edi + 132]
        invoke PutBoth32, eax, g_ptSizeJ
        mov eax, g_ptLJ
        mov [edi + 140], eax
        mov eax, g_ptMJ
        bswap eax
        mov [edi + 148], eax
        mov nul, 0
        invoke BuildDirRecord, addr rec, esi, [esi].NODE.wExtentJ, [esi].NODE.wDirSizeJ, ISO_FLAG_DIRECTORY, addr nul, 1
    .ENDIF
    lea eax, [edi + 156]
    lea ecx, rec
    invoke RtlMoveMemory, eax, ecx, 34

    ; text fields: volume set / publisher / preparer / application (128 each), then three 37-byte file ids
    .IF bJoliet == 0
        lea eax, [edi + 190]
        invoke FillBytes, eax, ' ', 128 * 4 + 37 * 3
        lea eax, [edi + 574]
        invoke RtlMoveMemory, eax, offset szAppId, 6
    .ELSE
        lea eax, [edi + 190]
        invoke FillWideSpaces, eax, 64 * 4
        lea eax, [edi + 702]
        invoke FillWideSpaces, eax, 18 * 3
        lea eax, [edi + 574]
        lea ecx, szAppId
        xor ebx, ebx
        .WHILE ebx < 6
            mov byte ptr [eax], 0
            mov dl, [ecx + ebx]
            mov [eax + 1], dl
            add eax, 2
            inc ebx
        .ENDW
    .ENDIF

    ; dates: creation = now, others zero
    invoke GetLocalTime, addr stm
    movzx eax, stm.wSecond
    push eax
    movzx eax, stm.wMinute
    push eax
    movzx eax, stm.wHour
    push eax
    movzx eax, stm.wDay
    push eax
    movzx eax, stm.wMonth
    push eax
    movzx eax, stm.wYear
    push eax
    push offset szDateFmtW
    lea eax, szDateW
    push eax
    call wsprintfW
    add esp, 8 * 4
    lea ecx, szDateW
    lea edx, [edi + 813]
    xor ebx, ebx
    .WHILE ebx < 16
        mov al, [ecx + ebx * 2]
        mov [edx + ebx], al
        inc ebx
    .ENDW
    mov byte ptr [edi + 829], 0
    lea eax, [edi + 830]
    invoke RtlMoveMemory, eax, offset szZeroDate, 17
    lea eax, [edi + 847]
    invoke RtlMoveMemory, eax, offset szZeroDate, 17
    lea eax, [edi + 864]
    invoke RtlMoveMemory, eax, offset szZeroDate, 17
    mov byte ptr [edi + 881], 1             ; file structure version

    invoke SecWrite
    ret
WriteVolumeDescriptor ENDP

WriteTerminator PROC USES edi
    invoke SecBegin
    mov edi, g_pSec
    mov byte ptr [edi], ISO_VD_TERMINATOR
    lea eax, [edi + 1]
    invoke RtlMoveMemory, eax, offset szCD001, 5
    mov byte ptr [edi + 6], 1
    invoke SecWrite
    ret
WriteTerminator ENDP

WritePathTable PROC USES esi ebx bJoliet:DWORD, bBigEndian:DWORD
    LOCAL rec[160]:BYTE
    LOCAL nameBuf[140]:BYTE
    LOCAL nameLen:DWORD
    LOCAL extent:DWORD
    LOCAL parentIdx:DWORD
    LOCAL startLba:DWORD
    LOCAL want:DWORD

    mov eax, g_lba
    mov startLba, eax
    invoke SecBegin
    xor ebx, ebx
    .WHILE ebx < g_nDirs
        mov eax, g_pDirs
        mov esi, [eax + ebx * 4]
        .IF ebx == 0
            mov nameBuf[0], 0
            mov nameLen, 1
            mov parentIdx, 1
        .ELSE
            mov eax, [esi].NODE.pParent
            mov eax, [eax].NODE.wPathIdx
            mov parentIdx, eax
            .IF bJoliet == 0
                lea eax, [esi].NODE.isoName
                invoke lstrlenA, eax
                mov nameLen, eax
                lea eax, [esi].NODE.isoName
                invoke RtlMoveMemory, addr nameBuf, eax, nameLen
            .ELSE
                invoke JolietName, esi, addr nameBuf
                mov nameLen, eax
            .ENDIF
        .ENDIF
        mov eax, [esi].NODE.wExtent
        .IF bJoliet != 0
            mov eax, [esi].NODE.wExtentJ
        .ENDIF
        mov extent, eax
        invoke BuildPathRecord, addr rec, extent, parentIdx, addr nameBuf, nameLen, bBigEndian
        invoke SecPutBytes, addr rec, eax
        inc ebx
    .ENDW
    invoke SecFlush
    ; pad to the reserved size
    mov eax, g_ptSize
    .IF bJoliet != 0
        mov eax, g_ptSizeJ
    .ENDIF
    invoke SectorsFor, eax
    add eax, startLba
    mov want, eax
    .WHILE TRUE
        mov eax, g_lba
        .BREAK .IF eax >= want
        invoke SecWrite
    .ENDW
    ret
WritePathTable ENDP

WriteDirectory PROC USES esi edi ebx pDir:DWORD, bJoliet:DWORD
    LOCAL rec[200]:BYTE
    LOCAL nameBuf[140]:BYTE
    LOCAL nameLen:DWORD
    LOCAL extent:DWORD
    LOCAL dataLen:DWORD
    LOCAL fileFlags:DWORD
    LOCAL startLba:DWORD
    LOCAL want:DWORD
    LOCAL one:BYTE
    LOCAL zero:BYTE

    mov eax, g_lba
    mov startLba, eax
    mov one, 1
    mov zero, 0
    invoke SecBegin
    mov esi, pDir

    ; "."
    mov eax, [esi].NODE.wExtent
    mov ecx, [esi].NODE.wDirSize
    .IF bJoliet != 0
        mov eax, [esi].NODE.wExtentJ
        mov ecx, [esi].NODE.wDirSizeJ
    .ENDIF
    mov extent, eax
    mov dataLen, ecx
    invoke BuildDirRecord, addr rec, esi, extent, dataLen, ISO_FLAG_DIRECTORY, addr zero, 1
    invoke SecPutRecord, addr rec, eax

    ; ".."
    mov edi, [esi].NODE.pParent
    .IF edi == 0
        mov edi, esi
    .ENDIF
    mov eax, [edi].NODE.wExtent
    mov ecx, [edi].NODE.wDirSize
    .IF bJoliet != 0
        mov eax, [edi].NODE.wExtentJ
        mov ecx, [edi].NODE.wDirSizeJ
    .ENDIF
    mov extent, eax
    mov dataLen, ecx
    invoke BuildDirRecord, addr rec, edi, extent, dataLen, ISO_FLAG_DIRECTORY, addr one, 1
    invoke SecPutRecord, addr rec, eax

    mov edi, [esi].NODE.pFirstChild
    .WHILE edi != 0
        invoke IsoSkips, edi
        .IF eax != 0
            mov edi, [edi].NODE.pNextSibling
            .CONTINUE
        .ENDIF
        test [edi].NODE.nflags, NF_DIR
        .IF !ZERO?
            mov fileFlags, ISO_FLAG_DIRECTORY
            mov eax, [edi].NODE.wExtent
            mov ecx, [edi].NODE.wDirSize
            .IF bJoliet != 0
                mov eax, [edi].NODE.wExtentJ
                mov ecx, [edi].NODE.wDirSizeJ
            .ENDIF
        .ELSE
            mov fileFlags, 0
            mov eax, [edi].NODE.wExtent
            mov ecx, [edi].NODE.dataSize
        .ENDIF
        mov extent, eax
        mov dataLen, ecx
        .IF bJoliet == 0
            lea eax, [edi].NODE.isoName
            invoke lstrlenA, eax
            mov nameLen, eax
            lea eax, [edi].NODE.isoName
            invoke RtlMoveMemory, addr nameBuf, eax, nameLen
        .ELSE
            invoke JolietName, edi, addr nameBuf
            mov nameLen, eax
        .ENDIF
        invoke BuildDirRecord, addr rec, edi, extent, dataLen, fileFlags, addr nameBuf, nameLen
        invoke SecPutRecord, addr rec, eax
        mov edi, [edi].NODE.pNextSibling
    .ENDW
    invoke SecFlush

    mov eax, [esi].NODE.wDirSize
    .IF bJoliet != 0
        mov eax, [esi].NODE.wDirSizeJ
    .ENDIF
    shr eax, 11
    add eax, startLba
    mov want, eax
    .WHILE TRUE
        mov eax, g_lba
        .BREAK .IF eax >= want
        invoke SecWrite
    .ENDW
    ret
WriteDirectory ENDP

WriteFiles PROC USES esi pDir:DWORD
    LOCAL pad:DWORD
    mov esi, pDir
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        .BREAK .IF g_fail != 0
        test [esi].NODE.nflags, NF_DIR
        .IF !ZERO?
            invoke WriteFiles, esi
        .ELSEIF [esi].NODE.dataSize != 0 || [esi].NODE.dataSizeHi != 0
            invoke VfsCopyData, esi, g_hOut
            .IF eax == 0
                mov g_fail, TRUE
                .BREAK
            .ENDIF
            mov eax, [esi].NODE.dataSize
            neg eax
            and eax, ISO_SECTOR - 1
            mov pad, eax
            invoke SecBegin
            .IF pad != 0
                invoke WriteAll, g_hOut, g_pSec, pad
            .ENDIF
            invoke SectorsFor64, [esi].NODE.dataSize, [esi].NODE.dataSizeHi
            add g_lba, eax
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    ret
WriteFiles ENDP

; ---------------------------------------------------------------------------
; IsoWrite - entry point
; ---------------------------------------------------------------------------
IsoWrite PROC USES esi ebx pszOutPath:DWORD
    mov g_fail, FALSE
    mov g_hOut, 0
    mov g_pDirs, 0
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

    invoke IsoGenNames, g_pRootNode
    invoke ComputeDirSizes, g_pRootNode
    invoke BuildDirArray
    .IF eax == 0
        jmp cleanup_fail
    .ENDIF
    invoke AssignLayout
    mov eax, g_totalSectors
    mov ecx, ISO_SECTOR
    mul ecx                                 ; edx:eax = bytes
    mov g_progTotal, eax                    ; every byte goes through WriteAll, which counts
    mov g_progTotalHi, edx

    invoke CreateFileW, pszOutPath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        jmp cleanup_fail
    .ENDIF
    mov g_hOut, eax
    invoke FilePresize, g_hOut, g_progTotal, g_progTotalHi  ; the layout already knows the final size

    mov g_lba, 0
    invoke WriteZeroSectors, 16
    invoke WriteVolumeDescriptor, FALSE
    .IF g_bootCount != 0
        invoke SecBegin
        invoke BootBuildBRVD, g_pSec
        invoke SecWrite
    .ENDIF
    invoke WriteVolumeDescriptor, TRUE
    invoke WriteTerminator
    invoke UdfEmitRecognition               ; BEA01 NSR02 TEA01 close the recognition sequence
    invoke UdfEmitPreamble                  ; VDS x2, LVID, anchor at 256 -> g_lba == UDF_PART_START
    invoke UdfEmitPartition                 ; FSD, file entries, directory streams
    invoke WritePathTable, FALSE, FALSE
    invoke WritePathTable, FALSE, TRUE
    invoke WritePathTable, TRUE, FALSE
    invoke WritePathTable, TRUE, TRUE
    .IF g_bootCount != 0
        invoke SecBegin
        invoke BootBuildCatalog, g_pSec
        invoke SecWrite
    .ENDIF

    xor ebx, ebx
    .WHILE ebx < g_nDirs
        mov eax, g_pDirs
        mov esi, [eax + ebx * 4]
        invoke WriteDirectory, esi, FALSE
        inc ebx
    .ENDW
    xor ebx, ebx
    .WHILE ebx < g_nDirs
        mov eax, g_pDirs
        mov esi, [eax + ebx * 4]
        invoke WriteDirectory, esi, TRUE
        inc ebx
    .ENDW
    invoke WriteFiles, g_pRootNode
    .IF g_bootCount != 0 && g_fail == 0
        invoke BootWriteBlobs
    .ENDIF
    .IF g_fail == 0
        invoke UdfEmitTrailer               ; closing anchor in the last block
    .ENDIF
    .IF g_bootCount != 0 && g_fail == 0
        invoke BootPatchInfoTables          ; seeks backwards, so after all sequential writes
    .ENDIF

    invoke CloseHandle, g_hOut
    mov g_hOut, 0
    .IF g_fail != 0
        invoke DeleteFileW, pszOutPath
        jmp cleanup_fail
    .ENDIF
    invoke VfsFreeMem, g_pDirs
    invoke VfsFreeMem, g_pSec
    mov eax, TRUE
    ret

cleanup_fail:
    .IF g_hOut != 0
        invoke CloseHandle, g_hOut
    .ENDIF
    invoke VfsFreeMem, g_pDirs
    invoke VfsFreeMem, g_pSec
    xor eax, eax
    ret
IsoWrite ENDP

END
