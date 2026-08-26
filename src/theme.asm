; FoxImg - dark mode (follows the Windows "Choose your app mode" setting)
include foximg.inc

; Undocumented uxtheme exports (Windows 10 1809+), imported by ordinal at runtime so the app still runs without them.
UXTHEME_ALLOWDARKMODEFORWINDOW  equ 133     ; BOOL WINAPI AllowDarkModeForWindow(HWND, BOOL)
UXTHEME_SETPREFERREDAPPMODE     equ 135     ; PreferredAppMode WINAPI SetPreferredAppMode(PreferredAppMode)
UXTHEME_FLUSHMENUTHEMES         equ 136     ; void WINAPI FlushMenuThemes(void)
APPMODE_FORCEDARK               equ 2
APPMODE_FORCELIGHT              equ 3

; COLORREF values are 00BBGGRR
DARK_WINDOW_BG      equ 00202020h
DARK_CTRL_BG        equ 00191919h
DARK_TEXT           equ 00E0E0E0h
DARK_LINES          equ 00505050h
DARK_STATUS_BG      equ 002B2B2Bh
DARK_MENU_HOT       equ 003A3A3Ah
DARK_TEXT_GRAY      equ 00808080h

.data
g_bDark             dd 0
g_hbrWindow         dd 0
g_hbrStatus         dd 0
g_hbrMenuHot        dd 0
g_pfnSetPreferredAppMode    dd 0
g_pfnAllowDarkModeForWindow dd 0
g_pfnFlushMenuThemes        dd 0

WSTR szUxTheme, <uxtheme.dll>
WSTR szDarkExplorer, <DarkMode_Explorer>
WSTR szDarkItemsView, <DarkMode_ItemsView>
WSTR szExplorer, <Explorer>
WSTR szPersonalizeKey, <Software\Microsoft\Windows\CurrentVersion\Themes\Personalize>
WSTR szAppsUseLightTheme, <AppsUseLightTheme>
WSTR szImmersiveColorSet, <ImmersiveColorSet>

.code

ThemeDetect         PROTO
ThemeSetAppMode     PROTO
ThemeCreateBrushes  PROTO
AllowDark           PROTO :DWORD

; ---------------------------------------------------------------------------
; ThemeDetect - read HKCU\...\Personalize\AppsUseLightTheme; missing value means light
; ---------------------------------------------------------------------------
ThemeDetect PROC
    LOCAL dwVal:DWORD
    LOCAL cb:DWORD
    mov dwVal, 1
    mov cb, 4
    invoke RegGetValueW, HKEY_CURRENT_USER, offset szPersonalizeKey, offset szAppsUseLightTheme, RRF_RT_REG_DWORD, NULL, addr dwVal, addr cb
    mov g_bDark, 0
    .IF eax == 0 && dwVal == 0
        mov g_bDark, 1
    .ENDIF
    mov eax, g_bDark
    ret
ThemeDetect ENDP

; ---------------------------------------------------------------------------
; ThemeInit - call once before creating any windows
; ---------------------------------------------------------------------------
ThemeInit PROC
    invoke ThemeDetect

    invoke LoadLibraryW, offset szUxTheme
    .IF eax != 0
        push eax
        invoke GetProcAddress, eax, UXTHEME_SETPREFERREDAPPMODE
        mov g_pfnSetPreferredAppMode, eax
        mov eax, [esp]
        invoke GetProcAddress, eax, UXTHEME_ALLOWDARKMODEFORWINDOW
        mov g_pfnAllowDarkModeForWindow, eax
        pop eax
        invoke GetProcAddress, eax, UXTHEME_FLUSHMENUTHEMES
        mov g_pfnFlushMenuThemes, eax
    .ENDIF

    invoke ThemeSetAppMode
    invoke ThemeCreateBrushes
    ret
ThemeInit ENDP

; ---------------------------------------------------------------------------
; ThemeSetAppMode - tells uxtheme which mode popup menus and tooltips should use
; ---------------------------------------------------------------------------
ThemeSetAppMode PROC
    .IF g_pfnSetPreferredAppMode != 0
        mov eax, APPMODE_FORCELIGHT
        .IF g_bDark != 0
            mov eax, APPMODE_FORCEDARK
        .ENDIF
        push eax
        call g_pfnSetPreferredAppMode
    .ENDIF
    .IF g_pfnFlushMenuThemes != 0
        call g_pfnFlushMenuThemes
    .ENDIF
    ret
ThemeSetAppMode ENDP

; ---------------------------------------------------------------------------
; ThemeCreateBrushes - (re)build the brushes used by WM_ERASEBKGND and the status bar
; ---------------------------------------------------------------------------
ThemeCreateBrushes PROC
    .IF g_hbrWindow != 0
        invoke DeleteObject, g_hbrWindow
    .ENDIF
    .IF g_hbrStatus != 0
        invoke DeleteObject, g_hbrStatus
    .ENDIF
    .IF g_hbrMenuHot != 0
        invoke DeleteObject, g_hbrMenuHot
        mov g_hbrMenuHot, 0
    .ENDIF
    .IF g_bDark != 0
        invoke CreateSolidBrush, DARK_WINDOW_BG
        mov g_hbrWindow, eax
        invoke CreateSolidBrush, DARK_STATUS_BG
        mov g_hbrStatus, eax
        invoke CreateSolidBrush, DARK_MENU_HOT
        mov g_hbrMenuHot, eax
    .ELSE
        invoke GetSysColor, COLOR_BTNFACE
        invoke CreateSolidBrush, eax
        mov g_hbrWindow, eax
        invoke GetSysColor, COLOR_BTNFACE
        invoke CreateSolidBrush, eax
        mov g_hbrStatus, eax
    .ENDIF
    ret
ThemeCreateBrushes ENDP

; ---------------------------------------------------------------------------
; AllowDark - per-window opt-in (no-op when the export is missing)
; ---------------------------------------------------------------------------
AllowDark PROC hWnd:DWORD
    .IF g_pfnAllowDarkModeForWindow != 0 && hWnd != 0
        push g_bDark
        push hWnd
        call g_pfnAllowDarkModeForWindow
    .ENDIF
    ret
AllowDark ENDP

; ---------------------------------------------------------------------------
; ListSubclassProc - intercepts the header's NM_CUSTOMDRAW so dark mode can recolour its text
; ---------------------------------------------------------------------------
.data
g_bListSubclassed   dd 0
.code

ListSubclassProc PROC hWnd:DWORD, uMsg:DWORD, wParam:DWORD, lParam:DWORD, uIdSubclass:DWORD, dwRefData:DWORD
    .IF uMsg == WM_DROPFILES
        invoke UiOnDropFiles, wParam
        xor eax, eax
        ret
    .ENDIF
    .IF uMsg == WM_NOTIFY && g_bDark != 0
        mov edx, lParam
        .IF [edx].NMHDR.code == NM_CUSTOMDRAW
            invoke SendMessageW, hWnd, LVM_GETHEADER, 0, 0
            mov edx, lParam
            .IF eax == [edx].NMHDR.hwndFrom
                mov eax, [edx].NMCUSTOMDRAW.dwDrawStage
                .IF eax == CDDS_PREPAINT
                    mov eax, CDRF_NOTIFYITEMDRAW
                    ret
                .ELSEIF eax == CDDS_ITEMPREPAINT
                    invoke SetTextColor, [edx].NMCUSTOMDRAW.hdc, DARK_TEXT
                    mov eax, CDRF_DODEFAULT
                    ret
                .ENDIF
            .ENDIF
        .ENDIF
    .ENDIF
    invoke DefSubclassProc, hWnd, uMsg, wParam, lParam
    ret
ListSubclassProc ENDP

; ---------------------------------------------------------------------------
; ThemeApply - push the current mode into the frame and every control
; ---------------------------------------------------------------------------
ThemeApply PROC hWnd:DWORD
    LOCAL bDark:DWORD
    LOCAL hHeader:DWORD
    LOCAL pTheme:DWORD

    mov eax, g_bDark
    mov bDark, eax

    ; Title bar
    invoke DwmSetWindowAttribute, hWnd, DWMWA_USE_IMMERSIVE_DARK_MODE, addr bDark, 4

    invoke AllowDark, hWnd
    invoke AllowDark, g_hTree
    invoke AllowDark, g_hList
    invoke AllowDark, g_hStatus

    ; Visual style subclasses: dark scrollbars, headers, selection highlights
    mov pTheme, offset szExplorer
    .IF g_bDark != 0
        mov pTheme, offset szDarkExplorer
    .ENDIF
    invoke SetWindowTheme, g_hTree, pTheme, NULL
    invoke SetWindowTheme, g_hList, pTheme, NULL
    .IF g_hEdit != 0
        invoke SetWindowTheme, g_hEdit, pTheme, NULL
    .ENDIF

    invoke SendMessageW, g_hList, LVM_GETHEADER, 0, 0
    mov hHeader, eax
    .IF eax != 0
        invoke AllowDark, hHeader
        mov pTheme, offset szExplorer
        .IF g_bDark != 0
            mov pTheme, offset szDarkItemsView
        .ENDIF
        invoke SetWindowTheme, hHeader, pTheme, NULL
    .ENDIF

    ; Content colours
    .IF g_bDark != 0
        invoke SendMessageW, g_hTree, TVM_SETBKCOLOR, 0, DARK_CTRL_BG
        invoke SendMessageW, g_hTree, TVM_SETTEXTCOLOR, 0, DARK_TEXT
        invoke SendMessageW, g_hTree, TVM_SETLINECOLOR, 0, DARK_LINES
        invoke SendMessageW, g_hList, LVM_SETBKCOLOR, 0, DARK_CTRL_BG
        invoke SendMessageW, g_hList, LVM_SETTEXTBKCOLOR, 0, DARK_CTRL_BG
        invoke SendMessageW, g_hList, LVM_SETTEXTCOLOR, 0, DARK_TEXT
        invoke SendMessageW, g_hStatus, SB_SETBKCOLOR, 0, DARK_STATUS_BG
    .ELSE
        invoke SendMessageW, g_hTree, TVM_SETBKCOLOR, 0, -1
        invoke SendMessageW, g_hTree, TVM_SETTEXTCOLOR, 0, -1
        invoke SendMessageW, g_hTree, TVM_SETLINECOLOR, 0, CLR_DEFAULT
        invoke GetSysColor, COLOR_WINDOW
        push eax
        invoke SendMessageW, g_hList, LVM_SETBKCOLOR, 0, eax
        pop eax
        invoke SendMessageW, g_hList, LVM_SETTEXTBKCOLOR, 0, eax
        invoke GetSysColor, COLOR_WINDOWTEXT
        invoke SendMessageW, g_hList, LVM_SETTEXTCOLOR, 0, eax
        invoke SendMessageW, g_hStatus, SB_SETBKCOLOR, 0, CLR_DEFAULT
    .ENDIF

    ; The header notifies the ListView, not us; subclass once so its text colour can follow the theme
    .IF g_bListSubclassed == 0
        invoke SetWindowSubclass, g_hList, offset ListSubclassProc, 1, 0
        mov g_bListSubclassed, eax
    .ENDIF

    ; Status text switches between owner-draw (dark) and native (light)
    invoke UiSetStatus, offset g_szStatus

    invoke RedrawWindow, hWnd, NULL, NULL, RDW_INVALIDATE or RDW_ERASE or RDW_ALLCHILDREN or RDW_FRAME
    ret
ThemeApply ENDP

; ---------------------------------------------------------------------------
; ThemeOnSettingChange - WM_SETTINGCHANGE handler; re-applies when the colour mode flips
; ---------------------------------------------------------------------------
ThemeOnSettingChange PROC hWnd:DWORD, lParam:DWORD
    .IF lParam == 0
        ret
    .ENDIF
    invoke lstrcmpiW, lParam, offset szImmersiveColorSet
    .IF eax != 0
        ret
    .ENDIF
    invoke ThemeDetect
    invoke ThemeSetAppMode
    invoke ThemeCreateBrushes
    invoke ThemeApply, hWnd
    ret
ThemeOnSettingChange ENDP

; ---------------------------------------------------------------------------
; Menu bar: DWM leaves the bar to user32, which has no dark theme; paint it ourselves
; ---------------------------------------------------------------------------
; MenuBarRect - bar rectangle in window coordinates
MenuBarRect PROC USES esi hWnd:DWORD, pRect:DWORD
    LOCAL mbi:MENUBARINFO
    LOCAL rcWin:RECT
    mov mbi.cbSize, sizeof MENUBARINFO
    invoke GetMenuBarInfo, hWnd, OBJID_MENU, 0, addr mbi
    .IF eax == 0
        ret
    .ENDIF
    invoke GetWindowRect, hWnd, addr rcWin
    mov esi, pRect
    mov eax, mbi.rcBar.left
    sub eax, rcWin.left
    mov [esi].RECT.left, eax
    mov eax, mbi.rcBar.right
    sub eax, rcWin.left
    mov [esi].RECT.right, eax
    mov eax, mbi.rcBar.top
    sub eax, rcWin.top
    mov [esi].RECT.top, eax
    mov eax, mbi.rcBar.bottom
    sub eax, rcWin.top
    mov [esi].RECT.bottom, eax
    mov eax, TRUE
    ret
MenuBarRect ENDP

ThemeDrawMenuBar PROC USES esi hWnd:DWORD, pUAH:DWORD
    LOCAL rc:RECT
    .IF g_bDark == 0
        xor eax, eax
        ret
    .ENDIF
    invoke MenuBarRect, hWnd, addr rc
    .IF eax != 0
        mov esi, pUAH
        invoke FillRect, [esi].UAHMENU.hdc, addr rc, g_hbrWindow
    .ENDIF
    mov eax, TRUE
    ret
ThemeDrawMenuBar ENDP

ThemeDrawMenuItem PROC USES esi ebx hWnd:DWORD, pDMI:DWORD
    LOCAL mii:MENUITEMINFOW
    LOCAL szText[128]:WORD
    LOCAL hbr:DWORD
    LOCAL flags:DWORD

    .IF g_bDark == 0
        xor eax, eax
        ret
    .ENDIF
    mov esi, pDMI

    mov szText[0], 0
    mov mii.cbSize, sizeof MENUITEMINFOW
    mov mii.fMask, MIIM_STRING
    lea eax, szText
    mov mii.dwTypeData, eax
    mov mii.cch, 128
    invoke GetMenuItemInfoW, [esi].UAHDRAWMENUITEM.um.hmenu, [esi].UAHDRAWMENUITEM.umi.iPosition, TRUE, addr mii

    mov ebx, [esi].UAHDRAWMENUITEM.ditem.itemState

    push g_hbrWindow
    pop hbr
    test ebx, ODS_HOTLIGHT or ODS_SELECTED
    .IF !ZERO?
        push g_hbrMenuHot
        pop hbr
    .ENDIF
    invoke FillRect, [esi].UAHDRAWMENUITEM.ditem.hDC, addr [esi].UAHDRAWMENUITEM.ditem.rcItem, hbr

    invoke SetBkMode, [esi].UAHDRAWMENUITEM.ditem.hDC, TRANSPARENT
    mov eax, DARK_TEXT
    test ebx, ODS_GRAYED or ODS_INACTIVE
    .IF !ZERO?
        mov eax, DARK_TEXT_GRAY
    .ENDIF
    invoke SetTextColor, [esi].UAHDRAWMENUITEM.ditem.hDC, eax
    invoke SelectObject, [esi].UAHDRAWMENUITEM.ditem.hDC, g_hFont

    mov flags, DT_CENTER or DT_SINGLELINE or DT_VCENTER
    test ebx, ODS_NOACCEL
    .IF !ZERO?
        or flags, DT_HIDEPREFIX
    .ENDIF
    invoke DrawTextW, [esi].UAHDRAWMENUITEM.ditem.hDC, addr szText, -1, addr [esi].UAHDRAWMENUITEM.ditem.rcItem, flags
    mov eax, TRUE
    ret
ThemeDrawMenuItem ENDP

; After DefWindowProc paints the frame, cover the 1px light line user32 draws under the bar
ThemeDrawMenuBottomLine PROC hWnd:DWORD
    LOCAL rc:RECT
    LOCAL hdc:DWORD
    .IF g_bDark == 0
        ret
    .ENDIF
    invoke MenuBarRect, hWnd, addr rc
    .IF eax == 0
        ret
    .ENDIF
    mov eax, rc.bottom
    mov rc.top, eax
    inc eax
    mov rc.bottom, eax
    invoke GetWindowDC, hWnd
    mov hdc, eax
    invoke FillRect, hdc, addr rc, g_hbrWindow
    invoke ReleaseDC, hWnd, hdc
    ret
ThemeDrawMenuBottomLine ENDP

; ---------------------------------------------------------------------------
; ThemeEraseBkgnd - WM_ERASEBKGND; returns TRUE
; ---------------------------------------------------------------------------
ThemeEraseBkgnd PROC hWnd:DWORD, hdc:DWORD
    LOCAL rc:RECT
    invoke GetClientRect, hWnd, addr rc
    invoke FillRect, hdc, addr rc, g_hbrWindow
    mov eax, TRUE
    ret
ThemeEraseBkgnd ENDP

; ---------------------------------------------------------------------------
; ThemeDrawStatus - WM_DRAWITEM for the owner-drawn status bar text (dark mode only)
; ---------------------------------------------------------------------------
ThemeDrawStatus PROC USES esi pDIS:DWORD
    LOCAL rc:RECT
    LOCAL pszText:DWORD
    mov esi, pDIS
    invoke UiStatusText, [esi].DRAWITEMSTRUCT.itemID
    mov pszText, eax
    invoke FillRect, [esi].DRAWITEMSTRUCT.hDC, addr [esi].DRAWITEMSTRUCT.rcItem, g_hbrStatus
    invoke SetBkMode, [esi].DRAWITEMSTRUCT.hDC, TRANSPARENT
    invoke SetTextColor, [esi].DRAWITEMSTRUCT.hDC, DARK_TEXT
    invoke SelectObject, [esi].DRAWITEMSTRUCT.hDC, g_hFont
    mov eax, [esi].DRAWITEMSTRUCT.rcItem.left
    add eax, 4
    mov rc.left, eax
    mov eax, [esi].DRAWITEMSTRUCT.rcItem.top
    mov rc.top, eax
    mov eax, [esi].DRAWITEMSTRUCT.rcItem.right
    mov rc.right, eax
    mov eax, [esi].DRAWITEMSTRUCT.rcItem.bottom
    mov rc.bottom, eax
    invoke DrawTextW, [esi].DRAWITEMSTRUCT.hDC, pszText, -1, addr rc, DT_SINGLELINE or DT_VCENTER or DT_NOPREFIX or DT_END_ELLIPSIS
    mov eax, TRUE
    ret
ThemeDrawStatus ENDP

END
