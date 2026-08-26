; FoxImg - explorer UI: tree of directories, list of entries, status bar
include foximg.inc

TREE_WIDTH  equ 280         ; at 96 DPI
NUM_COLUMNS equ 5
STATUS_MAX  equ 256

.data
g_hTree     dd 0
g_hList     dd 0
g_hStatus   dd 0
g_hFont     dd 0
g_nItems    dd 0
g_dpi       dd 96
g_colWidths dd 280, 100, 90, 130, 80    ; at 96 DPI, matches AddColumn order

.data?
g_szStatus  dw STATUS_MAX dup(?)

.data

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
WSTR szTypeFolder, <File Folder>
WSTR szTypeFile, <File>
WSTR szNoVolume, <(no volume name)>

szStatusFmt dw '%','u',' ','i','t','e','m','s',0
szUintFmt   dw '%','u',0

.code

; ---------------------------------------------------------------------------
; UiSetStatus - keeps a copy so the owner-draw path (dark mode) has stable text
; ---------------------------------------------------------------------------
UiSetStatus PROC pszText:DWORD
    mov eax, pszText
    .IF eax != offset g_szStatus
        invoke lstrcpynW, offset g_szStatus, pszText, STATUS_MAX
    .ENDIF
    .IF g_bDark != 0
        invoke SendMessageW, g_hStatus, SB_SETTEXTW, SBT_OWNERDRAW, offset g_szStatus
    .ELSE
        invoke SendMessageW, g_hStatus, SB_SETTEXTW, 0, offset g_szStatus
    .ENDIF
    ret
UiSetStatus ENDP

; ---------------------------------------------------------------------------
; Scale - MulDiv(value, dpi, 96)
; ---------------------------------------------------------------------------
Scale PROC value:DWORD
    invoke MulDiv, value, g_dpi, 96
    ret
Scale ENDP

; ---------------------------------------------------------------------------
; UiUpdateDpi - rebuild the UI font and scaled metrics for a new DPI
; ---------------------------------------------------------------------------
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
        invoke GetStockObject, DEFAULT_GUI_FONT      ; fallback, never deleted
        mov g_hFont, eax
    .ENDIF

    invoke SendMessageW, g_hTree, WM_SETFONT, g_hFont, TRUE
    invoke SendMessageW, g_hList, WM_SETFONT, g_hFont, TRUE
    invoke SendMessageW, g_hStatus, WM_SETFONT, g_hFont, TRUE

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
; AddColumn - helper for report-view columns
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

; ---------------------------------------------------------------------------
; UiCreateControls - called on WM_CREATE of the main window
; ---------------------------------------------------------------------------
UiCreateControls PROC hParent:DWORD
    invoke CreateWindowExW, WS_EX_CLIENTEDGE, offset szTreeClass, NULL, WS_CHILD or WS_VISIBLE or TVS_HASLINES or TVS_LINESATROOT or TVS_HASBUTTONS or TVS_SHOWSELALWAYS, 0, 0, 0, 0, hParent, IDC_TREE, g_hInst, NULL
    mov g_hTree, eax

    invoke CreateWindowExW, WS_EX_CLIENTEDGE, offset szListClass, NULL, WS_CHILD or WS_VISIBLE or LVS_REPORT or LVS_SHOWSELALWAYS, 0, 0, 0, 0, hParent, IDC_LIST, g_hInst, NULL
    mov g_hList, eax
    invoke SendMessageW, g_hList, LVM_SETEXTENDEDLISTVIEWSTYLE, LVS_EX_FULLROWSELECT, LVS_EX_FULLROWSELECT

    ; widths are placeholders; UiUpdateDpi scales g_colWidths into place
    invoke AddColumn, 0, offset szColName, 0, LVCFMT_LEFT
    invoke AddColumn, 1, offset szColSize, 0, LVCFMT_RIGHT
    invoke AddColumn, 2, offset szColType, 0, LVCFMT_LEFT
    invoke AddColumn, 3, offset szColDate, 0, LVCFMT_LEFT
    invoke AddColumn, 4, offset szColLBA, 0, LVCFMT_RIGHT

    invoke CreateWindowExW, 0, offset szStatusClass, NULL, WS_CHILD or WS_VISIBLE or SBARS_SIZEGRIP, 0, 0, 0, 0, hParent, IDC_STATUS, g_hInst, NULL
    mov g_hStatus, eax
    invoke UiSetStatus, offset szReady

    invoke GetDpiForWindow, hParent
    invoke UiUpdateDpi, hParent, eax
    ret
UiCreateControls ENDP

; ---------------------------------------------------------------------------
; UiLayout - called on WM_SIZE
; ---------------------------------------------------------------------------
UiLayout PROC hParent:DWORD
    LOCAL rc:RECT
    LOCAL rcStatus:RECT
    LOCAL cyStatus:DWORD
    LOCAL cxTree:DWORD

    invoke SendMessageW, g_hStatus, WM_SIZE, 0, 0     ; status bar positions itself
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
    invoke MoveWindow, g_hList, cxTree, 0, eax, rc.bottom, TRUE
    ret
UiLayout ENDP

; ---------------------------------------------------------------------------
; Tree population
; ---------------------------------------------------------------------------
UiAddDirChildren PROTO :DWORD, :DWORD

; Callback: insert every subdirectory under hParent (lParam) and recurse.
TreeEnumCb PROC USES esi edi ebx pRec:DWORD, lParam:DWORD
    LOCAL tvi:TVINSERTSTRUCTW
    LOCAL szName[256]:WORD

    mov esi, pRec
    test [esi].ISO_DIRREC.fileFlags, ISO_FLAG_DIRECTORY
    jz skip

    invoke IsoRecName, pRec, addr szName, 256

    push lParam
    pop tvi.hParent
    mov tvi.hInsertAfter, TVI_SORT
    mov tvi.item.imask, TVIF_TEXT or TVIF_PARAM
    lea eax, szName
    mov tvi.item.pszText, eax
    push pRec
    pop tvi.item.lParam
    invoke SendMessageW, g_hTree, TVM_INSERTITEMW, 0, addr tvi

    invoke UiAddDirChildren, eax, pRec

skip:
    mov eax, TRUE
    ret
TreeEnumCb ENDP

UiAddDirChildren PROC hParent:DWORD, pDirRec:DWORD
    invoke IsoEnumDir, pDirRec, offset TreeEnumCb, hParent
    ret
UiAddDirChildren ENDP

UiFillTree PROC
    LOCAL tvi:TVINSERTSTRUCTW
    LOCAL szName[64]:WORD
    LOCAL hRoot:DWORD

    invoke SendMessageW, g_hTree, WM_SETREDRAW, FALSE, 0
    invoke SendMessageW, g_hTree, TVM_DELETEITEM, 0, TVI_ROOT

    invoke IsoVolumeName, addr szName, 64
    .IF szName[0] == 0
        invoke lstrcpyW, addr szName, offset szNoVolume
    .ENDIF

    mov tvi.hParent, TVI_ROOT
    mov tvi.hInsertAfter, TVI_LAST
    mov tvi.item.imask, TVIF_TEXT or TVIF_PARAM
    lea eax, szName
    mov tvi.item.pszText, eax
    push g_pRoot
    pop tvi.item.lParam
    invoke SendMessageW, g_hTree, TVM_INSERTITEMW, 0, addr tvi
    mov hRoot, eax

    invoke UiAddDirChildren, hRoot, g_pRoot

    invoke SendMessageW, g_hTree, TVM_EXPAND, TVE_EXPAND, hRoot
    invoke SendMessageW, g_hTree, WM_SETREDRAW, TRUE, 0
    invoke InvalidateRect, g_hTree, NULL, TRUE
    invoke SendMessageW, g_hTree, TVM_SELECTITEM, TVGN_CARET, hRoot   ; fires TVN_SELCHANGED -> UiFillList
    ret
UiFillTree ENDP

; ---------------------------------------------------------------------------
; List population
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

ListEnumCb PROC USES esi edi ebx pRec:DWORD, lParam:DWORD
    LOCAL lvi:LVITEMW
    LOCAL szName[256]:WORD
    LOCAL szBuf[32]:WORD
    LOCAL iItem:DWORD

    invoke IsoRecName, pRec, addr szName, 256

    mov lvi.imask, LVIF_TEXT or LVIF_PARAM
    push g_nItems
    pop lvi.iItem
    mov lvi.iSubItem, 0
    lea eax, szName
    mov lvi.pszText, eax
    push pRec
    pop lvi.lParam
    invoke SendMessageW, g_hList, LVM_INSERTITEMW, 0, addr lvi
    mov iItem, eax

    mov esi, pRec
    test [esi].ISO_DIRREC.fileFlags, ISO_FLAG_DIRECTORY
    .IF !ZERO?
        invoke SetSubItem, iItem, 1, offset szDirTag
        invoke SetSubItem, iItem, 2, offset szTypeFolder
    .ELSE
        invoke wsprintfW, addr szBuf, offset szUintFmt, [esi].ISO_DIRREC.dataLenLE
        invoke SetSubItem, iItem, 1, addr szBuf
        invoke SetSubItem, iItem, 2, offset szTypeFile
    .ENDIF

    invoke IsoRecDate, pRec, addr szBuf
    invoke SetSubItem, iItem, 3, addr szBuf

    invoke wsprintfW, addr szBuf, offset szUintFmt, [esi].ISO_DIRREC.extentLE
    invoke SetSubItem, iItem, 4, addr szBuf

    inc g_nItems
    mov eax, TRUE
    ret
ListEnumCb ENDP

UiFillList PROC pDirRec:DWORD
    LOCAL szBuf[32]:WORD

    invoke SendMessageW, g_hList, WM_SETREDRAW, FALSE, 0
    invoke SendMessageW, g_hList, LVM_DELETEALLITEMS, 0, 0
    mov g_nItems, 0
    invoke IsoEnumDir, pDirRec, offset ListEnumCb, 0
    invoke SendMessageW, g_hList, WM_SETREDRAW, TRUE, 0
    invoke InvalidateRect, g_hList, NULL, TRUE

    invoke wsprintfW, addr szBuf, offset szStatusFmt, g_nItems
    invoke UiSetStatus, addr szBuf
    ret
UiFillList ENDP

END
