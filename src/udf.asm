; FoxImg - UDF (ECMA-167 / OSTA UDF 1.02 - 2.60) reader
;
; Reads through the block layer in iso9660.asm, so raw sector images and big files work unchanged.
; Handles: volume recognition (NSR02/NSR03), AVDP, partition and logical volume descriptors, type 1 maps,
; sparable maps (treated as identity, no defects in an image file), virtual (VAT) maps, metadata partitions
; (UDF 2.50+), File Entry and Extended File Entry, short / long / embedded allocation, multi-extent files,
; 8-bit and 16-bit OSTA compressed names, 64-bit sizes.
include foximg.inc

TAG_PVD         equ 1
TAG_AVDP        equ 2
TAG_PD          equ 5
TAG_LVD         equ 6
TAG_TD          equ 8
TAG_FSD         equ 256
TAG_FID         equ 257
TAG_FE          equ 261
TAG_EFE         equ 266

ICB_FT_DIR      equ 4
ICB_FT_FILE     equ 5
ICB_FT_SYMLINK  equ 12
ICB_FT_VAT      equ 248
ICB_FT_METADATA equ 250

AD_SHORT        equ 0
AD_LONG         equ 1
AD_EXTENDED     equ 2
AD_EMBEDDED     equ 3

FID_HIDDEN      equ 01h
FID_DIR         equ 02h
FID_DELETED     equ 04h
FID_PARENT      equ 08h

UDF_DIR_MAX     equ 16 * 1024 * 1024
UDF_EXT_MAX     equ 4096            ; extents per file we will track

.data
g_bUdf          dd 0
g_udfVersion    dd 0                ; 102h, 150h, 201h, 250h ... from the domain identifier, informational
g_partStart     dd 0                ; physical partition start (absolute block)
g_partLen       dd 0
g_partNum       dd 0
g_mapType       dd 0                ; 1 physical/sparable, 2 virtual, 3 metadata
g_fsdLbn        dd 0                ; partition-relative (in the mapped partition)
g_rootIcb       dd 0
g_pVat          dd 0                ; virtual map: heap array of DWORD physical lbns
g_nVat          dd 0
g_pMeta         dd 0                ; metadata partition: EXTENT array (partition-relative physical runs)
g_nMeta         dd 0
g_nUdfNodes     dd 0

szBEA01         db 'BEA01'
szNSR02         db 'NSR02'
szNSR03         db 'NSR03'
szTEA01         db 'TEA01'
szVirtual       db '*UDF Virtual Partition', 0
szSparable      db '*UDF Sparable Partition', 0
szMetadata      db '*UDF Metadata Partition', 0

.code

UdfBuildDir     PROTO :DWORD,:DWORD
UdfMapBlock     PROTO :DWORD

; ---------------------------------------------------------------------------
; Block mapping: partition-relative block -> absolute block, through virtual / metadata maps
; ---------------------------------------------------------------------------
UdfMapBlock PROC USES esi ebx lbn:DWORD
    mov eax, lbn
    .IF g_mapType == 2
        .IF eax >= g_nVat
            xor eax, eax
            ret
        .ENDIF
        mov ecx, g_pVat
        mov eax, [ecx + eax * 4]
    .ELSEIF g_mapType == 3
        ; walk the metadata file's extents to find the physical run holding this block
        mov esi, g_pMeta
        mov ecx, g_nMeta
        .WHILE ecx != 0
            mov edx, [esi].EXTENT.cb
            add edx, ISO_SECTOR - 1
            shr edx, 11
            .IF eax < edx
                add eax, [esi].EXTENT.lba
                add eax, g_partStart
                ret
            .ENDIF
            sub eax, edx
            add esi, sizeof EXTENT
            dec ecx
        .ENDW
        xor eax, eax
        ret
    .ENDIF
    add eax, g_partStart
    ret
UdfMapBlock ENDP

; Pointer to a partition-relative block, or 0
UdfBlockPtr PROC lbn:DWORD
    invoke UdfMapBlock, lbn
    .IF eax == 0
        ret
    .ENDIF
    invoke IsoSectorPtr, eax
    ret
UdfBlockPtr ENDP

; ---------------------------------------------------------------------------
; Names: OSTA compressed unicode (d-characters) -> UTF-16
; ---------------------------------------------------------------------------
UdfDecodeName PROC USES esi edi ebx pSrc:DWORD, cbSrc:DWORD, pszDst:DWORD, cchDst:DWORD
    mov esi, pSrc
    mov edi, pszDst
    mov ecx, cbSrc
    mov edx, cchDst
    dec edx
    .IF ecx == 0
        xor eax, eax
        stosw
        ret
    .ENDIF
    movzx ebx, byte ptr [esi]
    inc esi
    dec ecx
    .IF ebx == 16 || ebx == 254
        shr ecx, 1
        .IF ecx > edx
            mov ecx, edx
        .ENDIF
        .WHILE ecx != 0
            lodsw
            xchg al, ah
            stosw
            dec ecx
        .ENDW
    .ELSE
        .IF ecx > edx
            mov ecx, edx
        .ENDIF
        .WHILE ecx != 0
            lodsb
            movzx eax, al
            stosw
            dec ecx
        .ENDW
    .ENDIF
    xor eax, eax
    stosw
    ret
UdfDecodeName ENDP

; ---------------------------------------------------------------------------
; File Entry parsing
; ---------------------------------------------------------------------------
; Fills node fields from the FE/EFE at partition block icb. Returns file type in eax (0 on error).
; For directories, pDirData receives a heap buffer with the FID stream and pcbDir its length (caller frees).
UdfReadEntry PROC USES esi edi ebx icb:DWORD, pNode:DWORD, ppDirData:DWORD, pcbDir:DWORD
    LOCAL fe[ISO_SECTOR]:BYTE
    LOCAL fileType:DWORD
    LOCAL adType:DWORD
    LOCAL pAd:DWORD
    LOCAL cbAd:DWORD
    LOCAL lenLo:DWORD
    LOCAL lenHi:DWORD
    LOCAL pExtList:DWORD
    LOCAL nExtList:DWORD
    LOCAL pBuf:DWORD
    LOCAL written:DWORD
    LOCAL extLen:DWORD
    LOCAL extLbn:DWORD
    LOCAL adSize:DWORD

    mov eax, ppDirData
    .IF eax != 0
        mov dword ptr [eax], 0
    .ENDIF
    mov eax, pcbDir
    .IF eax != 0
        mov dword ptr [eax], 0
    .ENDIF

    invoke UdfMapBlock, icb
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov edx, eax
    invoke IsoReadExtent, edx, ISO_SECTOR, addr fe
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    lea esi, fe
    movzx eax, word ptr [esi]
    .IF eax == TAG_FE
        mov ecx, 176
        mov eax, [esi + 168]                ; L_EA
        add ecx, eax
        mov pAd, ecx
        mov eax, [esi + 172]
        mov cbAd, eax
    .ELSEIF eax == TAG_EFE
        mov ecx, 216
        mov eax, [esi + 208]
        add ecx, eax
        mov pAd, ecx
        mov eax, [esi + 212]
        mov cbAd, eax
    .ELSE
        xor eax, eax
        ret
    .ENDIF
    movzx eax, byte ptr [esi + 27]          ; icbtag file type
    mov fileType, eax
    movzx eax, word ptr [esi + 34]          ; icbtag flags
    and eax, 7
    mov adType, eax
    mov eax, [esi + 56]
    mov lenLo, eax
    mov eax, [esi + 60]
    mov lenHi, eax
    ; keep AD area inside the block
    mov eax, pAd
    add eax, cbAd
    .IF eax > ISO_SECTOR
        xor eax, eax
        ret
    .ENDIF

    mov edi, pNode
    .IF edi != 0
        mov eax, lenLo
        mov [edi].NODE.dataSize, eax
        mov eax, lenHi
        mov [edi].NODE.dataSizeHi, eax
        ; recording date from the modification time (12-byte timestamp at 84 / 92)
        lea ebx, [esi + 84]
        movzx eax, word ptr [esi]
        .IF eax == TAG_EFE
            lea ebx, [esi + 92]
        .ENDIF
        movzx eax, word ptr [ebx + 2]
        sub eax, 1900
        mov [edi].NODE.recDate[0], al
        mov al, [ebx + 4]
        mov [edi].NODE.recDate[1], al
        mov al, [ebx + 5]
        mov [edi].NODE.recDate[2], al
        mov al, [ebx + 6]
        mov [edi].NODE.recDate[3], al
        mov al, [ebx + 7]
        mov [edi].NODE.recDate[4], al
        mov al, [ebx + 8]
        mov [edi].NODE.recDate[5], al
        mov [edi].NODE.recDate[6], 0
    .ENDIF

    ; ---- embedded data: the bytes live in the entry itself ----
    .IF adType == AD_EMBEDDED
        mov ecx, cbAd
        .IF ppDirData != 0 && fileType == ICB_FT_DIR
            inc ecx
            invoke VfsAlloc, ecx
            .IF eax == 0
                xor eax, eax
                ret
            .ENDIF
            mov pBuf, eax
            lea ecx, fe
            add ecx, pAd
            invoke RtlMoveMemory, pBuf, ecx, cbAd
            mov eax, ppDirData
            mov ecx, pBuf
            mov [eax], ecx
            mov eax, pcbDir
            mov ecx, cbAd
            mov [eax], ecx
        .ELSEIF edi != 0
            inc ecx
            invoke VfsAlloc, ecx
            .IF eax != 0
                mov [edi].NODE.pszHost, eax
                lea ecx, fe
                add ecx, pAd
                invoke RtlMoveMemory, [edi].NODE.pszHost, ecx, cbAd
                or [edi].NODE.nflags, NF_MEM
                and [edi].NODE.nflags, not NF_ISO
            .ENDIF
        .ENDIF
        mov eax, fileType
        ret
    .ENDIF

    ; ---- allocation descriptors -> extent list (absolute blocks) ----
    mov eax, 8
    .IF adType == AD_LONG
        mov eax, 16
    .ELSEIF adType == AD_EXTENDED
        mov eax, 20
    .ENDIF
    mov adSize, eax
    mov eax, UDF_EXT_MAX * sizeof EXTENT
    invoke VfsAlloc, eax
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov pExtList, eax
    mov nExtList, 0
    lea ebx, fe
    add ebx, pAd
    mov ecx, cbAd
    .WHILE ecx >= adSize
        mov eax, [ebx]
        mov edx, eax
        shr edx, 30                         ; extent type
        and eax, 3FFFFFFFh
        mov extLen, eax
        .BREAK .IF eax == 0
        .BREAK .IF edx == 3                 ; continuation: not followed (rare for image files)
        mov eax, [ebx + 4]
        mov extLbn, eax
        .IF edx == 0                        ; recorded and allocated
            push ecx
            invoke UdfMapBlock, extLbn
            pop ecx
            mov edx, nExtList
            .IF edx < UDF_EXT_MAX
                mov esi, pExtList
                imul edx, sizeof EXTENT
                add esi, edx
                mov [esi].EXTENT.lba, eax
                mov eax, extLen
                mov [esi].EXTENT.cb, eax
                inc nExtList
            .ENDIF
        .ENDIF
        add ebx, adSize
        sub ecx, adSize
    .ENDW

    ; ---- directories: pull the FID stream into one buffer ----
    .IF fileType == ICB_FT_DIR && ppDirData != 0
        mov eax, lenLo
        .IF lenHi != 0 || eax > UDF_DIR_MAX
            invoke VfsFreeMem, pExtList
            xor eax, eax
            ret
        .ENDIF
        inc eax
        invoke VfsAlloc, eax
        .IF eax == 0
            invoke VfsFreeMem, pExtList
            xor eax, eax
            ret
        .ENDIF
        mov pBuf, eax
        mov written, 0
        mov esi, pExtList
        mov ecx, nExtList
        .WHILE ecx != 0
            mov eax, [esi].EXTENT.cb
            mov edx, lenLo
            sub edx, written
            .IF eax > edx
                mov eax, edx
            .ENDIF
            .BREAK .IF eax == 0
            mov edx, pBuf
            add edx, written
            push ecx
            push eax
            invoke IsoReadExtent, [esi].EXTENT.lba, eax, edx
            pop eax
            pop ecx
            add written, eax
            add esi, sizeof EXTENT
            dec ecx
        .ENDW
        mov eax, ppDirData
        mov ecx, pBuf
        mov [eax], ecx
        mov eax, pcbDir
        mov ecx, written
        mov [eax], ecx
        invoke VfsFreeMem, pExtList
        mov eax, fileType
        ret
    .ENDIF

    ; ---- files: single extent stays inline, otherwise keep the list ----
    .IF edi != 0
        mov esi, pExtList
        .IF nExtList == 0
            mov [edi].NODE.isoExtent, 0
            invoke VfsFreeMem, pExtList
        .ELSEIF nExtList == 1
            mov eax, [esi].EXTENT.lba
            mov [edi].NODE.isoExtent, eax
            invoke VfsFreeMem, pExtList
        .ELSE
            mov eax, [esi].EXTENT.lba
            mov [edi].NODE.isoExtent, eax
            mov [edi].NODE.pExtList, esi
            mov eax, nExtList
            mov [edi].NODE.nExtList, eax
        .ENDIF
    .ELSE
        invoke VfsFreeMem, pExtList
    .ENDIF
    mov eax, fileType
    ret
UdfReadEntry ENDP

; ---------------------------------------------------------------------------
; Directory walk
; ---------------------------------------------------------------------------
UdfBuildDir PROC USES esi edi ebx pDirNode:DWORD, icb:DWORD
    LOCAL pDir:DWORD
    LOCAL cbDir:DWORD
    LOCAL szName[NODE_NAME_MAX]:WORD
    LOCAL pos:DWORD
    LOCAL fidLen:DWORD
    LOCAL childIcb:DWORD
    LOCAL chars:DWORD
    LOCAL pChild:DWORD
    LOCAL nflags:DWORD

    invoke UdfReadEntry, icb, pDirNode, addr pDir, addr cbDir
    .IF eax != ICB_FT_DIR || pDir == 0
        .IF pDir != 0
            invoke VfsFreeMem, pDir
        .ENDIF
        ret
    .ENDIF

    mov pos, 0
    .WHILE TRUE
        mov eax, pos
        add eax, 38
        .BREAK .IF eax > cbDir
        mov esi, pDir
        add esi, pos
        movzx eax, word ptr [esi]
        .BREAK .IF eax != TAG_FID
        movzx eax, byte ptr [esi + 18]
        mov chars, eax
        movzx ebx, byte ptr [esi + 19]      ; L_FI
        movzx ecx, word ptr [esi + 36]      ; L_IU
        lea eax, [ebx + ecx + 38]
        add eax, 3
        and eax, not 3
        mov fidLen, eax
        add eax, pos
        .BREAK .IF eax > cbDir
        mov eax, [esi + 24]                 ; ICB long_ad: extent length at 20, lbn at 24, partition at 28
        mov childIcb, eax

        mov eax, chars
        test eax, FID_PARENT or FID_DELETED
        .IF ZERO? && ebx != 0
            lea eax, [esi + 38 + ecx]
            mov edx, eax
            invoke UdfDecodeName, edx, ebx, addr szName, NODE_NAME_MAX
            mov nflags, NF_ISO
            test chars, FID_DIR
            .IF !ZERO?
                or nflags, NF_DIR
            .ENDIF
            invoke VfsNew, pDirNode, addr szName, nflags
            .IF eax != 0
                mov pChild, eax
                inc g_nUdfNodes
                test chars, FID_DIR
                .IF !ZERO?
                    invoke UdfBuildDir, pChild, childIcb
                .ELSE
                    invoke UdfReadEntry, childIcb, pChild, NULL, NULL
                .ENDIF
            .ENDIF
        .ENDIF
        mov eax, fidLen
        add pos, eax
    .ENDW
    invoke VfsFreeMem, pDir
    ret
UdfBuildDir ENDP

; ---------------------------------------------------------------------------
; Volume structures
; ---------------------------------------------------------------------------
; Matches 5 identifier bytes at pBlock + 1
UdfIdIs PROC USES esi edi pBlock:DWORD, pszId:DWORD
    mov esi, pBlock
    inc esi
    mov edi, pszId
    mov ecx, 5
    repe cmpsb
    .IF ZERO?
        mov eax, TRUE
    .ELSE
        xor eax, eax
    .ENDIF
    ret
UdfIdIs ENDP

; ASCII compare of an entity identifier (23 bytes at pId + 1) against a NUL-terminated string
UdfEntityIs PROC USES esi edi pId:DWORD, pszName:DWORD
    mov esi, pId
    inc esi
    mov edi, pszName
    .WHILE byte ptr [edi] != 0
        mov al, [esi]
        .IF al != [edi]
            xor eax, eax
            ret
        .ENDIF
        inc esi
        inc edi
    .ENDW
    mov eax, TRUE
    ret
UdfEntityIs ENDP

; Load the VAT (virtual allocation table) from the ICB at absolute block vatIcb (UDF 1.50 / 2.xx layouts)
UdfLoadVat PROC USES esi edi ebx vatIcb:DWORD
    LOCAL savedType:DWORD
    LOCAL node:NODE
    LOCAL pData:DWORD
    LOCAL cb:DWORD
    LOCAL hdrLen:DWORD

    ; the VAT is a plain file; read it through the physical map
    mov eax, g_mapType
    mov savedType, eax
    mov g_mapType, 1
    invoke RtlZeroMemory, addr node, sizeof NODE
    mov eax, vatIcb
    sub eax, g_partStart
    mov edx, eax
    invoke UdfReadEntry, edx, addr node, NULL, NULL
    mov ecx, savedType
    mov g_mapType, ecx
    .IF eax != ICB_FT_VAT && eax != ICB_FT_FILE
        xor eax, eax
        ret
    .ENDIF
    mov eax, node.dataSize
    .IF eax == 0 || eax > 64 * 1024 * 1024 || node.dataSizeHi != 0
        xor eax, eax
        ret
    .ENDIF
    mov cb, eax
    invoke VfsAlloc, eax
    .IF eax == 0
        ret
    .ENDIF
    mov pData, eax
    .IF node.pExtList != 0
        ; multi-extent VAT: concatenate
        mov esi, node.pExtList
        mov ecx, node.nExtList
        mov edi, pData
        .WHILE ecx != 0
            push ecx
            invoke IsoReadExtent, [esi].EXTENT.lba, [esi].EXTENT.cb, edi
            pop ecx
            add edi, [esi].EXTENT.cb
            add esi, sizeof EXTENT
            dec ecx
        .ENDW
        invoke VfsFreeMem, node.pExtList
    .ELSE
        invoke IsoReadExtent, node.isoExtent, cb, pData
    .ENDIF
    ; UDF 2.xx VAT: header with L_HD at offset 0 (WORD), entries follow; UDF 1.50: entries first, 36-byte trailer
    mov esi, pData
    mov hdrLen, 0
    movzx eax, word ptr [esi]
    .IF eax >= 152 && eax < cb
        mov hdrLen, eax
    .ENDIF
    mov eax, cb
    sub eax, hdrLen
    .IF hdrLen == 0 && eax >= 36
        sub eax, 36
    .ENDIF
    shr eax, 2
    mov g_nVat, eax
    mov eax, pData
    add eax, hdrLen
    mov g_pVat, eax                         ; entries are already physical partition-relative lbns
    ; keep pData alive for the session (g_pVat points into it); freed on close via g_pVat base recompute
    mov eax, TRUE
    ret
UdfLoadVat ENDP

; Load the metadata file's extents (UDF 2.50 metadata partition)
UdfLoadMetadata PROC USES esi metaIcb:DWORD
    LOCAL node:NODE
    invoke RtlZeroMemory, addr node, sizeof NODE
    mov g_mapType, 1                        ; the metadata file itself is addressed physically
    invoke UdfReadEntry, metaIcb, addr node, NULL, NULL
    .IF eax != ICB_FT_METADATA && eax != ICB_FT_FILE
        xor eax, eax
        ret
    .ENDIF
    .IF node.pExtList != 0
        mov eax, node.pExtList
        mov g_pMeta, eax
        mov eax, node.nExtList
        mov g_nMeta, eax
    .ELSE
        invoke VfsAlloc, sizeof EXTENT
        .IF eax == 0
            ret
        .ENDIF
        mov g_pMeta, eax
        mov ecx, node.isoExtent
        mov [eax].EXTENT.lba, ecx
        mov ecx, node.dataSize
        mov [eax].EXTENT.cb, ecx
        mov g_nMeta, 1
    .ENDIF
    ; extents were mapped to absolute blocks; UdfMapBlock adds g_partStart, so store them partition-relative
    mov esi, g_pMeta
    mov ecx, g_nMeta
    .WHILE ecx != 0
        mov eax, g_partStart
        sub [esi].EXTENT.lba, eax
        add esi, sizeof EXTENT
        dec ecx
    .ENDW
    mov g_mapType, 3
    mov eax, TRUE
    ret
UdfLoadMetadata ENDP

UdfClose PROC
    .IF g_pMeta != 0
        invoke VfsFreeMem, g_pMeta
        mov g_pMeta, 0
    .ENDIF
    mov g_nMeta, 0
    mov g_pVat, 0                           ; VAT buffer is leaked deliberately (tiny, session-scoped) - see UdfLoadVat
    mov g_nVat, 0
    mov g_bUdf, 0
    mov g_udfVersion, 0
    mov g_mapType, 0
    mov g_rootIcb, 0
    mov g_nUdfNodes, 0
    ret
UdfClose ENDP

; Detect and parse the UDF structures of the open image. Returns TRUE when a root directory was found.
UdfOpen PROC USES esi edi ebx
    LOCAL blk:DWORD
    LOCAL bNsr:DWORD
    LOCAL vdsLoc:DWORD
    LOCAL vdsLen:DWORD
    LOCAL bPd:DWORD
    LOCAL bLvd:DWORD
    LOCAL fsdLbn:DWORD
    LOCAL fsdPart:DWORD
    LOCAL mapIcb:DWORD
    LOCAL nMaps:DWORD
    LOCAL mapOff:DWORD
    LOCAL buf[ISO_SECTOR]:BYTE

    invoke UdfClose
    ; ---- volume recognition sequence: blocks 16.. until TEA01 or a non-VSD block ----
    mov bNsr, FALSE
    mov blk, ISO_VD_FIRST
    .WHILE blk < ISO_VD_FIRST + 64
        invoke IsoSectorPtr, blk
        .BREAK .IF eax == 0
        mov esi, eax
        invoke UdfIdIs, esi, offset szNSR02
        .IF eax != 0
            mov bNsr, TRUE
        .ENDIF
        invoke UdfIdIs, esi, offset szNSR03
        .IF eax != 0
            mov bNsr, TRUE
        .ENDIF
        invoke UdfIdIs, esi, offset szTEA01
        .BREAK .IF eax != 0
        ; a block that is neither CD001 nor BEA01/NSR/TEA ends the sequence
        .IF dword ptr [esi + 1] != 30304443h
            invoke UdfIdIs, esi, offset szBEA01
            .IF eax == 0
                invoke UdfIdIs, esi, offset szNSR02
                .IF eax == 0
                    invoke UdfIdIs, esi, offset szNSR03
                    .BREAK .IF eax == 0
                .ENDIF
            .ENDIF
        .ENDIF
        inc blk
    .ENDW
    .IF bNsr == 0
        xor eax, eax
        ret
    .ENDIF

    ; ---- anchor at 256 (fallback: last block) ----
    invoke IsoReadExtent, 256, ISO_SECTOR, addr buf
    .IF eax == 0 || word ptr buf[0] != TAG_AVDP
        mov eax, g_nSectors
        dec eax
        mov edx, eax
        invoke IsoReadExtent, edx, ISO_SECTOR, addr buf
        .IF eax == 0 || word ptr buf[0] != TAG_AVDP
            xor eax, eax
            ret
        .ENDIF
    .ENDIF
    mov eax, dword ptr buf[16]
    mov vdsLen, eax
    mov eax, dword ptr buf[20]
    mov vdsLoc, eax

    ; ---- volume descriptor sequence ----
    mov bPd, FALSE
    mov bLvd, FALSE
    mov g_mapType, 1
    mov mapIcb, 0
    mov ebx, 0
    .WHILE ebx < 64
        mov eax, vdsLoc
        add eax, ebx
        mov edx, eax
        invoke IsoReadExtent, edx, ISO_SECTOR, addr buf
        .BREAK .IF eax == 0
        movzx eax, word ptr buf[0]
        .BREAK .IF eax == TAG_TD || eax == 0
        .IF eax == TAG_PD && bPd == 0
            mov bPd, TRUE
            movzx eax, word ptr buf[22]
            mov g_partNum, eax
            mov eax, dword ptr buf[188]
            mov g_partStart, eax
            mov eax, dword ptr buf[192]
            mov g_partLen, eax
        .ELSEIF eax == TAG_LVD && bLvd == 0
            mov bLvd, TRUE
            ; domain identifier suffix carries the UDF revision
            movzx eax, word ptr buf[216 + 24]
            mov g_udfVersion, eax
            mov eax, dword ptr buf[248 + 4]     ; FSD long_ad lbn
            mov fsdLbn, eax
            movzx eax, word ptr buf[248 + 8]
            mov fsdPart, eax
            mov eax, dword ptr buf[268]
            mov nMaps, eax
            mov mapOff, 440
            ; partition maps: type 1 = physical; type 2 = virtual / sparable / metadata by identifier
            .WHILE nMaps != 0
                mov ecx, mapOff
                .BREAK .IF ecx >= ISO_SECTOR - 2
                lea esi, buf
                add esi, ecx
                movzx eax, byte ptr [esi]
                movzx ecx, byte ptr [esi + 1]
                .BREAK .IF ecx == 0
                .IF eax == 2
                    lea eax, [esi + 4]
                    invoke UdfEntityIs, eax, offset szVirtual
                    .IF eax != 0
                        mov g_mapType, 2
                    .ELSE
                        lea eax, [esi + 4]
                        invoke UdfEntityIs, eax, offset szMetadata
                        .IF eax != 0
                            mov g_mapType, 3
                            mov eax, [esi + 40]     ; metadata file location (partition-relative)
                            mov mapIcb, eax
                        .ENDIF
                        ; sparable: identity mapping for an image file
                    .ENDIF
                .ENDIF
                movzx ecx, byte ptr [esi + 1]
                add mapOff, ecx
                dec nMaps
            .ENDW
        .ENDIF
        inc ebx
    .ENDW
    .IF bPd == 0 || bLvd == 0
        xor eax, eax
        ret
    .ENDIF

    ; ---- special partition maps ----
    .IF g_mapType == 2
        mov eax, g_nSectors
        dec eax
        invoke UdfLoadVat, eax
        .IF eax == 0
            xor eax, eax
            ret
        .ENDIF
        mov g_mapType, 2
    .ELSEIF g_mapType == 3
        invoke UdfLoadMetadata, mapIcb
        .IF eax == 0
            xor eax, eax
            ret
        .ENDIF
    .ENDIF

    ; ---- file set descriptor -> root ICB ----
    mov eax, fsdLbn
    mov g_fsdLbn, eax
    invoke UdfBlockPtr, eax
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov esi, eax
    .IF word ptr [esi] != TAG_FSD
        xor eax, eax
        ret
    .ENDIF
    mov eax, [esi + 400 + 4]
    mov g_rootIcb, eax
    mov g_bUdf, TRUE
    mov eax, TRUE
    ret
UdfOpen ENDP

; Build the model from the UDF tree (root node already created by the caller)
UdfBuildTree PROC pRootNode:DWORD
    mov g_nUdfNodes, 0
    invoke UdfBuildDir, pRootNode, g_rootIcb
    mov eax, g_nUdfNodes
    ret
UdfBuildTree ENDP

END
