; FoxImg - ISO 9660 / Joliet reader
; The whole image is memory-mapped read-only; every "record pointer" handed out is a pointer into that view.
include foximg.inc

.data
g_pView     dd 0            ; base of mapped view
g_cbView    dd 0            ; bytes mapped
g_pRoot     dd 0            ; root directory record (inside PVD or Joliet SVD)
g_bJoliet   dd 0            ; nonzero when names are UCS-2 big-endian
g_pPVD      dd 0
g_pSVD      dd 0
g_hFile     dd 0
g_hMap      dd 0

szDateFmt   dw '%','0','4','u','-','%','0','2','u','-','%','0','2','u',' ','%','0','2','u',':','%','0','2','u',0

.code

; ---------------------------------------------------------------------------
; IsoClose - release mapping and file
; ---------------------------------------------------------------------------
IsoClose PROC
    .IF g_pView != 0
        invoke UnmapViewOfFile, g_pView
        mov g_pView, 0
    .ENDIF
    .IF g_hMap != 0
        invoke CloseHandle, g_hMap
        mov g_hMap, 0
    .ENDIF
    .IF g_hFile != 0
        invoke CloseHandle, g_hFile
        mov g_hFile, 0
    .ENDIF
    mov g_cbView, 0
    mov g_pRoot, 0
    mov g_bJoliet, 0
    mov g_pPVD, 0
    mov g_pSVD, 0
    ret
IsoClose ENDP

; ---------------------------------------------------------------------------
; IsoOpen - map an image and locate the volume descriptors
; Returns eax = TRUE on success
; ---------------------------------------------------------------------------
IsoOpen PROC USES esi edi ebx pszPath:DWORD
    LOCAL liSize[2]:DWORD                   ; LARGE_INTEGER: [0] low, [4] high

    invoke IsoClose

    invoke CreateFileW, pszPath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov g_hFile, eax

    invoke GetFileSizeEx, g_hFile, addr liSize
    ; A 32-bit process cannot map more than ~2 GB in one view. Larger images need windowed views (TODO).
    cmp liSize[4], 0
    jne fail
    mov eax, liSize[0]
    cmp eax, 7FF00000h
    jae fail
    mov g_cbView, eax
    cmp eax, (ISO_VD_FIRST + 1) * ISO_SECTOR
    jb fail

    invoke CreateFileMappingW, g_hFile, NULL, PAGE_READONLY, 0, 0, NULL
    .IF eax == 0
        jmp fail
    .ENDIF
    mov g_hMap, eax

    invoke MapViewOfFile, g_hMap, FILE_MAP_READ, 0, 0, 0
    .IF eax == 0
        jmp fail
    .ENDIF
    mov g_pView, eax

    ; Walk the volume descriptor set starting at sector 16 until the terminator.
    mov esi, eax
    add esi, ISO_VD_FIRST * ISO_SECTOR
    mov edi, g_pView
    add edi, g_cbView                       ; end of view

vd_loop:
    lea eax, [esi + ISO_SECTOR]
    cmp eax, edi
    ja vd_done
    cmp dword ptr [esi + ISO_VD_ID], 30304443h  ; "CD00"
    jne vd_done
    cmp byte ptr [esi + ISO_VD_ID + 4], '1'
    jne vd_done

    movzx eax, byte ptr [esi + ISO_VD_TYPE]
    .IF al == ISO_VD_TERMINATOR
        jmp vd_done
    .ELSEIF al == ISO_VD_PRIMARY
        .IF g_pPVD == 0
            mov g_pPVD, esi
        .ENDIF
    .ELSEIF al == ISO_VD_SUPPLEMENTARY
        ; Joliet escape sequence: 25h 2Fh then 40h (level 1), 43h (level 2) or 45h (level 3)
        .IF byte ptr [esi + ISO_VD_ESCAPES] == 25h && byte ptr [esi + ISO_VD_ESCAPES + 1] == 2Fh
            mov bl, byte ptr [esi + ISO_VD_ESCAPES + 2]
            .IF bl == 40h || bl == 43h || bl == 45h
                .IF g_pSVD == 0
                    mov g_pSVD, esi
                .ENDIF
            .ENDIF
        .ENDIF
    .ENDIF
    add esi, ISO_SECTOR
    jmp vd_loop

vd_done:
    .IF g_pPVD == 0
        jmp fail
    .ENDIF

    ; Prefer Joliet names when available.
    mov eax, g_pSVD
    .IF eax != 0
        mov g_bJoliet, TRUE
    .ELSE
        mov eax, g_pPVD
    .ENDIF
    add eax, ISO_VD_ROOT_RECORD
    mov g_pRoot, eax

    mov eax, TRUE
    ret

fail:
    invoke IsoClose
    xor eax, eax
    ret
IsoOpen ENDP

; ---------------------------------------------------------------------------
; IsoEnumDir - iterate the directory records in the extent described by pDirRec.
; Skips the "." and ".." entries. Callback is stdcall (pRec, lParam) and returns nonzero to continue.
; Returns eax = TRUE if the extent was valid.
; ---------------------------------------------------------------------------
IsoEnumDir PROC USES esi edi ebx pDirRec:DWORD, pfnCallback:DWORD, lParam:DWORD
    mov esi, pDirRec
    mov eax, [esi].ISO_DIRREC.extentLE
    mov ecx, [esi].ISO_DIRREC.dataLenLE

    ; byte offset = LBA * 2048; reject anything that overflows or falls outside the view
    cmp eax, 0FFFFFh * 2                    ; > 2M sectors would exceed 32 bits
    ja bad
    shl eax, 11
    mov edx, eax
    add edx, ecx
    jc bad
    cmp edx, g_cbView
    ja bad

    add eax, g_pView
    mov esi, eax                            ; cursor
    lea edi, [eax + ecx]                    ; end of extent

rec_loop:
    cmp esi, edi
    jae done

    movzx eax, [esi].ISO_DIRREC.recLen
    test eax, eax
    jnz have_rec

    ; Zero length: rest of this logical sector is padding, jump to the next sector.
    mov eax, esi
    sub eax, g_pView
    add eax, ISO_SECTOR
    and eax, not (ISO_SECTOR - 1)
    add eax, g_pView
    mov esi, eax
    jmp rec_loop

have_rec:
    cmp eax, 33
    jb done                                 ; malformed, bail rather than spin
    lea edx, [esi + eax]
    cmp edx, edi
    ja done                                 ; record runs past the extent

    ; "." (name 00h) and ".." (name 01h) have a 1-byte identifier
    .IF [esi].ISO_DIRREC.nameLen == 1
        movzx edx, byte ptr [esi + 33]
        cmp edx, 1
        jbe next_rec
    .ENDIF

    push lParam
    push esi
    call pfnCallback
    test eax, eax
    jz done

next_rec:
    movzx eax, [esi].ISO_DIRREC.recLen
    add esi, eax
    jmp rec_loop

done:
    mov eax, TRUE
    ret

bad:
    xor eax, eax
    ret
IsoEnumDir ENDP

; ---------------------------------------------------------------------------
; IsoRecName - copy the identifier of a record into a UTF-16 buffer.
; Files get their ";version" suffix and trailing "." stripped.
; ---------------------------------------------------------------------------
IsoRecName PROC USES esi edi ebx pRec:DWORD, pszBuf:DWORD, cchBuf:DWORD
    mov esi, pRec
    movzx ecx, [esi].ISO_DIRREC.nameLen
    mov bl, [esi].ISO_DIRREC.fileFlags
    add esi, 33
    mov edi, pszBuf

    mov edx, cchBuf
    dec edx                                 ; room for terminator

    .IF g_bJoliet != 0
        shr ecx, 1                          ; UCS-2 code units
        .IF ecx > edx
            mov ecx, edx
        .ENDIF
        .WHILE ecx != 0
            lodsw
            xchg al, ah                     ; big-endian on disc
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

    ; Directories carry no version suffix.
    test bl, ISO_FLAG_DIRECTORY
    jnz finished

    ; Strip ";N"
    mov esi, pszBuf
    mov edi, esi
    .WHILE word ptr [esi] != 0
        .IF word ptr [esi] == ';'
            mov word ptr [esi], 0
            .BREAK
        .ENDIF
        add esi, 2
    .ENDW

    ; Strip trailing "." (ISO level 1 names like "README." for extensionless files)
    .IF esi > edi
        .IF word ptr [esi - 2] == '.'
            mov word ptr [esi - 2], 0
        .ENDIF
    .ENDIF

finished:
    ret
IsoRecName ENDP

; ---------------------------------------------------------------------------
; IsoRecDate - format the recording date as "YYYY-MM-DD HH:MM"
; ---------------------------------------------------------------------------
IsoRecDate PROC USES esi pRec:DWORD, pszBuf:DWORD
    mov esi, pRec
    movzx eax, [esi].ISO_DIRREC.recMinute
    push eax
    movzx eax, [esi].ISO_DIRREC.recHour
    push eax
    movzx eax, [esi].ISO_DIRREC.recDay
    push eax
    movzx eax, [esi].ISO_DIRREC.recMonth
    push eax
    movzx eax, [esi].ISO_DIRREC.recYear
    add eax, 1900
    push eax
    push offset szDateFmt
    push pszBuf
    call wsprintfW
    add esp, 7 * 4
    ret
IsoRecDate ENDP

; ---------------------------------------------------------------------------
; IsoVolumeName - volume identifier from the active descriptor, trailing spaces trimmed
; ---------------------------------------------------------------------------
IsoVolumeName PROC USES esi edi pszBuf:DWORD, cchBuf:DWORD
    mov edi, pszBuf
    mov edx, cchBuf
    dec edx
    .IF edx > 32
        mov edx, 32
    .ENDIF

    .IF g_bJoliet != 0
        mov esi, g_pSVD
        add esi, ISO_VD_VOLUME_ID
        mov ecx, 16                         ; 32 bytes of UCS-2
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
        mov esi, g_pPVD
        add esi, ISO_VD_VOLUME_ID
        mov ecx, edx
        .WHILE ecx != 0
            lodsb
            movzx eax, al
            stosw
            dec ecx
        .ENDW
    .ENDIF

    ; Trim trailing spaces / NULs
    .WHILE edi > pszBuf
        .IF word ptr [edi - 2] != ' ' && word ptr [edi - 2] != 0
            .BREAK
        .ENDIF
        sub edi, 2
    .ENDW
    xor eax, eax
    stosw
    ret
IsoVolumeName ENDP

END
