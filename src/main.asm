; FoxImg - entry point, main window, commands
include foximg.inc

VK_ESCAPE   equ 1Bh

.data
g_hInst     dd 0
g_hWnd      dd 0
g_hAccel    dd 0
g_saveIsCue dd 0
g_saveGzip  dd 0

WSTR szClassName, <FoxImgMain>
WSTR szTitle, <FoxImg>
WSTR szOpenTitle, <Open Disc Image>
WSTR szSaveTitle, <Save As / Convert>
WSTR szAddFilesTitle, <Add Files>
WSTR szBrowseTitle, <Choose a destination folder>
WSTR szErrOpen, <Could not open this image. It is not a readable ISO 9660 volume, or it is larger than 2 GB (not supported yet).>
WSTR szErrWrite, <Writing the image failed. Check free space and that the destination is writable.>
WSTR szErrReplace, <The image was written but the original could not be replaced.>
WSTR szErrExtract, <Some files could not be extracted.>
WSTR szErrBoot, <Select a file in the list first. Directories cannot be boot images.>
WSTR szBusy, <Please wait for the current operation to finish (or cancel it).>
WSTR szDiscard, <Discard unsaved changes?>
WSTR szDeleteAsk, <Delete the selected items from the image?>
WSTR szDeleteDirAsk, <Delete this folder and everything inside it?>
WSTR szAboutText, <FoxImg v1.2 - a small native disc image utility. ISO 9660 / Joliet / El Torito; ISO, IMG, BIN/CUE.>
WSTR szSaved, <Saved>
WSTR szExtracted, <Extracted>
WSTR szCancelled, <Cancelled>
WSTR szAdded, <Files added>
WSTR szExtIso, <iso>
WSTR szExtCueDot, <.cue>
WSTR szExtBinDot, <.bin>
WSTR szExtGzDot, <.gz>
WSTR szTmpSuffix, <.tmp>
WSTR szNewFolderName, <New Folder>
WSTR szNewFileName, <New File>

szFilterOpen LABEL WORD
    dw 'D','i','s','c',' ','I','m','a','g','e','s',0
    dw '*','.','i','s','o',';','*','.','i','m','g',';','*','.','b','i','n',';','*','.','c','u','e',';'
    dw '*','.','n','r','g',';','*','.','m','d','s',';','*','.','c','c','d',';','*','.','g','d','i',';','*','.','t','o','c',';','*','.','c','d','i',';'
    dw '*','.','e','c','m',';','*','.','g','z',';','*','.','z','i','p',';','*','.','c','s','o',';','*','.','c','i','s','o',0
    dw 'A','l','l',' ','F','i','l','e','s',' ','(','*','.','*',')',0
    dw '*','.','*',0
    dw 0
szFilterSave LABEL WORD
    dw 'I','S','O',' ','I','m','a','g','e',' ','(','*','.','i','s','o',')',0
    dw '*','.','i','s','o',0
    dw 'R','a','w',' ','I','m','a','g','e',' ','(','*','.','i','m','g',')',0
    dw '*','.','i','m','g',0
    dw 'B','I','N','/','C','U','E',' ','(','*','.','b','i','n',')',0
    dw '*','.','b','i','n',0
    dw 'g','z','i','p',' ','I','S','O',' ','(','*','.','i','s','o','.','g','z',')',0
    dw '*','.','g','z',0
    dw 0
szFilterAll LABEL WORD
    dw 'A','l','l',' ','F','i','l','e','s',' ','(','*','.','*',')',0
    dw '*','.','*',0
    dw 0

szCueFmt    dw 'F','I','L','E',' ','"','%','s','"',' ','B','I','N','A','R','Y',13,10
            dw ' ',' ','T','R','A','C','K',' ','0','1',' ','M','O','D','E','1','/','2','0','4','8',13,10
            dw ' ',' ',' ',' ','I','N','D','E','X',' ','0','1',' ','0','0',':','0','0',':','0','0',13,10,0
MULTI_BUF   equ 32768

.data?
g_szMulti   dw MULTI_BUF dup(?)
g_saveData  dw MAX_PATH dup(?)
g_saveCue   dw MAX_PATH dup(?)
g_saveTmp   dw MAX_PATH + 8 dup(?)

.code

; ---------------------------------------------------------------------------
; Dialog helpers
; ---------------------------------------------------------------------------
ConfirmDiscard PROC
    .IF g_bModified == 0
        mov eax, TRUE
        ret
    .ENDIF
    invoke MessageBoxW, g_hWnd, offset szDiscard, offset szTitle, MB_YESNO or MB_ICONWARNING
    .IF eax == IDYES
        mov eax, TRUE
    .ELSE
        xor eax, eax
    .ENDIF
    ret
ConfirmDiscard ENDP

SaveDialog PROC pszOut:DWORD, pszFilter:DWORD, pszDefExt:DWORD, pszTitle:DWORD
    LOCAL ofn:OPENFILENAMEW
    invoke RtlZeroMemory, addr ofn, sizeof OPENFILENAMEW
    mov ofn.lStructSize, sizeof OPENFILENAMEW
    push g_hWnd
    pop ofn.hwndOwner
    push pszFilter
    pop ofn.lpstrFilter
    mov ofn.nFilterIndex, 1
    push pszOut
    pop ofn.lpstrFile
    mov ofn.nMaxFile, MAX_PATH
    push pszTitle
    pop ofn.lpstrTitle
    push pszDefExt
    pop ofn.lpstrDefExt
    mov ofn.Flags, OFN_EXPLORER or OFN_OVERWRITEPROMPT or OFN_PATHMUSTEXIST or OFN_HIDEREADONLY
    invoke GetSaveFileNameW, addr ofn
    ret
SaveDialog ENDP

BrowseFolder PROC pszOut:DWORD
    LOCAL bi:BROWSEINFOW
    LOCAL pidl:DWORD
    invoke RtlZeroMemory, addr bi, sizeof BROWSEINFOW
    push g_hWnd
    pop bi.hwndOwner
    mov bi.lpszTitle, offset szBrowseTitle
    mov bi.ulFlags, BIF_RETURNONLYFSDIRS or BIF_NEWDIALOGSTYLE
    invoke SHBrowseForFolderW, addr bi
    .IF eax == 0
        ret
    .ENDIF
    mov pidl, eax
    invoke SHGetPathFromIDListW, pidl, pszOut
    push eax
    invoke CoTaskMemFree, pidl
    pop eax
    ret
BrowseFolder ENDP

; ---------------------------------------------------------------------------
; Image open / save
; ---------------------------------------------------------------------------
OpenImage PROC pszPath:DWORD
    LOCAL szLocal[MAX_PATH]:WORD
    invoke lstrcpynW, addr szLocal, pszPath, MAX_PATH
    invoke IsoOpen, addr szLocal
    .IF eax == 0
        invoke MessageBoxW, g_hWnd, offset szErrOpen, offset szTitle, MB_OK or MB_ICONERROR
        xor eax, eax
        ret
    .ENDIF
    invoke VfsBuildFromIso
    invoke BootParse
    invoke lstrcpynW, offset g_szPath, addr szLocal, MAX_PATH
    mov g_bHavePath, TRUE
    push g_pRootNode
    pop g_pCurDir
    invoke UiRefreshTree
    invoke UiUpdateInfo
    invoke UiUpdateTitle
    mov eax, TRUE
    ret
OpenImage ENDP

WriteCueFile PROC USES esi edi pszCue:DWORD, pszBin:DWORD
    LOCAL szText[512]:WORD
    LOCAL szAscii[512]:BYTE
    LOCAL hOut:DWORD
    invoke PathLeaf, pszBin
    invoke wsprintfW, addr szText, offset szCueFmt, eax
    lea esi, szText
    lea edi, szAscii
    .WHILE word ptr [esi] != 0
        movzx eax, word ptr [esi]
        .IF eax > 127
            mov eax, '?'
        .ENDIF
        mov [edi], al
        inc edi
        add esi, 2
    .ENDW
    lea eax, szAscii
    sub edi, eax
    invoke CreateFileW, pszCue, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    .IF eax == INVALID_HANDLE_VALUE
        xor eax, eax
        ret
    .ENDIF
    mov hOut, eax
    invoke WriteAll, hOut, addr szAscii, edi
    invoke CloseHandle, hOut
    mov eax, TRUE
    ret
WriteCueFile ENDP

; Save / convert to pszTarget on the worker thread. Format follows the extension:
; .bin/.cue -> BIN + CUE, anything else -> ISO. SaveFinish swaps the .tmp in and reopens.
SaveBegin PROC pszTarget:DWORD
    LOCAL szTarget[MAX_PATH]:WORD
    invoke lstrcpynW, addr szTarget, pszTarget, MAX_PATH
    mov g_saveIsCue, FALSE
    mov g_saveGzip, FALSE
    invoke PathExt, addr szTarget
    push eax
    invoke lstrcmpiW, eax, offset szExtCueDot
    pop ecx
    .IF eax == 0
        mov g_saveIsCue, TRUE
        invoke lstrcpynW, offset g_saveCue, addr szTarget, MAX_PATH
        invoke PathWithExt, offset g_saveData, addr szTarget, offset szExtBinDot
    .ELSE
        invoke lstrcmpiW, ecx, offset szExtBinDot
        .IF eax == 0
            mov g_saveIsCue, TRUE
            invoke lstrcpynW, offset g_saveData, addr szTarget, MAX_PATH
            invoke PathWithExt, offset g_saveCue, addr szTarget, offset szExtCueDot
        .ELSE
            invoke PathExt, addr szTarget
            invoke lstrcmpiW, eax, offset szExtGzDot
            .IF eax == 0
                mov g_saveGzip, TRUE
            .ENDIF
            invoke lstrcpynW, offset g_saveData, addr szTarget, MAX_PATH
        .ENDIF
    .ENDIF
    invoke wsprintfW, offset g_saveTmp, offset g_szCatFmt, offset g_saveData, offset szTmpSuffix
    invoke JobStartSave, offset g_saveTmp
    ret
SaveBegin ENDP

SaveFinish PROC result:DWORD
    .IF g_jobCancel != 0
        invoke DeleteFileW, offset g_saveTmp
        invoke UiSetStatus, offset szCancelled
        ret
    .ENDIF
    .IF result == 0
        invoke MessageBoxW, g_hWnd, offset szErrWrite, offset szTitle, MB_OK or MB_ICONERROR
        ret
    .ENDIF
    invoke IsoClose                             ; release the mapping before replacing the file
    invoke MoveFileExW, offset g_saveTmp, offset g_saveData, MOVEFILE_REPLACE_EXISTING
    .IF eax == 0
        invoke MessageBoxW, g_hWnd, offset szErrReplace, offset szTitle, MB_OK or MB_ICONERROR
        .IF g_bHavePath != 0
            invoke OpenImage, offset g_szPath
        .ENDIF
        ret
    .ENDIF
    .IF g_saveIsCue != 0
        invoke WriteCueFile, offset g_saveCue, offset g_saveData
        invoke OpenImage, offset g_saveCue
    .ELSE
        invoke OpenImage, offset g_saveData
    .ENDIF
    invoke UiSetStatus, offset szSaved
    ret
SaveFinish ENDP

; Worker thread completion (UI thread)
AppJobFinished PROC kind:DWORD, result:DWORD
    mov eax, kind
    .IF eax == JOB_SAVE
        invoke SaveFinish, result
    .ELSEIF eax == JOB_EXTRACT
        .IF g_jobCancel != 0
            invoke UiSetStatus, offset szCancelled
        .ELSEIF result == 0
            invoke MessageBoxW, g_hWnd, offset szErrExtract, offset szTitle, MB_OK or MB_ICONWARNING
            invoke UiSetStatus, offset szExtracted
        .ELSE
            invoke UiSetStatus, offset szExtracted
        .ENDIF
    .ELSEIF eax == JOB_ADD
        invoke UiRefreshTree
        invoke UiUpdateTitle
        .IF g_jobCancel != 0
            invoke UiSetStatus, offset szCancelled
        .ELSE
            invoke UiSetStatus, offset szAdded
        .ENDIF
    .ENDIF
    invoke UiUpdateInfo
    ret
AppJobFinished ENDP

; ---------------------------------------------------------------------------
; Commands
; ---------------------------------------------------------------------------
DeleteCb PROC pNode:DWORD, lParam:DWORD
    invoke BootForgetNode, pNode
    invoke VfsDelete, pNode
    ret
DeleteCb ENDP

CmdNew PROC
    invoke ConfirmDiscard
    .IF eax == 0
        ret
    .ENDIF
    invoke IsoClose
    mov g_bootCount, 0
    invoke VfsNewImage
    mov g_bHavePath, FALSE
    push g_pRootNode
    pop g_pCurDir
    invoke UiRefreshTree
    invoke UiUpdateInfo
    invoke UiUpdateTitle
    ret
CmdNew ENDP

CmdOpen PROC
    LOCAL ofn:OPENFILENAMEW
    LOCAL szFile[MAX_PATH]:WORD
    invoke ConfirmDiscard
    .IF eax == 0
        ret
    .ENDIF
    mov szFile[0], 0
    invoke RtlZeroMemory, addr ofn, sizeof OPENFILENAMEW
    mov ofn.lStructSize, sizeof OPENFILENAMEW
    push g_hWnd
    pop ofn.hwndOwner
    mov ofn.lpstrFilter, offset szFilterOpen
    mov ofn.nFilterIndex, 1
    lea eax, szFile
    mov ofn.lpstrFile, eax
    mov ofn.nMaxFile, MAX_PATH
    mov ofn.lpstrTitle, offset szOpenTitle
    mov ofn.Flags, OFN_EXPLORER or OFN_FILEMUSTEXIST or OFN_PATHMUSTEXIST or OFN_HIDEREADONLY
    invoke GetOpenFileNameW, addr ofn
    .IF eax != 0
        invoke OpenImage, addr szFile
    .ENDIF
    ret
CmdOpen ENDP

CmdSaveAs PROC
    LOCAL szFile[MAX_PATH]:WORD
    mov szFile[0], 0
    .IF g_bHavePath != 0
        invoke lstrcpynW, addr szFile, offset g_szPath, MAX_PATH
    .ENDIF
    invoke SaveDialog, addr szFile, offset szFilterSave, offset szExtIso, offset szSaveTitle
    .IF eax != 0
        invoke SaveBegin, addr szFile
    .ENDIF
    ret
CmdSaveAs ENDP

CmdSave PROC
    ; containers (NRG, MDS, ...) are read-only inputs: saving means choosing an output image; CUE stays writable
    mov eax, g_bContainer
    .IF g_bCue != 0
        xor eax, eax
    .ENDIF
    .IF g_bHavePath != 0 && eax == 0
        invoke SaveBegin, offset g_szPath
    .ELSE
        invoke CmdSaveAs
    .ENDIF
    ret
CmdSave ENDP

CmdExtractAll PROC USES esi
    LOCAL szDir[MAX_PATH]:WORD
    .IF g_pRootNode == 0
        ret
    .ENDIF
    invoke BrowseFolder, addr szDir
    .IF eax == 0
        ret
    .ENDIF
    invoke JobNodesReset
    mov esi, g_pRootNode
    mov esi, [esi].NODE.pFirstChild
    .WHILE esi != 0
        invoke JobNodesAdd, esi, 0
        mov esi, [esi].NODE.pNextSibling
    .ENDW
    invoke JobStartExtract, addr szDir
    ret
CmdExtractAll ENDP

CmdExtract PROC
    LOCAL szDir[MAX_PATH]:WORD
    invoke UiCtxIsTree
    .IF eax == 0
        invoke SendMessageW, g_hList, LVM_GETSELECTEDCOUNT, 0, 0
        .IF eax == 0
            ret
        .ENDIF
    .ENDIF
    invoke BrowseFolder, addr szDir
    .IF eax == 0
        ret
    .ENDIF
    invoke JobNodesReset
    invoke UiCtxIsTree
    .IF eax != 0
        invoke JobNodesAdd, g_pCurDir, 0
    .ELSE
        invoke UiForEachSelected, offset JobNodesAdd, 0
    .ENDIF
    invoke JobStartExtract, addr szDir
    ret
CmdExtract ENDP

CmdAddFiles PROC USES esi edi
    LOCAL ofn:OPENFILENAMEW
    LOCAL szPath[MAX_PATH]:WORD
    LOCAL pDir:DWORD

    invoke UiCtxDir
    .IF eax == 0
        ret
    .ENDIF
    mov pDir, eax
    mov g_szMulti[0], 0
    invoke RtlZeroMemory, addr ofn, sizeof OPENFILENAMEW
    mov ofn.lStructSize, sizeof OPENFILENAMEW
    push g_hWnd
    pop ofn.hwndOwner
    mov ofn.lpstrFilter, offset szFilterAll
    mov ofn.nFilterIndex, 1
    mov ofn.lpstrFile, offset g_szMulti
    mov ofn.nMaxFile, MULTI_BUF
    mov ofn.lpstrTitle, offset szAddFilesTitle
    mov ofn.Flags, OFN_EXPLORER or OFN_FILEMUSTEXIST or OFN_PATHMUSTEXIST or OFN_HIDEREADONLY or OFN_ALLOWMULTISELECT
    invoke GetOpenFileNameW, addr ofn
    .IF eax == 0
        ret
    .ENDIF
    invoke JobPathsReset
    mov esi, offset g_szMulti
    invoke lstrlenW, esi
    lea edi, [esi + eax * 2 + 2]
    .IF word ptr [edi] == 0
        invoke JobPathsAdd, esi
    .ELSE
        .WHILE word ptr [edi] != 0
            invoke wsprintfW, addr szPath, offset g_szJoinFmt, esi, edi
            invoke JobPathsAdd, addr szPath
            invoke lstrlenW, edi
            lea edi, [edi + eax * 2 + 2]
        .ENDW
    .ENDIF
    mov eax, pDir
    mov g_pCurDir, eax
    invoke JobStartAdd, pDir
    ret
CmdAddFiles ENDP

CmdNewNode PROC bDir:DWORD
    LOCAL szName[NODE_NAME_MAX]:WORD
    LOCAL pDir:DWORD
    LOCAL pNode:DWORD
    LOCAL nflags:DWORD
    invoke UiCtxDir
    .IF eax == 0
        ret
    .ENDIF
    mov pDir, eax
    mov nflags, 0
    mov ecx, offset szNewFileName
    .IF bDir != 0
        mov nflags, NF_DIR
        mov ecx, offset szNewFolderName
    .ENDIF
    invoke VfsUniqueName, pDir, ecx, addr szName
    invoke VfsNew, pDir, addr szName, nflags
    .IF eax == 0
        ret
    .ENDIF
    mov pNode, eax
    invoke VfsDateNow, eax
    mov g_bModified, TRUE
    mov eax, pDir
    mov g_pCurDir, eax
    invoke UiRefreshTree
    invoke UiUpdateTitle
    invoke UiBeginRename, pNode
    ret
CmdNewNode ENDP

CmdDelete PROC
    LOCAL pDir:DWORD
    invoke UiCtxIsTree
    .IF eax != 0
        mov eax, g_pCurDir
        .IF eax == 0 || eax == g_pRootNode
            ret
        .ENDIF
        invoke MessageBoxW, g_hWnd, offset szDeleteDirAsk, offset szTitle, MB_YESNO or MB_ICONQUESTION
        .IF eax != IDYES
            ret
        .ENDIF
        mov eax, g_pCurDir
        mov ecx, [eax].NODE.pParent
        mov pDir, ecx
        invoke DeleteCb, eax, 0
        mov eax, pDir
        mov g_pCurDir, eax
    .ELSE
        invoke SendMessageW, g_hList, LVM_GETSELECTEDCOUNT, 0, 0
        .IF eax == 0
            ret
        .ENDIF
        invoke MessageBoxW, g_hWnd, offset szDeleteAsk, offset szTitle, MB_YESNO or MB_ICONQUESTION
        .IF eax != IDYES
            ret
        .ENDIF
        invoke UiForEachSelected, offset DeleteCb, 0
    .ENDIF
    invoke UiRefreshTree
    invoke UiUpdateInfo
    invoke UiUpdateTitle
    ret
CmdDelete ENDP

CmdOpenDir PROC
    invoke UiSelectedNode
    .IF eax != 0
        test [eax].NODE.nflags, NF_DIR
        .IF !ZERO?
            invoke UiSelectDir, eax
        .ENDIF
    .ENDIF
    ret
CmdOpenDir ENDP

CmdBoot PROC platform:DWORD
    invoke UiSelectedNode
    .IF eax != 0
        invoke BootSetEntry, eax, platform
    .ENDIF
    .IF eax == 0
        invoke MessageBoxW, g_hWnd, offset szErrBoot, offset szTitle, MB_OK or MB_ICONINFORMATION
        ret
    .ENDIF
    invoke UiUpdateInfo
    invoke UiUpdateTitle
    ret
CmdBoot ENDP

AppCommand PROC id:DWORD
    mov eax, id
    .IF eax == IDC_CANCEL
        invoke JobCancel
        ret
    .ENDIF
    ; everything that touches the model or the files waits for the running job
    .IF g_jobBusy != 0
        .IF eax != IDM_ABOUT && eax != IDM_PREVIEW && eax != IDM_OPENDIR && eax != IDM_REFRESH
            invoke UiSetStatus, offset szBusy
            ret
        .ENDIF
    .ENDIF
    .IF eax == IDM_NEW
        invoke CmdNew
    .ELSEIF eax == IDM_OPEN
        invoke CmdOpen
    .ELSEIF eax == IDM_SAVE
        invoke CmdSave
    .ELSEIF eax == IDM_SAVEAS
        invoke CmdSaveAs
    .ELSEIF eax == IDM_EXTRACTALL
        invoke CmdExtractAll
    .ELSEIF eax == IDM_ADDFILES
        invoke CmdAddFiles
    .ELSEIF eax == IDM_NEWFOLDER
        invoke CmdNewNode, TRUE
    .ELSEIF eax == IDM_NEWFILE
        invoke CmdNewNode, FALSE
    .ELSEIF eax == IDM_RENAME
        invoke UiSelectedNode
        .IF eax != 0
            invoke UiBeginRename, eax
        .ENDIF
    .ELSEIF eax == IDM_DELETE
        invoke CmdDelete
    .ELSEIF eax == IDM_EXTRACT
        invoke CmdExtract
    .ELSEIF eax == IDM_OPENDIR
        invoke CmdOpenDir
    .ELSEIF eax == IDM_BOOT_BIOS
        invoke CmdBoot, BOOT_PLATFORM_X86
    .ELSEIF eax == IDM_BOOT_EFI
        invoke CmdBoot, BOOT_PLATFORM_EFI
    .ELSEIF eax == IDM_BOOT_CLEAR
        invoke BootClear
        invoke UiUpdateInfo
        invoke UiUpdateTitle
    .ELSEIF eax == IDM_PREVIEW
        xor g_bPreview, 1
        invoke UiLayout, g_hWnd
        invoke UiSelectedNode
        invoke PreviewShow, eax
    .ELSEIF eax == IDM_REFRESH
        .IF g_jobBusy == 0
            invoke UiRefreshTree
            invoke UiUpdateInfo
            invoke UiUpdateTitle
        .ENDIF
    .ELSEIF eax == IDM_EXIT
        invoke SendMessageW, g_hWnd, WM_CLOSE, 0, 0
    .ELSEIF eax == IDM_ABOUT
        invoke MessageBoxW, g_hWnd, offset szAboutText, offset szTitle, MB_OK or MB_ICONINFORMATION
    .ENDIF
    ret
AppCommand ENDP

; ---------------------------------------------------------------------------
; ParseCommandLine - first argument after the program name into g_szPath
; ---------------------------------------------------------------------------
ParseCommandLine PROC USES esi edi
    invoke GetCommandLineW
    mov esi, eax
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
    .WHILE word ptr [esi] == ' ' || word ptr [esi] == 9
        add esi, 2
    .ENDW
    .IF word ptr [esi] == 0
        xor eax, eax
        ret
    .ENDIF
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
; WndProc
; ---------------------------------------------------------------------------
WndProc PROC hWnd:DWORD, uMsg:DWORD, wParam:DWORD, lParam:DWORD
    mov eax, uMsg
    .IF eax == WM_CREATE
        invoke UiCreateControls, hWnd
        invoke JobInit, hWnd
        invoke ThemeApply, hWnd
        invoke DndInit
    .ELSEIF eax == WM_SIZE
        invoke UiLayout, hWnd
        invoke JobLayout
    .ELSEIF eax == WM_TIMER
        .IF wParam == JOB_TIMER_ID
            invoke JobOnTimer
        .ENDIF
    .ELSEIF eax == WM_JOBDONE
        invoke JobOnDone, wParam
    .ELSEIF eax == WM_SETCURSOR
        invoke JobSetCursor
        .IF eax != 0
            mov eax, TRUE
            ret
        .ENDIF
        invoke DefWindowProcW, hWnd, uMsg, wParam, lParam
        ret
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
    .ELSEIF eax == WM_CTLCOLOREDIT || eax == WM_CTLCOLORSTATIC
        invoke PreviewCtlColor, wParam, lParam
        .IF eax != 0
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
        mov edx, lParam
        mov eax, [edx].RECT.right
        sub eax, [edx].RECT.left
        mov ecx, [edx].RECT.bottom
        sub ecx, [edx].RECT.top
        invoke SetWindowPos, hWnd, NULL, [edx].RECT.left, [edx].RECT.top, eax, ecx, SWP_NOZORDER or SWP_NOACTIVATE
    .ELSEIF eax == WM_INITMENUPOPUP
        invoke GetMenu, hWnd
        mov ecx, MF_BYCOMMAND or MF_UNCHECKED
        .IF g_bPreview != 0
            mov ecx, MF_BYCOMMAND or MF_CHECKED
        .ENDIF
        invoke CheckMenuItem, eax, IDM_PREVIEW, ecx
    .ELSEIF eax == WM_COMMAND
        movzx eax, word ptr wParam
        invoke AppCommand, eax
    .ELSEIF eax == WM_NOTIFY
        invoke UiOnNotify, lParam
        ret
    .ELSEIF eax == WM_CONTEXTMENU
        .IF g_jobBusy == 0
            movsx eax, word ptr lParam
            movsx ecx, word ptr lParam[2]
            invoke UiContextMenu, wParam, eax, ecx
        .ENDIF
    .ELSEIF eax == WM_DROPFILES
        invoke UiOnDropFiles, wParam
    .ELSEIF eax == WM_CLOSE
        .IF g_jobBusy != 0
            invoke UiSetStatus, offset szBusy
        .ELSE
            invoke ConfirmDiscard
            .IF eax != 0
                invoke DestroyWindow, hWnd
            .ENDIF
        .ENDIF
    .ELSEIF eax == WM_DESTROY
        invoke DndShutdown
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
    invoke VfsInit
    invoke DndInit

    mov icc.dwSize, sizeof INITCOMMONCONTROLSEX
    mov icc.dwICC, ICC_LISTVIEW_CLASSES or ICC_TREEVIEW_CLASSES or ICC_BAR_CLASSES or ICC_PROGRESS_CLASS
    invoke InitCommonControlsEx, addr icc
    invoke ThemeInit

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
    mov wc.hbrBackground, NULL
    mov wc.lpszMenuName, NULL
    mov wc.lpszClassName, offset szClassName
    invoke RegisterClassExW, addr wc

    invoke LoadAcceleratorsW, g_hInst, IDR_ACCEL
    mov g_hAccel, eax
    invoke LoadMenuW, g_hInst, IDR_MAINMENU
    mov hMenu, eax

    invoke CreateWindowExW, 0, offset szClassName, offset szTitle, WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT, cxInit, cyInit, NULL, hMenu, g_hInst, NULL
    mov g_hWnd, eax
    invoke ShowWindow, g_hWnd, SW_SHOWDEFAULT
    invoke UpdateWindow, g_hWnd

    invoke ParseCommandLine
    .IF eax != 0
        invoke OpenImage, offset g_szPath
    .ELSE
        xor eax, eax
    .ENDIF
    .IF eax == 0
        invoke CmdNew
    .ENDIF

    .WHILE TRUE
        invoke GetMessageW, addr msg, NULL, 0, 0
        .BREAK .IF eax == 0
        ; Escape cancels a running job (only then, so label editing keeps its own Escape)
        .IF msg.message == WM_KEYDOWN && msg.wParam == VK_ESCAPE && g_jobBusy != 0
            invoke JobCancel
            .CONTINUE
        .ENDIF
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
