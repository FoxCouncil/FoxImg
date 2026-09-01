; FoxImg - CD audio: tracks served as WAV files and played through waveOut
;
; Containers fill g_ctTracks with byte ranges into the data file (g_szBinPath).
; VfsAddCdTracks turns the audio entries into TrackNN.wav nodes; extraction
; prepends a 44-byte WAV header to the raw PCM. Playback double-buffers one
; second of audio at a time through winmm with window-message callbacks.
; CHD images store their PCM big-endian, so g_ctAudioSwap flips byte pairs.
include foximg.inc

CDA_WAVHDR      equ 44
CDA_BUF         equ 176400              ; one second of CD audio

.data
g_hWave         dd 0
g_playNode      dd 0
g_playFile      dd 0
g_playPosLo     dd 0
g_playPosHi     dd 0
g_playEndLo     dd 0
g_playEndHi     dd 0
g_playActive    dd 0
g_wavBuf1       dd 0
g_wavBuf2       dd 0
szTrackFmt      dw 'T','r','a','c','k','%','0','2','u','.','w','a','v',0

.data?
g_wavFmt        WAVEFORMATEX <>
g_wavHdr1       WAVEHDR <>
g_wavHdr2       WAVEHDR <>

.code

; 44-byte canonical WAV header for pcmBytes of 44.1 kHz 16-bit stereo
CdaWavHeader PROC USES edi pBuf:DWORD, pcmBytes:DWORD
    mov edi, pBuf
    mov dword ptr [edi], 46464952h          ; RIFF
    mov eax, pcmBytes
    add eax, 36
    mov dword ptr [edi + 4], eax
    mov dword ptr [edi + 8], 45564157h      ; WAVE
    mov dword ptr [edi + 12], 20746D66h     ; fmt(space)
    mov dword ptr [edi + 16], 16
    mov word ptr [edi + 20], 1              ; PCM
    mov word ptr [edi + 22], 2              ; stereo
    mov dword ptr [edi + 24], 44100
    mov dword ptr [edi + 28], 176400
    mov word ptr [edi + 32], 4
    mov word ptr [edi + 34], 16
    mov dword ptr [edi + 36], 61746164h     ; data
    mov eax, pcmBytes
    mov dword ptr [edi + 40], eax
    ret
CdaWavHeader ENDP

; Byte range of a track node inside the data file
CdaNodeRange PROC pNode:DWORD, pOffLo:DWORD, pOffHi:DWORD, pLen:DWORD
    mov ecx, pNode
    mov eax, [ecx].NODE.isoExtent
    mov edx, eax
    shl eax, 11
    shr edx, 21
    add eax, [ecx].NODE.isoByteRem
    adc edx, 0
    mov ecx, pOffLo
    mov dword ptr [ecx], eax
    mov ecx, pOffHi
    mov dword ptr [ecx], edx
    mov ecx, pNode
    mov eax, [ecx].NODE.dataSize
    sub eax, CDA_WAVHDR
    mov ecx, pLen
    mov dword ptr [ecx], eax
    ret
CdaNodeRange ENDP

; Flip the byte pairs of 16-bit samples in place
CdaSwap PROC USES esi pBuf:DWORD, cb:DWORD
    mov esi, pBuf
    mov ecx, cb
    shr ecx, 1
    .WHILE ecx != 0
        mov ax, word ptr [esi]
        xchg al, ah
        mov word ptr [esi], ax
        add esi, 2
        dec ecx
    .ENDW
    ret
CdaSwap ENDP

; Extraction: WAV header, then the PCM streamed from the data file
CdaCopyData PROC USES esi ebx pNode:DWORD, hOut:DWORD
    LOCAL hIn:DWORD
    LOCAL pBuf:DWORD
    LOCAL offLo:DWORD
    LOCAL offHi:DWORD
    LOCAL remain:DWORD
    LOCAL hdr[CDA_WAVHDR]:BYTE
    LOCAL ok:DWORD
    mov ok, FALSE
    invoke CdaNodeRange, pNode, addr offLo, addr offHi, addr remain
    invoke CdaWavHeader, addr hdr, remain
    invoke WriteAll, hOut, addr hdr, CDA_WAVHDR
    .IF eax == 0
        ret
    .ENDIF
    invoke FileOpenReadSeq, offset g_szBinPath
    .IF eax == INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov hIn, eax
    invoke VfsAlloc, CDA_BUF
    mov pBuf, eax
    .IF eax == 0
        jmp done
    .ENDIF
    mov ok, TRUE
    .WHILE remain != 0 && ok != 0
        mov ebx, CDA_BUF
        .IF ebx > remain
            mov ebx, remain
        .ENDIF
        invoke FileReadAt, hIn, offLo, offHi, pBuf, ebx
        .IF eax != ebx
            mov ok, FALSE
            .BREAK
        .ENDIF
        .IF g_ctAudioSwap != 0
            invoke CdaSwap, pBuf, ebx
        .ENDIF
        invoke WriteAll, hOut, pBuf, ebx
        .IF eax == 0
            mov ok, FALSE
            .BREAK
        .ENDIF
        add offLo, ebx
        adc offHi, 0
        sub remain, ebx
    .ENDW
done:
    invoke VfsFreeMem, pBuf
    invoke CloseHandle, hIn
    mov eax, ok
    ret
CdaCopyData ENDP

; TrackNN.wav nodes for every audio entry in the container track table
VfsAddCdTracks PROC USES esi edi ebx pRoot:DWORD
    LOCAL i:DWORD
    LOCAL trkNo:DWORD
    LOCAL szName[32]:WORD
    mov i, 0
    mov trkNo, 0
    .WHILE TRUE
        mov eax, i
        .BREAK .IF eax >= g_ctNumTracks
        inc trkNo
        mov esi, offset g_ctTracks
        shl eax, 4
        add esi, eax
        .IF dword ptr [esi + 12] != 0       ; audio entry
            invoke wsprintfW, addr szName, offset szTrackFmt, trkNo
            invoke VfsNew, pRoot, addr szName, NF_CDA
            .IF eax != 0
                mov edi, eax
                mov eax, dword ptr [esi]    ; byte offset -> block and remainder
                mov edx, dword ptr [esi + 4]
                mov ecx, eax
                shrd eax, edx, 11
                mov [edi].NODE.isoExtent, eax
                and ecx, 2047
                mov [edi].NODE.isoByteRem, ecx
                mov eax, dword ptr [esi + 8]
                add eax, CDA_WAVHDR
                mov [edi].NODE.dataSize, eax
                invoke VfsDateNow, edi
            .ENDIF
        .ENDIF
        inc i
    .ENDW
    ret
VfsAddCdTracks ENDP

; ---------------------------------------------------------------------------
; Playback
; ---------------------------------------------------------------------------
AudioFill PROC USES ebx pHdr:DWORD, pBuf:DWORD
    LOCAL nRead:DWORD
    mov eax, g_playEndLo
    sub eax, g_playPosLo
    mov ecx, g_playEndHi
    sbb ecx, g_playPosHi
    .IF ecx == 0 && eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov ebx, CDA_BUF
    .IF ecx == 0 && eax < ebx
        mov ebx, eax
    .ENDIF
    invoke FileReadAt, g_playFile, g_playPosLo, g_playPosHi, pBuf, ebx
    .IF eax == 0
        xor eax, eax
        ret
    .ENDIF
    mov nRead, eax
    add g_playPosLo, eax
    adc g_playPosHi, 0
    .IF g_ctAudioSwap != 0
        invoke CdaSwap, pBuf, nRead
    .ENDIF
    mov ecx, pHdr
    mov eax, pBuf
    mov [ecx].WAVEHDR.lpData, eax
    mov eax, nRead
    mov [ecx].WAVEHDR.dwBufferLength, eax
    mov [ecx].WAVEHDR.dwFlags, 0
    invoke waveOutPrepareHeader, g_hWave, pHdr, sizeof WAVEHDR
    .IF eax != 0
        xor eax, eax
        ret
    .ENDIF
    invoke waveOutWrite, g_hWave, pHdr, sizeof WAVEHDR
    .IF eax != 0
        invoke waveOutUnprepareHeader, g_hWave, pHdr, sizeof WAVEHDR
        xor eax, eax
        ret
    .ENDIF
    inc g_playActive
    mov eax, TRUE
    ret
AudioFill ENDP

AudioStop PROC USES ebx
    mov ebx, g_hWave
    .IF ebx == 0
        ret
    .ENDIF
    mov g_hWave, 0                          ; done-messages arriving later are ignored
    invoke waveOutReset, ebx
    .IF g_wavHdr1.dwFlags & WHDR_PREPARED
        invoke waveOutUnprepareHeader, ebx, offset g_wavHdr1, sizeof WAVEHDR
    .ENDIF
    .IF g_wavHdr2.dwFlags & WHDR_PREPARED
        invoke waveOutUnprepareHeader, ebx, offset g_wavHdr2, sizeof WAVEHDR
    .ENDIF
    invoke waveOutClose, ebx
    .IF g_playFile != 0
        invoke CloseHandle, g_playFile
        mov g_playFile, 0
    .ENDIF
    mov g_playNode, 0
    mov g_playActive, 0
    ret
AudioStop ENDP

AudioToggle PROC USES ebx pNode:DWORD
    LOCAL offLo:DWORD
    LOCAL offHi:DWORD
    LOCAL cb:DWORD
    mov eax, pNode
    .IF g_hWave != 0 && eax == g_playNode
        invoke AudioStop                    ; second activation stops the track
        ret
    .ENDIF
    invoke AudioStop
    .IF g_wavBuf1 == 0
        invoke VfsAlloc, CDA_BUF
        mov g_wavBuf1, eax
        invoke VfsAlloc, CDA_BUF
        mov g_wavBuf2, eax
    .ENDIF
    .IF g_wavBuf1 == 0 || g_wavBuf2 == 0
        ret
    .ENDIF
    invoke CdaNodeRange, pNode, addr offLo, addr offHi, addr cb
    invoke FileOpenReadSeq, offset g_szBinPath
    .IF eax == INVALID_HANDLE_VALUE
        ret
    .ENDIF
    mov g_playFile, eax
    mov eax, offLo
    mov g_playPosLo, eax
    mov eax, offHi
    mov g_playPosHi, eax
    mov eax, offLo
    add eax, cb
    mov g_playEndLo, eax
    mov eax, offHi
    adc eax, 0
    mov g_playEndHi, eax
    mov g_wavFmt.wFormatTag, 1
    mov g_wavFmt.nChannels, 2
    mov g_wavFmt.nSamplesPerSec, 44100
    mov g_wavFmt.nAvgBytesPerSec, 176400
    mov g_wavFmt.nBlockAlign, 4
    mov g_wavFmt.wBitsPerSample, 16
    mov g_wavFmt.cbSize, 0
    invoke waveOutOpen, offset g_hWave, WAVE_MAPPER, offset g_wavFmt, g_hWnd, 0, CALLBACK_WINDOW
    .IF eax != 0
        mov g_hWave, 0
        invoke CloseHandle, g_playFile
        mov g_playFile, 0
        ret
    .ENDIF
    mov eax, pNode
    mov g_playNode, eax
    invoke AudioFill, offset g_wavHdr1, g_wavBuf1
    invoke AudioFill, offset g_wavHdr2, g_wavBuf2
    .IF g_playActive == 0
        invoke AudioStop
    .ENDIF
    ret
AudioToggle ENDP

; MM_WOM_DONE: recycle the finished buffer or wind the session down
AudioOnDone PROC pHdr:DWORD
    .IF g_hWave == 0
        ret
    .ENDIF
    invoke waveOutUnprepareHeader, g_hWave, pHdr, sizeof WAVEHDR
    dec g_playActive
    mov eax, pHdr
    mov ecx, g_wavBuf1
    .IF eax != offset g_wavHdr1
        mov ecx, g_wavBuf2
    .ENDIF
    invoke AudioFill, pHdr, ecx
    .IF eax == 0 && g_playActive == 0
        invoke AudioStop                    ; track finished
    .ENDIF
    ret
AudioOnDone ENDP

END
