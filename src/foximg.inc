; FoxImg - shared definitions
.586
.model flat, stdcall
option casemap:none

includelib kernel32.lib
includelib user32.lib
includelib gdi32.lib
includelib comctl32.lib
includelib comdlg32.lib
includelib advapi32.lib
includelib dwmapi.lib
includelib uxtheme.lib

; ---------------------------------------------------------------------------
; Macros
; ---------------------------------------------------------------------------

; WSTR label, <text>   -> NUL-terminated UTF-16 string (ASCII source only, no quotes/percent)
WSTR MACRO lbl:REQ, txt:REQ
    lbl LABEL WORD
    FORC ch, <txt>
        dw '&ch'
    ENDM
    dw 0
ENDM

; ---------------------------------------------------------------------------
; Win32 constants
; ---------------------------------------------------------------------------
NULL                    equ 0
TRUE                    equ 1
FALSE                   equ 0
INVALID_HANDLE_VALUE    equ -1
MAX_PATH                equ 260

GENERIC_READ            equ 80000000h
FILE_SHARE_READ         equ 1
OPEN_EXISTING           equ 3
FILE_ATTRIBUTE_NORMAL   equ 80h
PAGE_READONLY           equ 2
FILE_MAP_READ           equ 4

CS_VREDRAW              equ 1
CS_HREDRAW              equ 2
IDC_ARROW               equ 7F00h
IDI_APPLICATION         equ 7F00h
COLOR_WINDOW            equ 5
CW_USEDEFAULT           equ 80000000h
SW_SHOWDEFAULT          equ 10

WS_CHILD                equ 40000000h
WS_VISIBLE              equ 10000000h
WS_BORDER               equ 00800000h
WS_OVERLAPPEDWINDOW     equ 00CF0000h
WS_EX_CLIENTEDGE        equ 200h

WM_CREATE               equ 0001h
WM_DESTROY              equ 0002h
WM_SIZE                 equ 0005h
WM_SETREDRAW            equ 000Bh
WM_SETFONT              equ 0030h
WM_NOTIFY               equ 004Eh
WM_COMMAND              equ 0111h
WM_USER                 equ 0400h

MB_OK                   equ 0
MB_ICONERROR            equ 10h
MB_ICONINFORMATION      equ 40h

DEFAULT_GUI_FONT        equ 17

ICC_LISTVIEW_CLASSES    equ 1
ICC_TREEVIEW_CLASSES    equ 2
ICC_BAR_CLASSES         equ 4

OFN_HIDEREADONLY        equ 00000004h
OFN_PATHMUSTEXIST       equ 00000800h
OFN_FILEMUSTEXIST       equ 00001000h
OFN_EXPLORER            equ 00080000h

; TreeView
TVS_HASBUTTONS          equ 1
TVS_HASLINES            equ 2
TVS_LINESATROOT         equ 4
TVS_SHOWSELALWAYS       equ 20h
TVIF_TEXT               equ 1
TVIF_PARAM              equ 4
TVIF_STATE              equ 8
TVI_ROOT                equ 0FFFF0000h
TVI_FIRST               equ 0FFFF0001h
TVI_LAST                equ 0FFFF0002h
TVI_SORT                equ 0FFFF0003h
TV_FIRST                equ 1100h
TVM_DELETEITEM          equ TV_FIRST + 1
TVM_EXPAND              equ TV_FIRST + 2
TVM_SELECTITEM          equ TV_FIRST + 11
TVM_INSERTITEMW         equ TV_FIRST + 50
TVE_EXPAND              equ 2
TVGN_CARET              equ 9
TVN_FIRST               equ -400
TVN_SELCHANGEDW         equ TVN_FIRST - 51

; ListView
LVS_REPORT              equ 1
LVS_SHOWSELALWAYS       equ 8
LVS_EX_GRIDLINES        equ 1
LVS_EX_FULLROWSELECT    equ 20h
LVM_FIRST               equ 1000h
LVM_DELETEALLITEMS      equ LVM_FIRST + 9
LVM_SETEXTENDEDLISTVIEWSTYLE equ LVM_FIRST + 54
LVM_INSERTITEMW         equ LVM_FIRST + 77
LVM_INSERTCOLUMNW       equ LVM_FIRST + 97
LVM_SETITEMTEXTW        equ LVM_FIRST + 116
LVCF_FMT                equ 1
LVCF_WIDTH              equ 2
LVCF_TEXT               equ 4
LVCF_SUBITEM            equ 8
LVCFMT_LEFT             equ 0
LVCFMT_RIGHT            equ 1
LVIF_TEXT               equ 1
LVIF_PARAM              equ 4

; StatusBar
SBARS_SIZEGRIP          equ 100h
SB_SETTEXTW             equ WM_USER + 11

; Resource IDs (keep in sync with res\foximg.rc)
IDR_MAINMENU            equ 1
IDR_ACCEL               equ 1
IDM_OPEN                equ 101
IDM_EXIT                equ 102
IDM_ABOUT               equ 201

; Control IDs
IDC_TREE                equ 1001
IDC_LIST                equ 1002
IDC_STATUS              equ 1003

; ---------------------------------------------------------------------------
; Win32 structures
; ---------------------------------------------------------------------------
POINT STRUCT
    x       DWORD ?
    y       DWORD ?
POINT ENDS

RECT STRUCT
    left    DWORD ?
    top     DWORD ?
    right   DWORD ?
    bottom  DWORD ?
RECT ENDS

MSG STRUCT
    hwnd    DWORD ?
    message DWORD ?
    wParam  DWORD ?
    lParam  DWORD ?
    time    DWORD ?
    pt      POINT <>
MSG ENDS

WNDCLASSEXW STRUCT
    cbSize          DWORD ?
    style           DWORD ?
    lpfnWndProc     DWORD ?
    cbClsExtra      DWORD ?
    cbWndExtra      DWORD ?
    hInstance       DWORD ?
    hIcon           DWORD ?
    hCursor         DWORD ?
    hbrBackground   DWORD ?
    lpszMenuName    DWORD ?
    lpszClassName   DWORD ?
    hIconSm         DWORD ?
WNDCLASSEXW ENDS

INITCOMMONCONTROLSEX STRUCT
    dwSize  DWORD ?
    dwICC   DWORD ?
INITCOMMONCONTROLSEX ENDS

OPENFILENAMEW STRUCT
    lStructSize     DWORD ?
    hwndOwner       DWORD ?
    hInstance       DWORD ?
    lpstrFilter     DWORD ?
    lpstrCustomFilter DWORD ?
    nMaxCustFilter  DWORD ?
    nFilterIndex    DWORD ?
    lpstrFile       DWORD ?
    nMaxFile        DWORD ?
    lpstrFileTitle  DWORD ?
    nMaxFileTitle   DWORD ?
    lpstrInitialDir DWORD ?
    lpstrTitle      DWORD ?
    Flags           DWORD ?
    nFileOffset     WORD ?
    nFileExtension  WORD ?
    lpstrDefExt     DWORD ?
    lCustData       DWORD ?
    lpfnHook        DWORD ?
    lpTemplateName  DWORD ?
    pvReserved      DWORD ?
    dwReserved      DWORD ?
    FlagsEx         DWORD ?
OPENFILENAMEW ENDS

NMHDR STRUCT
    hwndFrom    DWORD ?
    idFrom      DWORD ?
    code        DWORD ?
NMHDR ENDS

TVITEMW STRUCT
    imask           DWORD ?
    hItem           DWORD ?
    state           DWORD ?
    stateMask       DWORD ?
    pszText         DWORD ?
    cchTextMax      DWORD ?
    iImage          DWORD ?
    iSelectedImage  DWORD ?
    cChildren       DWORD ?
    lParam          DWORD ?
TVITEMW ENDS

TVINSERTSTRUCTW STRUCT
    hParent         DWORD ?
    hInsertAfter    DWORD ?
    item            TVITEMW <>
TVINSERTSTRUCTW ENDS

NMTREEVIEWW STRUCT
    hdr         NMHDR <>
    action      DWORD ?
    itemOld     TVITEMW <>
    itemNew     TVITEMW <>
    ptDrag      POINT <>
NMTREEVIEWW ENDS

LVCOLUMNW STRUCT
    imask       DWORD ?
    fmt         DWORD ?
    cxWidth     DWORD ?
    pszText     DWORD ?
    cchTextMax  DWORD ?
    iSubItem    DWORD ?
    iImage      DWORD ?
    iOrder      DWORD ?
LVCOLUMNW ENDS

LVITEMW STRUCT
    imask       DWORD ?
    iItem       DWORD ?
    iSubItem    DWORD ?
    state       DWORD ?
    stateMask   DWORD ?
    pszText     DWORD ?
    cchTextMax  DWORD ?
    iImage      DWORD ?
    lParam      DWORD ?
    iIndent     DWORD ?
LVITEMW ENDS

; ---------------------------------------------------------------------------
; ISO 9660 (ECMA-119)
; ---------------------------------------------------------------------------
ISO_SECTOR              equ 2048
ISO_VD_FIRST            equ 16          ; first volume descriptor sector
ISO_VD_BOOT             equ 0
ISO_VD_PRIMARY          equ 1
ISO_VD_SUPPLEMENTARY    equ 2
ISO_VD_TERMINATOR       equ 255

; Directory record file flags
ISO_FLAG_HIDDEN         equ 01h
ISO_FLAG_DIRECTORY      equ 02h
ISO_FLAG_ASSOCIATED     equ 04h
ISO_FLAG_MULTIEXTENT    equ 80h

; Directory record layout (ECMA-119 9.1). Multi-byte fields are stored both-endian; we read the little-endian half.
ISO_DIRREC STRUCT
    recLen          BYTE ?          ; 0
    extAttrLen      BYTE ?          ; 1
    extentLE        DWORD ?         ; 2
    extentBE        DWORD ?         ; 6
    dataLenLE       DWORD ?         ; 10
    dataLenBE       DWORD ?         ; 14
    recYear         BYTE ?          ; 18  years since 1900
    recMonth        BYTE ?          ; 19
    recDay          BYTE ?          ; 20
    recHour         BYTE ?          ; 21
    recMinute       BYTE ?          ; 22
    recSecond       BYTE ?          ; 23
    recTz           BYTE ?          ; 24  15-minute offsets from GMT, -48..+52
    fileFlags       BYTE ?          ; 25
    unitSize        BYTE ?          ; 26
    gapSize         BYTE ?          ; 27
    volSeqLE        WORD ?          ; 28
    volSeqBE        WORD ?          ; 30
    nameLen         BYTE ?          ; 32
    ; name follows at 33, padded to even length, then system use area
ISO_DIRREC ENDS

; Volume descriptor offsets (Primary / Supplementary share layout, ECMA-119 8.4 / 8.5)
ISO_VD_TYPE             equ 0
ISO_VD_ID               equ 1           ; "CD001"
ISO_VD_VERSION          equ 6
ISO_VD_SYSTEM_ID        equ 8           ; 32 a-chars
ISO_VD_VOLUME_ID        equ 40          ; 32 d-chars (UCS-2 in Joliet)
ISO_VD_SPACE_SIZE       equ 80          ; both-endian dword, sectors
ISO_VD_ESCAPES          equ 88          ; 32 bytes, Joliet: 25h 2Fh 40h|43h|45h
ISO_VD_ROOT_RECORD      equ 156         ; 34-byte directory record for root

; ---------------------------------------------------------------------------
; Win32 prototypes
; ---------------------------------------------------------------------------
ExitProcess         PROTO :DWORD
GetModuleHandleW    PROTO :DWORD
GetCommandLineW     PROTO
CreateFileW         PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
CloseHandle         PROTO :DWORD
GetFileSizeEx       PROTO :DWORD,:DWORD
CreateFileMappingW  PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
MapViewOfFile       PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD
UnmapViewOfFile     PROTO :DWORD
RtlZeroMemory       PROTO :DWORD,:DWORD
lstrcpyW            PROTO :DWORD,:DWORD

RegisterClassExW    PROTO :DWORD
CreateWindowExW     PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
ShowWindow          PROTO :DWORD,:DWORD
UpdateWindow        PROTO :DWORD
GetMessageW         PROTO :DWORD,:DWORD,:DWORD,:DWORD
TranslateMessage    PROTO :DWORD
DispatchMessageW    PROTO :DWORD
TranslateAcceleratorW PROTO :DWORD,:DWORD,:DWORD
DefWindowProcW      PROTO :DWORD,:DWORD,:DWORD,:DWORD
PostQuitMessage     PROTO :DWORD
DestroyWindow       PROTO :DWORD
LoadCursorW         PROTO :DWORD,:DWORD
LoadIconW           PROTO :DWORD,:DWORD
LoadMenuW           PROTO :DWORD,:DWORD
LoadAcceleratorsW   PROTO :DWORD,:DWORD
SendMessageW        PROTO :DWORD,:DWORD,:DWORD,:DWORD
MoveWindow          PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
GetClientRect       PROTO :DWORD,:DWORD
InvalidateRect      PROTO :DWORD,:DWORD,:DWORD
GetWindowRect       PROTO :DWORD,:DWORD
MessageBoxW         PROTO :DWORD,:DWORD,:DWORD,:DWORD
SetWindowTextW      PROTO :DWORD,:DWORD
wsprintfW           PROTO C :VARARG

GetStockObject      PROTO :DWORD
InitCommonControlsEx PROTO :DWORD
GetOpenFileNameW    PROTO :DWORD

; ---------------------------------------------------------------------------
; Theme / DPI support
; ---------------------------------------------------------------------------
WM_ERASEBKGND           equ 0014h
WM_SETTINGCHANGE        equ 001Ah
WM_DRAWITEM             equ 002Bh
WM_DPICHANGED           equ 02E0h

SPI_GETNONCLIENTMETRICS equ 0029h
SPI_GETWORKAREA         equ 0030h
SystemParametersInfoW   PROTO :DWORD,:DWORD,:DWORD,:DWORD
DWMWA_USE_IMMERSIVE_DARK_MODE equ 20
CLR_NONE                equ 0FFFFFFFFh
CLR_DEFAULT             equ 0FF000000h
SWP_NOZORDER            equ 0004h
SWP_NOACTIVATE          equ 0010h
DT_VCENTER              equ 0004h
DT_SINGLELINE           equ 0020h
DT_NOPREFIX             equ 0800h
DT_END_ELLIPSIS         equ 8000h
TRANSPARENT             equ 1
HKEY_CURRENT_USER       equ 80000001h
RRF_RT_REG_DWORD        equ 10h
COLOR_WINDOWTEXT        equ 8
COLOR_BTNFACE           equ 15
RDW_INVALIDATE          equ 0001h
RDW_ERASE               equ 0004h
RDW_ALLCHILDREN         equ 0080h
RDW_FRAME               equ 0400h
IDI_APP                 equ 1

LVM_SETBKCOLOR          equ LVM_FIRST + 1
LVM_SETCOLUMNWIDTH      equ LVM_FIRST + 30
LVM_GETHEADER           equ LVM_FIRST + 31
LVM_SETTEXTCOLOR        equ LVM_FIRST + 36
LVM_SETTEXTBKCOLOR      equ LVM_FIRST + 38
TVM_SETBKCOLOR          equ TV_FIRST + 29
TVM_SETTEXTCOLOR        equ TV_FIRST + 30
TVM_SETLINECOLOR        equ TV_FIRST + 40
CCM_SETBKCOLOR          equ 2001h
SB_SETBKCOLOR           equ CCM_SETBKCOLOR
SBT_OWNERDRAW           equ 1000h

NM_CUSTOMDRAW           equ -12
CDDS_PREPAINT           equ 00000001h
CDDS_ITEMPREPAINT       equ 00010001h
CDRF_DODEFAULT          equ 00000000h
CDRF_NOTIFYITEMDRAW     equ 00000020h

NMCUSTOMDRAW STRUCT
    hdr         NMHDR <>
    dwDrawStage DWORD ?
    hdc         DWORD ?
    rc          RECT <>
    dwItemSpec  DWORD ?
    uItemState  DWORD ?
    lItemlParam DWORD ?
NMCUSTOMDRAW ENDS

SetWindowSubclass   PROTO :DWORD,:DWORD,:DWORD,:DWORD
DefSubclassProc     PROTO :DWORD,:DWORD,:DWORD,:DWORD

; Menu bar owner-draw. WM_UAHDRAWMENU* are undocumented but stable since Vista; layouts from public reverse engineering.
WM_NCPAINT              equ 0085h
WM_NCACTIVATE           equ 0086h
WM_UAHDRAWMENU          equ 0091h
WM_UAHDRAWMENUITEM      equ 0092h
OBJID_MENU              equ 0FFFFFFFDh
MIIM_STRING             equ 0040h
ODS_SELECTED            equ 0001h
ODS_GRAYED              equ 0002h
ODS_HOTLIGHT            equ 0040h
ODS_INACTIVE            equ 0080h
ODS_NOACCEL             equ 0100h
DT_CENTER               equ 0001h
DT_HIDEPREFIX           equ 00100000h

MENUBARINFO STRUCT
    cbSize      DWORD ?
    rcBar       RECT <>
    hMenu       DWORD ?
    hwndMenu    DWORD ?
    fFlags      DWORD ?
MENUBARINFO ENDS

MENUITEMINFOW STRUCT
    cbSize          DWORD ?
    fMask           DWORD ?
    fType           DWORD ?
    fState          DWORD ?
    wID             DWORD ?
    hSubMenu        DWORD ?
    hbmpChecked     DWORD ?
    hbmpUnchecked   DWORD ?
    dwItemData      DWORD ?
    dwTypeData      DWORD ?
    cch             DWORD ?
    hbmpItem        DWORD ?
MENUITEMINFOW ENDS

UAHMENU STRUCT
    hmenu       DWORD ?
    hdc         DWORD ?
    dwFlags     DWORD ?
UAHMENU ENDS

UAHMENUITEM STRUCT
    iPosition   DWORD ?
    umim        DWORD 8 dup(?)     ; UAHMENUITEMMETRICS
    umpm        DWORD 5 dup(?)     ; UAHMENUPOPUPMETRICS
UAHMENUITEM ENDS

GetMenuBarInfo      PROTO :DWORD,:DWORD,:DWORD,:DWORD
GetMenuItemInfoW    PROTO :DWORD,:DWORD,:DWORD,:DWORD
GetWindowDC         PROTO :DWORD
ReleaseDC           PROTO :DWORD,:DWORD

ThemeDrawMenuBar    PROTO :DWORD,:DWORD         ; hWnd, pUAHMENU -> TRUE if handled
ThemeDrawMenuItem   PROTO :DWORD,:DWORD         ; hWnd, pUAHDRAWMENUITEM -> TRUE if handled
ThemeDrawMenuBottomLine PROTO :DWORD            ; hWnd

LF_FACESIZE             equ 32

LOGFONTW STRUCT
    lfHeight        DWORD ?
    lfWidth         DWORD ?
    lfEscapement    DWORD ?
    lfOrientation   DWORD ?
    lfWeight        DWORD ?
    lfItalic        BYTE ?
    lfUnderline     BYTE ?
    lfStrikeOut     BYTE ?
    lfCharSet       BYTE ?
    lfOutPrecision  BYTE ?
    lfClipPrecision BYTE ?
    lfQuality       BYTE ?
    lfPitchAndFamily BYTE ?
    lfFaceName      WORD LF_FACESIZE dup(?)
LOGFONTW ENDS

NONCLIENTMETRICSW STRUCT
    cbSize          DWORD ?
    iBorderWidth    DWORD ?
    iScrollWidth    DWORD ?
    iScrollHeight   DWORD ?
    iCaptionWidth   DWORD ?
    iCaptionHeight  DWORD ?
    lfCaptionFont   LOGFONTW <>
    iSmCaptionWidth DWORD ?
    iSmCaptionHeight DWORD ?
    lfSmCaptionFont LOGFONTW <>
    iMenuWidth      DWORD ?
    iMenuHeight     DWORD ?
    lfMenuFont      LOGFONTW <>
    lfStatusFont    LOGFONTW <>
    lfMessageFont   LOGFONTW <>
    iPaddedBorderWidth DWORD ?
NONCLIENTMETRICSW ENDS

DRAWITEMSTRUCT STRUCT
    CtlType     DWORD ?
    CtlID       DWORD ?
    itemID      DWORD ?
    itemAction  DWORD ?
    itemState   DWORD ?
    hwndItem    DWORD ?
    hDC         DWORD ?
    rcItem      RECT <>
    itemData    DWORD ?
DRAWITEMSTRUCT ENDS

UAHDRAWMENUITEM STRUCT
    ditem       DRAWITEMSTRUCT <>
    um          UAHMENU <>
    umi         UAHMENUITEM <>
UAHDRAWMENUITEM ENDS

GetDpiForWindow     PROTO :DWORD
GetDpiForSystem     PROTO
SystemParametersInfoForDpi PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD
SetWindowPos        PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
FillRect            PROTO :DWORD,:DWORD,:DWORD
DrawTextW           PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD
GetSysColor         PROTO :DWORD
RedrawWindow        PROTO :DWORD,:DWORD,:DWORD,:DWORD
CreateFontIndirectW PROTO :DWORD
DeleteObject        PROTO :DWORD
CreateSolidBrush    PROTO :DWORD
SetTextColor        PROTO :DWORD,:DWORD
SetBkMode           PROTO :DWORD,:DWORD
SelectObject        PROTO :DWORD,:DWORD
MulDiv              PROTO :DWORD,:DWORD,:DWORD
LoadLibraryW        PROTO :DWORD
GetProcAddress      PROTO :DWORD,:DWORD
lstrcmpiW           PROTO :DWORD,:DWORD
lstrcpynW           PROTO :DWORD,:DWORD,:DWORD
RegGetValueW        PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
DwmSetWindowAttribute PROTO :DWORD,:DWORD,:DWORD,:DWORD
SetWindowTheme      PROTO :DWORD,:DWORD,:DWORD

; theme.asm
ThemeInit           PROTO
ThemeApply          PROTO :DWORD                ; hWnd
ThemeOnSettingChange PROTO :DWORD,:DWORD        ; hWnd, lParam
ThemeEraseBkgnd     PROTO :DWORD,:DWORD         ; hWnd, hdc -> TRUE
ThemeDrawStatus     PROTO :DWORD                ; pDIS -> TRUE
EXTERNDEF g_bDark:DWORD

; ui.asm (DPI)
UiUpdateDpi         PROTO :DWORD,:DWORD         ; hWndParent, dpi
EXTERNDEF g_dpi:DWORD
EXTERNDEF g_szStatus:WORD

; ---------------------------------------------------------------------------
; FoxImg cross-module symbols
; ---------------------------------------------------------------------------
; iso9660.asm
IsoOpen         PROTO :DWORD                    ; pszPath -> BOOL
IsoClose        PROTO
IsoEnumDir      PROTO :DWORD,:DWORD,:DWORD      ; pDirRec, pfnCallback(pRec, lParam) -> continue?, lParam
IsoRecName      PROTO :DWORD,:DWORD,:DWORD      ; pRec, pszBuf, cchBuf
IsoRecDate      PROTO :DWORD,:DWORD             ; pRec, pszBuf (>= 20 WCHARs)
IsoVolumeName   PROTO :DWORD,:DWORD             ; pszBuf, cchBuf

EXTERNDEF g_pView:DWORD
EXTERNDEF g_cbView:DWORD
EXTERNDEF g_pRoot:DWORD
EXTERNDEF g_bJoliet:DWORD

; ui.asm
UiCreateControls PROTO :DWORD                   ; hWndParent
UiLayout        PROTO :DWORD                    ; hWndParent
UiFillTree      PROTO
UiFillList      PROTO :DWORD                    ; pDirRec
UiSetStatus     PROTO :DWORD                    ; pszText

EXTERNDEF g_hInst:DWORD
EXTERNDEF g_hWnd:DWORD
EXTERNDEF g_hTree:DWORD
EXTERNDEF g_hList:DWORD
EXTERNDEF g_hStatus:DWORD
EXTERNDEF g_hFont:DWORD
