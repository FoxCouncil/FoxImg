; FoxImg - shared string, path and small-file helpers
include foximg.inc

.data
g_szJoinFmt     dw '%','s','\','%','s',0
g_szCatFmt      dw '%','s','%','s',0
g_szUintFmt     dw '%','u',0

.code

; ---------------------------------------------------------------------------
; Paths (UTF-16)
; ---------------------------------------------------------------------------
; Pointer to the extension (including '.') of the leaf, or to the terminating NUL when there is none
PathExt PROC USES esi pszPath:DWORD
    mov esi, pszPath
    mov edx, 0
    .WHILE word ptr [esi] != 0
        .IF word ptr [esi] == '.'
            mov edx, esi
        .ELSEIF word ptr [esi] == '\'
            mov edx, 0
        .ENDIF
        add esi, 2
    .ENDW
    .IF edx == 0
        mov edx, esi
    .ENDIF
    mov eax, edx
    ret
PathExt ENDP

; Pointer to the leaf name
PathLeaf PROC USES esi pszPath:DWORD
    mov esi, pszPath
    mov eax, esi
    .WHILE word ptr [esi] != 0
        .IF word ptr [esi] == '\'
            lea eax, [esi + 2]
        .ENDIF
        add esi, 2
    .ENDW
    ret
PathLeaf ENDP

; pszOut = pszPath with its extension replaced by pszNewExt (".cue")
PathWithExt PROC pszOut:DWORD, pszPath:DWORD, pszNewExt:DWORD
    invoke lstrcpynW, pszOut, pszPath, MAX_PATH - 8
    invoke PathExt, pszOut
    mov word ptr [eax], 0
    invoke lstrcatW, pszOut, pszNewExt
    ret
PathWithExt ENDP

; Does pszPath end with pszExt (case-insensitive)?
HasExt PROC pszPath:DWORD, pszExt:DWORD
    LOCAL cchExt:DWORD
    invoke lstrlenW, pszExt
    mov cchExt, eax
    invoke lstrlenW, pszPath
    .IF eax < cchExt
        xor eax, eax
        ret
    .ENDIF
    sub eax, cchExt
    mov ecx, pszPath
    lea ecx, [ecx + eax * 2]
    invoke lstrcmpiW, ecx, pszExt
    .IF eax == 0
        mov eax, TRUE
    .ELSE
        xor eax, eax
    .ENDIF
    ret
HasExt ENDP

; pszOut = directory of pszRef + pszName, unless pszName is absolute
PathDirJoin PROC USES esi edi pszOut:DWORD, pszRef:DWORD, pszName:DWORD
    mov eax, pszName
    .IF word ptr [eax] == '\' || word ptr [eax + 2] == ':'
        invoke lstrcpynW, pszOut, pszName, MAX_PATH
        ret
    .ENDIF
    invoke lstrcpynW, pszOut, pszRef, MAX_PATH
    mov esi, pszOut
    mov edi, esi
    .WHILE word ptr [esi] != 0
        .IF word ptr [esi] == '\'
            lea edi, [esi + 2]
        .ENDIF
        add esi, 2
    .ENDW
    mov word ptr [edi], 0
    invoke lstrlenW, pszOut
    mov esi, eax
    invoke lstrlenW, pszName
    add eax, esi
    .IF eax < MAX_PATH
        invoke lstrcatW, pszOut, pszName
    .ENDIF
    ret
PathDirJoin ENDP

; ---------------------------------------------------------------------------
; ASCII text parsing (cue sheets, toc files, gdi lists)
; ---------------------------------------------------------------------------
; Case-insensitive substring search; returns pointer past the keyword or 0
FindKeyword PROC USES esi edi ebx pBuf:DWORD, cb:DWORD, pszKey:DWORD
    LOCAL keyLen:DWORD
    invoke lstrlenA, pszKey
    mov keyLen, eax
    mov esi, pBuf
    mov ecx, cb
    .WHILE ecx >= keyLen
        mov edi, pszKey
        xor ebx, ebx
        .WHILE ebx < keyLen
            mov al, [esi + ebx]
            .IF al >= 'a' && al <= 'z'
                sub al, 20h
            .ENDIF
            .BREAK .IF al != [edi + ebx]
            inc ebx
        .ENDW
        .IF ebx == keyLen
            lea eax, [esi + ebx]
            ret
        .ENDIF
        inc esi
        dec ecx
    .ENDW
    xor eax, eax
    ret
FindKeyword ENDP

; Unsigned decimal at pText; value in eax, pointer past it in edx
ParseUint PROC USES esi pText:DWORD
    mov esi, pText
    .WHILE byte ptr [esi] == ' ' || byte ptr [esi] == 9
        inc esi
    .ENDW
    xor eax, eax
    .WHILE byte ptr [esi] >= '0' && byte ptr [esi] <= '9'
        movzx ecx, byte ptr [esi]
        sub ecx, '0'
        imul eax, 10
        add eax, ecx
        inc esi
    .ENDW
    mov edx, esi
    ret
ParseUint ENDP

; Quoted or bare token at pText -> UTF-16 into pszOut (MAX_PATH); pointer past it in edx
ParseName PROC USES esi edi ebx pText:DWORD, pszOut:DWORD
    mov esi, pText
    .WHILE byte ptr [esi] == ' ' || byte ptr [esi] == 9
        inc esi
    .ENDW
    mov ebx, esi
    .IF byte ptr [esi] == '"'
        inc esi
        mov ebx, esi
        .WHILE byte ptr [esi] != 0 && byte ptr [esi] != '"' && byte ptr [esi] != 13 && byte ptr [esi] != 10
            inc esi
        .ENDW
    .ELSE
        .WHILE byte ptr [esi] != 0 && byte ptr [esi] != ' ' && byte ptr [esi] != 9 && byte ptr [esi] != 13 && byte ptr [esi] != 10
            inc esi
        .ENDW
    .ENDIF
    mov ecx, esi
    sub ecx, ebx
    .IF ecx >= MAX_PATH
        mov ecx, MAX_PATH - 1
    .ENDIF
    push esi
    invoke MultiByteToWideChar, CP_ACP, 0, ebx, ecx, pszOut, MAX_PATH - 1
    mov ecx, pszOut
    mov word ptr [ecx + eax * 2], 0
    pop esi
    .IF byte ptr [esi] == '"'
        inc esi
    .ENDIF
    mov edx, esi
    ret
ParseName ENDP

; ---------------------------------------------------------------------------
; Files
; ---------------------------------------------------------------------------
; Read cb bytes at 64-bit offset into pDst. Returns bytes read.
; The open-for-shared-read every reader performs
FileOpenRead PROC pszPath:DWORD
    invoke CreateFileW, pszPath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL
    ret
FileOpenRead ENDP

FileReadAt PROC hFile:DWORD, offLo:DWORD, offHi:DWORD, pDst:DWORD, cb:DWORD
    LOCAL nRead:DWORD
    invoke SetFilePointerEx, hFile, offLo, offHi, NULL, FILE_BEGIN
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov nRead, 0
    invoke ReadFile, hFile, pDst, cb, addr nRead, NULL
    mov eax, nRead
    ret
FileReadAt ENDP

FileSize64 PROC hFile:DWORD, pLo:DWORD, pHi:DWORD
    LOCAL li[2]:DWORD
    invoke GetFileSizeEx, hFile, addr li
    mov eax, li[0]
    mov ecx, pLo
    mov [ecx], eax
    mov eax, li[4]
    mov ecx, pHi
    mov [ecx], eax
    ret
FileSize64 ENDP

; Whole small text file into a NUL-terminated heap buffer (caller frees); returns pointer, *pcb = length
ReadTextFile PROC pszPath:DWORD, pcb:DWORD
    LOCAL hFile:DWORD
    LOCAL lo:DWORD
    LOCAL hi:DWORD
    LOCAL pBuf:DWORD
    mov eax, pcb
    mov dword ptr [eax], 0
    invoke FileOpenRead, pszPath
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hFile, eax
    invoke FileSize64, hFile, addr lo, addr hi
    .IF hi != 0 || lo > 65536
        mov lo, 65536
    .ENDIF
    mov eax, lo
    inc eax
    invoke VfsAlloc, eax
    mov pBuf, eax
    .IF eax != 0
        invoke FileReadAt, hFile, 0, 0, pBuf, lo
        mov ecx, pcb
        mov [ecx], eax
    .ENDIF
    invoke CloseHandle, hFile
    mov eax, pBuf
    ret
ReadTextFile ENDP

END
