; FoxImg - Opera filesystem writer (3DO discs)
;
; Layout produced (2048-byte blocks, everything big-endian):
;   0      volume header: record type 1, five 5Ah sync bytes, version, comment,
;          the label, block size and count, the root directory's block count
;          and its one copy
;   1..    directory chains, root first then breadth-first: each block a
;          20-byte header (next block, previous block, flags, first free byte,
;          first entry at 20) and 72-byte entries (flags with the type in the
;          low byte, identifier, entry type, block size, byte count, block
;          count, burst, gap, a 32-byte name, last copy index 0, one start
;          block); 28 entries per block, 0FFFFFFFFh ends the chain
;   ..     file data, each padded to a block
; One copy of everything; sizes are 32-bit, as the format's. The staging
; and file copying are isowrite.asm's, the sort is xdvdwrite.asm's.
include foximg.inc

OPW_HDR         equ 20
OPW_ENTRY       equ 72
OPW_PER_BLOCK   equ (ISO_SECTOR - OPW_HDR) / OPW_ENTRY   ; 28
OPW_FLAG_FILE   equ 02h
OPW_FLAG_DIR    equ 07h
OPW_LAST_BLOCK  equ 40000000h
OPW_LAST_DIR    equ 80000000h

.data
szOpComment     db 'FoxImg', 0
g_owId          dd 0                    ; next entry identifier
.code

; Blocks a directory chain takes for n entries: at least one
OwDirBlocks PROC n:DWORD
    mov eax, n
    add eax, OPW_PER_BLOCK - 1
    xor edx, edx
    mov ecx, OPW_PER_BLOCK
    div ecx
    .IF eax == 0
        inc eax
    .ENDIF
    ret
OwDirBlocks ENDP

; pDst (4) as big-endian v
OwBE32 PROC pDst:DWORD, v:DWORD
    mov eax, v
    bswap eax
    mov ecx, pDst
    mov dword ptr [ecx], eax
    ret
OwBE32 ENDP

; The chain for pDir, written block by block from the staging sector
OwWriteDir PROC USES esi edi ebx pDir:DWORD
    LOCAL pSorted:DWORD
    LOCAL count:DWORD
    LOCAL i:DWORD
    LOCAL inBlock:DWORD
    LOCAL blocks:DWORD
    LOCAL blk:DWORD
    LOCAL pEnt:DWORD
    LOCAL szName[256]:BYTE
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
    invoke OwDirBlocks, eax
    mov blocks, eax
    mov blk, 0
    mov i, 0
    .WHILE g_fail == 0
        mov eax, blk
        .BREAK .IF eax >= blocks
        invoke SecBegin
        mov edi, g_pSec
        ; header: next (or the end mark), previous, flags, first free, first entry
        mov eax, blk
        inc eax
        .IF eax < blocks
            add eax, g_lba
        .ELSE
            mov eax, -1
        .ENDIF
        invoke OwBE32, edi, eax
        mov eax, blk
        .IF eax == 0
            mov eax, -1
        .ELSE
            add eax, g_lba
            dec eax
        .ENDIF
        lea ecx, [edi + 4]
        invoke OwBE32, ecx, eax
        lea ecx, [edi + 16]
        invoke OwBE32, ecx, OPW_HDR
        mov inBlock, 0
        mov ecx, OPW_HDR
        mov pEnt, ecx
        .WHILE inBlock < OPW_PER_BLOCK
            mov ecx, i
            .BREAK .IF ecx >= count
            mov eax, pSorted
            mov ebx, [eax + ecx * 4]
            mov edi, g_pSec
            add edi, pEnt
            invoke FillBytes, edi, 0, OPW_ENTRY
            mov eax, OPW_FLAG_FILE
            test [ebx].NODE.nflags, NF_DIR
            .IF !ZERO?
                mov eax, OPW_FLAG_DIR
            .ENDIF
            mov ecx, i
            inc ecx
            .IF ecx == count
                or eax, OPW_LAST_DIR or OPW_LAST_BLOCK
            .ELSEIF inBlock == OPW_PER_BLOCK - 1
                or eax, OPW_LAST_BLOCK
            .ENDIF
            invoke OwBE32, edi, eax
            mov eax, g_owId
            inc g_owId
            lea ecx, [edi + 4]
            invoke OwBE32, ecx, eax
            mov dword ptr [edi + 8], 'rid*'         ; "*dir"
            test [ebx].NODE.nflags, NF_DIR
            .IF ZERO?
                mov dword ptr [edi + 8], 'tad*'     ; "*dat"
            .ENDIF
            lea ecx, [edi + 12]
            invoke OwBE32, ecx, ISO_SECTOR
            test [ebx].NODE.nflags, NF_DIR
            .IF !ZERO?
                mov eax, [ebx].NODE.wDirSize
                lea ecx, [edi + 16]
                invoke OwBE32, ecx, eax
                mov eax, [ebx].NODE.wDirSize
                shr eax, 11
                lea ecx, [edi + 20]
                invoke OwBE32, ecx, eax
            .ELSE
                .IF [ebx].NODE.dataSizeHi != 0
                    mov g_fail, TRUE
                .ENDIF
                mov eax, [ebx].NODE.dataSize
                lea ecx, [edi + 16]
                invoke OwBE32, ecx, eax
                invoke SectorsFor, [ebx].NODE.dataSize
                lea ecx, [edi + 20]
                invoke OwBE32, ecx, eax
            .ENDIF
            lea ecx, [edi + 24]
            invoke OwBE32, ecx, 1                   ; burst
            invoke XwName, ebx, addr szName
            .IF eax > 31
                mov eax, 31                         ; the name field is 32 bytes with its NUL
            .ENDIF
            mov ecx, eax
            push edi
            add edi, 32
            lea esi, szName
            rep movsb
            pop edi
            lea ecx, [edi + 68]
            invoke OwBE32, ecx, [ebx].NODE.wExtent
            add pEnt, OPW_ENTRY
            inc inBlock
            inc i
        .ENDW
        mov edi, g_pSec
        lea ecx, [edi + 12]
        invoke OwBE32, ecx, pEnt                    ; first free byte
        invoke SecWrite
        inc blk
    .ENDW
    invoke VfsFreeMem, pSorted
    ret
OwWriteDir ENDP

OperaWrite PROC USES esi edi ebx pszOutPath:DWORD
    LOCAL szName[256]:BYTE
    mov g_fail, FALSE
    mov g_hOut, 0
    mov g_pDirs, 0
    mov g_owId, 2
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
    ; chain sizes, then the layout: root chain at block 1, files after every chain
    xor ebx, ebx
    .WHILE ebx < g_nDirs
        mov eax, g_pDirs
        mov esi, [eax + ebx * 4]
        invoke XwCollect, esi
        .IF eax == 0
            jmp cleanup_fail
        .ENDIF
        invoke OwDirBlocks, g_xwCount
        shl eax, 11
        mov [esi].NODE.wDirSize, eax
        inc ebx
    .ENDW
    mov g_lba, 1
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
    ; the volume header
    invoke SecBegin
    mov edi, g_pSec
    mov byte ptr [edi], 1
    mov dword ptr [edi + 1], 5A5A5A5Ah
    mov byte ptr [edi + 5], 5Ah
    mov byte ptr [edi + 6], 1                   ; record version
    invoke lstrlenA, offset szOpComment
    lea ecx, [edi + 8]
    invoke RtlMoveMemory, ecx, offset szOpComment, eax
    invoke XwName, g_pRootNode, addr szName
    .IF eax > 31
        mov eax, 31
    .ENDIF
    lea ecx, [edi + 40]
    invoke RtlMoveMemory, ecx, addr szName, eax
    lea eax, [edi + 72]
    invoke OwBE32, eax, 4B4F5846h               ; identifier
    lea eax, [edi + 76]
    invoke OwBE32, eax, ISO_SECTOR              ; block size
    lea eax, [edi + 80]
    invoke OwBE32, eax, g_totalSectors          ; block count
    lea eax, [edi + 84]
    invoke OwBE32, eax, 1                       ; root directory identifier
    mov esi, g_pRootNode
    mov eax, [esi].NODE.wDirSize
    shr eax, 11
    lea ecx, [edi + 88]
    invoke OwBE32, ecx, eax                     ; root directory blocks
    lea eax, [edi + 92]
    invoke OwBE32, eax, ISO_SECTOR              ; root directory block size
    lea eax, [edi + 96]
    invoke OwBE32, eax, 1                       ; one copy
    lea eax, [edi + 100]
    invoke OwBE32, eax, [esi].NODE.wExtent      ; at this block
    invoke SecWrite
    ; the chains, then the files
    xor ebx, ebx
    .WHILE ebx < g_nDirs
        .BREAK .IF g_fail != 0
        mov eax, g_pDirs
        mov esi, [eax + ebx * 4]
        invoke OwWriteDir, esi
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
OperaWrite ENDP

END
