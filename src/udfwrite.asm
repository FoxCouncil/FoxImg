; FoxImg - UDF 1.02 writer (bridge layout: ISO 9660 + Joliet + UDF share one copy of the file data)
;
; Block plan (absolute):
;   16.. ISO descriptors, then BEA01 NSR02 TEA01          (UdfEmitRecognition)
;   32   main VDS: PVD IUVD PD LVD USD TD, 48 reserve copy, 64 LVID TD, 256 AVDP   (UdfEmitPreamble)
;   257  partition start: FSD, TD, root FE, then per directory: FID stream + child FEs   (UdfLayout / UdfEmitPartition)
;   ...  ISO path tables, boot catalog, ISO directories, file data (shared), last block AVDP (UdfEmitTrailer)
; Tag locations inside the partition are partition-relative; everything else is absolute.
include foximg.inc

AD_MAX_EXTENT   equ 3FFFF800h       ; largest block-multiple short_ad length
VDS_MAIN        equ 32
VDS_RESERVE     equ 48
LVID_BLOCK      equ 64
AVDP_BLOCK      equ 256

.data
g_udfNextUid    dd 16
g_udfFiles      dd 0
g_udfDirs       dd 0
g_udfTime       SYSTEMTIME <>

szOstaCs0       db 'OSTA Compressed Unicode', 0
szDomainId      db '*OSTA UDF Compliant', 0
szImplId        db '*FoxImg', 0
szLvInfoId      db '*UDF LV Info', 0
szNsrContents   db '+NSR02', 0
szBEA01         db 'BEA01'
szNSR02         db 'NSR02'
szTEA01         db 'TEA01'

.code

; ---------------------------------------------------------------------------
; Primitives
; ---------------------------------------------------------------------------
; CRC-16 CCITT (poly 1021h, init 0) as ECMA-167 7.2.6 requires
Crc16 PROC USES esi ebx pData:DWORD, cb:DWORD
    mov esi, pData
    xor ebx, ebx
    mov ecx, cb
    .WHILE ecx != 0
        movzx eax, byte ptr [esi]
        shl eax, 8
        xor ebx, eax
        push ecx
        mov ecx, 8
        .WHILE ecx != 0
            test ebx, 8000h
            .IF !ZERO?
                shl ebx, 1
                xor ebx, 1021h
            .ELSE
                shl ebx, 1
            .ENDIF
            and ebx, 0FFFFh
            dec ecx
        .ENDW
        pop ecx
        inc esi
        dec ecx
    .ENDW
    mov eax, ebx
    ret
Crc16 ENDP

; Descriptor tag: identifier, version 2, CRC over the body, location, checksum
TagFinish PROC USES esi pDesc:DWORD, tagId:DWORD, lbn:DWORD, cbDesc:DWORD
    mov esi, pDesc
    mov eax, tagId
    mov [esi], ax
    mov word ptr [esi + 2], 2
    mov byte ptr [esi + 4], 0
    mov byte ptr [esi + 5], 0
    mov word ptr [esi + 6], 0
    mov eax, cbDesc
    sub eax, 16
    mov [esi + 10], ax
    mov eax, lbn
    mov [esi + 12], eax
    lea eax, [esi + 16]
    mov ecx, cbDesc
    sub ecx, 16
    invoke Crc16, eax, ecx
    mov [esi + 8], ax
    ; checksum: bytes 0..15 except byte 4
    xor eax, eax
    xor ecx, ecx
    .WHILE ecx < 16
        .IF ecx != 4
            add al, [esi + ecx]
        .ENDIF
        inc ecx
    .ENDW
    mov [esi + 4], al
    ret
TagFinish ENDP

; Entity identifier (32 bytes): flags 0, ASCII id, 8-byte suffix from pSuffix (may be 0)
PutEntity PROC USES esi edi pDst:DWORD, pszId:DWORD, pSuffix:DWORD
    invoke FillBytes, pDst, 0, 32
    mov edi, pDst
    inc edi
    mov esi, pszId
    mov ecx, 23
    .WHILE ecx != 0 && byte ptr [esi] != 0
        movsb
        dec ecx
    .ENDW
    .IF pSuffix != 0
        mov edi, pDst
        add edi, 24
        invoke RtlMoveMemory, edi, pSuffix, 8
    .ENDIF
    ret
PutEntity ENDP

; Character set specification (64 bytes): CS0
PutCS0 PROC pDst:DWORD
    invoke FillBytes, pDst, 0, 64
    mov eax, pDst
    inc eax
    invoke RtlMoveMemory, eax, offset szOstaCs0, 23
    ret
PutCS0 ENDP

; Compressed unicode of a UTF-16 string into pDst (max cbMax bytes). Returns byte length including the id byte.
NameCompress PROC USES esi edi ebx pDst:DWORD, pszWide:DWORD, cbMax:DWORD
    LOCAL wide:DWORD
    mov esi, pszWide
    mov wide, 0
    .WHILE word ptr [esi] != 0
        .IF word ptr [esi] > 0FFh
            mov wide, 1
        .ENDIF
        add esi, 2
    .ENDW
    mov esi, pszWide
    mov edi, pDst
    .IF wide != 0
        mov byte ptr [edi], 16
        inc edi
        mov ebx, 1
        .WHILE word ptr [esi] != 0
            mov eax, ebx
            add eax, 2
            .BREAK .IF eax > cbMax
            lodsw
            xchg al, ah
            stosw
            add ebx, 2
        .ENDW
    .ELSE
        mov byte ptr [edi], 8
        inc edi
        mov ebx, 1
        .WHILE word ptr [esi] != 0
            .BREAK .IF ebx >= cbMax
            lodsw
            stosb
            inc ebx
        .ENDW
    .ENDIF
    mov eax, ebx
    ret
NameCompress ENDP

; dstring: compressed name, zero padded, length in the last byte
PutDString PROC pDst:DWORD, cb:DWORD, pszWide:DWORD
    invoke FillBytes, pDst, 0, cb
    mov eax, cb
    dec eax
    invoke NameCompress, pDst, pszWide, eax
    mov ecx, pDst
    add ecx, cb
    dec ecx
    mov [ecx], al
    ret
PutDString ENDP

; 12-byte timestamp from year/month/day/hour/minute/second
PutTimestamp PROC USES edi pDst:DWORD, year:DWORD, month:DWORD, day:DWORD, hour:DWORD, minute:DWORD, second:DWORD
    mov edi, pDst
    mov word ptr [edi], 1801h               ; type 1 (local), timezone unspecified (-2047)
    mov eax, year
    mov [edi + 2], ax
    mov eax, month
    mov [edi + 4], al
    mov eax, day
    mov [edi + 5], al
    mov eax, hour
    mov [edi + 6], al
    mov eax, minute
    mov [edi + 7], al
    mov eax, second
    mov [edi + 8], al
    mov byte ptr [edi + 9], 0
    mov byte ptr [edi + 10], 0
    mov byte ptr [edi + 11], 0
    ret
PutTimestamp ENDP

PutTimestampNow PROC pDst:DWORD
    movzx eax, g_udfTime.wSecond
    push eax
    movzx eax, g_udfTime.wMinute
    push eax
    movzx eax, g_udfTime.wHour
    push eax
    movzx eax, g_udfTime.wDay
    push eax
    movzx eax, g_udfTime.wMonth
    push eax
    movzx eax, g_udfTime.wYear
    push eax
    push pDst
    call PutTimestamp
    ret
PutTimestampNow ENDP

PutTimestampNode PROC USES esi pDst:DWORD, pNode:DWORD
    mov esi, pNode
    movzx eax, [esi].NODE.recDate[5]
    push eax
    movzx eax, [esi].NODE.recDate[4]
    push eax
    movzx eax, [esi].NODE.recDate[3]
    push eax
    movzx eax, [esi].NODE.recDate[2]
    push eax
    movzx eax, [esi].NODE.recDate[1]
    push eax
    movzx eax, [esi].NODE.recDate[0]
    add eax, 1900
    push eax
    push pDst
    call PutTimestamp
    ret
PutTimestampNode ENDP

; Domain identifier suffix: UDF revision 1.02, no flags
DomainSuffix PROC pDst:DWORD
    mov eax, pDst
    mov word ptr [eax], 0102h
    mov dword ptr [eax + 2], 0
    mov word ptr [eax + 6], 0
    ret
DomainSuffix ENDP

; Implementation identifier suffix: OS class 6 (Windows NT), OS id 0
ImplSuffix PROC pDst:DWORD
    mov eax, pDst
    mov dword ptr [eax], 6
    mov dword ptr [eax + 4], 0
    ret
ImplSuffix ENDP

; ---------------------------------------------------------------------------
; Layout
; ---------------------------------------------------------------------------
; FID byte length for a child: 38 + L_FI, padded to 4
FidLen PROC USES esi pNode:DWORD
    LOCAL buf[NODE_NAME_MAX * 2 + 4]:BYTE
    mov esi, pNode
    lea eax, [esi].NODE.szName
    invoke NameCompress, addr buf, eax, 255
    add eax, 38
    add eax, 3
    and eax, not 3
    ret
FidLen ENDP

; FID stream length of a directory: parent entry + children
DirFidBytes PROC USES esi pDir:DWORD
    LOCAL total:DWORD
    mov total, 40                           ; parent FID: 38 rounded to 4
    mov esi, pDir
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        invoke FidLen, esi
        add total, eax
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    mov eax, total
    ret
DirFidBytes ENDP

LayoutDir PROC USES esi pDir:DWORD
    mov esi, pDir
    invoke DirFidBytes, esi
    mov [esi].NODE.wUdfDirLen, eax
    mov ecx, g_lba
    mov [esi].NODE.wUdfDir, ecx
    invoke SectorsFor, eax
    add g_lba, eax
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        mov eax, g_lba
        mov [esi].NODE.wUdfFe, eax
        inc g_lba
        test [esi].NODE.nflags, NF_DIR
        .IF !ZERO?
            inc g_udfDirs
            invoke LayoutDir, esi
        .ELSE
            inc g_udfFiles
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    ret
LayoutDir ENDP

; g_lba == UDF_PART_START on entry: FSD, TD, root FE, then the tree
UdfLayout PROC
    invoke GetLocalTime, offset g_udfTime
    mov g_udfNextUid, 16
    mov g_udfFiles, 0
    mov g_udfDirs, 1
    mov eax, g_lba
    add eax, 2                              ; FSD at +0, TD at +1
    mov ecx, g_pRootNode
    mov [ecx].NODE.wUdfFe, eax
    inc eax
    mov g_lba, eax
    invoke LayoutDir, g_pRootNode
    ret
UdfLayout ENDP

; ---------------------------------------------------------------------------
; Emission
; ---------------------------------------------------------------------------
UdfEmitRecognition PROC USES edi
    invoke SecBegin
    mov edi, g_pSec
    lea eax, [edi + 1]
    invoke RtlMoveMemory, eax, offset szBEA01, 5
    mov byte ptr [edi + 6], 1
    invoke SecWrite
    invoke SecBegin
    mov edi, g_pSec
    lea eax, [edi + 1]
    invoke RtlMoveMemory, eax, offset szNSR02, 5
    mov byte ptr [edi + 6], 1
    invoke SecWrite
    invoke SecBegin
    mov edi, g_pSec
    lea eax, [edi + 1]
    invoke RtlMoveMemory, eax, offset szTEA01, 5
    mov byte ptr [edi + 6], 1
    invoke SecWrite
    ret
UdfEmitRecognition ENDP

PadTo PROC blk:DWORD
    .WHILE TRUE
        mov eax, g_lba
        .BREAK .IF eax >= blk
        invoke SecBegin
        invoke SecWrite
    .ENDW
    ret
PadTo ENDP

; The six descriptors of one volume descriptor sequence starting at block base
EmitVDS PROC USES esi edi base:DWORD
    LOCAL suffix[8]:BYTE
    LOCAL blk:DWORD

    mov esi, g_pRootNode
    mov eax, base
    mov blk, eax

    ; --- Primary Volume Descriptor ---
    invoke SecBegin
    mov edi, g_pSec
    mov dword ptr [edi + 16], 0             ; VDS number
    mov dword ptr [edi + 20], 0             ; PVD number
    lea eax, [esi].NODE.szName
    lea ecx, [edi + 24]
    invoke PutDString, ecx, 32, eax
    mov word ptr [edi + 56], 1              ; volume sequence number
    mov word ptr [edi + 58], 1
    mov word ptr [edi + 60], 2              ; interchange level
    mov word ptr [edi + 62], 2
    mov dword ptr [edi + 64], 1             ; character set list
    mov dword ptr [edi + 68], 1
    lea eax, [esi].NODE.szName
    lea ecx, [edi + 72]
    invoke PutDString, ecx, 128, eax        ; volume set identifier
    lea eax, [edi + 200]
    invoke PutCS0, eax
    lea eax, [edi + 264]
    invoke PutCS0, eax
    invoke ImplSuffix, addr suffix
    lea eax, [edi + 344]
    mov edx, eax
    invoke PutEntity, edx,offset szImplId, addr suffix     ; application identifier
    lea eax, [edi + 376]
    invoke PutTimestampNow, eax
    lea eax, [edi + 388]
    mov edx, eax
    invoke PutEntity, edx,offset szImplId, addr suffix
    invoke TagFinish, edi, 1, blk, 512
    invoke SecWrite
    inc blk

    ; --- Implementation Use Volume Descriptor ---
    invoke SecBegin
    mov edi, g_pSec
    mov dword ptr [edi + 16], 1
    invoke DomainSuffix, addr suffix
    lea eax, [edi + 20]
    mov edx, eax
    invoke PutEntity, edx,offset szLvInfoId, addr suffix
    lea eax, [edi + 52]
    invoke PutCS0, eax
    lea eax, [esi].NODE.szName
    lea ecx, [edi + 116]
    invoke PutDString, ecx, 128, eax
    invoke ImplSuffix, addr suffix
    lea eax, [edi + 352]
    mov edx, eax
    invoke PutEntity, edx,offset szImplId, addr suffix
    invoke TagFinish, edi, 4, blk, 512
    invoke SecWrite
    inc blk

    ; --- Partition Descriptor ---
    invoke SecBegin
    mov edi, g_pSec
    mov dword ptr [edi + 16], 2
    mov word ptr [edi + 20], 1              ; allocated
    mov word ptr [edi + 22], 0              ; partition number
    lea eax, [edi + 24]
    mov edx, eax
    invoke PutEntity, edx,offset szNsrContents, NULL
    mov dword ptr [edi + 184], 1            ; access type: read only
    mov dword ptr [edi + 188], UDF_PART_START
    mov eax, g_totalSectors
    sub eax, UDF_PART_START + 1             ; up to, not including, the closing anchor
    mov [edi + 192], eax
    invoke ImplSuffix, addr suffix
    lea eax, [edi + 196]
    mov edx, eax
    invoke PutEntity, edx,offset szImplId, addr suffix
    invoke TagFinish, edi, 5, blk, 512
    invoke SecWrite
    inc blk

    ; --- Logical Volume Descriptor ---
    invoke SecBegin
    mov edi, g_pSec
    mov dword ptr [edi + 16], 3
    lea eax, [edi + 20]
    invoke PutCS0, eax
    lea eax, [esi].NODE.szName
    lea ecx, [edi + 84]
    invoke PutDString, ecx, 128, eax
    mov dword ptr [edi + 212], ISO_SECTOR
    invoke DomainSuffix, addr suffix
    lea eax, [edi + 216]
    mov edx, eax
    invoke PutEntity, edx,offset szDomainId, addr suffix
    mov dword ptr [edi + 248], ISO_SECTOR   ; FSD long_ad: length
    mov dword ptr [edi + 252], 0            ; lbn 0
    mov word ptr [edi + 256], 0             ; partition 0
    mov dword ptr [edi + 264], 6            ; map table length
    mov dword ptr [edi + 268], 1            ; one partition map
    invoke ImplSuffix, addr suffix
    lea eax, [edi + 272]
    mov edx, eax
    invoke PutEntity, edx,offset szImplId, addr suffix
    mov dword ptr [edi + 432], 2 * ISO_SECTOR   ; integrity sequence extent
    mov dword ptr [edi + 436], LVID_BLOCK
    mov byte ptr [edi + 440], 1             ; type 1 map
    mov byte ptr [edi + 441], 6
    mov word ptr [edi + 442], 1             ; volume sequence number
    mov word ptr [edi + 444], 0             ; partition number
    invoke TagFinish, edi, 6, blk, 446
    invoke SecWrite
    inc blk

    ; --- Unallocated Space Descriptor ---
    invoke SecBegin
    mov edi, g_pSec
    mov dword ptr [edi + 16], 4
    mov dword ptr [edi + 20], 0
    invoke TagFinish, edi, 7, blk, 24
    invoke SecWrite
    inc blk

    ; --- Terminating Descriptor ---
    invoke SecBegin
    mov edi, g_pSec
    invoke TagFinish, edi, 8, blk, 512
    invoke SecWrite
    ret
EmitVDS ENDP

EmitAVDP PROC USES edi blk:DWORD
    invoke SecBegin
    mov edi, g_pSec
    mov dword ptr [edi + 16], 16 * ISO_SECTOR
    mov dword ptr [edi + 20], VDS_MAIN
    mov dword ptr [edi + 24], 16 * ISO_SECTOR
    mov dword ptr [edi + 28], VDS_RESERVE
    invoke TagFinish, edi, 2, blk, 512
    invoke SecWrite
    ret
EmitAVDP ENDP

UdfEmitPreamble PROC USES edi
    LOCAL suffix[8]:BYTE
    invoke PadTo, VDS_MAIN
    invoke EmitVDS, VDS_MAIN
    invoke PadTo, VDS_RESERVE
    invoke EmitVDS, VDS_RESERVE
    invoke PadTo, LVID_BLOCK

    ; --- Logical Volume Integrity Descriptor (closed) ---
    invoke SecBegin
    mov edi, g_pSec
    lea eax, [edi + 16]
    invoke PutTimestampNow, eax
    mov dword ptr [edi + 28], 1             ; integrity type: close
    mov eax, g_udfNextUid
    mov [edi + 40], eax                     ; next unique id (low)
    mov dword ptr [edi + 44], 0
    mov dword ptr [edi + 72], 1             ; partitions
    mov dword ptr [edi + 76], 46            ; implementation use length
    mov dword ptr [edi + 80], 0             ; free space
    mov eax, g_totalSectors
    sub eax, UDF_PART_START + 1
    mov [edi + 84], eax                     ; size table
    invoke ImplSuffix, addr suffix
    lea eax, [edi + 88]
    mov edx, eax
    invoke PutEntity, edx,offset szImplId, addr suffix
    mov eax, g_udfFiles
    mov [edi + 120], eax
    mov eax, g_udfDirs
    mov [edi + 124], eax
    mov word ptr [edi + 128], 0102h         ; minimum UDF read revision
    mov word ptr [edi + 130], 0102h         ; minimum write
    mov word ptr [edi + 132], 0102h         ; maximum write
    invoke TagFinish, edi, 9, LVID_BLOCK, 134
    invoke SecWrite
    invoke SecBegin
    mov edi, g_pSec
    invoke TagFinish, edi, 8, LVID_BLOCK + 1, 512
    invoke SecWrite

    invoke PadTo, AVDP_BLOCK
    invoke EmitAVDP, AVDP_BLOCK
    ret
UdfEmitPreamble ENDP

; File Entry for a node into the staging block and write it
EmitFE PROC USES esi edi ebx pNode:DWORD
    LOCAL suffix[8]:BYTE
    LOCAL lenLo:DWORD
    LOCAL lenHi:DWORD
    LOCAL lbn:DWORD
    LOCAL nAd:DWORD
    LOCAL linkCount:DWORD
    LOCAL sizeLo:DWORD
    LOCAL sizeHi:DWORD

    mov esi, pNode
    invoke SecBegin
    mov edi, g_pSec

    ; icbtag
    mov dword ptr [edi + 16], 0             ; prior recorded direct entries
    mov word ptr [edi + 20], 4              ; strategy type 4
    mov word ptr [edi + 22], 0
    mov word ptr [edi + 24], 1              ; max entries
    mov byte ptr [edi + 26], 0
    test [esi].NODE.nflags, NF_DIR
    .IF !ZERO?
        mov byte ptr [edi + 27], 4
    .ELSE
        mov byte ptr [edi + 27], 5
    .ENDIF
    mov dword ptr [edi + 28], 0             ; parent ICB
    mov word ptr [edi + 32], 0
    mov word ptr [edi + 34], 0              ; short allocation descriptors

    mov dword ptr [edi + 36], -1            ; uid
    mov dword ptr [edi + 40], -1            ; gid
    mov dword ptr [edi + 44], 14A5h         ; permissions: r-x for all
    test [esi].NODE.nflags, NF_DIR
    .IF !ZERO?
        ; link count: own FID + one parent FID per subdirectory (+1 self-parent for root)
        mov linkCount, 1
        .IF esi == g_pRootNode
            inc linkCount
        .ENDIF
        mov ebx, [esi].NODE.pFirstChild
        .WHILE ebx != 0
            test [ebx].NODE.nflags, NF_DIR
            .IF !ZERO?
                inc linkCount
            .ENDIF
            mov ebx, [ebx].NODE.pNextSibling
        .ENDW
        mov eax, [esi].NODE.wUdfDirLen
        mov sizeLo, eax
        mov sizeHi, 0
    .ELSE
        mov linkCount, 1
        mov eax, [esi].NODE.dataSize
        mov sizeLo, eax
        mov eax, [esi].NODE.dataSizeHi
        mov sizeHi, eax
    .ENDIF
    mov eax, linkCount
    mov [edi + 48], ax
    mov byte ptr [edi + 50], 0
    mov byte ptr [edi + 51], 0
    mov dword ptr [edi + 52], 0
    mov eax, sizeLo
    mov [edi + 56], eax                     ; information length
    mov eax, sizeHi
    mov [edi + 60], eax
    invoke SectorsFor64, sizeLo, sizeHi
    mov [edi + 64], eax                     ; logical blocks recorded
    mov dword ptr [edi + 68], 0
    lea eax, [edi + 72]
    invoke PutTimestampNode, eax, esi
    lea eax, [edi + 84]
    invoke PutTimestampNode, eax, esi
    lea eax, [edi + 96]
    invoke PutTimestampNode, eax, esi
    mov dword ptr [edi + 108], 1            ; checkpoint
    invoke ImplSuffix, addr suffix
    lea eax, [edi + 128]
    mov edx, eax
    invoke PutEntity, edx,offset szImplId, addr suffix
    .IF esi == g_pRootNode
        mov dword ptr [edi + 160], 0
    .ELSE
        mov eax, g_udfNextUid
        mov [edi + 160], eax
        inc g_udfNextUid
    .ENDIF
    mov dword ptr [edi + 164], 0
    mov dword ptr [edi + 168], 0            ; L_EA

    ; allocation descriptors
    lea ebx, [edi + 176]
    mov nAd, 0
    test [esi].NODE.nflags, NF_DIR
    .IF !ZERO?
        mov eax, [esi].NODE.wUdfDirLen
        mov [ebx], eax
        mov eax, [esi].NODE.wUdfDir
        sub eax, UDF_PART_START
        mov [ebx + 4], eax
        mov nAd, 1
    .ELSE
        mov eax, sizeLo
        mov lenLo, eax
        mov eax, sizeHi
        mov lenHi, eax
        mov eax, [esi].NODE.wExtent
        sub eax, UDF_PART_START
        mov lbn, eax
        .WHILE lenLo != 0 || lenHi != 0
            .BREAK .IF nAd >= 230
            mov eax, AD_MAX_EXTENT
            .IF lenHi == 0 && lenLo < AD_MAX_EXTENT
                mov eax, lenLo
            .ENDIF
            mov [ebx], eax
            mov ecx, lbn
            mov [ebx + 4], ecx
            sub lenLo, eax
            sbb lenHi, 0
            add eax, ISO_SECTOR - 1
            shr eax, 11
            add lbn, eax
            add ebx, 8
            inc nAd
        .ENDW
    .ENDIF
    mov eax, nAd
    shl eax, 3
    mov [edi + 172], eax                    ; L_AD
    add eax, 176
    mov ecx, [esi].NODE.wUdfFe
    sub ecx, UDF_PART_START
    invoke TagFinish, edi, 261, ecx, eax
    invoke SecWrite
    ret
EmitFE ENDP

; FID stream of a directory: parent entry then one entry per child; written as a byte stream
EmitFids PROC USES esi edi ebx pDir:DWORD
    LOCAL pBuf:DWORD
    LOCAL pos:DWORD
    LOCAL fid[300]:BYTE
    LOCAL nameLen:DWORD
    LOCAL total:DWORD
    LOCAL lbnBase:DWORD

    mov esi, pDir
    mov eax, [esi].NODE.wUdfDirLen
    mov total, eax
    invoke VfsAlloc, eax
    .IF eax == 0
        mov g_fail, TRUE
        ret
    .ENDIF
    mov pBuf, eax
    mov pos, 0
    mov eax, [esi].NODE.wUdfDir
    sub eax, UDF_PART_START
    mov lbnBase, eax

    ; parent
    invoke FillBytes, addr fid, 0, 40
    mov word ptr fid[16], 1                 ; file version number
    mov byte ptr fid[18], FID_PARENT_DIR
    mov byte ptr fid[19], 0
    mov dword ptr fid[20], ISO_SECTOR
    mov eax, [esi].NODE.pParent
    .IF eax == 0
        mov eax, esi
    .ENDIF
    mov eax, [eax].NODE.wUdfFe
    sub eax, UDF_PART_START
    mov dword ptr fid[24], eax
    mov word ptr fid[28], 0
    mov word ptr fid[36], 0
    mov eax, lbnBase
    invoke TagFinish, addr fid, 257, eax, 40
    mov edx, pBuf
    invoke RtlMoveMemory, edx, addr fid, 40
    mov pos, 40

    mov ebx, [esi].NODE.pFirstChild
    .WHILE ebx != 0
        invoke FillBytes, addr fid, 0, 300
        mov word ptr fid[16], 1
        mov byte ptr fid[18], 0
        test [ebx].NODE.nflags, NF_DIR
        .IF !ZERO?
            mov byte ptr fid[18], FID_DIR_FLAG
        .ENDIF
        mov dword ptr fid[20], ISO_SECTOR
        mov eax, [ebx].NODE.wUdfFe
        sub eax, UDF_PART_START
        mov dword ptr fid[24], eax
        mov word ptr fid[28], 0
        mov word ptr fid[36], 0
        lea eax, [ebx].NODE.szName
        invoke NameCompress, addr fid[38], eax, 255
        mov nameLen, eax
        mov byte ptr fid[19], al
        add eax, 38
        add eax, 3
        and eax, not 3
        push eax
        mov ecx, pos
        shr ecx, 11
        add ecx, lbnBase
        invoke TagFinish, addr fid, 257, ecx, eax
        pop eax
        mov ecx, pBuf
        add ecx, pos
        push eax
        invoke RtlMoveMemory, ecx, addr fid, eax
        pop eax
        add pos, eax
        mov ebx, [ebx].NODE.pNextSibling
    .ENDW

    invoke SecBegin
    invoke SecPutBytes, pBuf, total
    invoke SecFlush
    invoke VfsFreeMem, pBuf
    ret
EmitFids ENDP

EmitDirTree PROC USES esi pDir:DWORD
    mov esi, pDir
    invoke EmitFids, esi
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        invoke EmitFE, esi
        test [esi].NODE.nflags, NF_DIR
        .IF !ZERO?
            invoke EmitDirTree, esi
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    ret
EmitDirTree ENDP

UdfEmitPartition PROC USES esi edi
    LOCAL suffix[8]:BYTE
    mov esi, g_pRootNode

    ; --- File Set Descriptor (partition block 0) ---
    invoke SecBegin
    mov edi, g_pSec
    lea eax, [edi + 16]
    invoke PutTimestampNow, eax
    mov word ptr [edi + 28], 3              ; interchange level
    mov word ptr [edi + 30], 3
    mov dword ptr [edi + 32], 1             ; character set list
    mov dword ptr [edi + 36], 1
    mov dword ptr [edi + 40], 0             ; file set number
    mov dword ptr [edi + 44], 0
    lea eax, [edi + 48]
    invoke PutCS0, eax
    lea eax, [esi].NODE.szName
    lea ecx, [edi + 112]
    invoke PutDString, ecx, 128, eax        ; logical volume identifier
    lea eax, [edi + 240]
    invoke PutCS0, eax
    lea eax, [esi].NODE.szName
    lea ecx, [edi + 304]
    invoke PutDString, ecx, 32, eax         ; file set identifier
    mov dword ptr [edi + 400], ISO_SECTOR   ; root ICB
    mov eax, [esi].NODE.wUdfFe
    sub eax, UDF_PART_START
    mov [edi + 404], eax
    mov word ptr [edi + 408], 0
    invoke DomainSuffix, addr suffix
    lea eax, [edi + 416]
    mov edx, eax
    invoke PutEntity, edx,offset szDomainId, addr suffix
    invoke TagFinish, edi, 256, 0, 512
    invoke SecWrite

    ; --- Terminating Descriptor (partition block 1) ---
    invoke SecBegin
    mov edi, g_pSec
    invoke TagFinish, edi, 8, 1, 512
    invoke SecWrite

    ; --- root File Entry, then the tree ---
    invoke EmitFE, esi
    invoke EmitDirTree, esi
    ret
UdfEmitPartition ENDP

UdfEmitTrailer PROC
    invoke EmitAVDP, g_lba
    ret
UdfEmitTrailer ENDP

END
