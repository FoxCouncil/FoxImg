; FoxImg - preview pane: text files and .ico files
include foximg.inc

PREVIEW_MAX     equ 65536
MAX_ICONS       equ 16
CLEARTYPE_QUALITY equ 5
PV_DARK_BG      equ 00191919h
PV_DARK_TEXT    equ 00E0E0E0h

.data
g_bPreview      dd 1
g_hEdit         dd 0
g_hIconView     dd 0
g_hFontMono     dd 0
g_hbrPreview    dd 0
g_brDark        dd -1           ; g_bDark value the brush was made for
g_nIcons        dd 0
g_hIcons        dd MAX_ICONS dup(0)
g_iconCx        dd MAX_ICONS dup(0)
g_iconCy        dd MAX_ICONS dup(0)

WSTR szEditClass, <EDIT>
WSTR szIconClass, <FoxImgIconView>
WSTR szConsolas, <Consolas>
WSTR szNoPreview, <No preview available for this file.>
WSTR szEmptyFile, <(empty file)>
WSTR szExtIco, <.ico>

.code

; ---------------------------------------------------------------------------
; Brush for the current theme (edit background + icon view background)
; ---------------------------------------------------------------------------
PreviewBrush PROC
    mov eax, g_bDark
    .IF eax != g_brDark
        .IF g_hbrPreview != 0
            invoke DeleteObject, g_hbrPreview
        .ENDIF
        .IF g_bDark != 0
            invoke CreateSolidBrush, PV_DARK_BG
        .ELSE
            invoke GetSysColor, COLOR_WINDOW
            invoke CreateSolidBrush, eax
        .ENDIF
        mov g_hbrPreview, eax
        mov eax, g_bDark
        mov g_brDark, eax
    .ENDIF
    mov eax, g_hbrPreview
    ret
PreviewBrush ENDP

PreviewCtlColor PROC hdc:DWORD, hwndCtl:DWORD
    mov eax, hwndCtl
    .IF eax != g_hEdit || eax == 0
        xor eax, eax
        ret
    .ENDIF
    .IF g_bDark != 0
        invoke SetTextColor, hdc, PV_DARK_TEXT
        invoke SetBkColor, hdc, PV_DARK_BG
    .ELSE
        invoke GetSysColor, COLOR_WINDOWTEXT
        invoke SetTextColor, hdc, eax
        invoke GetSysColor, COLOR_WINDOW
        invoke SetBkColor, hdc, eax
    .ENDIF
    invoke PreviewBrush
    ret
PreviewCtlColor ENDP

; ---------------------------------------------------------------------------
; Icon view window: draws every frame of the .ico at native size in a row
; ---------------------------------------------------------------------------
IconViewProc PROC USES esi ebx hWnd:DWORD, uMsg:DWORD, wParam:DWORD, lParam:DWORD
    LOCAL ps:PAINTSTRUCT
    LOCAL rc:RECT
    LOCAL x:DWORD
    LOCAL y:DWORD
    LOCAL rowH:DWORD
    LOCAL zoom:DWORD
    LOCAL cxDraw:DWORD
    LOCAL cyDraw:DWORD

    .IF uMsg == WM_ERASEBKGND
        mov eax, TRUE
        ret
    .ELSEIF uMsg == WM_PAINT
        invoke BeginPaint, hWnd, addr ps
        invoke GetClientRect, hWnd, addr rc
        invoke PreviewBrush
        invoke FillRect, ps.hdc, addr rc, eax

        ; Integer zoom so the largest frame fills ~60% of the shorter pane edge (icons are tiny at 1:1 on a 4K panel)
        mov ecx, 1
        xor ebx, ebx
        .WHILE ebx < g_nIcons
            mov eax, g_iconCy[ebx * 4]
            .IF eax > ecx
                mov ecx, eax
            .ENDIF
            inc ebx
        .ENDW
        mov eax, rc.right
        .IF eax > rc.bottom
            mov eax, rc.bottom
        .ENDIF
        mov edx, eax
        shr edx, 1
        add eax, edx                        ; 1.5 * short edge
        shr eax, 1                          ; ...then /2 -> 0.75; combined with the margin this lands near 60%
        xor edx, edx
        div ecx
        .IF eax == 0
            mov eax, 1
        .ENDIF
        .IF eax > 32
            mov eax, 32
        .ENDIF
        mov zoom, eax

        invoke Scale, 12
        mov x, eax
        mov y, eax
        mov rowH, 0
        xor ebx, ebx
        .WHILE ebx < g_nIcons
            mov eax, g_iconCx[ebx * 4]
            imul eax, zoom
            mov cxDraw, eax
            mov eax, g_iconCy[ebx * 4]
            imul eax, zoom
            mov cyDraw, eax
            ; wrap to the next row when the frame would overflow the width
            mov eax, x
            add eax, cxDraw
            .IF eax > rc.right && x != 0
                invoke Scale, 12
                mov x, eax
                mov eax, rowH
                add y, eax
                invoke Scale, 12
                add y, eax
                mov rowH, 0
            .ENDIF
            invoke DrawIconEx, ps.hdc, x, y, g_hIcons[ebx * 4], cxDraw, cyDraw, 0, NULL, DI_NORMAL
            mov eax, cxDraw
            add x, eax
            invoke Scale, 12
            add x, eax
            mov eax, cyDraw
            .IF eax > rowH
                mov rowH, eax
            .ENDIF
            inc ebx
        .ENDW
        invoke EndPaint, hWnd, addr ps
        xor eax, eax
        ret
    .ENDIF
    invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
    ret
IconViewProc ENDP

PreviewFreeIcons PROC USES ebx
    xor ebx, ebx
    .WHILE ebx < g_nIcons
        .IF g_hIcons[ebx * 4] != 0
            invoke DestroyIcon, g_hIcons[ebx * 4]
            mov g_hIcons[ebx * 4], 0
        .ENDIF
        inc ebx
    .ENDW
    mov g_nIcons, 0
    ret
PreviewFreeIcons ENDP

; ---------------------------------------------------------------------------
; Setup
; ---------------------------------------------------------------------------
PreviewSetFont PROC
    LOCAL lf:LOGFONTW
    invoke RtlZeroMemory, addr lf, sizeof LOGFONTW
    invoke MulDiv, 10, g_dpi, 72
    neg eax
    mov lf.lfHeight, eax
    mov lf.lfWeight, 400
    mov lf.lfQuality, CLEARTYPE_QUALITY
    invoke lstrcpyW, addr lf.lfFaceName, offset szConsolas
    invoke CreateFontIndirectW, addr lf
    .IF eax != 0
        .IF g_hFontMono != 0
            push eax
            invoke DeleteObject, g_hFontMono
            pop eax
        .ENDIF
        mov g_hFontMono, eax
    .ENDIF
    .IF g_hEdit != 0
        invoke SendMessageW, g_hEdit, WM_SETFONT, g_hFontMono, TRUE
    .ENDIF
    ret
PreviewSetFont ENDP

PreviewInit PROC hParent:DWORD
    LOCAL wc:WNDCLASSEXW
    invoke RtlZeroMemory, addr wc, sizeof WNDCLASSEXW
    mov wc.cbSize, sizeof WNDCLASSEXW
    mov wc.lpfnWndProc, offset IconViewProc
    push g_hInst
    pop wc.hInstance
    invoke LoadCursorW, NULL, IDC_ARROW
    mov wc.hCursor, eax
    mov wc.lpszClassName, offset szIconClass
    invoke RegisterClassExW, addr wc

    invoke CreateWindowExW, WS_EX_CLIENTEDGE, offset szEditClass, NULL, WS_CHILD or WS_VSCROLL or WS_HSCROLL or ES_MULTILINE or ES_READONLY or ES_AUTOVSCROLL or ES_AUTOHSCROLL, 0, 0, 0, 0, hParent, IDC_EDIT, g_hInst, NULL
    mov g_hEdit, eax
    invoke CreateWindowExW, WS_EX_CLIENTEDGE, offset szIconClass, NULL, WS_CHILD, 0, 0, 0, 0, hParent, IDC_ICONVIEW, g_hInst, NULL
    mov g_hIconView, eax
    invoke PreviewSetFont
    ret
PreviewInit ENDP

PreviewLayout PROC x:DWORD, y:DWORD, pcx:DWORD, pcy:DWORD
    invoke MoveWindow, g_hEdit, x, y, pcx, pcy, TRUE
    invoke MoveWindow, g_hIconView, x, y, pcx, pcy, TRUE
    ret
PreviewLayout ENDP

; ---------------------------------------------------------------------------
; Content
; ---------------------------------------------------------------------------
PreviewShowText PROC pszText:DWORD
    invoke ShowWindow, g_hIconView, SW_HIDE
    invoke SendMessageW, g_hEdit, WM_SETTEXT, 0, pszText
    .IF g_bPreview != 0
        invoke ShowWindow, g_hEdit, SW_SHOW
    .ENDIF
    ret
PreviewShowText ENDP

; Load an .ico from memory: every directory entry becomes an HICON
PreviewLoadIcon PROC USES esi edi ebx pData:DWORD, cb:DWORD
    LOCAL count:DWORD
    LOCAL icx:DWORD
    LOCAL icy:DWORD

    invoke PreviewFreeIcons
    mov esi, pData
    .IF cb < 6
        ret
    .ENDIF
    .IF word ptr [esi] != 0 || word ptr [esi + 2] != 1
        ret
    .ENDIF
    movzx eax, word ptr [esi + 4]
    .IF eax > MAX_ICONS
        mov eax, MAX_ICONS
    .ENDIF
    mov count, eax
    xor ebx, ebx
    .WHILE ebx < count
        mov edi, ebx
        shl edi, 4
        lea edi, [esi + edi + 6]            ; ICONDIRENTRY
        lea eax, [edi + 16]
        sub eax, esi
        .BREAK .IF eax > cb
        movzx eax, byte ptr [edi]
        .IF eax == 0
            mov eax, 256
        .ENDIF
        mov icx, eax
        movzx eax, byte ptr [edi + 1]
        .IF eax == 0
            mov eax, 256
        .ENDIF
        mov icy, eax
        mov eax, [edi + 12]                 ; image offset
        mov ecx, [edi + 8]                  ; image size
        mov edx, eax
        add edx, ecx
        jc next_entry
        cmp edx, cb
        ja next_entry
        add eax, esi
        invoke CreateIconFromResourceEx, eax, ecx, TRUE, 00030000h, icx, icy, 0
        .IF eax != 0
            mov ecx, g_nIcons
            mov g_hIcons[ecx * 4], eax
            mov eax, icx
            mov g_iconCx[ecx * 4], eax
            mov eax, icy
            mov g_iconCy[ecx * 4], eax
            inc g_nIcons
        .ENDIF
next_entry:
        inc ebx
    .ENDW
    ret
PreviewLoadIcon ENDP

; Decode bytes to UTF-16 with CRLF line endings into a fresh heap buffer
PreviewDecodeText PROC USES esi edi ebx pData:DWORD, cb:DWORD
    LOCAL pWide:DWORD
    LOCAL nWide:DWORD
    LOCAL pOut:DWORD
    LOCAL pSrc:DWORD
    LOCAL cbSrc:DWORD

    mov eax, pData
    mov pSrc, eax
    mov eax, cb
    mov cbSrc, eax

    ; UTF-16 LE BOM
    mov esi, pData
    .IF cb >= 2 && word ptr [esi] == 0FEFFh
        add pSrc, 2
        sub cbSrc, 2
        mov eax, cbSrc
        shr eax, 1
        mov nWide, eax
        inc eax
        shl eax, 1
        invoke VfsAlloc, eax
        mov pWide, eax
        .IF eax == 0
            ret
        .ENDIF
        mov eax, nWide
        shl eax, 1
        invoke RtlMoveMemory, pWide, pSrc, eax
        jmp have_wide
    .ENDIF
    ; UTF-8 BOM
    .IF cb >= 3 && byte ptr [esi] == 0EFh && byte ptr [esi + 1] == 0BBh && byte ptr [esi + 2] == 0BFh
        add pSrc, 3
        sub cbSrc, 3
    .ENDIF
    ; binary sniff: NUL in the first 512 bytes
    mov ecx, cbSrc
    .IF ecx > 512
        mov ecx, 512
    .ENDIF
    mov esi, pSrc
    .WHILE ecx != 0
        .IF byte ptr [esi] == 0
            xor eax, eax
            ret
        .ENDIF
        inc esi
        dec ecx
    .ENDW

    mov eax, cbSrc
    inc eax
    shl eax, 1
    invoke VfsAlloc, eax
    mov pWide, eax
    .IF eax == 0
        ret
    .ENDIF
    .IF cbSrc == 0
        mov nWide, 0
        jmp have_wide
    .ENDIF
    invoke MultiByteToWideChar, CP_UTF8, MB_ERR_INVALID_CHARS, pSrc, cbSrc, pWide, cbSrc
    .IF eax == 0
        invoke MultiByteToWideChar, CP_ACP, 0, pSrc, cbSrc, pWide, cbSrc
    .ENDIF
    mov nWide, eax

have_wide:
    ; expand lone LF to CRLF; worst case doubles
    mov eax, nWide
    shl eax, 1
    inc eax
    shl eax, 1
    invoke VfsAlloc, eax
    mov pOut, eax
    .IF eax == 0
        invoke VfsFreeMem, pWide
        xor eax, eax
        ret
    .ENDIF
    mov esi, pWide
    mov edi, pOut
    mov ecx, nWide
    xor ebx, ebx                            ; previous char
    .WHILE ecx != 0
        lodsw
        .IF ax == 0Ah && bx != 0Dh
            push ax
            mov ax, 0Dh
            stosw
            pop ax
        .ENDIF
        stosw
        movzx ebx, ax
        dec ecx
    .ENDW
    xor eax, eax
    stosw
    invoke VfsFreeMem, pWide
    mov eax, pOut
    ret
PreviewDecodeText ENDP

PreviewShow PROC USES esi pNode:DWORD
    LOCAL pData:DWORD
    LOCAL cb:DWORD
    LOCAL pText:DWORD
    LOCAL isIco:DWORD

    invoke PreviewFreeIcons
    mov esi, pNode
    .IF esi == 0 || g_bPreview == 0
        invoke ShowWindow, g_hEdit, SW_HIDE
        invoke ShowWindow, g_hIconView, SW_HIDE
        ret
    .ENDIF
    test [esi].NODE.nflags, NF_DIR
    .IF !ZERO?
        invoke ShowWindow, g_hEdit, SW_HIDE
        invoke ShowWindow, g_hIconView, SW_HIDE
        ret
    .ENDIF
    .IF [esi].NODE.dataSize == 0
        invoke PreviewShowText, offset szEmptyFile
        ret
    .ENDIF

    ; extension check
    mov isIco, FALSE
    lea eax, [esi].NODE.szName
    invoke lstrlenW, eax
    .IF eax >= 4
        lea ecx, [esi].NODE.szName
        lea ecx, [ecx + eax * 2 - 8]
        invoke lstrcmpiW, ecx, offset szExtIco
        .IF eax == 0
            mov isIco, TRUE
        .ENDIF
    .ENDIF

    invoke VfsReadAll, esi, PREVIEW_MAX, addr cb
    mov pData, eax
    .IF eax == 0
        invoke PreviewShowText, offset szNoPreview
        ret
    .ENDIF

    .IF isIco != 0
        invoke PreviewLoadIcon, pData, cb
        .IF g_nIcons != 0
            invoke ShowWindow, g_hEdit, SW_HIDE
            invoke ShowWindow, g_hIconView, SW_SHOW
            invoke InvalidateRect, g_hIconView, NULL, TRUE
            invoke VfsFreeMem, pData
            ret
        .ENDIF
    .ENDIF

    invoke PreviewDecodeText, pData, cb
    mov pText, eax
    invoke VfsFreeMem, pData
    .IF pText == 0
        invoke PreviewShowText, offset szNoPreview
        ret
    .ENDIF
    invoke PreviewShowText, pText
    invoke VfsFreeMem, pText
    ret
PreviewShow ENDP

END
