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
includelib ntdll.lib
includelib winmm.lib
includelib crypt32.lib

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
FILE_FLAG_SEQUENTIAL_SCAN equ 08000000h    ; winbase.h - read ahead harder, evict behind
FileAllocationInfo      equ 5              ; minwinbase.h FILE_INFO_BY_HANDLE_CLASS
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
MessageBoxA         PROTO :DWORD,:DWORD,:DWORD,:DWORD
SetWindowTextW      PROTO :DWORD,:DWORD
wsprintfW           PROTO C :VARARG
wsprintfA           PROTO C :VARARG

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
DWMWA_USE_IMMERSIVE_DARK_MODE equ 20        ; dwmapi.h; Windows 10 2004 and later
DWMWA_USE_IMMERSIVE_DARK_MODE_OLD equ 19    ; the same flag on 1809 - 1903, before it was documented
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
; v1 feature set: model, writer, preview, editing UI
; ---------------------------------------------------------------------------
includelib shell32.lib
includelib ole32.lib

FOXIMG_VERSION_TEXT     equ <FoxImg v1.0>

WM_SETFOCUS             equ 0007h
WM_KILLFOCUS            equ 0008h
WM_SETTEXT              equ 000Ch
WM_PAINT                equ 000Fh
WM_CONTEXTMENU          equ 007Bh
WM_KEYDOWN              equ 0100h
WM_CTLCOLOREDIT         equ 0133h
WM_CTLCOLORSTATIC       equ 0138h
WM_DROPFILES            equ 0233h
WM_INITMENUPOPUP        equ 0117h

WS_HSCROLL              equ 00100000h
WS_VSCROLL              equ 00200000h
WS_CLIPCHILDREN         equ 02000000h
WS_CLIPSIBLINGS         equ 04000000h
ES_MULTILINE            equ 0004h
ES_AUTOVSCROLL          equ 0040h
ES_AUTOHSCROLL          equ 0080h
ES_READONLY             equ 0800h
SW_HIDE                 equ 0
SW_SHOW                 equ 5

TPM_RIGHTBUTTON         equ 0002h
TPM_RETURNCMD           equ 0100h
MF_STRING               equ 0000h
MF_GRAYED               equ 0001h
MF_POPUP                equ 0010h
MF_SEPARATOR            equ 0800h
MF_BYCOMMAND            equ 0000h
MF_CHECKED              equ 0008h
MF_UNCHECKED            equ 0000h

MB_YESNO                equ 0004h
MB_ICONQUESTION         equ 0020h
MB_ICONWARNING          equ 0030h
IDYES                   equ 6

VK_RETURN               equ 0Dh
VK_DELETE               equ 2Eh
VK_F2                   equ 71h

OFN_OVERWRITEPROMPT     equ 0002h
BIF_RETURNONLYFSDIRS    equ 0001h
BIF_NEWDIALOGSTYLE      equ 0040h
HEAP_ZERO_MEMORY        equ 0008h
MOVEFILE_REPLACE_EXISTING equ 0001h
FILE_ATTRIBUTE_DIRECTORY equ 0010h
INVALID_FILE_ATTRIBUTES equ 0FFFFFFFFh
GENERIC_WRITE           equ 40000000h
CREATE_ALWAYS           equ 2
FILE_BEGIN              equ 0
FILE_END                equ 2
DI_NORMAL               equ 0003h
CP_ACP                  equ 0
CP_UTF8                 equ 65001
MB_ERR_INVALID_CHARS    equ 0008h

LVS_SINGLESEL           equ 0004h
LVS_EDITLABELS          equ 0200h
LVIF_STATE              equ 0008h
LVIS_SELECTED           equ 0002h
LVNI_SELECTED           equ 0002h
LVM_GETITEMCOUNT        equ LVM_FIRST + 4
LVM_DELETEITEM          equ LVM_FIRST + 8
LVM_GETNEXTITEM         equ LVM_FIRST + 12
LVM_HITTEST             equ LVM_FIRST + 18
LVM_ENSUREVISIBLE       equ LVM_FIRST + 19
LVM_GETEDITCONTROL      equ LVM_FIRST + 24
LVM_SETITEMSTATE        equ LVM_FIRST + 43
LVM_GETSELECTEDCOUNT    equ LVM_FIRST + 50
LVM_GETITEMW            equ LVM_FIRST + 75
LVM_SETITEMW            equ LVM_FIRST + 76
LVM_EDITLABELW          equ LVM_FIRST + 118
LVHT_ONITEM             equ 000Eh
LVN_FIRST               equ -100
LVN_ITEMCHANGED         equ LVN_FIRST - 1
LVN_KEYDOWN             equ LVN_FIRST - 55
LVN_BEGINLABELEDITW     equ LVN_FIRST - 75
LVN_ENDLABELEDITW       equ LVN_FIRST - 76
NM_DBLCLK               equ -3
NM_RCLICK               equ -5
TVM_GETNEXTITEM         equ TV_FIRST + 10
TVM_GETITEMW            equ TV_FIRST + 62
TVIF_HANDLE             equ 0010h
TVM_HITTEST             equ TV_FIRST + 17
TVGN_ROOT               equ 0
TVHT_ONITEM             equ 0046h

LVHITTESTINFO STRUCT
    pt          POINT <>
    flags       DWORD ?
    iItem       DWORD ?
    iSubItem    DWORD ?
    iGroup      DWORD ?
LVHITTESTINFO ENDS

TVHITTESTINFO STRUCT
    pt          POINT <>
    flags       DWORD ?
    hItem       DWORD ?
TVHITTESTINFO ENDS

NMLISTVIEW STRUCT
    hdr         NMHDR <>
    iItem       DWORD ?
    iSubItem    DWORD ?
    uNewState   DWORD ?
    uOldState   DWORD ?
    uChanged    DWORD ?
    ptAction    POINT <>
    lParam      DWORD ?
NMLISTVIEW ENDS

NMLVDISPINFOW STRUCT
    hdr         NMHDR <>
    item        LVITEMW <>
NMLVDISPINFOW ENDS

NMLVKEYDOWN STRUCT
    hdr         NMHDR <>
    wVKey       WORD ?
    wPad        WORD ?
    flags       DWORD ?
NMLVKEYDOWN ENDS

PAINTSTRUCT STRUCT
    hdc         DWORD ?
    fErase      DWORD ?
    rcPaint     RECT <>
    fRestore    DWORD ?
    fIncUpdate  DWORD ?
    rgbReserved BYTE 32 dup(?)
PAINTSTRUCT ENDS

FILETIME STRUCT
    dwLowDateTime   DWORD ?
    dwHighDateTime  DWORD ?
FILETIME ENDS

SYSTEMTIME STRUCT
    wYear           WORD ?
    wMonth          WORD ?
    wDayOfWeek      WORD ?
    wDay            WORD ?
    wHour           WORD ?
    wMinute         WORD ?
    wSecond         WORD ?
    wMilliseconds   WORD ?
SYSTEMTIME ENDS

WIN32_FIND_DATAW STRUCT
    dwFileAttributes    DWORD ?
    ftCreationTime      FILETIME <>
    ftLastAccessTime    FILETIME <>
    ftLastWriteTime     FILETIME <>
    nFileSizeHigh       DWORD ?
    nFileSizeLow        DWORD ?
    dwReserved0         DWORD ?
    dwReserved1         DWORD ?
    cFileName           WORD MAX_PATH dup(?)
    cAlternateFileName  WORD 14 dup(?)
WIN32_FIND_DATAW ENDS

BROWSEINFOW STRUCT
    hwndOwner       DWORD ?
    pidlRoot        DWORD ?
    pszDisplayName  DWORD ?
    lpszTitle       DWORD ?
    ulFlags         DWORD ?
    lpfn            DWORD ?
    lParam          DWORD ?
    iImage          DWORD ?
BROWSEINFOW ENDS

; In-memory image model node
NODE_NAME_MAX           equ 256
NF_DIR                  equ 1       ; directory
NF_ISO                  equ 2       ; data lives in the mapped image (pRec / isoExtent)
NF_HOST                 equ 4       ; data lives in a host file (pszHost)

NF_MEM                  equ 8       ; data is a heap block (pszHost points at it) - UDF embedded files
NF_UDFONLY              equ 16      ; over 4 GB: written to the UDF half only
NF_CDA                  equ 32      ; CD audio track: raw PCM in the container's data file, served as WAV

; Extent list entry for multi-extent files (absolute block, bytes)
EXTENT STRUCT
    lba     DWORD ?
    cb      DWORD ?
EXTENT ENDS

NODE STRUCT
    pParent         DWORD ?
    pFirstChild     DWORD ?
    pNextSibling    DWORD ?
    nflags          DWORD ?
    pRec            DWORD ?
    pszHost         DWORD ?
    dataSize        DWORD ?         ; low 32 bits
    isoExtent       DWORD ?         ; first (or only) extent, absolute block
    hTree           DWORD ?
    dataSizeHi      DWORD ?         ; high 32 bits
    pExtList        DWORD ?         ; EXTENT array when the data is not one contiguous run, else 0
    nExtList        DWORD ?
    isoByteRem      DWORD ?         ; byte offset inside the first block (GameCube packs files unaligned)
    wUdfFe          DWORD ?         ; writer: partition-relative block of this node's File Entry
    wUdfDir         DWORD ?         ; writer: partition-relative block of directory FID data (dirs)
    wUdfDirLen      DWORD ?         ; writer: bytes of FID data (dirs)
    wExtent         DWORD ?         ; writer: primary dir extent / file data extent
    wExtentJ        DWORD ?         ; writer: Joliet dir extent
    wDirSize        DWORD ?
    wDirSizeJ       DWORD ?
    wPathIdx        DWORD ?
    wPathIdxJ       DWORD ?
    recDate         BYTE 7 dup(?)   ; ISO 9660 recording date
    isoName         BYTE 33 dup(?)  ; generated primary identifier, NUL-terminated
    szName          WORD NODE_NAME_MAX dup(?)
NODE ENDS

HeapAlloc           PROTO :DWORD,:DWORD,:DWORD
HeapFree            PROTO :DWORD,:DWORD,:DWORD
GetProcessHeap      PROTO
RtlMoveMemory       PROTO :DWORD,:DWORD,:DWORD
WriteFile           PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD
ReadFile            PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD
SetFilePointerEx    PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD
SetFileInformationByHandle PROTO :DWORD,:DWORD,:DWORD,:DWORD
WideCharToMultiByte PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
SetEndOfFile        PROTO :DWORD
CryptBinaryToStringA PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD
CRYPT_STRING_BASE64     equ 1              ; wincrypt.h
AddVectoredExceptionHandler PROTO :DWORD,:DWORD
CreateDirectoryW    PROTO :DWORD,:DWORD
MoveFileExW         PROTO :DWORD,:DWORD,:DWORD
DeleteFileW         PROTO :DWORD
GetFileAttributesW  PROTO :DWORD
FindFirstFileW      PROTO :DWORD,:DWORD
FindNextFileW       PROTO :DWORD,:DWORD
FindClose           PROTO :DWORD
FileTimeToLocalFileTime PROTO :DWORD,:DWORD
FileTimeToSystemTime PROTO :DWORD,:DWORD
GetLocalTime        PROTO :DWORD
lstrcatW            PROTO :DWORD,:DWORD
lstrcmpW            PROTO :DWORD,:DWORD
lstrlenW            PROTO :DWORD
MultiByteToWideChar PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
CharUpperW          PROTO :DWORD
GetSaveFileNameW    PROTO :DWORD
SHBrowseForFolderW  PROTO :DWORD
SHGetPathFromIDListW PROTO :DWORD,:DWORD
CoTaskMemFree       PROTO :DWORD
CoInitialize        PROTO :DWORD
DragAcceptFiles     PROTO :DWORD,:DWORD
DragQueryFileW      PROTO :DWORD,:DWORD,:DWORD,:DWORD
DragFinish          PROTO :DWORD
CreatePopupMenu     PROTO
AppendMenuW         PROTO :DWORD,:DWORD,:DWORD,:DWORD
TrackPopupMenu      PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
DestroyMenu         PROTO :DWORD
GetMenu             PROTO :DWORD
CheckMenuItem       PROTO :DWORD,:DWORD,:DWORD
GetCursorPos        PROTO :DWORD
ScreenToClient      PROTO :DWORD,:DWORD
SetFocus            PROTO :DWORD
BeginPaint          PROTO :DWORD,:DWORD
EndPaint            PROTO :DWORD,:DWORD
CreateIconFromResourceEx PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
DrawIconEx          PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
DestroyIcon         PROTO :DWORD
SetBkColor          PROTO :DWORD,:DWORD
IsWindowVisible     PROTO :DWORD

; vfs.asm
VfsInit             PROTO
VfsClear            PROTO
VfsNewImage         PROTO                       ; blank volume
VfsBuildFromIso     PROTO                       ; from the currently mapped image
VfsNew              PROTO :DWORD,:DWORD,:DWORD  ; pParent, pszName, flags -> NODE*
VfsDelete           PROTO :DWORD                ; unlink + free
VfsRename           PROTO :DWORD,:DWORD         ; pNode, pszName
VfsFindChild        PROTO :DWORD,:DWORD         ; pParent, pszName -> NODE* or 0
VfsUniqueName       PROTO :DWORD,:DWORD,:DWORD  ; pParent, pszBase, pszOut(NODE_NAME_MAX)
VfsAddHostPath      PROTO :DWORD,:DWORD         ; pParent, pszPath -> NODE* or 0
VfsDateNow          PROTO :DWORD                ; pNode
VfsCopyData         PROTO :DWORD,:DWORD         ; pNode, hOut -> BOOL
VfsReadAll          PROTO :DWORD,:DWORD,:DWORD  ; pNode, cbMax, pcbOut -> heap buffer or 0
VfsExtract          PROTO :DWORD,:DWORD         ; pNode, pszDir -> BOOL
VfsAlloc            PROTO :DWORD
VfsFreeMem          PROTO :DWORD
WriteAll            PROTO :DWORD,:DWORD,:DWORD  ; hFile, pData, cb -> BOOL
EXTERNDEF g_pRootNode:DWORD
EXTERNDEF g_bModified:DWORD

; isowrite.asm
IsoWrite            PROTO :DWORD                ; pszOutPath -> BOOL

; preview.asm
PreviewInit         PROTO :DWORD                ; hWndParent
PreviewShow         PROTO :DWORD                ; pNode or 0 (clears)
PreviewLayout       PROTO :DWORD,:DWORD,:DWORD,:DWORD ; x, y, cx, cy
PreviewSetFont      PROTO                       ; after DPI change
PreviewCtlColor     PROTO :DWORD,:DWORD         ; hdc, hwndCtl -> brush or 0
EXTERNDEF g_bPreview:DWORD
EXTERNDEF g_hEdit:DWORD
EXTERNDEF g_hFontMono:DWORD                 ; Consolas at the current DPI (preview text and status bar)

; ui.asm (editing)
UiRefreshTree       PROTO                       ; rebuild tree from model, keep current dir
UiFillListNode      PROTO :DWORD                ; pDirNode
UiSelectDir         PROTO :DWORD                ; pDirNode (select in tree)
UiSelectedNode      PROTO                       ; -> first selected list NODE* or 0
UiForEachSelected   PROTO :DWORD,:DWORD         ; pfn(pNode, lParam), lParam
UiBeginRename       PROTO :DWORD                ; pNode (must be in current list)
UiUpdateTitle       PROTO
UiListSubclass      PROTO :DWORD,:DWORD,:DWORD,:DWORD  ; called by theme's ListSubclassProc first; returns nonzero if handled (eax) and result in edx... (see ui.asm)
EXTERNDEF g_pCurDir:DWORD
EXTERNDEF g_szPath:WORD
EXTERNDEF g_bHavePath:DWORD

; Menu / accelerator IDs (keep in sync with res\foximg.rc)
IDM_NEW                 equ 100
IDM_SAVE                equ 103
IDM_SAVEAS              equ 104
IDM_EXPORT_FOLDER       equ 105
IDM_EXPORT_BINCUE       equ 106
IDM_ADDFILES            equ 110
IDM_NEWFOLDER           equ 111
IDM_NEWFILE             equ 112
IDM_RENAME              equ 113
IDM_DELETE              equ 114
IDM_EXTRACT             equ 115
IDM_PREVIEW             equ 120
IDM_OPENDIR             equ 121
IDC_EDIT                equ 1004
IDC_ICONVIEW            equ 1005

; ---------------------------------------------------------------------------
; El Torito (eltorito.asm)
; ---------------------------------------------------------------------------
BOOT_MAX                equ 8
BOOT_PLATFORM_X86       equ 0
BOOT_PLATFORM_EFI       equ 0EFh

BOOTENTRY STRUCT
    platform    DWORD ?
    media       DWORD ?         ; 0 = no emulation, 1..3 floppy, 4 hard disk
    loadSeg     DWORD ?
    sysType     DWORD ?
    sectors     DWORD ?         ; 512-byte virtual sectors to load
    pNode       DWORD ?         ; file in the tree providing the image, or 0
    blobExtent  DWORD ?         ; source lba in the open image when pNode == 0
    blobSize    DWORD ?
    bInfoTable  DWORD ?         ; patch the isolinux/GRUB boot info table on write
    wExtent     DWORD ?         ; writer: blob extent
BOOTENTRY ENDS

BootParse           PROTO                       ; after IsoOpen + VfsBuildFromIso
BootClear           PROTO
BootSetEntry        PROTO :DWORD,:DWORD         ; pNode, platform -> BOOL
BootSummary         PROTO :DWORD                ; pszBuf (>= 256 WCHARs)
BootForgetNode      PROTO :DWORD                ; pNode about to be deleted
BootBuildBRVD       PROTO :DWORD                ; pSector (zeroed 2048)
BootAssignLayout    PROTO :DWORD                ; pLba (in/out) - catalog + blobs
BootBuildCatalog    PROTO :DWORD                ; pSector
BootWriteBlobs      PROTO                       ; hidden images (uses g_hOut)
BootPatchInfoTables PROTO                       ; after all data is written
EXTERNDEF g_bootCount:DWORD
EXTERNDEF g_bootWCatalog:DWORD

; isowrite.asm helpers exposed for eltorito
IsoWritePadTo       PROTO :DWORD                ; cb written -> pad to a 2048 boundary
EXTERNDEF g_hOut:DWORD
EXTERNDEF g_lba:DWORD

; ---------------------------------------------------------------------------
; OLE drag and drop (dragdrop.asm)
; ---------------------------------------------------------------------------
CF_HDROP                equ 15
TYMED_HGLOBAL           equ 1
DVASPECT_CONTENT        equ 1
DROPEFFECT_NONE         equ 0
DROPEFFECT_COPY         equ 1
DROPEFFECT_MOVE         equ 2
DRAGDROP_S_DROP         equ 00040100h
DRAGDROP_S_CANCEL       equ 00040101h
DRAGDROP_S_USEDEFAULTCURSORS equ 00040102h
S_OK                    equ 0
S_FALSE                 equ 1
E_NOINTERFACE           equ 80004002h
MK_LBUTTON              equ 0001h
GMEM_MOVEABLE           equ 0002h
GMEM_ZEROINIT           equ 0040h
LVN_BEGINDRAG           equ LVN_FIRST - 9
TVN_BEGINDRAGW          equ TVN_FIRST - 56
TVGN_DROPHILITE         equ 0008h
LVIS_DROPHILITED        equ 0008h
SB_SETPARTS             equ WM_USER + 4
SB_GETRECT              equ WM_USER + 10

FORMATETC STRUCT
    cfFormat    WORD ?
    wPad        WORD ?
    ptd         DWORD ?
    dwAspect    DWORD ?
    lindex      DWORD ?
    tymed       DWORD ?
FORMATETC ENDS

STGMEDIUM STRUCT
    tymed           DWORD ?
    hGlobal         DWORD ?
    pUnkForRelease  DWORD ?
STGMEDIUM ENDS

DROPFILES STRUCT
    pFiles      DWORD ?
    pt          POINT <>
    fNC         DWORD ?
    fWide       DWORD ?
DROPFILES ENDS

OleInitialize       PROTO :DWORD
OleUninitialize     PROTO
RegisterDragDrop    PROTO :DWORD,:DWORD
RevokeDragDrop      PROTO :DWORD
DoDragDrop          PROTO :DWORD,:DWORD,:DWORD,:DWORD
ReleaseStgMedium    PROTO :DWORD
SHCreateDataObject  PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
RegisterClipboardFormatW PROTO :DWORD
GlobalAlloc         PROTO :DWORD,:DWORD
GlobalLock          PROTO :DWORD
GlobalUnlock        PROTO :DWORD
GlobalFree          PROTO :DWORD
GetTempPathW        PROTO :DWORD,:DWORD
GetTickCount        PROTO

DndInit             PROTO                       ; after the controls exist
DndShutdown         PROTO
DndBeginDrag        PROTO :DWORD                ; bFromTree

; vfs additions
VfsFindByExtent     PROTO :DWORD,:DWORD         ; pDir, lba -> file NODE* or 0
VfsMove             PROTO :DWORD,:DWORD         ; pNode, pNewParent -> BOOL
VfsIsAncestor       PROTO :DWORD,:DWORD         ; pMaybeAncestor, pNode -> BOOL

; ui status parts
STATUS_PARTS        equ 3
UiSetStatusPart     PROTO :DWORD,:DWORD         ; part, pszText
UiStatusText        PROTO :DWORD                ; part -> WCHAR*
UiUpdateInfo        PROTO                       ; refresh format + boot parts
UiListNodeAt        PROTO :DWORD,:DWORD         ; x, y (list client) -> NODE* or 0
UiTreeNodeAt        PROTO :DWORD,:DWORD,:DWORD  ; x, y (tree client), bHilite -> NODE* or 0

IDM_EXTRACTALL          equ 116
IDM_BOOT_BIOS           equ 130
IDM_BOOT_EFI            equ 131
IDM_BOOT_CLEAR          equ 132

; ---------------------------------------------------------------------------
; Background jobs with progress (worker.asm)
; ---------------------------------------------------------------------------
WM_TIMER                equ 0113h
WM_SETCURSOR            equ 0020h
WM_APP                  equ 8000h
WM_JOBDONE              equ WM_APP + 1          ; wParam = result
IDC_WAIT                equ 7F02h
ICC_PROGRESS_CLASS      equ 0020h
PBM_SETPOS              equ WM_USER + 2
PBM_SETRANGE32          equ WM_USER + 6
PBM_SETBARCOLOR         equ WM_USER + 9
PBM_SETBKCOLOR          equ 2001h
PBM_SETMARQUEE          equ WM_USER + 10
PBS_MARQUEE             equ 0008h
BS_PUSHBUTTON           equ 0
IDC_PROGRESS            equ 1006
IDC_CANCEL              equ 1007
JOB_TIMER_ID            equ 1

JOB_NONE                equ 0
JOB_SAVE                equ 1
JOB_EXTRACT             equ 2
JOB_ADD                 equ 3

CreateThread        PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
SetTimer            PROTO :DWORD,:DWORD,:DWORD,:DWORD
KillTimer           PROTO :DWORD,:DWORD
SetCursor           PROTO :DWORD
EnableWindow        PROTO :DWORD,:DWORD

JobInit             PROTO :DWORD                ; hParent
JobLayout           PROTO                       ; after status bar layout
JobBusy             PROTO                       ; -> nonzero while a job runs
JobCancel           PROTO
JobOnTimer          PROTO
JobOnDone           PROTO :DWORD                ; result
JobStartSave        PROTO :DWORD                ; pszTmpPath -> BOOL started
JobNodesReset       PROTO
JobNodesAdd         PROTO :DWORD,:DWORD         ; pNode, lParam (UiForEachSelected callback shape)
JobStartExtract     PROTO :DWORD                ; pszDir -> BOOL
JobPathsReset       PROTO
JobPathsAdd         PROTO :DWORD                ; pszPath
JobStartAdd         PROTO :DWORD                ; pDirNode -> BOOL
JobSetCursor        PROTO                       ; -> nonzero if the wait cursor was applied
EXTERNDEF g_jobBusy:DWORD
EXTERNDEF g_jobCancel:DWORD
EXTERNDEF g_progDone:DWORD
EXTERNDEF g_progTotal:DWORD
EXTERNDEF g_hCancelBtn:DWORD
EXTERNDEF g_hProgress:DWORD
AppJobFinished      PROTO :DWORD,:DWORD         ; main.asm: kind, result

; ---------------------------------------------------------------------------
; UDF (udf.asm reader, udfwrite.asm writer)
; ---------------------------------------------------------------------------
UdfOpen             PROTO                       ; after IsoOpen -> TRUE when a UDF root was found
UdfClose            PROTO
UdfBuildTree        PROTO :DWORD                ; pRootNode -> node count
EXTERNDEF g_bUdf:DWORD
EXTERNDEF g_udfVersion:DWORD

UDF_PART_START      equ 257                     ; partition begins right after the anchor at 256
UdfLayout           PROTO                       ; assign FE / FID blocks from g_lba (call with g_lba == UDF_PART_START)
UdfEmitRecognition  PROTO                       ; BEA01 NSR02 TEA01 at the current g_lba
UdfEmitPreamble     PROTO                       ; pad to 32, VDS x2, LVID, pad to 256, AVDP (leaves g_lba == 257)
UdfEmitPartition    PROTO                       ; FSD, TD, every FE and directory FID stream
UdfEmitTrailer      PROTO                       ; closing AVDP (last block)
EXTERNDEF g_totalSectors:DWORD
SectorsFor64        PROTO :DWORD,:DWORD         ; lo, hi -> blocks
; isowrite.asm staging shared with udfwrite.asm
SectorsFor          PROTO :DWORD
FillBytes           PROTO :DWORD,:DWORD,:DWORD
SecBegin            PROTO
SecWrite            PROTO
SecFlush            PROTO
SecPutBytes         PROTO :DWORD,:DWORD
EXTERNDEF g_pSec:DWORD
EXTERNDEF g_fail:DWORD
FID_DIR_FLAG        equ 02h
FID_PARENT_DIR      equ 0Ah
EXTERNDEF g_progDoneHi:DWORD
EXTERNDEF g_progTotalHi:DWORD

; ---------------------------------------------------------------------------
; DEFLATE codec (deflate.asm): inflate + fixed-Huffman compress, gzip / zip / CSO wrappers
; ---------------------------------------------------------------------------
RtlComputeCrc32     PROTO :DWORD,:DWORD,:DWORD  ; seed, pData, cb -> running CRC-32 (ntdll)
GzExpandFile        PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL (CRC verified)
ZipExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, largest stored/deflated entry
CsoExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, CISO v0/v1
GczExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, Dolphin GCZ
DaxExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, PSP DAX
JsoExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, PSP JSO (deflate method)
IszExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, UltraISO ISZ (zlib chunks)
DaaExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, PowerISO DAA v0x100
ChdExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, MAME CHD v5
UifExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, MagicISO UIF
DmgExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, Apple UDIF (zlib/raw/zero)
PbpExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, PSP EBOOT holding a PS1 disc
BzExpandFile        PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, whole-file bzip2 stream
ZsDecode            PROTO :DWORD,:DWORD,:DWORD,:DWORD  ; pIn, cbIn, pOut, cbOutMax -> bytes produced, 0 on error
EXTERNDEF g_zsErr:DWORD                             ; which check declined the frame, for the test harness
RvzExpandFile       PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, Dolphin RVZ holding a GameCube disc
BzDecodeStream      PROTO                      ; one bzip2 stream from the current input -> BOOL
BzFree              PROTO                      ; release the block buffer between images
; the pieces of the deflate session bzip2.asm shares: same input, same output,
; same sticky error flag, so the two codecs stay interchangeable to a caller
EXTERNDEF g_zfErr:DWORD
EXTERNDEF g_zfHOut:DWORD
ZfInByte            PROTO                      ; next input byte in eax, sets g_zfErr at the end
ZfPutB              PROTO :DWORD               ; one byte to the output buffer
ZfPutMem            PROTO :DWORD,:DWORD        ; pSrc, cb
ZfPutZeros          PROTO :DWORD               ; cb
ZfBeginOut          PROTO :DWORD,:DWORD,:DWORD,:DWORD  ; pszDst, hIn, cbLo, cbHi -> hOut or INVALID_HANDLE_VALUE
ZfOutFinal          PROTO
ZfExpandFree        PROTO
ZfClosePair         PROTO :DWORD,:DWORD,:DWORD  ; ok, hIn, pszDst -> ok (closes the session's output)
ZfRunExpander       PROTO :DWORD,:DWORD,:DWORD  ; pszSrc, pszDst, body(hIn, pszDst) -> BOOL
GzCompressFile      PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL; worker progress + Cancel
ZipCompressFile     PROTO :DWORD,:DWORD,:DWORD  ; pszSrc, pszDst, pszEntry (UTF-16) -> BOOL, one deflated entry, zip64 past 4 GB
CsoCompressFile     PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> BOOL, CSO v1 with 2 KB deflate blocks
IszCompressFile     PROTO :DWORD,:DWORD        ; the block-container writers in writers.asm
DaxCompressFile     PROTO :DWORD,:DWORD
JsoCompressFile     PROTO :DWORD,:DWORD
GczCompressFile     PROTO :DWORD,:DWORD
UifCompressFile     PROTO :DWORD,:DWORD
DaaCompressFile     PROTO :DWORD,:DWORD
DmgCompressFile     PROTO :DWORD,:DWORD
; the compressor session pieces those writers share
DfSetup             PROTO :DWORD               ; hOut -> BOOL
DfTeardown          PROTO
DfOpenPair          PROTO :DWORD,:DWORD        ; pszSrc, pszDst -> hIn in eax, hOut in edx, or 0
DfClosePair         PROTO :DWORD,:DWORD,:DWORD,:DWORD  ; ok, hIn, hOut, pszDst -> ok
DfWriteRaw          PROTO :DWORD,:DWORD        ; pData, cb to the session's output
DfBlockDeflate      PROTO :DWORD,:DWORD        ; cb of the chunk buffer, zlib framing -> length in g_dfOut
DfAdler32           PROTO :DWORD,:DWORD        ; pData, cb
EXTERNDEF g_dfChunkPtr:DWORD
EXTERNDEF g_dfOut:DWORD
EXTERNDEF g_dfErr:DWORD
EXTERNDEF g_dfSizeLo:DWORD
EXTERNDEF g_dfSizeHi:DWORD
EXTERNDEF g_saveKind:DWORD                      ; SAVE_*: how the worker finishes the image after IsoWrite
SAVE_NONE               equ 0
SAVE_GZ                 equ 1
SAVE_ZIP                equ 2
SAVE_CSO                equ 3
SAVE_ISZ                equ 4
SAVE_DAX                equ 5
SAVE_JSO                equ 6
SAVE_GCZ                equ 7
SAVE_UIF                equ 8
SAVE_DAA                equ 9
SAVE_DMG                equ 10

; ---------------------------------------------------------------------------
; Optical containers (container.asm): NRG, MDS/MDF, CCD/IMG, GDI, TOC, generic scan
; ---------------------------------------------------------------------------
BSwap32             PROTO :DWORD                ; big-endian dword swap (container.asm)
BE32                PROTO :DWORD                ; big-endian dword at a pointer (opera.asm)

; ---------------------------------------------------------------------------
; CD audio (audio.asm): track table filled by containers, WAV serving, playback
; ---------------------------------------------------------------------------
CT_MAXTRK           equ 99
CtTrackAdd          PROTO :DWORD,:DWORD,:DWORD,:DWORD   ; offLo, offHi, pcmBytes, audio
CdaCopyData         PROTO :DWORD,:DWORD                 ; pNode, hOut -> BOOL (WAV header + PCM)
VfsAddCdTracks      PROTO :DWORD                        ; pRootNode
AudioToggle         PROTO :DWORD                        ; pNode -> starts or stops playback
AudioStop           PROTO
AudioOnDone         PROTO :DWORD                        ; LPWAVEHDR from MM_WOM_DONE
EXTERNDEF g_ctTracks:DWORD                              ; CT_MAXTRK entries: offLo, offHi, pcmBytes, audio
EXTERNDEF g_ctNumTracks:DWORD
EXTERNDEF g_ctAudioSwap:DWORD                           ; PCM stored big-endian (CHD)
EXTERNDEF g_bAudioOnly:DWORD                            ; image has audio tracks but no filesystem

MM_WOM_DONE         equ 3BDh
CALLBACK_WINDOW     equ 10000h
WAVE_MAPPER         equ -1
WHDR_PREPARED       equ 2

WAVEFORMATEX STRUCT 2
    wFormatTag      WORD ?
    nChannels       WORD ?
    nSamplesPerSec  DWORD ?
    nAvgBytesPerSec DWORD ?
    nBlockAlign     WORD ?
    wBitsPerSample  WORD ?
    cbSize          WORD ?
WAVEFORMATEX ENDS

WAVEHDR STRUCT
    lpData          DWORD ?
    dwBufferLength  DWORD ?
    dwBytesRecorded DWORD ?
    dwUser          DWORD ?
    dwFlags         DWORD ?
    dwLoops         DWORD ?
    lpNext          DWORD ?
    reserved        DWORD ?
WAVEHDR ENDS

waveOutOpen         PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
waveOutClose        PROTO :DWORD
waveOutReset        PROTO :DWORD
waveOutPrepareHeader PROTO :DWORD,:DWORD,:DWORD
waveOutUnprepareHeader PROTO :DWORD,:DWORD,:DWORD
waveOutWrite        PROTO :DWORD,:DWORD,:DWORD
CtBuildOpenFilter   PROTO :DWORD,:DWORD,:DWORD  ; pDst, "Disc Images", the All Files pair -> filter string
CtResolve           PROTO :DWORD                ; pszPath -> TRUE when recognised (geometry + g_szBinPath set)
CtResolveByScan     PROTO :DWORD                ; pszPath -> TRUE when an ISO 9660 descriptor was found inside
CtReset             PROTO
EXTERNDEF g_ctBaseLo:DWORD
EXTERNDEF g_ctBaseHi:DWORD
EXTERNDEF g_ctSecSize:DWORD
EXTERNDEF g_ctSecOff:DWORD
EXTERNDEF g_ctLbaBase:DWORD
EXTERNDEF g_ctName:DWORD
EXTERNDEF g_bContainer:DWORD

; ---------------------------------------------------------------------------
; Foreign disc filesystems (read-only): xdvdfs.asm, opera.asm
; ---------------------------------------------------------------------------
XdvdfsDetect        PROTO                       ; -> TRUE when an Xbox volume descriptor was found
XdvdfsBuild         PROTO :DWORD                ; pRootNode
XdvdfsClose         PROTO
OperaDetect         PROTO
OperaBuild          PROTO :DWORD
OperaClose          PROTO
GcDetect            PROTO                       ; -> TRUE when a GameCube disc header was found
GcBuild             PROTO :DWORD                ; pRootNode
GcClose             PROTO
EXTERNDEF g_bXdvdfs:DWORD
EXTERNDEF g_bOpera:DWORD
EXTERNDEF g_bGcm:DWORD
EXTERNDEF g_bCdi:DWORD

; main.asm commands callable from ui
AppCommand          PROTO :DWORD                ; id
IDM_REFRESH             equ 199
WM_CLOSE                equ 0010h
OFN_ALLOWMULTISELECT    equ 0200h
PostMessageW        PROTO :DWORD,:DWORD,:DWORD,:DWORD
Scale               PROTO :DWORD                ; ui.asm: MulDiv(value, g_dpi, 96)
UiOnNotify          PROTO :DWORD                ; pNMHDR -> LRESULT
UiContextMenu       PROTO :DWORD,:DWORD,:DWORD  ; hwndFrom, xScreen, yScreen
UiOnDropFiles       PROTO :DWORD                ; hDrop
UiCtxDir            PROTO                       ; -> directory NODE* that New Folder/File/Add target
UiCtxIsTree         PROTO                       ; -> nonzero when the context menu came from the tree

; ---------------------------------------------------------------------------
; FoxImg cross-module symbols
; ---------------------------------------------------------------------------
; iso9660.asm
FMT_ISO         equ 0                           ; 2048-byte blocks (.iso/.img/.bin MODE1/2048)
FMT_RAW2352_M1  equ 1                           ; raw 2352 MODE1  (data at +16)
FMT_RAW2352_M2  equ 2                           ; raw 2352 MODE2 form 1 (data at +24)
FMT_RAW2336     equ 3                           ; MODE2/2336 (data at +8)
IsoSectorPtr    PROTO :DWORD
EXTERNDEF szSync:BYTE                           ; the 12-byte CD sync pattern (iso9660.asm)                    ; lba -> pointer to 2048 user bytes or 0
IsoCopyExtent   PROTO :DWORD,:DWORD,:DWORD      ; lba, cb, hOut -> BOOL
IsoReadExtent   PROTO :DWORD,:DWORD,:DWORD      ; lba, cb, pDst -> BOOL
IsoCopyBytes    PROTO :DWORD,:DWORD,:DWORD,:DWORD   ; lba, byteRem, cb, hOut -> BOOL
IsoReadBytes    PROTO :DWORD,:DWORD,:DWORD,:DWORD   ; lba, byteRem, cb, pDst -> BOOL
IsoFormatName   PROTO :DWORD                    ; pszBuf (>= 48 WCHARs)
lstrlenA        PROTO :DWORD
lstrcmpA        PROTO :DWORD,:DWORD
lstrcpyA        PROTO :DWORD,:DWORD
lstrcatA        PROTO :DWORD,:DWORD
EXTERNDEF g_secSize:DWORD
EXTERNDEF g_nSectors:DWORD
EXTERNDEF g_fmt:DWORD
EXTERNDEF g_bCue:DWORD
EXTERNDEF g_szBinPath:WORD
IsoOpen         PROTO :DWORD                    ; pszPath -> BOOL
IsoClose        PROTO
IsoEnumDir      PROTO :DWORD,:DWORD,:DWORD,:DWORD ; lba, cb, pfnCallback(pRec, lParam) -> continue?, lParam
IsoRootRecord   PROTO                           ; -> pointer to the root directory record (valid until the next block fetch)
IsoRecName      PROTO :DWORD,:DWORD,:DWORD      ; pRec, pszBuf, cchBuf
IsoVolumeName   PROTO :DWORD,:DWORD             ; pszBuf, cchBuf

EXTERNDEF g_pView:DWORD                         ; nonzero while an image is open
EXTERNDEF g_cbFileLo:DWORD
EXTERNDEF g_cbFileHi:DWORD
EXTERNDEF g_bJoliet:DWORD

; strutil.asm
PathExt         PROTO :DWORD                    ; pszPath -> pointer to ".ext" or the NUL
PathLeaf        PROTO :DWORD                    ; pszPath -> pointer to the leaf
PathWithExt     PROTO :DWORD,:DWORD,:DWORD      ; pszOut, pszPath, pszNewExt
HasExt          PROTO :DWORD,:DWORD             ; pszPath, pszExt -> BOOL
PathDirJoin     PROTO :DWORD,:DWORD,:DWORD      ; pszOut, pszRef, pszName (relative to pszRef's directory)
FindKeyword     PROTO :DWORD,:DWORD,:DWORD      ; pBuf, cb, pszKeyA -> pointer past it or 0
ParseUint       PROTO :DWORD                    ; pText -> eax value, edx next
ParseName       PROTO :DWORD,:DWORD             ; pText, pszOut -> edx next
FileOpenRead    PROTO :DWORD                    ; pszPath -> handle or INVALID_HANDLE_VALUE
FileOpenReadSeq PROTO :DWORD                    ; same, for whole-file one-pass readers
FilePresize     PROTO :DWORD,:DWORD,:DWORD      ; hFile, cbLo, cbHi - reserve the extent up front
FileReadAt      PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD  ; hFile, offLo, offHi, pDst, cb -> bytes read
FileSize64      PROTO :DWORD,:DWORD,:DWORD      ; hFile, pLo, pHi
ReadTextFile    PROTO :DWORD,:DWORD             ; pszPath, pcb -> heap buffer or 0
EXTERNDEF g_szJoinFmt:WORD
EXTERNDEF g_szCatFmt:WORD
EXTERNDEF g_szUintFmt:WORD

; ui.asm
UiCreateControls PROTO :DWORD                   ; hWndParent
UiLayout        PROTO :DWORD                    ; hWndParent
UiSetStatus     PROTO :DWORD                    ; pszText

EXTERNDEF g_hInst:DWORD
EXTERNDEF g_hWnd:DWORD
EXTERNDEF g_hTree:DWORD
EXTERNDEF g_hList:DWORD
EXTERNDEF g_hStatus:DWORD
EXTERNDEF g_hFont:DWORD
