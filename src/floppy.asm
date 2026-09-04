; FoxImg - floppy images: the ImageDisk container and the FAT12/16 filesystem
;
; ImageDisk (.imd, Dave Dunfield): an ASCII comment ended by 1Ah, then one
; record per track - mode, cylinder, head (bit 7: a cylinder map follows the
; sector map, bit 6: a head map), sector count, size code (128 << n), the
; sector number map, the optional maps, then one type byte per sector: 0
; absent, 1/3/5/7 the data, 2/4/6/8 one byte that fills the sector. The
; expander lays the tracks out in file order with the sectors of each in
; number order, which is what a flat floppy image is.
;
; FAT (raw .img / .ima and anything that expands to one): the BIOS parameter
; block at byte 0 gives the geometry; FAT12 or FAT16 by cluster count. The
; root directory is a fixed area, subdirectories are cluster chains. Long
; names come from the 0Fh entries before a short one. A file whose chain is
; one run is served from its byte offset; a fragmented one carries an extent
; list in 512-byte units (NF_SEC512).
include foximg.inc

IMD_MAX         equ 64 * 1024 * 1024
FAT_MAX_CLUSTER equ 65536
FAT_DIR_MAX     equ 65536               ; bytes of one directory cluster run read at a time

.data
g_bFat          dd 0
g_fatBps        dd 0                    ; bytes per sector
g_fatSpc        dd 0                    ; sectors per cluster
g_fatBytesPerCl dd 0
g_fatStart      dd 0                    ; byte offsets
g_fatRootStart  dd 0
g_fatRootEnts   dd 0
g_fatDataStart  dd 0
g_fatClusters   dd 0                    ; data clusters (numbered from 2)
g_fatIs16       dd 0
g_fatTable      dd 0                    ; the first FAT, in memory
g_fatTableCb    dd 0
g_fatDepth      dd 0
WSTR szCtImd, <ImageDisk>
WSTR szFatRoot, <FLOPPY>
.code

; ---------------------------------------------------------------------------
; ImageDisk
; ---------------------------------------------------------------------------
; cb copies of one byte to the output
ImdPutFill PROC USES edi ebx b:DWORD, cb:DWORD
    LOCAL buf[512]:BYTE
    lea edi, buf
    mov eax, b
    mov ecx, 512
    rep stosb
    mov ebx, cb
    .WHILE ebx != 0
        mov eax, ebx
        .IF eax > 512
            mov eax, 512
        .ENDIF
        invoke ZfPutMem, addr buf, eax
        sub ebx, eax
    .ENDW
    ret
ImdPutFill ENDP

ImdExpandFile PROC USES esi edi ebx hIn:DWORD, pszDst:DWORD
    LOCAL sizeLo:DWORD
    LOCAL sizeHi:DWORD
    LOCAL pBuf:DWORD
    LOCAL pEnd:DWORD
    LOCAL pTrack:DWORD                      ; the first track record
    LOCAL totLo:DWORD
    LOCAL nSec:DWORD
    LOCAL secCb:DWORD
    LOCAL pMap:DWORD
    LOCAL pData:DWORD                       ; the first sector's type byte
    LOCAL pass:DWORD
    LOCAL i:DWORD
    LOCAL want:DWORD
    LOCAL hOut:DWORD
    LOCAL ok:DWORD
    LOCAL ptrs[256]:DWORD
    mov ok, FALSE
    mov pBuf, 0
    invoke FileSize64, hIn, addr sizeLo, addr sizeHi
    .IF sizeHi != 0 || sizeLo > IMD_MAX || sizeLo < 16
        ret
    .ENDIF
    invoke VfsAlloc, sizeLo
    mov pBuf, eax
    .IF eax == 0
        ret
    .ENDIF
    invoke FileReadAt, hIn, 0, 0, pBuf, sizeLo
    .IF eax != sizeLo
        jmp done
    .ENDIF
    mov esi, pBuf
    mov eax, sizeLo
    add eax, esi
    mov pEnd, eax
    .IF dword ptr [esi] != 20444D49h        ; "IMD "
        jmp done
    .ENDIF
    .WHILE esi < pEnd && byte ptr [esi] != 1Ah
        inc esi
    .ENDW
    .IF esi >= pEnd
        jmp done
    .ENDIF
    inc esi
    mov pTrack, esi
    ; pass 0 sizes the image, pass 1 writes it
    mov pass, 0
    .WHILE pass < 2
        mov totLo, 0
        mov esi, pTrack
        .WHILE esi < pEnd
            lea eax, [esi + 5]
            .IF eax > pEnd
                jmp done
            .ENDIF
            movzx eax, byte ptr [esi + 3]
            mov nSec, eax
            movzx ecx, byte ptr [esi + 4]
            .IF ecx > 6
                jmp done
            .ENDIF
            mov eax, 128
            shl eax, cl
            mov secCb, eax
            movzx ebx, byte ptr [esi + 2]   ; head, with the map flags
            add esi, 5
            mov pMap, esi
            add esi, nSec
            .IF ebx & 80h
                add esi, nSec               ; cylinder map
            .ENDIF
            .IF ebx & 40h
                add esi, nSec               ; head map
            .ENDIF
            mov pData, esi
            ; where each sector's record starts
            mov i, 0
            .WHILE 1
                mov ecx, i
                .BREAK .IF ecx >= nSec
                .IF esi >= pEnd
                    jmp done
                .ENDIF
                mov ptrs[ecx * 4], esi
                movzx eax, byte ptr [esi]
                inc esi
                .IF eax == 0
                .ELSEIF eax & 1
                    add esi, secCb
                .ELSE
                    inc esi
                .ENDIF
                .IF eax > 8
                    jmp done
                .ENDIF
                inc i
            .ENDW
            .IF esi > pEnd
                jmp done
            .ENDIF
            .IF pass == 0
                mov eax, nSec
                imul eax, secCb
                add totLo, eax
            .ELSE
                ; sectors in number order: the smallest map value not yet taken
                mov want, 0
                .WHILE 1
                    mov eax, want
                    .BREAK .IF eax >= nSec
                    mov ebx, -1                 ; best index
                    mov edx, 100h               ; best number
                    mov ecx, 0
                    .WHILE ecx < nSec
                        mov eax, pMap
                        movzx eax, byte ptr [eax + ecx]
                        .IF eax < edx
                            mov edx, eax
                            mov ebx, ecx
                        .ENDIF
                        inc ecx
                    .ENDW
                    mov eax, pMap
                    mov byte ptr [eax + ebx], 0FFh  ; taken
                    mov edi, ptrs[ebx * 4]
                    movzx eax, byte ptr [edi]
                    .IF eax == 0
                        invoke ZfPutZeros, secCb
                    .ELSEIF eax & 1
                        lea eax, [edi + 1]
                        invoke ZfPutMem, eax, secCb
                    .ELSE
                        movzx eax, byte ptr [edi + 1]
                        invoke ImdPutFill, eax, secCb
                    .ENDIF
                    inc want
                .ENDW
            .ENDIF
        .ENDW
        .IF pass == 0
            .IF totLo == 0
                jmp done
            .ENDIF
            invoke ZfBeginOut, pszDst, hIn, totLo, 0
            .IF eax == INVALID_HANDLE_VALUE
                jmp done
            .ENDIF
            mov hOut, eax
        .ENDIF
        inc pass
    .ENDW
    invoke ZfOutFinal
    invoke ZfCheckTotal, totLo, 0
    mov ok, eax
done:
    invoke VfsFreeMem, pBuf
    mov eax, ok
    ret
ImdExpandFile ENDP

; ---------------------------------------------------------------------------
; FAT12 / FAT16
; ---------------------------------------------------------------------------
FatDirChain PROTO :DWORD,:DWORD

; A 16-bit little-endian value at pSrc
FatU16 PROC pSrc:DWORD
    mov ecx, pSrc
    movzx eax, word ptr [ecx]
    ret
FatU16 ENDP

; The BIOS parameter block at byte 0, if it is one; sets the geometry
FatDetect PROC USES esi ebx
    LOCAL totSec:DWORD
    LOCAL spf:DWORD
    LOCAL rootSecs:DWORD
    mov g_bFat, 0
    invoke IsoSectorPtr, 0
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov esi, eax
    movzx eax, byte ptr [esi]
    .IF eax != 0EBh && eax != 0E9h
        xor eax, eax
        ret
    .ENDIF
    movzx eax, word ptr [esi + 11]
    .IF eax != 512 && eax != 1024 && eax != 2048 && eax != 4096
        xor eax, eax
        ret
    .ENDIF
    mov g_fatBps, eax
    movzx ecx, byte ptr [esi + 13]
    .IF ecx == 0 || ecx > 128
        xor eax, eax
        ret
    .ENDIF
    lea edx, [ecx - 1]
    test ecx, edx
    .IF !ZERO?
        xor eax, eax
        ret
    .ENDIF
    mov g_fatSpc, ecx
    imul eax, ecx
    mov g_fatBytesPerCl, eax
    movzx eax, word ptr [esi + 14]          ; reserved sectors
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov ebx, eax                            ; running sector count
    movzx eax, byte ptr [esi + 16]          ; FATs
    .IF eax == 0 || eax > 4
        xor eax, eax
        ret
    .ENDIF
    movzx ecx, word ptr [esi + 22]          ; sectors per FAT
    .IF ecx == 0
        xor eax, eax                        ; FAT32 keeps it at 36; not here
        ret
    .ENDIF
    mov spf, ecx
    imul ecx, eax
    push ebx
    mov eax, ebx
    imul eax, g_fatBps
    mov g_fatStart, eax
    pop ebx
    add ebx, ecx                            ; root directory sector
    movzx eax, word ptr [esi + 17]          ; root entries
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov g_fatRootEnts, eax
    shl eax, 5
    add eax, g_fatBps
    dec eax
    xor edx, edx
    div g_fatBps
    mov rootSecs, eax
    mov eax, ebx
    imul eax, g_fatBps
    mov g_fatRootStart, eax
    add ebx, rootSecs
    mov eax, ebx
    imul eax, g_fatBps
    mov g_fatDataStart, eax
    movzx eax, word ptr [esi + 19]
    .IF eax == 0
        mov eax, dword ptr [esi + 32]
    .ENDIF
    mov totSec, eax
    .IF eax <= ebx
        xor eax, eax
        ret
    .ENDIF
    movzx ecx, byte ptr [esi + 21]          ; media descriptor
    .IF ecx < 0F0h
        xor eax, eax
        ret
    .ENDIF
    ; the image must hold what the block claims
    mov eax, totSec
    mul g_fatBps
    .IF edx != 0 || eax > g_cbFileLo
        .IF g_cbFileHi == 0
            xor eax, eax
            ret
        .ENDIF
    .ENDIF
    mov eax, totSec
    sub eax, ebx
    xor edx, edx
    div g_fatSpc
    mov g_fatClusters, eax
    .IF eax == 0 || eax >= 65525
        xor eax, eax                        ; FAT32 or nonsense
        ret
    .ENDIF
    mov g_fatIs16, 0
    .IF eax >= 4085
        mov g_fatIs16, 1
    .ENDIF
    ; the table covers every cluster
    mov eax, spf
    imul eax, g_fatBps
    mov g_fatTableCb, eax
    mov eax, g_fatClusters
    add eax, 2
    .IF g_fatIs16 != 0
        shl eax, 1
    .ELSE
        lea eax, [eax + eax * 2]
        shr eax, 1
        inc eax
    .ENDIF
    .IF eax > g_fatTableCb
        xor eax, eax
        ret
    .ENDIF
    mov g_bFat, TRUE
    mov eax, TRUE
    ret
FatDetect ENDP

; The next cluster after clus, or 0FFFFFFFFh at the chain's end or anything odd
FatNext PROC clus:DWORD
    mov eax, clus
    .IF eax < 2
        mov eax, -1
        ret
    .ENDIF
    mov ecx, g_fatClusters
    add ecx, 2
    .IF eax >= ecx
        mov eax, -1
        ret
    .ENDIF
    mov ecx, g_fatTable
    .IF g_fatIs16 != 0
        movzx eax, word ptr [ecx + eax * 2]
        .IF eax >= 0FFF8h
            mov eax, -1
        .ENDIF
    .ELSE
        mov edx, eax
        lea edx, [edx + edx * 2]
        shr edx, 1                          ; entry offset: clus * 3 / 2
        movzx edx, word ptr [ecx + edx]
        test eax, 1
        .IF ZERO?
            and edx, 0FFFh
        .ELSE
            shr edx, 4
        .ENDIF
        mov eax, edx
        .IF eax >= 0FF8h
            mov eax, -1
        .ENDIF
    .ENDIF
    .IF eax != -1
        .IF eax < 2
            mov eax, -1
        .ELSE
            mov ecx, g_fatClusters
            add ecx, 2
            .IF eax >= ecx
                mov eax, -1
            .ENDIF
        .ENDIF
    .ENDIF
    ret
FatNext ENDP

; Byte offset of cluster clus in the image
FatClusterOff PROC clus:DWORD
    mov eax, clus
    sub eax, 2
    imul eax, g_fatBytesPerCl
    add eax, g_fatDataStart
    ret
FatClusterOff ENDP

; cb bytes at image byte offset off into pDst
FatRead PROC off:DWORD, cb:DWORD, pDst:DWORD
    mov eax, off
    mov ecx, eax
    shr eax, 11
    and ecx, 2047
    invoke IsoReadBytes, eax, ecx, cb, pDst
    ret
FatRead ENDP

; A FAT date and time onto the node
FatSetDate PROC pNode:DWORD, fdate:DWORD, ftime:DWORD
    LOCAL stm:SYSTEMTIME
    invoke RtlZeroMemory, addr stm, sizeof SYSTEMTIME
    mov eax, fdate
    .IF eax == 0
        invoke VfsDateNow, pNode
        ret
    .ENDIF
    mov ecx, eax
    shr ecx, 9
    add ecx, 1980
    mov stm.wYear, cx
    mov ecx, eax
    shr ecx, 5
    and ecx, 15
    .IF ecx == 0 || ecx > 12
        mov ecx, 1
    .ENDIF
    mov stm.wMonth, cx
    and eax, 31
    .IF eax == 0
        mov eax, 1
    .ENDIF
    mov stm.wDay, ax
    mov eax, ftime
    mov ecx, eax
    shr ecx, 11
    .IF ecx > 23
        mov ecx, 23
    .ENDIF
    mov stm.wHour, cx
    mov ecx, eax
    shr ecx, 5
    and ecx, 63
    .IF ecx > 59
        mov ecx, 59
    .ENDIF
    mov stm.wMinute, cx
    and eax, 31
    shl eax, 1
    .IF eax > 59
        mov eax, 59
    .ENDIF
    mov stm.wSecond, ax
    invoke VfsSetDate, pNode, addr stm
    ret
FatSetDate ENDP

; A file's data: its chain as one byte offset when it is one run, else an
; extent list in 512-byte units
FatSetData PROC USES esi edi ebx pNode:DWORD, firstCl:DWORD, cb:DWORD
    LOCAL runs:DWORD
    LOCAL clus:DWORD
    LOCAL prev:DWORD
    LOCAL left:DWORD
    LOCAL pList:DWORD
    LOCAL runStart:DWORD
    LOCAL runCb:DWORD
    mov esi, pNode
    mov eax, cb
    mov [esi].NODE.dataSize, eax
    .IF eax == 0 || firstCl < 2
        ret
    .ENDIF
    ; count the runs
    mov runs, 1
    mov eax, firstCl
    mov clus, eax
    mov prev, eax
    mov eax, cb
    mov left, eax
    .WHILE 1
        mov eax, left
        .IF eax <= g_fatBytesPerCl
            .BREAK
        .ENDIF
        sub eax, g_fatBytesPerCl
        mov left, eax
        invoke FatNext, clus
        .BREAK .IF eax == -1
        mov ecx, prev
        inc ecx
        .IF eax != ecx
            inc runs
        .ENDIF
        mov prev, eax
        mov clus, eax
    .ENDW
    invoke FatClusterOff, firstCl
    mov ecx, eax
    shr eax, 11
    and ecx, 2047
    mov [esi].NODE.isoExtent, eax
    mov [esi].NODE.isoByteRem, ecx
    .IF runs == 1
        ret
    .ENDIF
    ; the list: one extent per run, in 512-byte sectors
    mov eax, runs
    shl eax, 3
    invoke VfsAlloc, eax
    .IF eax == 0
        ret
    .ENDIF
    mov pList, eax
    mov edi, eax
    mov [esi].NODE.pExtList, eax
    mov eax, runs
    mov [esi].NODE.nExtList, eax
    or [esi].NODE.nflags, NF_SEC512
    mov eax, firstCl
    mov clus, eax
    mov prev, eax
    invoke FatClusterOff, firstCl
    mov runStart, eax
    mov runCb, 0
    mov eax, cb
    mov left, eax
    .WHILE 1
        mov eax, g_fatBytesPerCl
        .IF eax > left
            mov eax, left
        .ENDIF
        add runCb, eax
        sub left, eax
        .IF left == 0
            .BREAK
        .ENDIF
        invoke FatNext, clus
        .BREAK .IF eax == -1
        mov ecx, prev
        inc ecx
        .IF eax != ecx
            mov ecx, runStart
            shr ecx, 9
            mov [edi].EXTENT.lba, ecx
            mov ecx, runCb
            mov [edi].EXTENT.cb, ecx
            add edi, sizeof EXTENT
            push eax
            invoke FatClusterOff, eax
            mov runStart, eax
            mov runCb, 0
            pop eax
        .ENDIF
        mov prev, eax
        mov clus, eax
    .ENDW
    mov ecx, runStart
    shr ecx, 9
    mov [edi].EXTENT.lba, ecx
    mov ecx, runCb
    mov [edi].EXTENT.cb, ecx
    ret
FatSetData ENDP

; The directory entries in the cb bytes at pBuf become children of pParent;
; long names are gathered from the 0Fh entries ahead of each short one
FatDirEntries PROC USES esi edi ebx pParent:DWORD, pBuf:DWORD, cb:DWORD
    LOCAL szName[NODE_NAME_MAX]:WORD
    LOCAL szLong[NODE_NAME_MAX]:WORD
    LOCAL longOk:DWORD
    LOCAL nflags:DWORD
    LOCAL pNode:DWORD
    LOCAL k:DWORD
    mov longOk, 0
    mov esi, pBuf
    mov ebx, cb
    .WHILE ebx >= 32
        movzx eax, byte ptr [esi]
        .BREAK .IF eax == 0                 ; the end of the directory
        .IF eax == 0E5h
            mov longOk, 0                   ; deleted
        .ELSE
            movzx eax, byte ptr [esi + 11]
            .IF eax == 0Fh
                ; long name piece: sequence 1-based, 13 UTF-16 units at 1, 14, 28
                movzx ecx, byte ptr [esi]
                .IF ecx & 40h
                    mov longOk, 1
                    invoke RtlZeroMemory, addr szLong, NODE_NAME_MAX * 2
                    movzx ecx, byte ptr [esi]
                .ENDIF
                and ecx, 3Fh
                .IF ecx >= 1 && ecx <= 19 && longOk != 0
                    dec ecx
                    lea eax, [ecx + ecx * 2]
                    shl eax, 2
                    add eax, ecx                ; * 13
                    lea edi, szLong
                    lea edi, [edi + eax * 2]
                    mov k, 0
                    .WHILE k < 13
                        mov ecx, k
                        .IF ecx < 5
                            movzx eax, word ptr [esi + 1 + ecx * 2]
                        .ELSEIF ecx < 11
                            sub ecx, 5
                            movzx eax, word ptr [esi + 14 + ecx * 2]
                        .ELSE
                            sub ecx, 11
                            movzx eax, word ptr [esi + 28 + ecx * 2]
                        .ENDIF
                        .IF eax == 0FFFFh
                            xor eax, eax
                        .ENDIF
                        mov word ptr [edi], ax
                        add edi, 2
                        inc k
                    .ENDW
                .ENDIF
            .ELSEIF eax & 8
                mov longOk, 0                   ; the volume label
            .ELSEIF byte ptr [esi] == '.'
                mov longOk, 0                   ; . and ..
            .ELSE
                ; the short name: 8 + 3, blank padded; 05h stands for E5h
                lea edi, szName
                mov k, 0
                .WHILE k < 8
                    mov ecx, k
                    movzx eax, byte ptr [esi + ecx]
                    .BREAK .IF eax == ' '
                    .IF eax == 5
                        mov eax, 0E5h
                    .ENDIF
                    .IF byte ptr [esi + 12] & 8
                        .IF eax >= 'A' && eax <= 'Z'
                            add eax, 32
                        .ENDIF
                    .ENDIF
                    mov word ptr [edi], ax
                    add edi, 2
                    inc k
                .ENDW
                .IF byte ptr [esi + 8] != ' '
                    mov word ptr [edi], '.'
                    add edi, 2
                    mov k, 8
                    .WHILE k < 11
                        mov ecx, k
                        movzx eax, byte ptr [esi + ecx]
                        .BREAK .IF eax == ' '
                        .IF byte ptr [esi + 12] & 16
                            .IF eax >= 'A' && eax <= 'Z'
                                add eax, 32
                            .ENDIF
                        .ENDIF
                        mov word ptr [edi], ax
                        add edi, 2
                        inc k
                    .ENDW
                .ENDIF
                mov word ptr [edi], 0
                mov nflags, NF_ISO
                movzx eax, byte ptr [esi + 11]
                .IF eax & 10h
                    or nflags, NF_DIR
                .ENDIF
                lea eax, szName
                .IF longOk != 0 && szLong[0] != 0
                    lea eax, szLong
                .ENDIF
                invoke VfsNew, pParent, eax, nflags
                mov longOk, 0
                .IF eax != 0
                    mov pNode, eax
                    movzx eax, word ptr [esi + 24]
                    movzx ecx, word ptr [esi + 22]
                    invoke FatSetDate, pNode, eax, ecx
                    movzx eax, word ptr [esi + 26]
                    mov ecx, dword ptr [esi + 28]
                    .IF nflags & NF_DIR
                        mov ecx, 0
                        .IF eax >= 2 && g_fatDepth < 64
                            inc g_fatDepth
                            invoke FatDirChain, pNode, eax
                            dec g_fatDepth
                        .ENDIF
                    .ELSE
                        invoke FatSetData, pNode, eax, ecx
                    .ENDIF
                .ENDIF
            .ENDIF
        .ENDIF
        add esi, 32
        sub ebx, 32
    .ENDW
    ret
FatDirEntries ENDP

; A subdirectory: its clusters gathered into one buffer, then the entries
FatDirChain PROC USES esi ebx pParent:DWORD, firstCl:DWORD
    LOCAL pBuf:DWORD
    LOCAL cb:DWORD
    LOCAL clus:DWORD
    ; the chain's length first
    mov cb, 0
    mov eax, firstCl
    mov clus, eax
    .WHILE clus != -1 && cb < FAT_DIR_MAX * 4
        mov eax, g_fatBytesPerCl
        add cb, eax
        invoke FatNext, clus
        mov clus, eax
    .ENDW
    .IF cb == 0
        ret
    .ENDIF
    invoke VfsAlloc, cb
    .IF eax == 0
        ret
    .ENDIF
    mov pBuf, eax
    mov esi, eax
    mov eax, firstCl
    mov clus, eax
    mov ebx, 0
    .WHILE clus != -1 && ebx < cb
        invoke FatClusterOff, clus
        lea ecx, [esi + ebx]
        invoke FatRead, eax, g_fatBytesPerCl, ecx
        add ebx, g_fatBytesPerCl
        invoke FatNext, clus
        mov clus, eax
    .ENDW
    invoke FatDirEntries, pParent, pBuf, cb
    invoke VfsFreeMem, pBuf
    ret
FatDirChain ENDP

FatBuild PROC USES esi edi pRoot:DWORD
    LOCAL pBuf:DWORD
    LOCAL cb:DWORD
    LOCAL szLabel[16]:WORD
    ; the volume label from the boot sector, when the extended block is there
    invoke IsoSectorPtr, 0
    .IF eax != 0 && byte ptr [eax + 38] == 29h
        lea esi, [eax + 43]
        lea edi, szLabel
        mov ecx, 11
        .WHILE ecx != 0
            movzx eax, byte ptr [esi]
            stosw
            inc esi
            dec ecx
        .ENDW
        ; trailing blanks off
        lea eax, szLabel
        .WHILE edi > eax && word ptr [edi - 2] == ' '
            sub edi, 2
        .ENDW
        xor eax, eax
        stosw
        .IF szLabel[0] != 0 && szLabel[0] != 'N'
            mov edx, pRoot
            lea edx, [edx].NODE.szName
            invoke lstrcpynW, edx, addr szLabel, NODE_NAME_MAX
        .ENDIF
    .ENDIF
    invoke VfsAlloc, g_fatTableCb
    mov g_fatTable, eax
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    invoke FatRead, g_fatStart, g_fatTableCb, g_fatTable
    mov eax, g_fatRootEnts
    shl eax, 5
    mov cb, eax
    invoke VfsAlloc, eax
    mov pBuf, eax
    .IF eax == 0
        jmp fail
    .ENDIF
    invoke FatRead, g_fatRootStart, cb, pBuf
    mov g_fatDepth, 0
    invoke FatDirEntries, pRoot, pBuf, cb
    invoke VfsFreeMem, pBuf
    invoke VfsFreeMem, g_fatTable
    mov g_fatTable, 0
    mov eax, TRUE
    ret
fail:
    invoke VfsFreeMem, g_fatTable
    mov g_fatTable, 0
    xor eax, eax
    ret
FatBuild ENDP

FatClose PROC
    mov g_bFat, 0
    ret
FatClose ENDP

END
