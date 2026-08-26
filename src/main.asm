; FoxImg - entry point, main window, message loop
include foximg.inc

.data
g_hInst     dd 0
g_hWnd      dd 0
g_hAccel    dd 0

WSTR szClassName, <FoxImgMain>
WSTR szTitle, <FoxImg>
WSTR szOpenTitle, <Open Disc Image>
WSTR szErrTitle, <FoxImg>
WSTR szErrOpen, <Could not open this image. It is not a readable ISO 9660 volume, or it is larger than 2 GB (not supported yet).>
WSTR szAboutText, <FoxImg - a small native disc image utility. ISO 9660 and Joliet browsing.>

szFilter LABEL WORD
    dw 'I','S','O',' ','I','m','a','g','e','s',' ','(','*','.','i','s','o',')',0
    dw '*','.','i','s','o',0
    dw 'A','l','l',' ','F','i','l','e','s',' ','(','*','.','*',')',0
    dw '*','.','*',0
    dw 0

szTitleFmt  dw 'F','o','x','I','m','g',' ','-',' ','%','s',0

.data?
g_szPath    dw MAX_PATH dup(?)
g_szTitle   dw MAX_PATH + 16 dup(?)

.code

; ---------------------------------------------------------------------------
; LoadImage - open the file in g_szPath and populate the UI
; ---------------------------------------------------------------------------
LoadImage PROC hWnd:DWORD
    invoke IsoOpen, offset g_szPath
    .IF eax == 0
        invoke MessageBoxW, hWnd, offset szErrOpen, offset szErrTitle, MB_OK or MB_ICONERROR
        ret
    .ENDIF
    invoke wsprintfW, offset g_szTitle, offset szTitleFmt, offset g_szPath
    invoke SetWindowTextW, hWnd, offset g_szTitle
    invoke UiFillTree
    ret
LoadImage ENDP

; ---------------------------------------------------------------------------
; ParseCommandLine - copy the first argument after the program name into g_szPath (quotes stripped)
; Returns eax = TRUE if an argument was present
; ---------------------------------------------------------------------------
ParseCommandLine PROC USES esi edi
    invoke GetCommandLineW
    mov esi, eax

    ; skip program name: quoted or up to first space
    .IF word ptr [esi] == '"'
        add esi, 2
        .WHILE word ptr [esi] != 0 && word ptr [esi] != '"'
            add esi, 2
        .ENDW
        .IF word ptr [esi] == '"'
            add esi, 2
        .ENDIF
    .ELSE
        .WHILE word ptr [esi] != 0 && word ptr [esi] != ' '
            add esi, 2
        .ENDW
    .ENDIF

    ; skip whitespace
    .WHILE word ptr [esi] == ' ' || word ptr [esi] == 9
        add esi, 2
    .ENDW
    .IF word ptr [esi] == 0
        xor eax, eax
        ret
    .ENDIF

    ; copy argument, honouring surrounding quotes
    mov edi, offset g_szPath
    mov ecx, MAX_PATH - 1
    .IF word ptr [esi] == '"'
        add esi, 2
        .WHILE ecx != 0 && word ptr [esi] != 0 && word ptr [esi] != '"'
            movsw
            dec ecx
        .ENDW
    .ELSE
        .WHILE ecx != 0 && word ptr [esi] != 0 && word ptr [esi] != ' '
            movsw
            dec ecx
        .ENDW
    .ENDIF
    xor eax, eax
    stosw
    mov eax, TRUE
    ret
ParseCommandLine ENDP

; ---------------------------------------------------------------------------
; OnOpen - file dialog, then load and display the image
; ---------------------------------------------------------------------------
OnOpen PROC hWnd:DWORD
    LOCAL ofn:OPENFILENAMEW

    invoke RtlZeroMemory, addr ofn, sizeof OPENFILENAMEW
    mov ofn.lStructSize, sizeof OPENFILENAMEW
    push hWnd
    pop ofn.hwndOwner
    push g_hInst
    pop ofn.hInstance
    mov ofn.lpstrFilter, offset szFilter
    mov ofn.nFilterIndex, 1
    mov ofn.lpstrFile, offset g_szPath
    mov ofn.nMaxFile, MAX_PATH
    mov ofn.lpstrTitle, offset szOpenTitle
    mov ofn.Flags, OFN_EXPLORER or OFN_FILEMUSTEXIST or OFN_PATHMUSTEXIST or OFN_HIDEREADONLY

    invoke GetOpenFileNameW, addr ofn
    .IF eax != 0
        invoke LoadImage, hWnd
    .ENDIF
    ret
OnOpen ENDP

; ---------------------------------------------------------------------------
; WndProc
; ---------------------------------------------------------------------------
WndProc PROC hWnd:DWORD, uMsg:DWORD, wParam:DWORD, lParam:DWORD
    mov eax, uMsg
    .IF eax == WM_CREATE
        invoke UiCreateControls, hWnd
        invoke ThemeApply, hWnd
    .ELSEIF eax == WM_SIZE
        invoke UiLayout, hWnd
    .ELSEIF eax == WM_ERASEBKGND
        invoke ThemeEraseBkgnd, hWnd, wParam
        ret
    .ELSEIF eax == WM_DRAWITEM
        .IF g_bDark != 0
            invoke ThemeDrawStatus, lParam
            ret
        .ENDIF
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ELSEIF eax == WM_SETTINGCHANGE
        invoke ThemeOnSettingChange, hWnd, lParam
    .ELSEIF eax == WM_UAHDRAWMENU
        invoke ThemeDrawMenuBar, hWnd, lParam
        .IF eax != 0
            ret
        .ENDIF
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ELSEIF eax == WM_UAHDRAWMENUITEM
        invoke ThemeDrawMenuItem, hWnd, lParam
        .IF eax != 0
            ret
        .ENDIF
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ELSEIF eax == WM_NCPAINT || eax == WM_NCACTIVATE
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        push eax
        invoke ThemeDrawMenuBottomLine, hWnd
        pop eax
        ret
    .ELSEIF eax == WM_DPICHANGED
        movzx eax, word ptr wParam
        invoke UiUpdateDpi, hWnd, eax
        mov edx, lParam                         ; suggested new window rect
        mov eax, [edx].RECT.right
        sub eax, [edx].RECT.left
        mov ecx, [edx].RECT.bottom
        sub ecx, [edx].RECT.top
        invoke SetWindowPos, hWnd, NULL, [edx].RECT.left, [edx].RECT.top, eax, ecx, SWP_NOZORDER or SWP_NOACTIVATE
    .ELSEIF eax == WM_COMMAND
        movzx eax, word ptr wParam
        .IF eax == IDM_OPEN
            invoke OnOpen, hWnd
        .ELSEIF eax == IDM_EXIT
            invoke DestroyWindow, hWnd
        .ELSEIF eax == IDM_ABOUT
            invoke MessageBoxW, hWnd, offset szAboutText, offset szTitle, MB_OK or MB_ICONINFORMATION
        .ENDIF
    .ELSEIF eax == WM_NOTIFY
        mov edx, lParam
        mov ecx, [edx].NMHDR.code
        .IF ecx == TVN_SELCHANGEDW
            mov eax, [edx].NMTREEVIEWW.itemNew.lParam
            .IF eax != 0
                invoke UiFillList, eax
            .ENDIF
        .ENDIF
    .ELSEIF eax == WM_DESTROY
        invoke IsoClose
        invoke PostQuitMessage, 0
    .ELSE
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
    .ENDIF
    xor eax, eax
    ret
WndProc ENDP

; ---------------------------------------------------------------------------
; start - process entry (no CRT)
; ---------------------------------------------------------------------------
start PROC
    LOCAL wc:WNDCLASSEXW
    LOCAL msg:MSG
    LOCAL icc:INITCOMMONCONTROLSEX
    LOCAL hMenu:DWORD
    LOCAL rcWork:RECT
    LOCAL cxInit:DWORD
    LOCAL cyInit:DWORD

    invoke GetModuleHandleW, NULL
    mov g_hInst, eax

    mov icc.dwSize, sizeof INITCOMMONCONTROLSEX
    mov icc.dwICC, ICC_LISTVIEW_CLASSES or ICC_TREEVIEW_CLASSES or ICC_BAR_CLASSES
    invoke InitCommonControlsEx, addr icc
    invoke ThemeInit

    ; initial size: 65% of the primary work area, so it looks the same on a 1080p laptop and a 4K desktop
    invoke SystemParametersInfoW, SPI_GETWORKAREA, 0, addr rcWork, 0
    mov eax, rcWork.right
    sub eax, rcWork.left
    invoke MulDiv, eax, 65, 100
    mov cxInit, eax
    mov eax, rcWork.bottom
    sub eax, rcWork.top
    invoke MulDiv, eax, 65, 100
    mov cyInit, eax

    mov wc.cbSize, sizeof WNDCLASSEXW
    mov wc.style, CS_HREDRAW or CS_VREDRAW
    mov wc.lpfnWndProc, offset WndProc
    mov wc.cbClsExtra, 0
    mov wc.cbWndExtra, 0
    push g_hInst
    pop wc.hInstance
    invoke LoadIconW, g_hInst, IDI_APP
    mov wc.hIcon, eax
    mov wc.hIconSm, eax
    invoke LoadCursorW, NULL, IDC_ARROW
    mov wc.hCursor, eax
    mov wc.hbrBackground, NULL                  ; painted in WM_ERASEBKGND so dark mode can own it
    mov wc.lpszMenuName, NULL
    mov wc.lpszClassName, offset szClassName
    invoke RegisterClassExW, addr wc

    invoke LoadAcceleratorsW, g_hInst, IDR_ACCEL
    mov g_hAccel, eax
    invoke LoadMenuW, g_hInst, IDR_MAINMENU
    mov hMenu, eax

    invoke CreateWindowExW, 0, offset szClassName, offset szTitle, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, cxInit, cyInit, NULL, hMenu, g_hInst, NULL
    mov g_hWnd, eax
    invoke ShowWindow, g_hWnd, SW_SHOWDEFAULT
    invoke UpdateWindow, g_hWnd

    invoke ParseCommandLine
    .IF eax != 0
        invoke LoadImage, g_hWnd
    .ENDIF

    .WHILE TRUE
        invoke GetMessageW, addr msg, NULL, 0, 0
        .BREAK .IF eax == 0
        invoke TranslateAcceleratorW, g_hWnd, g_hAccel, addr msg
        .IF eax == 0
            invoke TranslateMessage, addr msg
            invoke DispatchMessageW, addr msg
        .ENDIF
    .ENDW

    invoke ExitProcess, msg.wParam
    ret
start ENDP

END start
