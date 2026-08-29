; FoxImg - explorer UI: tree of directories, list of entries, status bar, editing gestures
include foximg.inc

TREE_WIDTH  equ 280         ; at 96 DPI
PREVIEW_PCT equ 38          ; percent of the non-tree width given to the preview pane
NUM_COLUMNS equ 5
STATUS_MAX  equ 256

.data
g_hTree     dd 0
g_hList     dd 0
g_hStatus   dd 0
g_hFont     dd 0
g_nItems    dd 0
g_dpi       dd 96
g_pCurDir   dd 0
g_bHavePath dd 0
g_pCtxNode  dd 0            ; node under the context menu (list) or 0
g_bCtxTree  dd 0            ; context menu came from the tree
g_colWidths dd 280, 100, 90, 130, 80    ; at 96 DPI, matches AddColumn order

WSTR szTreeClass, <SysTreeView32>
WSTR szListClass, <SysListView32>
WSTR szStatusClass, <msctls_statusbar32>
WSTR szColName, <Name>
WSTR szColSize, <Size>
WSTR szColType, <Type>
WSTR szColDate, <Modified>
WSTR szColLBA, <LBA>
WSTR szReady, <Ready>
WSTR szDirTag, <DIR>
WSTR szDash, <->
WSTR szTypeFolder, <File Folder>
WSTR szTypeFile, <File>
WSTR szUntitled, <Untitled>
WSTR szMenuOpen, <Open>
WSTR szMenuExtract, <Extract...>
WSTR szMenuNewFolder, <New Folder>
WSTR szMenuNewFile, <New File>
WSTR szMenuAddFiles, <Add Files...>
WSTR szMenuRename, <Rename>
WSTR szMenuDelete, <Delete>
WSTR szMenuExportAll, <Export All To Folder...>

szStatusFmt dw '%','u',' ','i','t','e','m','s',0
szUintFmt   dw '%','u',0
szMBFmt     dw '%','u',' ','M','B',0
szDateFmt   dw '%','0','4','u','-','%','0','2','u','-','%','0','2','u',' ','%','0','2','u',':','%','0','2','u',0
szTitleFmt  dw 'F','o','x','I','m','g',' ','-',' ','%','s',0
szTitleModFmt dw 'F','o','x','I','m','g',' ','-',' ','%','s',' ','*',0

.data?
g_szStatus  dw STATUS_MAX dup(?)            ; part 0: items / last action
g_szStatusBoot dw STATUS_MAX dup(?)         ; part 1: El Torito summary
g_szStatusFmt dw STATUS_MAX dup(?)          ; part 2: format and size
g_szPath    dw MAX_PATH dup(?)
g_szTitle   dw MAX_PATH + 16 dup(?)

.data
g_statusParts dd 0, 0, -1
WSTR szNewImageFmt, <New image>
szSizeFmt   dw '%','s',' ',' ','%','u',' ','K','B',' ','(','%','u',' ','b','l','o','c','k','s',')',0

.code

UiAddDirChildren PROTO :DWORD, :DWORD

; ---------------------------------------------------------------------------
; Status bar (three parts) / title
; ---------------------------------------------------------------------------
UiStatusText PROC part:DWORD
    mov eax, part
    .IF eax == 1
        mov eax, offset g_szStatusBoot
    .ELSEIF eax == 2
        mov eax, offset g_szStatusFmt
    .ELSE
        mov eax, offset g_szStatus
    .ENDIF
    ret
UiStatusText ENDP

UiSetStatusPart PROC part:DWORD, pszText:DWORD
    LOCAL pBuf:DWORD
    invoke UiStatusText, part
    mov pBuf, eax
    .IF eax != pszText
        invoke lstrcpynW, pBuf, pszText, STATUS_MAX
    .ENDIF
    mov eax, part
    .IF g_bDark != 0
        or eax, SBT_OWNERDRAW
    .ENDIF
    invoke SendMessageW, g_hStatus, SB_SETTEXTW, eax, pBuf
    ret
UiSetStatusPart ENDP

UiSetStatus PROC pszText:DWORD
    invoke UiSetStatusPart, 0, pszText
    ret
UiSetStatus ENDP

UiSetStatusParts PROC
    invoke Scale, 180
    mov g_statusParts[0], eax
    invoke Scale, 640
    add eax, g_statusParts[0]
    mov g_statusParts[4], eax
    mov g_statusParts[8], -1
    invoke SendMessageW, g_hStatus, SB_SETPARTS, STATUS_PARTS, offset g_statusParts
    ret
UiSetStatusParts ENDP

; Format + size and boot summary parts
UiUpdateInfo PROC
    LOCAL szFmt[64]:WORD
    LOCAL szText[STATUS_MAX]:WORD
    .IF g_pView == 0
        invoke lstrcpyW, addr szText, offset szNewImageFmt
    .ELSE
        invoke IsoFormatName, addr szFmt
        mov edx, g_cbFileHi
        mov eax, g_cbFileLo
        shrd eax, edx, 10                   ; 64-bit size in KB (fits: 4 TB limit)
        invoke wsprintfW, addr szText, offset szSizeFmt, addr szFmt, eax, g_nSectors
    .ENDIF
    invoke UiSetStatusPart, 2, addr szText
    invoke BootSummary, addr szText
    invoke UiSetStatusPart, 1, addr szText
    ret
UiUpdateInfo ENDP

UiUpdateTitle PROC
    mov eax, offset szUntitled
    .IF g_bHavePath != 0
        mov eax, offset g_szPath
    .ENDIF
    mov ecx, offset szTitleFmt
    .IF g_bModified != 0
        mov ecx, offset szTitleModFmt
    .ENDIF
    invoke wsprintfW, offset g_szTitle, ecx, eax
    invoke SetWindowTextW, g_hWnd, offset g_szTitle
    ret
UiUpdateTitle ENDP

; ---------------------------------------------------------------------------
; DPI
; ---------------------------------------------------------------------------
Scale PROC value:DWORD
    invoke MulDiv, value, g_dpi, 96
    ret
Scale ENDP

UiUpdateDpi PROC USES ebx hParent:DWORD, dpi:DWORD
    LOCAL ncm:NONCLIENTMETRICSW

    mov eax, dpi
    mov g_dpi, eax

    mov ncm.cbSize, sizeof NONCLIENTMETRICSW
    invoke SystemParametersInfoForDpi, SPI_GETNONCLIENTMETRICS, sizeof NONCLIENTMETRICSW, addr ncm, 0, dpi
    .IF eax != 0
        invoke CreateFontIndirectW, addr ncm.lfMessageFont
        .IF eax != 0
            .IF g_hFont != 0
                push eax
                invoke DeleteObject, g_hFont
                pop eax
            .ENDIF
            mov g_hFont, eax
        .ENDIF
    .ENDIF
    .IF g_hFont == 0
        invoke GetStockObject, DEFAULT_GUI_FONT
        mov g_hFont, eax
    .ENDIF

    invoke SendMessageW, g_hTree, WM_SETFONT, g_hFont, TRUE
    invoke SendMessageW, g_hList, WM_SETFONT, g_hFont, TRUE
    invoke SendMessageW, g_hStatus, WM_SETFONT, g_hFont, TRUE
    invoke UiSetStatusParts
    invoke PreviewSetFont

    xor ebx, ebx
    .WHILE ebx < NUM_COLUMNS
        invoke Scale, g_colWidths[ebx * 4]
        invoke SendMessageW, g_hList, LVM_SETCOLUMNWIDTH, ebx, eax
        inc ebx
    .ENDW

    invoke UiLayout, hParent
    ret
UiUpdateDpi ENDP

; ---------------------------------------------------------------------------
; Creation / layout
; ---------------------------------------------------------------------------
AddColumn PROC iCol:DWORD, pszText:DWORD, cxCol:DWORD, fmtCol:DWORD
    LOCAL lvc:LVCOLUMNW
    mov lvc.imask, LVCF_FMT or LVCF_WIDTH or LVCF_TEXT or LVCF_SUBITEM
    push fmtCol
    pop lvc.fmt
    push cxCol
    pop lvc.cxWidth
    push pszText
    pop lvc.pszText
    push iCol
    pop lvc.iSubItem
    invoke SendMessageW, g_hList, LVM_INSERTCOLUMNW, iCol, addr lvc
    ret
AddColumn ENDP

UiCreateControls PROC hParent:DWORD
    invoke CreateWindowExW, WS_EX_CLIENTEDGE, offset szTreeClass, NULL, WS_CHILD or WS_VISIBLE or TVS_HASLINES or TVS_LINESATROOT or TVS_HASBUTTONS or TVS_SHOWSELALWAYS, 0, 0, 0, 0, hParent, IDC_TREE, g_hInst, NULL
    mov g_hTree, eax

    invoke CreateWindowExW, WS_EX_CLIENTEDGE, offset szListClass, NULL, WS_CHILD or WS_VISIBLE or LVS_REPORT or LVS_SHOWSELALWAYS or LVS_EDITLABELS, 0, 0, 0, 0, hParent, IDC_LIST, g_hInst, NULL
    mov g_hList, eax
    invoke SendMessageW, g_hList, LVM_SETEXTENDEDLISTVIEWSTYLE, LVS_EX_FULLROWSELECT, LVS_EX_FULLROWSELECT

    invoke AddColumn, 0, offset szColName, 0, LVCFMT_LEFT
    invoke AddColumn, 1, offset szColSize, 0, LVCFMT_RIGHT
    invoke AddColumn, 2, offset szColType, 0, LVCFMT_LEFT
    invoke AddColumn, 3, offset szColDate, 0, LVCFMT_LEFT
    invoke AddColumn, 4, offset szColLBA, 0, LVCFMT_RIGHT

    invoke CreateWindowExW, 0, offset szStatusClass, NULL, WS_CHILD or WS_VISIBLE or WS_CLIPSIBLINGS or SBARS_SIZEGRIP, 0, 0, 0, 0, hParent, IDC_STATUS, g_hInst, NULL
    mov g_hStatus, eax
    invoke UiSetStatus, offset szReady

    invoke PreviewInit, hParent

    invoke GetDpiForWindow, hParent
    invoke UiUpdateDpi, hParent, eax
    ret
UiCreateControls ENDP

UiLayout PROC hParent:DWORD
    LOCAL rc:RECT
    LOCAL rcStatus:RECT
    LOCAL cyStatus:DWORD
    LOCAL cxTree:DWORD
    LOCAL cxList:DWORD
    LOCAL cxPreview:DWORD

    invoke SendMessageW, g_hStatus, WM_SIZE, 0, 0
    invoke GetWindowRect, g_hStatus, addr rcStatus
    mov eax, rcStatus.bottom
    sub eax, rcStatus.top
    mov cyStatus, eax

    invoke GetClientRect, hParent, addr rc
    mov eax, rc.bottom
    sub eax, cyStatus
    mov rc.bottom, eax

    invoke Scale, TREE_WIDTH
    mov cxTree, eax
    invoke MoveWindow, g_hTree, 0, 0, cxTree, rc.bottom, TRUE

    mov eax, rc.right
    sub eax, cxTree
    mov cxList, eax
    mov cxPreview, 0
    .IF g_bPreview != 0
        invoke MulDiv, cxList, PREVIEW_PCT, 100
        mov cxPreview, eax
        sub cxList, eax
    .ENDIF
    invoke MoveWindow, g_hList, cxTree, 0, cxList, rc.bottom, TRUE
    mov eax, cxTree
    add eax, cxList
    invoke PreviewLayout, eax, 0, cxPreview, rc.bottom
    ret
UiLayout ENDP

; ---------------------------------------------------------------------------
; Tree (directories only)
; ---------------------------------------------------------------------------
UiAddDirChildren PROC USES esi hParent:DWORD, pDirNode:DWORD
    LOCAL tvi:TVINSERTSTRUCTW
    mov esi, pDirNode
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        test [esi].NODE.nflags, NF_DIR
        .IF !ZERO?
            push hParent
            pop tvi.hParent
            mov tvi.hInsertAfter, TVI_LAST
            mov tvi.item.imask, TVIF_TEXT or TVIF_PARAM
            lea eax, [esi].NODE.szName
            mov tvi.item.pszText, eax
            mov tvi.item.lParam, esi
            invoke SendMessageW, g_hTree, TVM_INSERTITEMW, 0, addr tvi
            mov [esi].NODE.hTree, eax
            invoke UiAddDirChildren, eax, esi
        .ENDIF
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    ret
UiAddDirChildren ENDP

UiRefreshTree PROC USES esi
    LOCAL tvi:TVINSERTSTRUCTW
    LOCAL hRoot:DWORD

    invoke SendMessageW, g_hTree, WM_SETREDRAW, FALSE, 0
    invoke SendMessageW, g_hTree, TVM_DELETEITEM, 0, TVI_ROOT
    mov esi, g_pRootNode
    .IF esi == 0
        invoke SendMessageW, g_hTree, WM_SETREDRAW, TRUE, 0
        invoke UiFillListNode, 0
        ret
    .ENDIF

    mov tvi.hParent, TVI_ROOT
    mov tvi.hInsertAfter, TVI_LAST
    mov tvi.item.imask, TVIF_TEXT or TVIF_PARAM
    lea eax, [esi].NODE.szName
    mov tvi.item.pszText, eax
    mov tvi.item.lParam, esi
    invoke SendMessageW, g_hTree, TVM_INSERTITEMW, 0, addr tvi
    mov hRoot, eax
    mov [esi].NODE.hTree, eax
    invoke UiAddDirChildren, hRoot, esi
    invoke SendMessageW, g_hTree, TVM_EXPAND, TVE_EXPAND, hRoot
    invoke SendMessageW, g_hTree, WM_SETREDRAW, TRUE, 0
    invoke InvalidateRect, g_hTree, NULL, TRUE

    mov eax, g_pCurDir
    .IF eax == 0
        mov eax, esi
    .ENDIF
    invoke UiSelectDir, eax
    ret
UiRefreshTree ENDP

UiSelectDir PROC pDirNode:DWORD
    mov eax, pDirNode
    .IF eax == 0
        ret
    .ENDIF
    mov eax, [eax].NODE.hTree
    .IF eax != 0
        invoke SendMessageW, g_hTree, TVM_SELECTITEM, TVGN_CARET, eax    ; TVN_SELCHANGED -> UiFillListNode
    .ELSE
        invoke UiFillListNode, pDirNode
    .ENDIF
    ret
UiSelectDir ENDP

UiCurrentDir PROC
    mov eax, g_pCurDir
    ret
UiCurrentDir ENDP

; ---------------------------------------------------------------------------
; List
; ---------------------------------------------------------------------------
SetSubItem PROC iItem:DWORD, iSub:DWORD, pszText:DWORD
    LOCAL lvi:LVITEMW
    mov lvi.imask, LVIF_TEXT
    push iItem
    pop lvi.iItem
    push iSub
    pop lvi.iSubItem
    push pszText
    pop lvi.pszText
    invoke SendMessageW, g_hList, LVM_SETITEMTEXTW, iItem, addr lvi
    ret
SetSubItem ENDP

NodeDate PROC USES esi pNode:DWORD, pszBuf:DWORD
    mov esi, pNode
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
    push offset szDateFmt
    push pszBuf
    call wsprintfW
    add esp, 7 * 4
    ret
NodeDate ENDP

UiInsertListItem PROC USES esi pNode:DWORD
    LOCAL lvi:LVITEMW
    LOCAL szBuf[32]:WORD
    LOCAL iItem:DWORD

    mov esi, pNode
    mov lvi.imask, LVIF_TEXT or LVIF_PARAM
    push g_nItems
    pop lvi.iItem
    mov lvi.iSubItem, 0
    lea eax, [esi].NODE.szName
    mov lvi.pszText, eax
    mov lvi.lParam, esi
    invoke SendMessageW, g_hList, LVM_INSERTITEMW, 0, addr lvi
    mov iItem, eax

    test [esi].NODE.nflags, NF_DIR
    .IF !ZERO?
        invoke SetSubItem, iItem, 1, offset szDirTag
        invoke SetSubItem, iItem, 2, offset szTypeFolder
    .ELSE
        .IF [esi].NODE.dataSizeHi != 0
            mov eax, [esi].NODE.dataSize
            mov edx, [esi].NODE.dataSizeHi
            shrd eax, edx, 20
            invoke wsprintfW, addr szBuf, offset szMBFmt, eax
        .ELSE
            invoke wsprintfW, addr szBuf, offset szUintFmt, [esi].NODE.dataSize
        .ENDIF
        invoke SetSubItem, iItem, 1, addr szBuf
        invoke SetSubItem, iItem, 2, offset szTypeFile
    .ENDIF

    invoke NodeDate, esi, addr szBuf
    invoke SetSubItem, iItem, 3, addr szBuf

    test [esi].NODE.nflags, NF_ISO
    .IF !ZERO?
        invoke wsprintfW, addr szBuf, offset szUintFmt, [esi].NODE.isoExtent
        invoke SetSubItem, iItem, 4, addr szBuf
    .ELSE
        invoke SetSubItem, iItem, 4, offset szDash
    .ENDIF
    inc g_nItems
    ret
UiInsertListItem ENDP

UiFillListNode PROC USES esi pDirNode:DWORD
    LOCAL szBuf[32]:WORD

    mov eax, pDirNode
    mov g_pCurDir, eax
    invoke SendMessageW, g_hList, WM_SETREDRAW, FALSE, 0
    invoke SendMessageW, g_hList, LVM_DELETEALLITEMS, 0, 0
    mov g_nItems, 0
    mov esi, pDirNode
    .IF esi != 0
        mov esi, [esi].NODE.pFirstChild
        .WHILE esi != 0
            invoke UiInsertListItem, esi
            mov esi, [esi].NODE.pNextSibling
        .ENDW
    .ENDIF
    invoke SendMessageW, g_hList, WM_SETREDRAW, TRUE, 0
    invoke InvalidateRect, g_hList, NULL, TRUE

    invoke wsprintfW, addr szBuf, offset szStatusFmt, g_nItems
    invoke UiSetStatus, addr szBuf
    invoke PreviewShow, 0
    ret
UiFillListNode ENDP

; Compatibility shim for older callers
UiFillList PROC pDirRec:DWORD
    invoke UiFillListNode, g_pCurDir
    ret
UiFillList ENDP

UiFillTree PROC
    invoke UiRefreshTree
    ret
UiFillTree ENDP

UiListItemNode PROC iItem:DWORD
    LOCAL lvi:LVITEMW
    mov lvi.imask, LVIF_PARAM
    push iItem
    pop lvi.iItem
    mov lvi.iSubItem, 0
    mov lvi.lParam, 0
    invoke SendMessageW, g_hList, LVM_GETITEMW, 0, addr lvi
    mov eax, lvi.lParam
    ret
UiListItemNode ENDP

UiSelectedNode PROC
    invoke SendMessageW, g_hList, LVM_GETNEXTITEM, -1, LVNI_SELECTED
    .IF eax == -1
        xor eax, eax
        ret
    .ENDIF
    invoke UiListItemNode, eax
    ret
UiSelectedNode ENDP

UiForEachSelected PROC USES ebx pfn:DWORD, lParam:DWORD
    mov ebx, -1
    .WHILE TRUE
        invoke SendMessageW, g_hList, LVM_GETNEXTITEM, ebx, LVNI_SELECTED
        .BREAK .IF eax == -1
        mov ebx, eax
        invoke UiListItemNode, ebx
        push lParam
        push eax
        call pfn
    .ENDW
    ret
UiForEachSelected ENDP

UiFindItem PROC USES ebx pNode:DWORD
    invoke SendMessageW, g_hList, LVM_GETITEMCOUNT, 0, 0
    mov ecx, eax
    xor ebx, ebx
    .WHILE ebx < ecx
        push ecx
        invoke UiListItemNode, ebx
        pop ecx
        .IF eax == pNode
            mov eax, ebx
            ret
        .ENDIF
        inc ebx
    .ENDW
    mov eax, -1
    ret
UiFindItem ENDP

UiBeginRename PROC pNode:DWORD
    LOCAL lvi:LVITEMW
    LOCAL iItem:DWORD
    invoke UiFindItem, pNode
    .IF eax == -1
        ret
    .ENDIF
    mov iItem, eax
    invoke SendMessageW, g_hList, LVM_ENSUREVISIBLE, iItem, FALSE
    mov lvi.imask, LVIF_STATE
    mov lvi.state, LVIS_SELECTED
    mov lvi.stateMask, LVIS_SELECTED
    invoke SendMessageW, g_hList, LVM_SETITEMSTATE, iItem, addr lvi
    invoke SetFocus, g_hList
    invoke SendMessageW, g_hList, LVM_EDITLABELW, iItem, 0
    ret
UiBeginRename ENDP

; ---------------------------------------------------------------------------
; Notifications from tree / list (WM_NOTIFY)
; ---------------------------------------------------------------------------
UiValidName PROC USES esi pszName:DWORD
    mov esi, pszName
    .IF word ptr [esi] == 0
        xor eax, eax
        ret
    .ENDIF
    .WHILE word ptr [esi] != 0
        movzx eax, word ptr [esi]
        .IF eax == '\' || eax == '/' || eax == ':' || eax == '*' || eax == '?' || eax == '"' || eax == '<' || eax == '>' || eax == '|'
            xor eax, eax
            ret
        .ENDIF
        add esi, 2
    .ENDW
    mov eax, TRUE
    ret
UiValidName ENDP

UiOnNotify PROC USES esi edi pNMHDR:DWORD
    mov esi, pNMHDR
    mov ecx, [esi].NMHDR.code
    mov edx, [esi].NMHDR.hwndFrom

    .IF edx == g_hTree
        .IF ecx == TVN_SELCHANGEDW
            mov eax, [esi].NMTREEVIEWW.itemNew.lParam
            .IF eax != 0
                invoke UiFillListNode, eax
            .ENDIF
        .ELSEIF ecx == TVN_BEGINDRAGW && g_jobBusy == 0
            mov eax, [esi].NMTREEVIEWW.itemNew.hItem
            invoke SendMessageW, g_hTree, TVM_SELECTITEM, TVGN_CARET, eax
            invoke DndBeginDrag, TRUE
        .ENDIF
        xor eax, eax
        ret
    .ENDIF

    .IF edx != g_hList
        xor eax, eax
        ret
    .ENDIF

    .IF ecx == LVN_BEGINDRAG
        .IF g_jobBusy == 0
            invoke DndBeginDrag, FALSE
        .ENDIF
    .ELSEIF ecx == LVN_BEGINLABELEDITW && g_jobBusy != 0
        mov eax, TRUE                       ; refuse edits while a job owns the model
        ret
    .ELSEIF ecx == NM_DBLCLK
        invoke AppCommand, IDM_OPENDIR
    .ELSEIF ecx == LVN_ITEMCHANGED
        mov eax, [esi].NMLISTVIEW.uNewState
        and eax, LVIS_SELECTED
        mov ecx, [esi].NMLISTVIEW.uOldState
        and ecx, LVIS_SELECTED
        .IF eax != 0 && ecx == 0
            invoke PreviewShow, [esi].NMLISTVIEW.lParam
        .ENDIF
    .ELSEIF ecx == LVN_KEYDOWN
        movzx eax, [esi].NMLVKEYDOWN.wVKey
        .IF eax == VK_DELETE
            invoke AppCommand, IDM_DELETE
        .ELSEIF eax == VK_F2
            invoke AppCommand, IDM_RENAME
        .ELSEIF eax == VK_RETURN
            invoke AppCommand, IDM_OPENDIR
        .ENDIF
    .ELSEIF ecx == LVN_BEGINLABELEDITW
        xor eax, eax                        ; allow
        ret
    .ELSEIF ecx == LVN_ENDLABELEDITW
        mov edi, [esi].NMLVDISPINFOW.item.pszText
        .IF edi == 0
            xor eax, eax                    ; cancelled
            ret
        .ENDIF
        invoke UiValidName, edi
        .IF eax == 0
            xor eax, eax
            ret
        .ENDIF
        mov eax, [esi].NMLVDISPINFOW.item.lParam
        .IF eax == 0
            xor eax, eax
            ret
        .ENDIF
        push eax
        mov eax, [eax].NODE.pParent
        invoke VfsFindChild, eax, edi
        pop ecx
        .IF eax != 0 && eax != ecx
            xor eax, eax                    ; duplicate name in this directory
            ret
        .ENDIF
        invoke VfsRename, ecx, edi
        invoke PostMessageW, g_hWnd, WM_COMMAND, IDM_REFRESH, 0
        mov eax, TRUE
        ret
    .ENDIF
    xor eax, eax
    ret
UiOnNotify ENDP

; ---------------------------------------------------------------------------
; Context menus
; ---------------------------------------------------------------------------
UiCtxDir PROC
    mov eax, g_pCtxNode
    .IF eax != 0
        test [eax].NODE.nflags, NF_DIR
        .IF !ZERO?
            ret
        .ENDIF
    .ENDIF
    mov eax, g_pCurDir
    ret
UiCtxDir ENDP

UiCtxIsTree PROC
    mov eax, g_bCtxTree
    ret
UiCtxIsTree ENDP

UiContextMenu PROC USES ebx hwndFrom:DWORD, xScreen:DWORD, yScreen:DWORD
    LOCAL pt:POINT
    LOCAL lvht:LVHITTESTINFO
    LOCAL tvht:TVHITTESTINFO
    LOCAL lvi:LVITEMW
    LOCAL hMenu:DWORD
    LOCAL cmd:DWORD

    mov g_pCtxNode, 0
    mov g_bCtxTree, 0
    mov eax, hwndFrom
    .IF eax != g_hList && eax != g_hTree
        ret
    .ENDIF

    ; keyboard-invoked (-1,-1): use the cursor position
    .IF xScreen == -1 && yScreen == -1
        invoke GetCursorPos, addr pt
        mov eax, pt.x
        mov xScreen, eax
        mov eax, pt.y
        mov yScreen, eax
    .ENDIF
    mov eax, xScreen
    mov pt.x, eax
    mov eax, yScreen
    mov pt.y, eax
    invoke ScreenToClient, hwndFrom, addr pt

    invoke CreatePopupMenu
    mov hMenu, eax

    mov eax, hwndFrom
    .IF eax == g_hList
        mov eax, pt.x
        mov lvht.pt.x, eax
        mov eax, pt.y
        mov lvht.pt.y, eax
        invoke SendMessageW, g_hList, LVM_HITTEST, 0, addr lvht
        .IF eax != -1
            mov ebx, eax
            invoke UiListItemNode, ebx
            mov g_pCtxNode, eax
            ; make sure the clicked item is part of the selection
            mov lvi.imask, LVIF_STATE
            mov lvi.stateMask, LVIS_SELECTED
            mov lvi.state, 0
            push ebx
            pop lvi.iItem
            invoke SendMessageW, g_hList, LVM_GETITEMW, 0, addr lvi
            .IF !(lvi.state & LVIS_SELECTED)
                mov lvi.state, 0
                invoke SendMessageW, g_hList, LVM_SETITEMSTATE, -1, addr lvi
                mov lvi.state, LVIS_SELECTED
                invoke SendMessageW, g_hList, LVM_SETITEMSTATE, ebx, addr lvi
            .ENDIF
            mov eax, g_pCtxNode
            test [eax].NODE.nflags, NF_DIR
            .IF !ZERO?
                invoke AppendMenuW, hMenu, MF_STRING, IDM_OPENDIR, offset szMenuOpen
            .ENDIF
            invoke AppendMenuW, hMenu, MF_STRING, IDM_EXTRACT, offset szMenuExtract
            invoke AppendMenuW, hMenu, MF_SEPARATOR, 0, NULL
            invoke AppendMenuW, hMenu, MF_STRING, IDM_RENAME, offset szMenuRename
            invoke AppendMenuW, hMenu, MF_STRING, IDM_DELETE, offset szMenuDelete
            invoke AppendMenuW, hMenu, MF_SEPARATOR, 0, NULL
        .ENDIF
        invoke AppendMenuW, hMenu, MF_STRING, IDM_NEWFOLDER, offset szMenuNewFolder
        invoke AppendMenuW, hMenu, MF_STRING, IDM_NEWFILE, offset szMenuNewFile
        invoke AppendMenuW, hMenu, MF_STRING, IDM_ADDFILES, offset szMenuAddFiles
        .IF g_pCtxNode == 0
            invoke AppendMenuW, hMenu, MF_SEPARATOR, 0, NULL
            invoke AppendMenuW, hMenu, MF_STRING, IDM_EXPORT_FOLDER, offset szMenuExportAll
        .ENDIF
    .ELSE
        mov g_bCtxTree, 1
        mov eax, pt.x
        mov tvht.pt.x, eax
        mov eax, pt.y
        mov tvht.pt.y, eax
        invoke SendMessageW, g_hTree, TVM_HITTEST, 0, addr tvht
        .IF eax != 0
            invoke SendMessageW, g_hTree, TVM_SELECTITEM, TVGN_CARET, eax
        .ENDIF
        invoke AppendMenuW, hMenu, MF_STRING, IDM_NEWFOLDER, offset szMenuNewFolder
        invoke AppendMenuW, hMenu, MF_STRING, IDM_NEWFILE, offset szMenuNewFile
        invoke AppendMenuW, hMenu, MF_STRING, IDM_ADDFILES, offset szMenuAddFiles
        invoke AppendMenuW, hMenu, MF_SEPARATOR, 0, NULL
        invoke AppendMenuW, hMenu, MF_STRING, IDM_EXTRACT, offset szMenuExtract
        mov eax, g_pCurDir
        .IF eax != 0 && eax != g_pRootNode
            invoke AppendMenuW, hMenu, MF_STRING, IDM_DELETE, offset szMenuDelete
        .ENDIF
    .ENDIF

    invoke TrackPopupMenu, hMenu, TPM_RETURNCMD or TPM_RIGHTBUTTON, xScreen, yScreen, 0, g_hWnd, NULL
    mov cmd, eax
    invoke DestroyMenu, hMenu
    .IF cmd != 0
        invoke AppCommand, cmd
    .ENDIF
    mov g_pCtxNode, 0
    mov g_bCtxTree, 0
    ret
UiContextMenu ENDP

; ---------------------------------------------------------------------------
; Hit testing for drop targets
; ---------------------------------------------------------------------------
UiListNodeAt PROC x:DWORD, y:DWORD
    LOCAL lvht:LVHITTESTINFO
    mov eax, x
    mov lvht.pt.x, eax
    mov eax, y
    mov lvht.pt.y, eax
    invoke SendMessageW, g_hList, LVM_HITTEST, 0, addr lvht
    .IF eax == -1
        xor eax, eax
        ret
    .ENDIF
    invoke UiListItemNode, eax
    ret
UiListNodeAt ENDP

; Directory node under a tree point; optionally moves the drop highlight there
UiTreeNodeAt PROC x:DWORD, y:DWORD, bHilite:DWORD
    LOCAL tvht:TVHITTESTINFO
    LOCAL tvi:TVITEMW
    mov eax, x
    mov tvht.pt.x, eax
    mov eax, y
    mov tvht.pt.y, eax
    invoke SendMessageW, g_hTree, TVM_HITTEST, 0, addr tvht
    .IF bHilite != 0
        invoke SendMessageW, g_hTree, TVM_SELECTITEM, TVGN_DROPHILITE, tvht.hItem
    .ENDIF
    .IF tvht.hItem == 0
        xor eax, eax
        ret
    .ENDIF
    mov tvi.imask, TVIF_PARAM or TVIF_HANDLE
    push tvht.hItem
    pop tvi.hItem
    mov tvi.lParam, 0
    invoke SendMessageW, g_hTree, TVM_GETITEMW, 0, addr tvi
    mov eax, tvi.lParam
    ret
UiTreeNodeAt ENDP

; ---------------------------------------------------------------------------
; Drag and drop from Explorer (WM_DROPFILES fallback): add into the current directory
; ---------------------------------------------------------------------------
UiOnDropFiles PROC USES ebx hDrop:DWORD
    LOCAL szFile[MAX_PATH]:WORD
    LOCAL n:DWORD
    .IF g_pCurDir == 0
        invoke DragFinish, hDrop
        ret
    .ENDIF
    invoke DragQueryFileW, hDrop, -1, NULL, 0
    mov n, eax
    xor ebx, ebx
    .WHILE ebx < n
        invoke DragQueryFileW, hDrop, ebx, addr szFile, MAX_PATH
        .IF eax != 0
            invoke VfsAddHostPath, g_pCurDir, addr szFile
        .ENDIF
        inc ebx
    .ENDW
    invoke DragFinish, hDrop
    invoke UiRefreshTree
    invoke UiUpdateTitle
    ret
UiOnDropFiles ENDP

END
