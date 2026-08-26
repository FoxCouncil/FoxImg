; FoxImg - OLE drag and drop
;   out:   list/tree items -> Explorer (files are extracted to %TEMP%\FoxImg\<tick>\ and offered as CF_HDROP)
;   in:    CF_HDROP from Explorer onto the list or a specific tree folder
;   move:  our own drag dropped back on the tree/list moves the nodes inside the image
include foximg.inc

DRAG_MAX        equ 256

; COM object = pointer to vtable followed by our own fields
DROPTARGET STRUCT
    pVtbl       DWORD ?
    hwnd        DWORD ?
    bTree       DWORD ?
DROPTARGET ENDS

.data
IID_IUnknown    db 00h,00h,00h,00h, 00h,00h, 00h,00h, 0C0h,00h,00h,00h,00h,00h,00h,46h
IID_IDropSource db 21h,01h,00h,00h, 00h,00h, 00h,00h, 0C0h,00h,00h,00h,00h,00h,00h,46h
IID_IDropTarget db 22h,01h,00h,00h, 00h,00h, 00h,00h, 0C0h,00h,00h,00h,00h,00h,00h,46h
IID_IDataObject db 0Eh,01h,00h,00h, 00h,00h, 00h,00h, 0C0h,00h,00h,00h,00h,00h,00h,46h

g_srcVtbl       dd offset SrcQueryInterface, offset SrcAddRef, offset SrcRelease, offset SrcQueryContinueDrag, offset SrcGiveFeedback
g_dropSource    dd offset g_srcVtbl

g_tgtVtbl       dd offset TgtQueryInterface, offset TgtAddRef, offset TgtRelease, offset TgtDragEnter, offset TgtDragOver, offset TgtDragLeave, offset TgtDrop
g_tgtList       DROPTARGET <offset g_tgtVtbl, 0, 0>
g_tgtTree       DROPTARGET <offset g_tgtVtbl, 0, 1>

g_bInternalDrag dd 0
g_curEffect     dd 0
g_nDragNodes    dd 0
g_bOleInit      dd 0
g_bRegistered   dd 0

WSTR szTempSub, <FoxImg>
szTempFmt       dw '%','s','F','o','x','I','m','g','\','%','u',0
szJoinFmt       dw '%','s','\','%','s',0

.data?
g_dragNodes     dd DRAG_MAX dup(?)
g_szTempDir     dw MAX_PATH dup(?)

.code

; ---------------------------------------------------------------------------
; GUID compare
; ---------------------------------------------------------------------------
GuidEqual PROC USES esi edi pA:DWORD, pB:DWORD
    mov esi, pA
    mov edi, pB
    mov ecx, 4
    repe cmpsd
    .IF ZERO?
        mov eax, TRUE
    .ELSE
        xor eax, eax
    .ENDIF
    ret
GuidEqual ENDP

; ---------------------------------------------------------------------------
; IDropSource
; ---------------------------------------------------------------------------
SrcQueryInterface PROC pThis:DWORD, riid:DWORD, ppv:DWORD
    invoke GuidEqual, riid, offset IID_IUnknown
    .IF eax == 0
        invoke GuidEqual, riid, offset IID_IDropSource
    .ENDIF
    mov ecx, ppv
    .IF eax != 0
        mov eax, pThis
        mov [ecx], eax
        mov eax, S_OK
    .ELSE
        mov dword ptr [ecx], 0
        mov eax, E_NOINTERFACE
    .ENDIF
    ret
SrcQueryInterface ENDP

SrcAddRef PROC pThis:DWORD
    mov eax, 1
    ret
SrcAddRef ENDP

SrcRelease PROC pThis:DWORD
    mov eax, 1
    ret
SrcRelease ENDP

SrcQueryContinueDrag PROC pThis:DWORD, fEscapePressed:DWORD, grfKeyState:DWORD
    .IF fEscapePressed != 0
        mov eax, DRAGDROP_S_CANCEL
        ret
    .ENDIF
    test grfKeyState, MK_LBUTTON
    .IF ZERO?
        mov eax, DRAGDROP_S_DROP
        ret
    .ENDIF
    mov eax, S_OK
    ret
SrcQueryContinueDrag ENDP

SrcGiveFeedback PROC pThis:DWORD, dwEffect:DWORD
    mov eax, DRAGDROP_S_USEDEFAULTCURSORS
    ret
SrcGiveFeedback ENDP

; ---------------------------------------------------------------------------
; IDropTarget
; ---------------------------------------------------------------------------
TgtQueryInterface PROC pThis:DWORD, riid:DWORD, ppv:DWORD
    invoke GuidEqual, riid, offset IID_IUnknown
    .IF eax == 0
        invoke GuidEqual, riid, offset IID_IDropTarget
    .ENDIF
    mov ecx, ppv
    .IF eax != 0
        mov eax, pThis
        mov [ecx], eax
        mov eax, S_OK
    .ELSE
        mov dword ptr [ecx], 0
        mov eax, E_NOINTERFACE
    .ENDIF
    ret
TgtQueryInterface ENDP

TgtAddRef PROC pThis:DWORD
    mov eax, 1
    ret
TgtAddRef ENDP

TgtRelease PROC pThis:DWORD
    mov eax, 1
    ret
TgtRelease ENDP

; Does the data object carry CF_HDROP?
HasHDrop PROC pDataObj:DWORD
    LOCAL fmt:FORMATETC
    mov fmt.cfFormat, CF_HDROP
    mov fmt.wPad, 0
    mov fmt.ptd, 0
    mov fmt.dwAspect, DVASPECT_CONTENT
    mov fmt.lindex, -1
    mov fmt.tymed, TYMED_HGLOBAL
    mov eax, pDataObj
    mov ecx, [eax]
    lea edx, fmt
    push edx
    push eax
    call dword ptr [ecx + 5 * 4]            ; IDataObject::QueryGetData
    .IF eax == S_OK
        mov eax, TRUE
    .ELSE
        xor eax, eax
    .ENDIF
    ret
HasHDrop ENDP

; Update tree drop highlight for a screen point; returns nothing
TgtHilite PROC pThis:DWORD, x:DWORD, y:DWORD
    LOCAL pt:POINT
    mov eax, pThis
    .IF [eax].DROPTARGET.bTree == 0
        ret
    .ENDIF
    mov eax, x
    mov pt.x, eax
    mov eax, y
    mov pt.y, eax
    invoke ScreenToClient, g_hTree, addr pt
    invoke UiTreeNodeAt, pt.x, pt.y, TRUE
    ret
TgtHilite ENDP

TgtDragEnter PROC pThis:DWORD, pDataObj:DWORD, grfKeyState:DWORD, ptx:DWORD, pty:DWORD, pdwEffect:DWORD
    mov g_curEffect, DROPEFFECT_NONE
    .IF g_jobBusy != 0
        ; a job is using the model; refuse drops until it finishes
    .ELSEIF g_bInternalDrag != 0
        mov g_curEffect, DROPEFFECT_MOVE
    .ELSE
        invoke HasHDrop, pDataObj
        .IF eax != 0
            mov g_curEffect, DROPEFFECT_COPY
        .ENDIF
    .ENDIF
    invoke TgtHilite, pThis, ptx, pty
    mov ecx, pdwEffect
    mov eax, g_curEffect
    mov [ecx], eax
    mov eax, S_OK
    ret
TgtDragEnter ENDP

TgtDragOver PROC pThis:DWORD, grfKeyState:DWORD, ptx:DWORD, pty:DWORD, pdwEffect:DWORD
    invoke TgtHilite, pThis, ptx, pty
    mov ecx, pdwEffect
    mov eax, g_curEffect
    mov [ecx], eax
    mov eax, S_OK
    ret
TgtDragOver ENDP

TgtDragLeave PROC pThis:DWORD
    mov eax, pThis
    .IF [eax].DROPTARGET.bTree != 0
        invoke SendMessageW, g_hTree, TVM_SELECTITEM, TVGN_DROPHILITE, 0
    .ENDIF
    mov eax, S_OK
    ret
TgtDragLeave ENDP

; Target directory for a drop at screen (x, y) on the given target
DropTargetDir PROC pThis:DWORD, x:DWORD, y:DWORD
    LOCAL pt:POINT
    mov eax, x
    mov pt.x, eax
    mov eax, y
    mov pt.y, eax
    mov eax, pThis
    .IF [eax].DROPTARGET.bTree != 0
        invoke ScreenToClient, g_hTree, addr pt
        invoke UiTreeNodeAt, pt.x, pt.y, FALSE
        .IF eax == 0
            mov eax, g_pCurDir
        .ENDIF
        ret
    .ENDIF
    invoke ScreenToClient, g_hList, addr pt
    invoke UiListNodeAt, pt.x, pt.y
    .IF eax != 0
        test [eax].NODE.nflags, NF_DIR
        .IF !ZERO?
            ret
        .ENDIF
    .ENDIF
    mov eax, g_pCurDir
    ret
DropTargetDir ENDP

TgtDrop PROC USES esi ebx pThis:DWORD, pDataObj:DWORD, grfKeyState:DWORD, ptx:DWORD, pty:DWORD, pdwEffect:DWORD
    LOCAL pDir:DWORD
    LOCAL fmt:FORMATETC
    LOCAL stg:STGMEDIUM
    LOCAL hDrop:DWORD
    LOCAL n:DWORD
    LOCAL szFile[MAX_PATH]:WORD
    LOCAL moved:DWORD

    invoke TgtDragLeave, pThis
    invoke DropTargetDir, pThis, ptx, pty
    mov pDir, eax
    mov ecx, pdwEffect
    mov dword ptr [ecx], DROPEFFECT_NONE
    .IF eax == 0
        mov eax, S_OK
        ret
    .ENDIF

    .IF g_bInternalDrag != 0
        mov moved, 0
        xor ebx, ebx
        .WHILE ebx < g_nDragNodes
            mov esi, g_dragNodes[ebx * 4]
            invoke VfsMove, esi, pDir
            .IF eax != 0
                inc moved
            .ENDIF
            inc ebx
        .ENDW
        .IF moved != 0
            mov ecx, pdwEffect
            mov dword ptr [ecx], DROPEFFECT_MOVE
            invoke PostMessageW, g_hWnd, WM_COMMAND, IDM_REFRESH, 0
        .ENDIF
        mov eax, S_OK
        ret
    .ENDIF

    ; CF_HDROP from another application
    mov fmt.cfFormat, CF_HDROP
    mov fmt.wPad, 0
    mov fmt.ptd, 0
    mov fmt.dwAspect, DVASPECT_CONTENT
    mov fmt.lindex, -1
    mov fmt.tymed, TYMED_HGLOBAL
    mov eax, pDataObj
    mov ecx, [eax]
    lea edx, stg
    push edx
    lea edx, fmt
    push edx
    push eax
    call dword ptr [ecx + 3 * 4]            ; IDataObject::GetData
    .IF eax != S_OK
        mov eax, S_OK
        ret
    .ENDIF
    invoke GlobalLock, stg.hGlobal
    mov hDrop, eax
    .IF eax != 0
        invoke JobPathsReset
        invoke DragQueryFileW, hDrop, -1, NULL, 0
        mov n, eax
        xor ebx, ebx
        .WHILE ebx < n
            invoke DragQueryFileW, hDrop, ebx, addr szFile, MAX_PATH
            .IF eax != 0
                invoke JobPathsAdd, addr szFile
            .ENDIF
            inc ebx
        .ENDW
        invoke GlobalUnlock, stg.hGlobal
        mov ecx, pdwEffect
        mov dword ptr [ecx], DROPEFFECT_COPY
        mov eax, pDir
        mov g_pCurDir, eax
        invoke JobStartAdd, pDir            ; copies on the worker thread with progress
    .ENDIF
    invoke ReleaseStgMedium, addr stg
    mov eax, S_OK
    ret
TgtDrop ENDP

; ---------------------------------------------------------------------------
; Setup
; ---------------------------------------------------------------------------
DndInit PROC
    .IF g_bOleInit == 0
        invoke OleInitialize, NULL
        mov g_bOleInit, TRUE
    .ENDIF
    .IF g_bRegistered == 0 && g_hList != 0 && g_hTree != 0
        push g_hList
        pop g_tgtList.hwnd
        push g_hTree
        pop g_tgtTree.hwnd
        invoke RegisterDragDrop, g_hList, offset g_tgtList
        invoke RegisterDragDrop, g_hTree, offset g_tgtTree
        mov g_bRegistered, TRUE
    .ENDIF
    ret
DndInit ENDP

DndShutdown PROC
    .IF g_bRegistered != 0
        invoke RevokeDragDrop, g_hList
        invoke RevokeDragDrop, g_hTree
        mov g_bRegistered, 0
    .ENDIF
    .IF g_bOleInit != 0
        invoke OleUninitialize
        mov g_bOleInit, 0
    .ENDIF
    ret
DndShutdown ENDP

; ---------------------------------------------------------------------------
; Starting a drag from our own list / tree
; ---------------------------------------------------------------------------
CollectCb PROC pNode:DWORD, lParam:DWORD
    mov eax, g_nDragNodes
    .IF eax < DRAG_MAX
        mov ecx, pNode
        mov g_dragNodes[eax * 4], ecx
        inc g_nDragNodes
    .ENDIF
    ret
CollectCb ENDP

; Extract the dragged nodes to a fresh temp directory and build an HDROP listing them
BuildHDrop PROC USES esi edi ebx
    LOCAL cbList:DWORD
    LOCAL hGlobal:DWORD
    LOCAL szPath[MAX_PATH]:WORD
    LOCAL szTemp[MAX_PATH]:WORD

    invoke GetTempPathW, MAX_PATH, addr szTemp
    invoke GetTickCount
    invoke wsprintfW, offset g_szTempDir, offset szTempFmt, addr szTemp, eax
    ; create "...\FoxImg" then "...\FoxImg\<tick>"
    invoke lstrcpynW, addr szPath, offset g_szTempDir, MAX_PATH
    mov esi, offset g_szTempDir
    lea edi, szPath
    invoke lstrlenW, offset g_szTempDir
    lea ecx, [edi + eax * 2]
    .WHILE ecx > edi && word ptr [ecx] != '\'
        sub ecx, 2
    .ENDW
    mov word ptr [ecx], 0
    invoke CreateDirectoryW, addr szPath, NULL
    invoke CreateDirectoryW, offset g_szTempDir, NULL

    ; size of the path list
    mov cbList, 0
    xor ebx, ebx
    .WHILE ebx < g_nDragNodes
        mov esi, g_dragNodes[ebx * 4]
        invoke VfsExtract, esi, offset g_szTempDir
        invoke lstrlenW, offset g_szTempDir
        add cbList, eax
        lea eax, [esi].NODE.szName
        invoke lstrlenW, eax
        add cbList, eax
        add cbList, 2                       ; '\' + NUL
        inc ebx
    .ENDW
    inc cbList                              ; final NUL
    mov eax, cbList
    shl eax, 1
    add eax, sizeof DROPFILES
    invoke GlobalAlloc, GMEM_MOVEABLE or GMEM_ZEROINIT, eax
    .IF eax == 0
        ret
    .ENDIF
    mov hGlobal, eax
    invoke GlobalLock, eax
    mov edi, eax
    mov [edi].DROPFILES.pFiles, sizeof DROPFILES
    mov [edi].DROPFILES.fWide, TRUE
    add edi, sizeof DROPFILES
    xor ebx, ebx
    .WHILE ebx < g_nDragNodes
        mov esi, g_dragNodes[ebx * 4]
        lea eax, [esi].NODE.szName
        invoke wsprintfW, edi, offset szJoinFmt, offset g_szTempDir, eax
        lea edi, [edi + eax * 2 + 2]
        inc ebx
    .ENDW
    mov word ptr [edi], 0
    invoke GlobalUnlock, hGlobal
    mov eax, hGlobal
    ret
BuildHDrop ENDP

DndBeginDrag PROC USES esi bFromTree:DWORD
    LOCAL pdo:DWORD
    LOCAL fmt:FORMATETC
    LOCAL stg:STGMEDIUM
    LOCAL effect:DWORD
    LOCAL hGlobal:DWORD

    mov g_nDragNodes, 0
    .IF bFromTree != 0
        mov eax, g_pCurDir
        .IF eax == 0 || eax == g_pRootNode
            ret
        .ENDIF
        mov g_dragNodes[0], eax
        mov g_nDragNodes, 1
    .ELSE
        invoke UiForEachSelected, offset CollectCb, 0
    .ENDIF
    .IF g_nDragNodes == 0
        ret
    .ENDIF

    invoke BuildHDrop
    .IF eax == 0
        ret
    .ENDIF
    mov hGlobal, eax

    mov pdo, 0
    invoke SHCreateDataObject, NULL, 0, NULL, NULL, offset IID_IDataObject, addr pdo
    .IF eax != S_OK || pdo == 0
        invoke GlobalFree, hGlobal
        ret
    .ENDIF
    mov fmt.cfFormat, CF_HDROP
    mov fmt.wPad, 0
    mov fmt.ptd, 0
    mov fmt.dwAspect, DVASPECT_CONTENT
    mov fmt.lindex, -1
    mov fmt.tymed, TYMED_HGLOBAL
    mov stg.tymed, TYMED_HGLOBAL
    mov eax, hGlobal
    mov stg.hGlobal, eax
    mov stg.pUnkForRelease, 0
    mov eax, pdo
    mov ecx, [eax]
    push TRUE
    lea edx, stg
    push edx
    lea edx, fmt
    push edx
    push eax
    call dword ptr [ecx + 7 * 4]            ; IDataObject::SetData (takes ownership)

    mov g_bInternalDrag, TRUE
    mov effect, 0
    invoke DoDragDrop, pdo, offset g_dropSource, DROPEFFECT_COPY or DROPEFFECT_MOVE, addr effect
    mov g_bInternalDrag, FALSE

    mov eax, pdo
    mov ecx, [eax]
    push eax
    call dword ptr [ecx + 2 * 4]            ; Release
    ret
DndBeginDrag ENDP

END
