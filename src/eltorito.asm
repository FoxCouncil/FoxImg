; FoxImg - El Torito boot catalog: parse, preserve, edit, write, and patch isolinux/GRUB boot info tables
include foximg.inc

ET_SIG_LEN      equ 23
INFOTABLE_MAX   equ 16 * 1024 * 1024

.data
g_bootCount     dd 0
g_bootWCatalog  dd 0
g_bootEntries   BOOTENTRY BOOT_MAX dup(<>)
g_bootIdString  db 24 dup(0)
szElTorito      db 'EL TORITO SPECIFICATION', 0

WSTR szNotBootable, <Not bootable>
WSTR szBootPrefix, <Boot: >
WSTR szBiosTag, <BIOS>
WSTR szEfiTag, <UEFI>
WSTR szPpcTag, <PPC>
WSTR szMacTag, <Mac>
WSTR szOtherTag, <Other>
WSTR szHidden, <hidden image>
WSTR szSep, <, >
szEntryFmt      dw '%','s',' ','(','%','s',')',0
WSTR szIsolinux, <isolinux.bin>
WSTR szEltoritoImg, <eltorito.img>
WSTR szEltoritoBin, <eltorito.bin>

.code

; ---------------------------------------------------------------------------
; Parsing the open image
; ---------------------------------------------------------------------------
BootAddEntry PROC USES esi edi platform:DWORD, pEntry:DWORD
    LOCAL hdr[64]:BYTE
    LOCAL pNode:DWORD
    LOCAL rba:DWORD

    .IF g_bootCount >= BOOT_MAX
        ret
    .ENDIF
    mov esi, pEntry
    .IF byte ptr [esi] != 88h
        ret
    .ENDIF
    mov eax, g_bootCount
    imul eax, sizeof BOOTENTRY
    lea edi, g_bootEntries
    add edi, eax
    inc g_bootCount

    mov eax, platform
    mov [edi].BOOTENTRY.platform, eax
    movzx eax, byte ptr [esi + 1]
    and eax, 0Fh
    mov [edi].BOOTENTRY.media, eax
    movzx eax, word ptr [esi + 2]
    mov [edi].BOOTENTRY.loadSeg, eax
    movzx eax, byte ptr [esi + 4]
    mov [edi].BOOTENTRY.sysType, eax
    movzx eax, word ptr [esi + 6]
    mov [edi].BOOTENTRY.sectors, eax
    mov eax, [esi + 8]
    mov rba, eax
    mov [edi].BOOTENTRY.bInfoTable, 0

    invoke VfsFindByExtent, g_pRootNode, rba
    mov pNode, eax
    mov [edi].BOOTENTRY.pNode, eax
    .IF eax != 0
        ; boot info table present when the file carries its own current LBA and length at offsets 12 / 16
        mov ecx, [eax].NODE.dataSize
        .IF ecx >= 64
            invoke IsoReadExtent, rba, 64, addr hdr
            .IF eax != 0
                mov eax, dword ptr hdr[12]
                mov ecx, dword ptr hdr[16]
                mov edx, pNode
                .IF eax == rba && ecx == [edx].NODE.dataSize
                    mov [edi].BOOTENTRY.bInfoTable, TRUE
                .ENDIF
            .ENDIF
        .ENDIF
    .ELSE
        mov [edi].BOOTENTRY.blobExtent, eax
        mov eax, rba
        mov [edi].BOOTENTRY.blobExtent, eax
        mov eax, [edi].BOOTENTRY.sectors
        shl eax, 9
        .IF eax == 0
            mov eax, ISO_SECTOR
        .ENDIF
        mov [edi].BOOTENTRY.blobSize, eax
    .ENDIF
    ret
BootAddEntry ENDP

BootParse PROC USES esi edi ebx
    LOCAL catLba:DWORD
    LOCAL platform:DWORD
    LOCAL catalog[ISO_SECTOR]:BYTE

    mov g_bootCount, 0
    mov catLba, 0

    ; Boot Record Volume Descriptor: type 0 with the El Torito signature at offset 7
    mov ebx, ISO_VD_FIRST
    .WHILE ebx < ISO_VD_FIRST + 64
        invoke IsoSectorPtr, ebx
        .BREAK .IF eax == 0
        mov esi, eax
        .BREAK .IF dword ptr [esi + 1] != 30304443h
        .BREAK .IF byte ptr [esi] == ISO_VD_TERMINATOR
        .IF byte ptr [esi] == ISO_VD_BOOT
            xor edx, edx
sig_loop:
            cmp edx, ET_SIG_LEN
            jae sig_done
            mov al, byte ptr [esi + 7 + edx]
            cmp al, byte ptr [szElTorito + edx]
            jne sig_done
            inc edx
            jmp sig_loop
sig_done:
            .IF edx == ET_SIG_LEN
                mov eax, [esi + 71]
                mov catLba, eax
                .BREAK
            .ENDIF
        .ENDIF
        inc ebx
    .ENDW
    .IF catLba == 0
        ret
    .ENDIF

    ; work on a copy: BootAddEntry reads other blocks, which can move the mapping window
    invoke IsoReadExtent, catLba, ISO_SECTOR, addr catalog
    .IF eax == 0
        ret
    .ENDIF
    lea esi, catalog
    ; validation entry
    .IF byte ptr [esi] != 1 || byte ptr [esi + 30] != 55h || byte ptr [esi + 31] != 0AAh
        ret
    .ENDIF
    movzx eax, byte ptr [esi + 1]
    mov platform, eax
    lea eax, [esi + 4]
    invoke RtlMoveMemory, offset g_bootIdString, eax, 24

    ; initial/default entry
    lea eax, [esi + 32]
    invoke BootAddEntry, platform, eax

    ; section headers + entries
    lea ebx, [esi + 64]
    lea edi, [esi + ISO_SECTOR]
    .WHILE ebx < edi
        movzx eax, byte ptr [ebx]
        .BREAK .IF eax != 90h && eax != 91h
        movzx ecx, byte ptr [ebx + 1]
        mov platform, ecx
        movzx ecx, word ptr [ebx + 2]
        push eax
        add ebx, 32
        .WHILE ecx != 0 && ebx < edi
            .IF byte ptr [ebx] == 88h || byte ptr [ebx] == 0
                push ecx
                invoke BootAddEntry, platform, ebx
                pop ecx
                dec ecx
            .ENDIF
            add ebx, 32
        .ENDW
        pop eax
        .BREAK .IF eax == 91h
    .ENDW
    ret
BootParse ENDP

BootClear PROC
    mov g_bootCount, 0
    mov g_bModified, TRUE
    ret
BootClear ENDP

; A node being deleted must not stay referenced
BootForgetNode PROC USES esi ebx pNode:DWORD
    xor ebx, ebx
    .WHILE ebx < g_bootCount
        mov eax, ebx
        imul eax, sizeof BOOTENTRY
        lea esi, g_bootEntries
        add esi, eax
        mov eax, [esi].BOOTENTRY.pNode
        .IF eax == pNode
            ; drop the entry by shifting the tail down
            mov ecx, g_bootCount
            dec ecx
            sub ecx, ebx
            .IF ecx != 0
                imul ecx, sizeof BOOTENTRY
                lea eax, [esi + sizeof BOOTENTRY]
                invoke RtlMoveMemory, esi, eax, ecx
            .ENDIF
            dec g_bootCount
            .CONTINUE
        .ENDIF
        inc ebx
    .ENDW
    ret
BootForgetNode ENDP

; ---------------------------------------------------------------------------
; Editing
; ---------------------------------------------------------------------------
BootSetEntry PROC USES esi edi ebx pNode:DWORD, platform:DWORD
    mov esi, pNode
    .IF esi == 0
        xor eax, eax
        ret
    .ENDIF
    test [esi].NODE.nflags, NF_DIR
    .IF !ZERO?
        xor eax, eax
        ret
    .ENDIF

    ; replace an existing entry for this platform, else append
    xor ebx, ebx
    mov edi, 0
    .WHILE ebx < g_bootCount
        mov eax, ebx
        imul eax, sizeof BOOTENTRY
        lea ecx, g_bootEntries
        add ecx, eax
        mov eax, [ecx].BOOTENTRY.platform
        .IF eax == platform
            mov edi, ecx
            .BREAK
        .ENDIF
        inc ebx
    .ENDW
    .IF edi == 0
        .IF g_bootCount >= BOOT_MAX
            xor eax, eax
            ret
        .ENDIF
        mov eax, g_bootCount
        imul eax, sizeof BOOTENTRY
        lea edi, g_bootEntries
        add edi, eax
        inc g_bootCount
    .ENDIF

    mov eax, platform
    mov [edi].BOOTENTRY.platform, eax
    mov [edi].BOOTENTRY.media, 0
    mov [edi].BOOTENTRY.loadSeg, 0
    mov [edi].BOOTENTRY.sysType, 0
    mov [edi].BOOTENTRY.pNode, esi
    mov [edi].BOOTENTRY.blobExtent, 0
    mov [edi].BOOTENTRY.blobSize, 0
    mov [edi].BOOTENTRY.bInfoTable, 0
    .IF platform == BOOT_PLATFORM_EFI
        mov eax, [esi].NODE.dataSize
        add eax, 511
        shr eax, 9
        .IF eax > 0FFFFh
            mov eax, 0FFFFh
        .ENDIF
        mov [edi].BOOTENTRY.sectors, eax
    .ELSE
        mov [edi].BOOTENTRY.sectors, 4
        lea eax, [esi].NODE.szName
        invoke lstrcmpiW, eax, offset szIsolinux
        .IF eax == 0
            mov [edi].BOOTENTRY.bInfoTable, TRUE
        .ENDIF
        lea eax, [esi].NODE.szName
        invoke lstrcmpiW, eax, offset szEltoritoImg
        .IF eax == 0
            mov [edi].BOOTENTRY.bInfoTable, TRUE
        .ENDIF
        lea eax, [esi].NODE.szName
        invoke lstrcmpiW, eax, offset szEltoritoBin
        .IF eax == 0
            mov [edi].BOOTENTRY.bInfoTable, TRUE
        .ENDIF
    .ENDIF
    mov g_bModified, TRUE
    mov eax, TRUE
    ret
BootSetEntry ENDP

; ---------------------------------------------------------------------------
; Status text
; ---------------------------------------------------------------------------
BootSummary PROC USES esi edi ebx pszBuf:DWORD
    LOCAL szItem[300]:WORD
    .IF g_bootCount == 0
        invoke lstrcpyW, pszBuf, offset szNotBootable
        ret
    .ENDIF
    invoke lstrcpyW, pszBuf, offset szBootPrefix
    xor ebx, ebx
    .WHILE ebx < g_bootCount
        mov eax, ebx
        imul eax, sizeof BOOTENTRY
        lea esi, g_bootEntries
        add esi, eax
        .IF ebx != 0
            invoke lstrcatW, pszBuf, offset szSep
        .ENDIF
        mov eax, [esi].BOOTENTRY.platform
        mov ecx, offset szOtherTag
        .IF eax == BOOT_PLATFORM_X86
            mov ecx, offset szBiosTag
        .ELSEIF eax == BOOT_PLATFORM_EFI
            mov ecx, offset szEfiTag
        .ELSEIF eax == 1
            mov ecx, offset szPpcTag
        .ELSEIF eax == 2
            mov ecx, offset szMacTag
        .ENDIF
        mov edx, offset szHidden
        mov eax, [esi].BOOTENTRY.pNode
        .IF eax != 0
            lea edx, [eax].NODE.szName
        .ENDIF
        invoke wsprintfW, addr szItem, offset szEntryFmt, ecx, edx
        invoke lstrcatW, pszBuf, addr szItem
        inc ebx
    .ENDW
    ret
BootSummary ENDP

; ---------------------------------------------------------------------------
; Writing
; ---------------------------------------------------------------------------
BootBuildBRVD PROC USES edi pSector:DWORD
    mov edi, pSector
    mov byte ptr [edi], ISO_VD_BOOT
    mov byte ptr [edi + 1], 'C'
    mov byte ptr [edi + 2], 'D'
    mov byte ptr [edi + 3], '0'
    mov byte ptr [edi + 4], '0'
    mov byte ptr [edi + 5], '1'
    mov byte ptr [edi + 6], 1
    lea eax, [edi + 7]
    invoke RtlMoveMemory, eax, offset szElTorito, ET_SIG_LEN
    mov eax, g_bootWCatalog
    mov [edi + 71], eax
    ret
BootBuildBRVD ENDP

; Extents for hidden boot images (the catalog block itself is placed by the writer)
BootAssignLayout PROC USES esi ebx pLba:DWORD
    xor ebx, ebx
    .WHILE ebx < g_bootCount
        mov eax, ebx
        imul eax, sizeof BOOTENTRY
        lea esi, g_bootEntries
        add esi, eax
        .IF [esi].BOOTENTRY.pNode == 0
            mov ecx, pLba
            mov eax, [ecx]
            mov [esi].BOOTENTRY.wExtent, eax
            mov eax, [esi].BOOTENTRY.blobSize
            add eax, ISO_SECTOR - 1
            shr eax, 11
            add [ecx], eax
        .ENDIF
        inc ebx
    .ENDW
    ret
BootAssignLayout ENDP

; Fill one 32-byte catalog entry
BootFillEntry PROC USES esi edi pDst:DWORD, pEntry:DWORD
    mov edi, pDst
    mov esi, pEntry
    mov byte ptr [edi], 88h
    mov eax, [esi].BOOTENTRY.media
    mov [edi + 1], al
    mov eax, [esi].BOOTENTRY.loadSeg
    mov [edi + 2], ax
    mov eax, [esi].BOOTENTRY.sysType
    mov [edi + 4], al
    mov eax, [esi].BOOTENTRY.sectors
    mov [edi + 6], ax
    mov eax, [esi].BOOTENTRY.pNode
    .IF eax != 0
        mov eax, [eax].NODE.wExtent
    .ELSE
        mov eax, [esi].BOOTENTRY.wExtent
    .ENDIF
    mov [edi + 8], eax
    ret
BootFillEntry ENDP

BootBuildCatalog PROC USES esi edi ebx pSector:DWORD
    mov edi, pSector
    .IF g_bootCount == 0
        ret
    .ENDIF
    ; validation entry
    mov byte ptr [edi], 1
    mov eax, g_bootEntries[0].BOOTENTRY.platform
    mov [edi + 1], al
    lea eax, [edi + 4]
    invoke RtlMoveMemory, eax, offset g_bootIdString, 24
    mov byte ptr [edi + 30], 55h
    mov byte ptr [edi + 31], 0AAh
    ; checksum: all 16 words sum to zero
    xor eax, eax
    xor ecx, ecx
    .WHILE ecx < 32
        movzx edx, word ptr [edi + ecx]
        add eax, edx
        add ecx, 2
    .ENDW
    neg eax
    mov [edi + 28], ax

    ; initial entry
    lea eax, [edi + 32]
    invoke BootFillEntry, eax, offset g_bootEntries

    ; one section per additional entry
    lea edi, [edi + 64]
    mov ebx, 1
    .WHILE ebx < g_bootCount
        mov eax, ebx
        imul eax, sizeof BOOTENTRY
        lea esi, g_bootEntries
        add esi, eax
        mov byte ptr [edi], 90h
        mov eax, ebx
        inc eax
        .IF eax == g_bootCount
            mov byte ptr [edi], 91h
        .ENDIF
        mov eax, [esi].BOOTENTRY.platform
        mov [edi + 1], al
        mov word ptr [edi + 2], 1
        lea eax, [edi + 32]
        invoke BootFillEntry, eax, esi
        add edi, 64
        inc ebx
    .ENDW
    ret
BootBuildCatalog ENDP

BootWriteBlobs PROC USES esi ebx
    xor ebx, ebx
    .WHILE ebx < g_bootCount
        mov eax, ebx
        imul eax, sizeof BOOTENTRY
        lea esi, g_bootEntries
        add esi, eax
        .IF [esi].BOOTENTRY.pNode == 0
            invoke IsoCopyExtent, [esi].BOOTENTRY.blobExtent, [esi].BOOTENTRY.blobSize, g_hOut
            invoke IsoWritePadTo, [esi].BOOTENTRY.blobSize
        .ENDIF
        inc ebx
    .ENDW
    ret
BootWriteBlobs ENDP

; isolinux / GRUB boot info table: dwords at 8: PVD lba, file lba, file length, checksum(bytes 64..end)
BootPatchInfoTables PROC USES esi edi ebx
    LOCAL pNode:DWORD
    LOCAL pData:DWORD
    LOCAL cb:DWORD
    LOCAL table[4]:DWORD
    LOCAL pos[2]:DWORD
    LOCAL written:DWORD

    xor ebx, ebx
    .WHILE ebx < g_bootCount
        mov eax, ebx
        imul eax, sizeof BOOTENTRY
        lea esi, g_bootEntries
        add esi, eax
        mov eax, [esi].BOOTENTRY.pNode
        .IF eax != 0 && [esi].BOOTENTRY.bInfoTable != 0
            mov pNode, eax
            mov ecx, [eax].NODE.dataSize
            .IF ecx >= 64 && ecx <= INFOTABLE_MAX
                invoke VfsReadAll, pNode, INFOTABLE_MAX, addr cb
                .IF eax != 0
                    mov pData, eax
                    ; checksum of little-endian dwords from byte 64; a trailing partial dword is zero padded
                    xor eax, eax
                    mov ecx, 64
                    mov edi, pData
                    .WHILE ecx < cb
                        mov edx, cb
                        sub edx, ecx
                        .IF edx >= 4
                            add eax, [edi + ecx]
                        .ELSE
                            push eax
                            xor eax, eax
                            .IF edx >= 1
                                mov al, [edi + ecx]
                            .ENDIF
                            .IF edx >= 2
                                mov ah, [edi + ecx + 1]
                            .ENDIF
                            .IF edx >= 3
                                push ebx
                                movzx ebx, byte ptr [edi + ecx + 2]
                                shl ebx, 16
                                or eax, ebx
                                pop ebx
                            .ENDIF
                            mov edx, eax
                            pop eax
                            add eax, edx
                        .ENDIF
                        add ecx, 4
                    .ENDW
                    mov table[12], eax
                    mov table[0], ISO_VD_FIRST
                    mov eax, pNode
                    mov ecx, [eax].NODE.wExtent
                    mov table[4], ecx
                    mov ecx, [eax].NODE.dataSize
                    mov table[8], ecx
                    invoke VfsFreeMem, pData

                    mov eax, pNode
                    mov eax, [eax].NODE.wExtent
                    shl eax, 11             ; extents stay below 2 GB here
                    add eax, 8
                    mov pos[0], eax
                    mov pos[4], 0
                    invoke SetFilePointerEx, g_hOut, pos[0], pos[4], NULL, FILE_BEGIN
                    invoke WriteFile, g_hOut, addr table, 16, addr written, NULL
                .ENDIF
            .ENDIF
        .ENDIF
        inc ebx
    .ENDW
    ret
BootPatchInfoTables ENDP

END
