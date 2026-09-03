; FoxImg - background jobs: one worker thread, progress bar + cancel in the status bar, UI stays responsive
;
; While a job runs the UI thread keeps pumping messages; commands, edits and drops are refused (JobBusy).
; The worker only reads the model (save, extract) or appends to it (add) while the list is emptied, so no locking is needed.
include foximg.inc

JOB_MAX_NODES   equ 1024
JOB_PATHS_MAX   equ 65536       ; WCHARs

.data
g_jobBusy       dd 0
g_jobKind       dd 0
g_jobCancel     dd 0
g_progDone      dd 0            ; 64-bit byte counters (lo, hi)
g_progDoneHi    dd 0
g_progTotal     dd 0            ; 0:0 = unknown (marquee)
g_progTotalHi   dd 0
g_hProgress     dd 0
g_hCancelBtn    dd 0
g_hJobThread    dd 0
g_jobNode       dd 0            ; JOB_ADD target directory
g_nJobNodes     dd 0
g_jobPaths      dd 0            ; heap WCHAR list, double-NUL terminated
g_jobPathsEnd   dd 0
g_jobResult     dd 0
g_bMarquee      dd 0

WSTR szProgressClass, <msctls_progress32>
WSTR szButtonClass, <BUTTON>
WSTR szCancel, <Cancel>
WSTR szJobSave, <Writing image>
WSTR szJobExtract, <Extracting>
WSTR szJobAdd, <Adding files>
WSTR szCancelling, <Cancelling...>
WSTR szGzSuffix, <.gz>
WSTR szZipSuffix, <.zip>
WSTR szCsoSuffix, <.cso>
WSTR szIszSuffix, <.isz>
WSTR szDaxSuffix, <.dax>
WSTR szJsoSuffix, <.jso>
WSTR szGczSuffix, <.gcz>
WSTR szUifSuffix, <.uif>
WSTR szDaaSuffix, <.daa>
WSTR szDmgSuffix, <.dmg>
WSTR szEcmSuffix, <.ecm>
WSTR szNrgSuffix, <.nrg>
WSTR szZsoSuffix, <.zso>
WSTR szRawSuffix, <.raw>
; indexed by SAVE_* - 1: the suffix the second pass writes beside the image, and its writer
g_saveSuffix    dd offset szGzSuffix, offset szZipSuffix, offset szCsoSuffix, offset szIszSuffix, offset szDaxSuffix
                dd offset szJsoSuffix, offset szGczSuffix, offset szUifSuffix, offset szDaaSuffix, offset szDmgSuffix
                dd offset szEcmSuffix, offset szNrgSuffix, offset szZsoSuffix, offset szRawSuffix
g_saveWriter    dd offset GzCompressFile, 0, offset CsoCompressFile, offset IszCompressFile, offset DaxCompressFile
                dd offset JsoCompressFile, offset GczCompressFile, offset UifCompressFile, offset DaaCompressFile, offset DmgCompressFile
                dd offset EcmWrapFile, offset NrgWrapFile, offset ZsoCompressFile, offset RawWrapFile
WSTR szIsoDot, <.iso>
szPctFmt        dw '%','s','.','.','.',' ',' ','%','u','%','%',0
szDotsFmt       dw '%','s','.','.','.',0

.data?
g_jobPath       dw MAX_PATH dup(?)
g_jobDir        dw MAX_PATH dup(?)
g_jobNodes      dd JOB_MAX_NODES dup(?)

.code

JobThreadProc   PROTO :DWORD

; ---------------------------------------------------------------------------
; UI pieces
; ---------------------------------------------------------------------------
; The status bar owner-draws its parts on every update and would paint over siblings, so the progress bar
; and the cancel button are its children; a subclass forwards the button's WM_COMMAND to us.
StatusSubclassProc PROC hWnd:DWORD, uMsg:DWORD, wParam:DWORD, lParam:DWORD, uIdSubclass:DWORD, dwRefData:DWORD
    .IF uMsg == WM_COMMAND
        movzx eax, word ptr wParam
        .IF eax == IDC_CANCEL
            invoke JobCancel
            xor eax, eax
            ret
        .ENDIF
    .ENDIF
    invoke DefSubclassProc, hWnd, uMsg, wParam, lParam
    ret
StatusSubclassProc ENDP

JobInit PROC hParent:DWORD
    invoke CreateWindowExW, 0, offset szProgressClass, NULL, WS_CHILD, 0, 0, 0, 0, g_hStatus, IDC_PROGRESS, g_hInst, NULL
    mov g_hProgress, eax
    invoke SendMessageW, g_hProgress, PBM_SETRANGE32, 0, 1000
    invoke CreateWindowExW, 0, offset szButtonClass, offset szCancel, WS_CHILD or BS_PUSHBUTTON, 0, 0, 0, 0, g_hStatus, IDC_CANCEL, g_hInst, NULL
    mov g_hCancelBtn, eax
    invoke SendMessageW, g_hCancelBtn, WM_SETFONT, g_hFont, TRUE
    invoke SetWindowSubclass, g_hStatus, offset StatusSubclassProc, 2, 0
    ret
JobInit ENDP

; Progress bar over status part 0, cancel button at the right edge of part 1 (status-bar client coordinates)
JobLayout PROC
    LOCAL rc:RECT
    LOCAL x:DWORD
    LOCAL y:DWORD
    LOCAL cxP:DWORD
    LOCAL cyP:DWORD
    LOCAL cxBtn:DWORD
    .IF g_hProgress == 0 || g_hStatus == 0
        ret
    .ENDIF
    invoke SendMessageW, g_hStatus, SB_GETRECT, 0, addr rc
    mov eax, rc.left
    inc eax
    mov x, eax
    mov eax, rc.top
    inc eax
    mov y, eax
    mov eax, rc.right
    sub eax, rc.left
    sub eax, 2
    mov cxP, eax
    mov eax, rc.bottom
    sub eax, rc.top
    sub eax, 2
    mov cyP, eax
    invoke MoveWindow, g_hProgress, x, y, cxP, cyP, TRUE

    invoke SendMessageW, g_hStatus, SB_GETRECT, 1, addr rc
    invoke Scale, 80
    mov cxBtn, eax
    mov eax, rc.right
    sub eax, cxBtn
    sub eax, 2
    mov x, eax
    invoke MoveWindow, g_hCancelBtn, x, y, cxBtn, cyP, TRUE
    ret
JobLayout ENDP

JobBusy PROC
    mov eax, g_jobBusy
    ret
JobBusy ENDP

JobSetCursor PROC
    .IF g_jobBusy == 0
        xor eax, eax
        ret
    .ENDIF
    invoke LoadCursorW, NULL, IDC_WAIT
    invoke SetCursor, eax
    mov eax, TRUE
    ret
JobSetCursor ENDP

; done * scale / total, computed in KB so 64-bit byte counts fit (up to 4 TB)
JobProgress PROC scale:DWORD
    mov eax, g_progDone
    mov edx, g_progDoneHi
    shrd eax, edx, 10
    mov ecx, g_progTotal
    mov edx, g_progTotalHi
    shrd ecx, edx, 10
    .IF ecx == 0
        inc ecx
    .ENDIF
    xor edx, edx
    imul eax, scale
    div ecx
    .IF eax > scale
        mov eax, scale
    .ENDIF
    ret
JobProgress ENDP

JobHaveTotal PROC
    mov eax, g_progTotal
    or eax, g_progTotalHi
    ret
JobHaveTotal ENDP

JobStatusText PROC
    LOCAL szText[128]:WORD
    LOCAL pct:DWORD
    LOCAL pKind:DWORD
    mov eax, g_jobKind
    mov ecx, offset szJobSave
    .IF eax == JOB_EXTRACT
        mov ecx, offset szJobExtract
    .ELSEIF eax == JOB_ADD
        mov ecx, offset szJobAdd
    .ENDIF
    mov pKind, ecx
    .IF g_jobCancel != 0
        invoke UiSetStatusPart, 1, offset szCancelling
        ret
    .ENDIF
    invoke JobHaveTotal
    .IF eax != 0
        invoke JobProgress, 100
        mov pct, eax
        invoke wsprintfW, addr szText, offset szPctFmt, pKind, pct
    .ELSE
        invoke wsprintfW, addr szText, offset szDotsFmt, pKind
    .ENDIF
    invoke UiSetStatusPart, 1, addr szText
    ret
JobStatusText ENDP

JobOnTimer PROC
    .IF g_jobBusy == 0
        ret
    .ENDIF
    invoke JobHaveTotal
    .IF eax != 0
        .IF g_bMarquee != 0
            invoke SendMessageW, g_hProgress, PBM_SETMARQUEE, FALSE, 0
            mov g_bMarquee, 0
        .ENDIF
        invoke JobProgress, 1000
        invoke SendMessageW, g_hProgress, PBM_SETPOS, eax, 0
    .ELSEIF g_bMarquee == 0
        invoke SendMessageW, g_hProgress, PBM_SETMARQUEE, TRUE, 50
        mov g_bMarquee, 1
    .ENDIF
    invoke JobStatusText
    ret
JobOnTimer ENDP

JobCancel PROC
    .IF g_jobBusy != 0
        mov g_jobCancel, TRUE
        invoke EnableWindow, g_hCancelBtn, FALSE
        invoke JobStatusText
    .ENDIF
    ret
JobCancel ENDP

; ---------------------------------------------------------------------------
; Lifecycle
; ---------------------------------------------------------------------------
JobBegin PROC kind:DWORD
    LOCAL tid:DWORD
    .IF g_jobBusy != 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, kind
    mov g_jobKind, eax
    mov g_jobCancel, 0
    mov g_progDone, 0
    mov g_progDoneHi, 0
    mov g_jobResult, 0
    mov g_bMarquee, 0
    mov g_jobBusy, TRUE
    invoke CreateThread, NULL, 0, offset JobThreadProc, 0, 0, addr tid
    .IF eax == 0
        mov g_jobBusy, 0
        xor eax, eax
        ret
    .ENDIF
    mov g_hJobThread, eax
    invoke JobLayout
    invoke SendMessageW, g_hProgress, PBM_SETPOS, 0, 0
    invoke ShowWindow, g_hProgress, SW_SHOW
    invoke EnableWindow, g_hCancelBtn, TRUE
    invoke ShowWindow, g_hCancelBtn, SW_SHOW
    invoke SetTimer, g_hWnd, JOB_TIMER_ID, 100, NULL
    invoke JobStatusText
    mov eax, TRUE
    ret
JobBegin ENDP

JobOnDone PROC result:DWORD
    LOCAL kind:DWORD
    .IF g_jobBusy == 0
        ret
    .ENDIF
    invoke KillTimer, g_hWnd, JOB_TIMER_ID
    .IF g_hJobThread != 0
        invoke CloseHandle, g_hJobThread
        mov g_hJobThread, 0
    .ENDIF
    invoke ShowWindow, g_hProgress, SW_HIDE
    invoke ShowWindow, g_hCancelBtn, SW_HIDE
    invoke SendMessageW, g_hProgress, PBM_SETMARQUEE, FALSE, 0
    mov g_bMarquee, 0
    mov eax, g_jobKind
    mov kind, eax
    mov g_jobBusy, 0
    mov g_jobKind, JOB_NONE
    .IF g_jobPaths != 0
        invoke VfsFreeMem, g_jobPaths
        mov g_jobPaths, 0
    .ENDIF
    invoke AppJobFinished, kind, result
    ret
JobOnDone ENDP

; ---------------------------------------------------------------------------
; Job inputs
; ---------------------------------------------------------------------------
JobStartSave PROC pszTmpPath:DWORD
    .IF g_jobBusy != 0
        xor eax, eax
        ret
    .ENDIF
    invoke lstrcpynW, offset g_jobPath, pszTmpPath, MAX_PATH
    mov g_progTotalHi, 0
    mov g_progTotal, 0                      ; the writer fills it in once the layout is known
    invoke JobBegin, JOB_SAVE
    ret
JobStartSave ENDP

JobNodesReset PROC
    mov g_nJobNodes, 0
    ret
JobNodesReset ENDP

JobNodesAdd PROC pNode:DWORD, lParam:DWORD
    mov eax, g_nJobNodes
    .IF eax < JOB_MAX_NODES
        mov ecx, pNode
        mov g_jobNodes[eax * 4], ecx
        inc g_nJobNodes
    .ENDIF
    ret
JobNodesAdd ENDP

; Bytes below a node (files only), accumulated into the 64-bit total
NodeBytes PROC USES esi pNode:DWORD
    mov esi, pNode
    test [esi].NODE.nflags, NF_DIR
    .IF ZERO?
        mov eax, [esi].NODE.dataSize
        add g_progTotal, eax
        mov eax, [esi].NODE.dataSizeHi
        adc g_progTotalHi, eax
        ret
    .ENDIF
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        invoke NodeBytes, esi
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    ret
NodeBytes ENDP

JobStartExtract PROC USES ebx pszDir:DWORD
    .IF g_jobBusy != 0 || g_nJobNodes == 0
        xor eax, eax
        ret
    .ENDIF
    invoke lstrcpynW, offset g_jobDir, pszDir, MAX_PATH
    mov g_progTotal, 0
    mov g_progTotalHi, 0
    xor ebx, ebx
    .WHILE ebx < g_nJobNodes
        invoke NodeBytes, g_jobNodes[ebx * 4]
        inc ebx
    .ENDW
    invoke JobHaveTotal
    .IF eax == 0
        mov g_progTotal, 1
    .ENDIF
    invoke JobBegin, JOB_EXTRACT
    ret
JobStartExtract ENDP

JobPathsReset PROC
    .IF g_jobPaths == 0
        invoke VfsAlloc, JOB_PATHS_MAX * 2
        mov g_jobPaths, eax
    .ENDIF
    mov eax, g_jobPaths
    mov g_jobPathsEnd, eax
    .IF eax != 0
        mov word ptr [eax], 0
    .ENDIF
    ret
JobPathsReset ENDP

JobPathsAdd PROC pszPath:DWORD
    .IF g_jobPaths == 0
        ret
    .ENDIF
    invoke lstrlenW, pszPath
    mov ecx, g_jobPathsEnd
    sub ecx, g_jobPaths
    shr ecx, 1
    add ecx, eax
    add ecx, 2
    .IF ecx >= JOB_PATHS_MAX
        ret
    .ENDIF
    invoke lstrcpyW, g_jobPathsEnd, pszPath
    invoke lstrlenW, g_jobPathsEnd
    mov ecx, g_jobPathsEnd
    lea ecx, [ecx + eax * 2 + 2]
    mov g_jobPathsEnd, ecx
    mov word ptr [ecx], 0
    ret
JobPathsAdd ENDP

JobStartAdd PROC pDirNode:DWORD
    .IF g_jobBusy != 0 || g_jobPaths == 0 || pDirNode == 0
        xor eax, eax
        ret
    .ENDIF
    mov eax, pDirNode
    mov g_jobNode, eax
    mov g_progTotalHi, 0
    mov g_progTotal, 0                      ; unknown -> marquee
    ; the worker may replace nodes shown in the list; empty it first
    invoke UiFillListNode, 0
    invoke JobBegin, JOB_ADD
    ret
JobStartAdd ENDP

; ---------------------------------------------------------------------------
; Worker thread
; ---------------------------------------------------------------------------
; The save itself: the image to g_jobPath (pszTmpPath first copied there when
; given), then the second pass when a container or raw sectors were asked for.
; Runs on the worker thread, and on the main thread for a command-line convert.
JobRunSave PROC USES esi ebx pszTmpPath:DWORD
    LOCAL result:DWORD
    LOCAL szGz[MAX_PATH + 8]:WORD
    LOCAL szEntry[MAX_PATH]:WORD
    LOCAL szEntry2[MAX_PATH]:WORD
    LOCAL pLeaf:DWORD
    .IF pszTmpPath != 0
        invoke lstrcpynW, offset g_jobPath, pszTmpPath, MAX_PATH
    .ENDIF
    invoke IsoWrite, offset g_jobPath
    mov result, eax
    .IF eax != 0 && g_saveKind != SAVE_NONE
        ; second pass: pack the finished image beside itself, then take its place
        mov eax, g_saveKind
        dec eax
        mov ecx, dword ptr g_saveSuffix[eax * 4]
        invoke wsprintfW, addr szGz, offset g_szCatFmt, offset g_jobPath, ecx
        .IF g_saveKind == SAVE_ZIP
            ; the entry is named after the target, .zip.tmp -> .iso
            invoke lstrcpynW, addr szEntry, offset g_jobPath, MAX_PATH
            invoke lstrlenW, addr szEntry
            lea ecx, szEntry
            mov word ptr [ecx + eax * 2 - 8], 0     ; drop ".tmp"
            invoke PathWithExt, addr szEntry2, addr szEntry, offset szIsoDot
            invoke PathLeaf, addr szEntry2
            mov pLeaf, eax
            invoke ZipCompressFile, offset g_jobPath, addr szGz, pLeaf
        .ELSE
            mov eax, g_saveKind
            dec eax
            mov eax, dword ptr g_saveWriter[eax * 4]
            lea ecx, szGz
            push ecx
            push offset g_jobPath
            call eax
        .ENDIF
        .IF eax != 0
            invoke DeleteFileW, offset g_jobPath
            invoke MoveFileExW, addr szGz, offset g_jobPath, MOVEFILE_REPLACE_EXISTING
            mov result, eax
        .ELSE
            invoke DeleteFileW, addr szGz
            mov result, FALSE
        .ENDIF
    .ENDIF
    mov eax, result
    ret
JobRunSave ENDP

JobThreadProc PROC USES esi ebx lpParam:DWORD
    LOCAL result:DWORD
    mov result, FALSE
    mov eax, g_jobKind
    .IF eax == JOB_SAVE
        invoke JobRunSave, 0
        mov result, eax
    .ELSEIF eax == JOB_EXTRACT
        mov result, TRUE
        xor ebx, ebx
        .WHILE ebx < g_nJobNodes
            .BREAK .IF g_jobCancel != 0
            invoke VfsExtract, g_jobNodes[ebx * 4], offset g_jobDir
            .IF eax == 0
                mov result, FALSE
            .ENDIF
            inc ebx
        .ENDW
        .IF g_jobCancel != 0
            mov result, FALSE
        .ENDIF
    .ELSEIF eax == JOB_ADD
        mov result, TRUE
        mov esi, g_jobPaths
        .WHILE word ptr [esi] != 0
            .BREAK .IF g_jobCancel != 0
            invoke VfsAddHostPath, g_jobNode, esi
            invoke lstrlenW, esi
            lea esi, [esi + eax * 2 + 2]
        .ENDW
    .ENDIF
    invoke PostMessageW, g_hWnd, WM_JOBDONE, result, 0
    xor eax, eax
    ret
JobThreadProc ENDP

END
