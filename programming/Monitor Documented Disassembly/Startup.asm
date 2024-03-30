    org 0x0000

    di                          ; interrupts off 
    jp start                    ; Warm/cold system (re)start

    nop                     

; jump table for user access of monitor routines
    jp cpm_start                ;0005 
    jp printscreen              ;0008
    jp readdisk                 ;000b

    defw error_030              ;000e vector to system error (A <- 0x30 and system frozen)

    jp rstdebug                 ;0010
    jp writedisk                ;0013

    defw error_030              ;0016 vector to system error (A <- 0x30 and system frozen)

    jp cassette                 ;0018
    jp initkey                  ;001b

    defw getdos                 ;001e vector to DOS load bootstrap

    jp enablekey                ;0020
    jp disablekey               ;0023
    jp readkey                  ;0026
    jp statuskey                ;0029
    jp clearkey                 ;002c
    jp error_031                ;002f
    jp BEEP                     ;0032
    jp clear_lines              ;0035

; Keyboard interrupt entry address.
; interrupt triggered by video circuit every field, or 20ms
; or by CTC, when extension board is present, also every 20ms
; increments tick counter (clock)
; scans keyboard 
keyscan:
    call saveregs               ; 0x0038 save registers 
    ld hl,(clock)               ; get current tick counter 
    inc hl                      ; increment with wrap
    ld (clock),hl               ; and store 
    in a,(000h)                 ; read keyboard flags
    cp 0ffh                     ; 0xff means no key was pressed 
    ld a,000h                   ; KBIEN off
    out (010h),a                ; send to kbd
    jr z,no_key_pressed         ; no key pressed 
    call handle_key             ; returns keycode in B
    ld a,b
    cp 0ffh                     ; keycode 0xff = no key, only shift or shift-lock was pressed
    jr z,reset_repeat           ; no 'real' key, so reset repeat logic and exit

; this part handles key-repeat
;
    ld a,(last_key)             ; was the previous key
    cp b                        ; equal to the current key?
    jr nz,add_to_keybuffer      ; no

    ld hl,key_time              ; pointer repeat to delay counter 
    dec (hl)                    ; decrement
    jr z,handle_repeat          ; zero means repeat delay elapsed
    jr keyscan_normal           ; don't add to buffer (yet) and exit

handle_repeat:
    push hl                     ; key_time pointe
    jp skip_NMI                 ; 0x0066 is hardcoded NMI vector, skip it!

NMI_vector:
    jp 01016h                   ; standard NMI entry in maintenance module

skip_NMI:
    ld hl,auto_repeat           ; turn on autorepeat flag (bit 0)` 
    set 0,(hl)
    pop hl                      ; key_time pointer back
    call buffer_key             ; add key to buffer
    ld a,002h                   ; new delay (2 fields = 25 chatcters per second)  
    ld (key_time),a             ; and save
    jr keyscan_normal           ; clean exit that enables key-scanning again

; when no key was pressed, do some house keeping
; turn off repeat, adjusts shift/lock state
no_key_pressed:
    push af                     ; ? seems unnecessary
    ld a,(auto_repeat)          ; was auto repeat on?
    bit 0,a
    jr z,reset_keystates        ; no
    res 0,a                     ; turn auto repeat off
    ld (auto_repeat),a
    xor a                       ; and clear keybuffer
    ld (keycount),a             ; otherwise some buffered keys may still be processed` 

reset_keystates:
    pop af                      ; ? seems unnecessary 
    ld a,0ffh                   ; set last key to no key
    ld (last_key),a
    ld a,(key_status)           ; was shift lock presssed?  
    bit 2,a
    jr nz,keep_shiftlock        ; yes, so remember that state     . 
    and 0feh                    ; no, so also reset shift bit
    ld (key_status),a           ; and save status
keep_shiftlock:
    jr keyscan_normal

add_to_keybuffer:
    call buffer_key

reset_repeat:
    ld a,032h                   ; key repeat delay at 50 (fields = 1 second)
    ld (key_time),a
    ld a,b                      ; store ket code for repeat tests
    ld (last_key),a

keyscan_normal:
    ld a,040h                   ; set KBIEN
    out (010h),a
    call restoreregs
    ei                          ; enable interruots (mode 1)
    reti                        ; and we're done

enablekey:
    call saveregs           
    call CTC_enable             ; enable CTC chip
    jr keyscan_normal           ; key scanning on

disablekey:
    ld a,000h                   ; diable KBIEN flag 
    out (010h),a

; fall through into CTC disable

; The P2000 contains a Z8430 Counter/Timer Circuit (CTC).
; the video chip triggers a countdown pulse on the CTC, every vertical retrace (20ms)
; The CTC generates an interrupt on the Z80.
; This chain ensurees that a keyboard scan and clock update happen every 20ms.
CTC_disable:
    ld a,001h                   ; Control word, INTEN and counters off
    out (CTC_CH3),a 
    ret

CTC_enable:
    ld a,0d5h                   ; binary 11010101 = Control word with
                                ; enable interrupt trigger, Counter mode, prescaler = 0,
                                ; rising edge triggers, timeconstant follows 
    out (CTC_CH3),a             ; send
    ld a,001h                   ; time constant = 1, interrupt is generated by the CTC when countdown reaches 0.
                                ; the video generates 1 pulse every field (vertical retrace)
                                ; so this setting causes an interrupt every field, or every 20ms
    out (CTC_CH3),a             ; send 

enable_interrupts:
    ei
    reti

; routine that adds a keycode to the keyboard buffer
; B contains the keycode
buffer_key:
    ld a,b                      ; is the key equal to STOP 
    cp 058h                     ; 0x10 + 0x48 = shift-stop
    jr nz,not_STOP              ; no
    ld (keybuffer),a            ; put STOP in buffer pos 1 (STOP has high priority!
    ld a,001h                   ; mak buflen 1, to erase any pending keys
    jr set_buflen   

not_STOP:   
    cp 012h                     ; is it the '00' key? 
    jr nz,add_key               ; no, so add the key
    ld b,a                      ; copy to B (not really necessary here)
    call add_key                ; add key once
                                ; fall through for 2nd time!
add_key:    
    ld a,(keycount)             ; get # of keys in buffer 
    ld hl,keybuffer             ; start of buffer
    ld l,a                      ; add # of keys 
    cp 00ch                     ; buffer full (12 keys already buffered)?  
    jr z,buffer_full            ; yep, so overwrite last key in the buffer 

store_key:  
    ld a,b                      ; get keycode from b
    ld (hl),a                   ; store keycode in buffer
    inc hl                      ; increment bufferpointer
    ld a,l                      ; get # of keys in buffer 
set_buflen: 
    ld (keycount),a             ; store in keycount
    ret                         ; and we're done

buffer_full:    
    dec hl                      ; buffer pointer to last position
    jr store_key                ; and store keycode there 

; when a key was pressed this routine finds out which key it was
; handles repeats and puts key(s) in the keyboard buffer.
; returns key in B, or 0xff if only a modifier was pressed 
handle_key:
    ld b,0ffh                   ; assume modifier (will be overwritten by 'real' key, if pressed)
    ld hl,key_status            ; current keystatus (tracks shift/lock)
    ld c,000h                   ; start with key matrix row 0 
kb_scan_row:    
    in a,(c)                    ; get bitmaks (0xff = no key was pressed)
    ld e,a                      ; save mask
    xor 0ffh                    ; 0xff xor 0xff = 0
    call nz,decode_key          ; if not zero a key was pressed 
    inc c                       ; next key matrix row
    ld a,c                      ; in a 
    cp 009h                     ; reached shift key row? 
    jr nz,kb_scan_row           ; no, so scan next normal key row
    in a,(c)                    ; read shift key state
    cp 0ffh                     ; shift key pressed? 
    jr z,no_shifts              ; no, so
    set 0,(hl)                  ; set shift bit 
    res 2,(hl)                  ; clear lock bit
    push bc                     ; save B
    ld b,000h                   ; 0x00 = clear
    ld e,001h                   ; offset 1 
    call show_mon_status        ; and put on screen
    pop bc                      ; B back 
    ret                         
; HL points at key_status   
no_shifts:  
    bit 2,(hl)                  ; Shift-lock set?
    ret nz                      ; then we're done 
    res 0,(hl)                  ; also reset Shift bit 
    ret

; key decode routine
; input:
; C keyboard scan row #
; E original row bits
; A inverted row bits (bit set for a pressed key)
decode_key:
    push af                     ; save inverted bitmask
    ld a,003h                   ; at row containing shift-lock (#3)?  
    cp c                        ; 
    jr nz,no_shift_lock         ; no
    bit 0,e                     ; shift-lock pressed (bit 0 == 0)?
    jr nz,no_shift_lock         ; no
    push bc                     ;
    push hl                     ;
    ld b,'L'                    ; show Locked status 'L' 
    ld e,001h                   ; offset 1
    call show_mon_status        ; put on screen
    pop hl  
    pop bc  
    ld a,(key_status)   
    or 005h                     ; set both shift-lock and shift bits in key_status
    ld (key_status),a
    pop af
    ret

; we know that at least 1 bit is set in A
; when we find a bit that is set, handle it and we're done
; multiple keys on one row not supported!
; input:
; A inverted row bits (bit set for a pressed key)
; C keyboard scan row #
no_shift_lock:
    pop af                      ; get inverted bitmask0148  f1  . 
    ld e,000h                   ; bitnumber starts at 0
try_next_bit:   
    rra                         ; bit in carry
    jr c,key_bit_set            ; handle key key is pressed 
    inc e                       ; increment bitnumber
    jr try_next_bit

; C keyboard scan row #
; E contains bit number of pressed key
; first generate key-code kc = row*3 + bitnumber
key_bit_set:
    ld a,c                      ; key-row#
    rlca                        ; multiply with 8 (row<<3)
    rlca    
    rlca    
    or e                        ; add bit number
    ld e,a                      ; save keycode
    ld a,(key_status)           ; get current key-status
    bit 0,a                     ; shift?
    ld a,e                      ; keycode back 
    jr z,not_shifted 

; 9 rows of 8 keys:
; keycode  0..71  = normal keys
; keycode 72..143 = shifted keys  
    ld a,048h                   ; add 72 to keycode (0x48 = 72)  
    add a,e     

not_shifted:    
    ld b,a                      ; keycode in B
    call maintain_repeat        ; fix to keep repeat on while releasing shift
    ret 

initkey:    
    call CTC_setup_for_IM2      ; Set IM 2 and prepare the CTC and I registers for interrupt
    ld hl,CTC_testcode          ; We want the interrupt to go there
    ld (CTC_keyboard),hl        ; store in the CTC_keyboard interrupt vector
    ld a,000h                   ; disable keyscan (^KBIEN)
    out (010h),a    
    ld a,032h                   ; key repeat delay  
    ld (key_time),a 

    ld a,085h                   ; b10000101   CTC INTEN, Time constant follows, control word, no prescaler  
    out (CTC_CH3),a 
    ld a,001h                   ; 1 = shortest possible delay 
    out (CTC_CH3),a 
    call enable_interrupts      ; If a CTC is present, after the EI and RETI the CTC interrupt (IM2)
                                ; will cause the exution to continue at CTC_testcode
                                ; if not IM1 is enabled below and we continue 
    im 1
    jr skip_testcode

; the code above (initkey) sets an interrupt that causes execution to continue here.
CTC_testcode:
    pop hl                      ; remove interrupt return address from stack
    call CTC_disable            ; disable interrupt generation by CTC
    ld hl,keyscan               ; restore interrupt vector to proper handler
    ld (CTC_keyboard),hl  
    call CTC_enable             ; and switch CTC interrupts back on (triggered by vertical retrace)


skip_testcode:
    ld a,040h                   ; turn on keyscan (KBIEN)
    out (010h),a    
    ld hl,keybuffer             ; get address of keybuffer 
    ld a,l                      ; set keycount to 0
    ld (keycount),a     
    xor a                       ; reset status (shift/shift-lock off)  
    ld (key_status),a   
    ret 

saveregs:   
    ex (sp),hl                  ; put HL on, and get return address off, the stack
    push de 
    push bc 
    push af 
    di                          ; interrupts off 
    jp (hl)                     ; jump back to where we came from (address is in HL) 

restoreregs:    
    pop hl                      ; calling address off stack  
    pop af                      ; restore other registers
    pop bc  
    pop de  
    ei                          ; re-enable interrupts
    ex (sp),hl                  ; gets correct HL and puts calling address back on the stack
    ret                         ; return there! 

CTC_setup_for_IM2:  
    im 2                        ; interrupt mode 2
    ld hl,06020h                ; intterupt vector 1 address
    ld a,l                      ; lo byte in a 
    out (CTC_CH0),a             ; send to CTC channel 0  
    ld a,h                      ; hi byte of vector 
    ld i,a                      ; in I register
    ret

; show a charcter on the (top row of the) screen
; for example when the bootstrap tries to load a tape it shows a flashing 'T'
; B contains character
; E displacement on the row
show_mon_status:
    push af                     ; save registers
    push hl 
    push de 
    ld hl,(mon_status_io)       ; get the address where we can put the character 
    ld d,000h                   ; clear D, DE now contains a 16 bit offset for the caracter
    add hl,de                   ; add to the base address 
    ld (hl),b                   ; store the character
    ld de,0x0800                ; add offset for model m character attribute memory 
    add hl,de                   ;
    ld (hl),0f5h                ; store 0xF5h or bxxxx0101 which means Flashing and Graphics
    pop de                      ; restore registers and return
    pop hl
    pop af
    ret

; new keycode in B (range 0..143) 
; releasing the shift key during repeat must not stop repeat!
maintain_repeat:
    ld a,(last_key)             ; last pressed key
    sub 048h                    ; subtract shift
    cp b                        ; compare to new key
    ret nz                      ; new key != unshifted previous key
    ld a,b                      ; shift was released while holding this key 
    ld (last_key),a             ; now save new, unshifted key as previous key to keep repeat alive 
    ret 

; 3 system error trap entry points.
; loads A with error code 0x35, 0x31 or 0x30 and freezes the system
; by invoking an NMI with a maintenance module the error can be retrieved.
error_035:    
    ld a,035h                   ; set error to 35 and freeze 
    defb 001h                   ; 01 transorms next ld a,031h into  ld bc,0313eh, so a is not changed!
error_031:  
    ld a,031h                   ; set error to 31 and freeze
    defb 001h                   ; 01 transorms next ld a,030h into  ld bc,0303eh, so a is not changed!
error_030:
    ld a,030h                   ; set error to 30 and freeze 
; fall into endless loop
freeze_system:
    di                          ; interrupts off  
    halt                        ; pause processor
    jr freeze_system            ; if we somehow unpauze: repeat!

; beep toggles beep bit high-low 128 times
; producing a short beep-sound 
BEEP:
    call saveregs
    ld e,080h                   ; 128 pulses 
beeper_loop:
    ld a,001h                   ; bit 0 = sound bit on!
    out (050h),a                ; send to beeper
    call beep_delay             ; about 0.7 ms
    xor a                       ; toggle!
    out (050h),a
    call beep_delay 
    dec e                       ; all pulses done? 
    ld a,e
    or a
    jr nz,beeper_loop           ; no, so repeat
    call restoreregs
    ret

; sound delay takes:17T(call) + 7 + 128*13 - 5 + 10 (ret) = 1693 Tstates (0,0006772 sec)
beep_delay:
    ld b,080h                   ;  7T
delayloop:
    djnz delayloop              ; 13T 
    ret                         ; 10T

; move data
; DE is destination address
; HL points to length byte, followed by length bytes of data
not_used_at_all:
    ld a,(hl)                   ; get length
    ld b,000h                   ; clear B
    ld c,a                      ; length in C 
    inc hl                      ; point to first byte of data
    ldir                        ; move C bytes  
    ret

CALL_SERVICE:
    defm  'CALL SERVICE'  

startup_msg:
    defw    051ech              ; destination
    defb    15                  ; length
    defb    6, 13               ; Cyan, Double Height 
    defm    'P H I L I P S' 

    defw    052dch              ; destination on screen
    defb    15                  ; length
    defb    6, 13               ; Cyan, Double Height 
    defm    'MICROCOMPUTER' 

    defw    053d0h              ; destination on screen
    defb    7                   ; length
    defb    6, 13               ; Cyan, Double Height 
    defm    'P2000' 

    defb    0xff

boot_error:
    ld hl,CALL_SERVICE          ; start of message
    ld de,05012h                ; line 1 on screen
    ld bc,12                    ; length of 'CALL SERVICE'
    ldir                        ; copy to screen
    jr freeze_system            ; avoid further damage

start:
    ld a,001h                   ; disable all 4 CTC channels
    out (CTC_CH0),a
    out (CTC_CH1),a
    out (CTC_CH2),a
    out (CTC_CH3),a
    ld a,000h                   ; disable KBIEN (no key scanning)
    out (010h),a                ;
    ld a,(01000h)               ; Start of cartridge memory
l026bh:
       cp 058h                  ; maintenance module has 0x58 as first byte
    jp z,01010h                 ; if we find that value, hand over control!

; no maintenance module present, continue with initialization

; Since there is always 2kb of 8-bit video memory
; we use that for the initial stack location. 
    ld sp,057ffh                ; end of video memory
    call BEEP

; check first bank of 16K 
    ld hl,RAM_bank1             ; that starts at 0x6000
    ld bc,040ffh                ; check 64 pages of 256 bytes, all 8 bits are significant (0xff == all bits)  
    call test_memory
    or a                        ; succes?
    jr nz,boot_error            ; no, so diplay CALL SERVICE
    ld sp,06200h                ; 1st 16k RAM is OK, stack can be moved to here!
    ld hl,memsize               ; RAM was cleared by the test
    inc (hl)                    ; memsize <- 1 means 16k found

; check 2K 8-bit video RAM, both M and T models have this
    ld hl,VIDEO_ram             ; Video mem start
    ld bc,008ffh                ; 8 pages, 8 bits
    call test_memory    
    or a                        ; all ok?

jr_nz_boot_error:               ; label used as a stepping stone for another (too far) relative jump
    jr nz,boot_error            ; no, abort

; check 2K of 4-bits video attribute RAM, present in the model M
    ld hl,ATTR_ram              ; (0x5800)
    ld bc,0080fh                ; 8 pages, only lower 4 bits
    call test_memory    
    cp 002h                     ; failure after first byte? 
    jr z,boot_error             ; yes, this must be a 2000M, with failure in attribute RAM: abort
    cp 001h                     ; Failure at 1st byte?
    jr z,model_is_2000T         ; it's a 2000T 

; we may think it is a 2000M but it can be that the memory always returns 0
; double check with a bit pattern
    ld a,005h                   ; binary 00000101 
    ld (ATTR_ram),a             ; write pattern 
    ld a,(ATTR_ram)             ; read back
    and 00fh                    ; mask off not-connecte bits
    cp 005h                     ; compare with pattern
    jr nz,model_is_2000T        ; error, so it is a 2000T after all..

; it definitely is a 2000M  
    ld hl,type_T_M              ; address that stores model data
    set 0,(hl)                  ; set Model M bit 
    xor a                       ; fix memory that was modified by the test
    ld (ATTR_ram),a

model_is_2000T:
    ld hl,RAM_bank2             ; Test bank 2, at 0xa0000
    ld bc,040ffh                ; 64 pages (16k), and 8 bits
    call test_memory
    cp 002h                     ; failure after first byte
jr_z_boot_error:                    ; label used as a stepping stone for another (too far) relative jump
    jr z,boot_error             ; then abort
    cp 001h                     ; First byte? 
    jr z,no_more_ram            ; then no memory was found

    ld hl,RAM_bank2             ; double check memory with a bit-pattern
    call check_pattern
    jr nz,no_more_ram           ; pattern test failed

    ld hl,memsize               ; 2nd 16k block of memeory is ok 
    inc (hl)                    ; memsize <- 2 = 32K

; test 3rd 16k block of memory at 0xe000
; this block is bank-switched in chunks of 8k at 0xe000
    xor a                       ; switch to 1st bank (0)
    out (094h),a
    ld hl,RAM_bank3             ; start address (0xe0000) 
    ld bc,020ffh                ; test 32 pages of 256 bytes, all 8 bits   
    call test_memory
    cp 002h                     ; failure past 1st byte?
    jr z,jr_z_boot_error        ; boot_error is too far for a relative jump, do it in 2 steps :-)
    cp 001h                     ; 1st byte a failure? 
    jr z,no_more_ram            ; then we're done with RAM
    ld hl,RAM_bank3             ; double check memory with a bit-pattern
    call check_pattern
    jr nz,no_more_ram           ; failed, we're done 
    ld a,001h                   ; switch to 2nd bank (1)
    out (094h),a
    ld hl,RAM_bank3             ; start address (0xe0000) 
    ld bc,020ffh                ; test 32 pages of 256 bytes, all 8 bits   
    call test_memory
l0303h:
    or a                        ; zero?
    jr nz,jr_nz_boot_error      ; no, abort but boot_error is too far for a relative jump, do it in 2 steps :-)
    ld hl,memsize               ; 3rd block of 16k memory is ok
    inc (hl)                    ; memsize <- 3 = 48k 
    out (094h),a                ; switch back to 1st bank (0)

no_more_ram:
    ld a,(memsize)              ; how many banks were found?
    cp 003h                     ; 3?
    jr nz,prep_status_display   ; mem at 0xe000 is on the extension board.
                                ; so when no mem is found at 0xe000 there are also no diskdrives.

; disk boot logic
; is a cartridge inserted that needs a disk (DOS) boot?
    ld a,(01000h)               ; is a cartridge present? 
    bit 0,a                     ; then this bit is set
    jr nz,prep_status_display   ; no cartridge, so don't boot from disk
    bit 1,a                     ; cartridge needs dos? 
    jr z,prep_status_display    ; no so don't boot from disk

    ld a,004h                   ; Bit 2 = RESET command to FDC
    out (DSKCTRL),a             ; send to FDC
    ld b,000h                   ; delayloop of 256 iterations 
fdc_test_delay:
    djnz fdc_test_delay 
    in a,(DSKIO1)               ; read fdc reply
    cp 080h                     ; hi bit set indicates FDC is ready
    call z,getdos               ; it is set, so device is present. load DOS tracks

    xor a                       ; always switch FDC off again 
    out (DSKCTRL),a             ; just to make sure

; continue startup, wether DOS was loaded or not.
prep_status_display:
    ld hl,0500eh                ; screen address of base address for mon_status display
    ld (mon_status_io),hl       ; save in status byte pointer
; prepare flash-on and flash off.
; status characters will be placed in between
; to make them flash
    ld b,8                      ; 8 = flash on
    ld e,0                      ; offset0 
    call show_mon_status        ; put on screen
    ld b,9                      ; 9 = flash off
    ld e,4                      ; offset  4
    call show_mon_status        ; put on screen

; check for printer baud rate setting
    in a,(CPRIN)                ; read
    bit 0,a                     ; check printer data bit
    ld a,007h                   ; presume 300baud 
    jr z,store_baud             ; data bit low = 300baud
    ld a,001h                   ; if data bit high, use 1200baud (default)
store_baud:
    ld (baudrate),a             ; save baudrate (formula : baud = 2400 / baudrate+1)  
    call cas_Init               ; init MDCR (Mini Digital Cassette Recorder) 
    call initkey                ; int keyboard 
    call enablekey              ; enable keyboard 

; check cartridge
    ld a,(Cartridge_ROM)        ; first byte of cartridge ROM
    and 0f5h                    ; mask with 0b11110101  
    cp 054h                     ; egual to  0b11110100 ? 
    jr nz,bootstrap             ; no cartridge signature present, try loading from tape

    ld hl,Cartridge_ROM         ; pointer to 1st byte of ROM
    ld a,(hl)                   ; get 1st byte
    bit 0,a                     ; bit 0 set?
    jr nz,bootstrap             ; then try to bootstrap

    push hl                     ; save start of cartridge
    call validate_cartridge     ; check 1st 8k bank of cartridge ROM
                                ; jumps into cassette load on checksum error 
    pop hl                      ; get start of cartridge back
    bit 3,(hl)                  ; check bit 3 (0370 cb 5e   . ^ 
    set 5,h                     ; H contained 10, now contains 30  
    call z,validate_cartridge   ; check 2nd 8k Bank of cartridge ROM
                                ; jumps into cassette load on checksum error 
    ld hl,Cartridge_NAME        ; ROM name is stored at cartridge start + 5 
    ld de,05002h                ; print name on line 1, char 3 of the screen 
    ld bc,00008h                ; len is 8 characters 
    ldir                        ; print on screen
    jp Cartridge_START          ; and jump to start of executable code in the ROM

bootstrap:
    call show_start_message
bootloop:
    ld b,000h                   ; clear mon status character
    ld e,003h
    call show_mon_status

check_tape_loop:
    ld a,cStatus                ; get cassette status
    call cassette
    jr z,check_tape_loop        ; Z = No Tape present wait for one!

    ld a,cRewind                ; rewind tape
    call cassette
    jr nz,bootloop              ; NZ: tape too long, tape broken

    ld hl,1024                  ; try to load a block
    ld (file_length),hl         ; 1024 long
    ld hl,0000h                 ; 
    ld (record_length),hl       ; actual length  
    ld a,cRead                  ; read a block
    call cassette
    jr nz,bootloop              ; NZ means no marker or block found: try again

    ld a,cRewind                ; rewind again
    call cassette               ;
    jr nz,bootloop              ; NZ: tape too long, tape broken

    ld a,(type)                 ; get file type from header
    cp 'P'                      ; is it a stand-alone P rogram? 
    jr nz,bootloop              ; no, so try again

    ld hl,(record_length)       ; get real file length from header 
    ld (file_length),hl
    ld hl,(load)                ; set load address to the one from the header
    ld (transfer),hl

    ld a,cRead                  ; and load the complete file
    call cassette
    jr nz,bootloop              ; load error? keep booting

    ld b,000h                   ; 0 = empty
    ld e,003h                   ; offset
    call show_mon_status
    ld hl,(start_boot)          ; get execution address from header
    jp (hl)                     ; and start bootstrap code

; test_memory 
; inputs: 
; HL: start address
; BC: B # of pages, C bitpattern
; returns: A
; 0 = succes, 1 = maybe ROM, 2 = RAM failure
test_memory:
    push hl                     ; start address
    pop ix                      ; to  IX
    ld d,c                      ; copy bitpattern 
    ld c,000h                   ; and turn BC into # of bytes to test
    dec hl                      ; prepare for pre-increment
test_byte:  
    inc hl                      ; point to next RAM location
    ld (hl),000h                ; store zero
    ld a,(hl)                   ; read back
    and d                       ; mask bits to test 
    jr nz,memory_error          ; one of the bits not zero? ERROR! 
    dec bc                      ; one less byte to test
    or b                        ; a was zero
    jr nz,test_byte             ; not at last page then continue
    or c                        ; last byte of last page?  
    jr nz,test_byte             ; no, continue  
    ret                         ; return with a==0 success! 

memory_error:
    push ix                     ; start address
    pop bc                      ; in BC
    xor a                       ; A<-0
    inc a                       ; A<-1 presume ROM 
    sbc hl,bc                   ; was the error on the first byte? 
    jr nz,ram_error             ; no, so error must be in RAM
    ret

ram_error:  
    inc a                       ; a<-2 = RAM failure
    ret


check_pattern:  
    ld (hl),001010101b          ; pattern to try  
    ld a,(hl)                   ; read back
    cp 001010101b               ; pattern intact?
    ret nz                      ; no, return NZ (=error)
    xor a                       ; restore tested memory location 
    ld (hl),a   
    ret                         ; and return Z (=ok)

; validate cartridge ROM 
; inputs:
; HL points to 1st byte of cartridge ROM to check
; 1st 5 bytes of cartridge ROM:
; defb signature
; defw len
; defw checksum
; returns: Z flag if success
; jumps into cassette bootstrap routine on error
validate_cartridge:
    inc hl                      ; skip signature byte
    ld c,(hl)                   ; lo byte of byte count
    inc hl                      ;
    ld b,(hl)                   ; hi byte of byte count
    inc hl                      ;
    ld e,(hl)                   ; lo byte of checksum
    inc hl                      ;
    ld d,(hl)                   ; hi byte of checksum
rom_test_loop:  
    ld a,b                      ; is byte count zero? 
    or c                        ; 
    jr nz,do_ROM_test           ; no, so keep checking 
    ld a,d                      ; checksum also zero?  
                                ; can be zero from the start: OK
    or e                        ; otherwise all bytes were added to DE. 
                                ; result should then also be zero, if not it is a checksum error
    ret z                       ; Z is ok, NZ = checksum error
    jp bootstrap                ; try to load a program from tape

do_ROM_test:    
    inc hl                      ;get next byte
    ld a,(hl)   
    add a,e                     ;add to 16 bit checksum 
    jr nc,no_add_carry  
    inc d                       ;handle carry 
no_add_carry:   
    ld e,a                      ;sum back in e
    dec bc                      ;dec bytes done 
    jr rom_test_loop

; clear lines on screen
; input:
; HL contains start address
; A: number of lines to erase
clear_lines:
    ld b,80                     ; 80 characters per line
l0425h: 
    ld (hl),000h                ; clear char 
    inc hl                      ; next pos
    djnz l0425h                 ; repeat until B == 0 
    dec a                       ; decrement linecount
    jr nz,clear_lines           ; and do next line
    ret                         ; until done 

; show_start_message
; puts multiple strings on screen
; data format:
; defw startaddress
; defb len
; len characters
; repeat, or end, indicated by 0xff
; if model is 2000M, 20 is added to the start position
; so the text is also 'centered' on a 80 column screen
show_start_message:
    ld hl,startup_msg
next_string:
    ld e,(hl)                   ; get lo byte of dest
    inc hl  
    ld d,(hl)                   ; hi byte of dest
    inc hl      
    ld b,000h                   ; hi byte of cout to 0
    ld c,(hl)                   ; get count byte
    inc hl                      ; point to 1st character
    ld a,(type_T_M)             ; check model
    bit 0,a 
    jr z,plot_string            ; bit not set: 2000T 
    push hl                     ; save char pointer 
    ld hl,20                    ; on 2000M add 20 to startpos 
    add hl,de   
    ex de,hl                    ; adjusted destination
    pop hl                      ; get character pointer back
plot_string:    
    ldir                        ; and plot
    ld a,(hl)                   ; peek next byte
    cp 0ffh                     ; 0xff indicates last string was plotted 
    jr nz,next_string           ; otherwise do next string
    ret

; cpm_start
; switches to bank 2 at 0xe000 and calls CPM startcode
; switches back to bank 1 and returns result in A
cpm_start:
    ld (stacktemp),sp           ; save stackpointer, CPM uses its own stack
    ld sp,06130h                ; Get CPM/DOS stackpointer
    ld a,001h                   ; CPM/DOS runs in Bank 1 
    out (094h),a    
    call CPM_entry_point    
    push af                     ; save result from CPM
    xor a                       ; Back to bank 0 at 0xe000, user data
    out (094h),a                ;
    pop af                      ; get CPM result 
    ld sp,(stacktemp)           ; and restore user stack 
    ret

; readdisk
; reads B bytes from port C and stores at HL 
; C contains port to read from (depends on device ????)
; HL points to destination address
; B contains # bytes to read
readdisk:
    xor a                       ; switch to bank 0 at 0xe000-0xffff (user data)
    out (094h),a    
wait_fdc_byte:                  ; also called from (dead!) code in Disk.asm
    in a,(DSKCTRL)                  ; get FDC status
    rra                         ; lower bit into carry
    jp nc,wait_fdc_byte         ; FDC not ready so keep waiting
    ini                         ; read and store
    jp nz,wait_fdc_byte         ; B not zero, so get next byte
disk_io_exit:    
    ld a,001h                   ; switch to bank 1, back to DOS code/data 
    out (094h),a
    ret

; writedisk
; writes B# of bytes stored at HL to port C
; C contains port to write to (depends on device ????)
; HL points to source address
; B contains # bytes to write
writedisk:
    xor a                       ; switch to bank 0 at 0xe000, User data
    out (094h),a    
writedisk_loop: 
    in a,(DSKCTRL)              ; FDC status
    rra                         ; lo bit into carry
    jr nc,writedisk_loop        ; FDC not ready
    outi                        ; write byte from (HL) to port C, inc HL, dec B
    jp nz,writedisk_loop        ; B not zero, so output next byte
    jr disk_io_exit

; statuskey
; input: none
; results
; Z-flag set: keybuffer is empty
; C-flag set: STOP (shift + bottom right of keypad) is next key in the buffer
statuskey:
    ld a,(keycount)             ; is keycount zero? 
    or a    
    ret z                       ; yes! we're done
    ld a,(keybuffer)            ; get first key in the buffer
    cp 058h                     ; is it 'STOP'? (0x58)
    jr nz,is_not_STOP               ; no so clear carry
    sub 059h                    ; subtract 0x59 causes underflow and sets Carry
    ret 
is_not_STOP:   
    scf                         ; set carry
    ccf                         ; complement carry
    ret

; readkey
; reads the next key from the keyboardbuffer
; waits for a key when buffer is empty, so call statuskey first to prevent that
; also writes 0x00 to empty buffer positions
; input: none
; results:
; reg A contains keycode, NOT ASCII/Display value
; C-flag set: key is STOP key (shift + bottom right of keypad)
readkey:
    call statuskey              ; key available? 
    jr z,readkey                ; no, so wait until a key comes available
    di                          ; interrupts off to prevent keybuffer changes (interrupt routine scans keyboard!)
    exx                         ; save register pairs
    ld hl,keycount              ; get keycountaddress
    ld a,(hl)                   ; get count
    or a                        ; is it zero? (can happen when an interrupt occurred between call statuskey and jr z)
    jr z,readkey                ; wait untill a key is available
    dec (hl)                    ; one less key in the buffer
    ld a,(keycount)             ; was this the last key?
    or a    
    jr nz,move_keys             ; no, so move all buffered keys one position
    ld a,(keybuffer)            ; get keycode
    ld hl,keybuffer             ; reset keycode to 0
    ld (hl),000h    
    jr l04d3h                   ; and check for STOP
move_keys:  
    ld b,000h                   ; prepare BC as counter
    ld c,a                      ; a = keycount, BC <- keys to move
    ld hl,keybuffer+1           ; copy from here 
    ld de,keybuffer             ; to here
    ld a,(keybuffer)            ; get keycode to return, will be overwritten by the move
    ldir                        ; do the move
    ld hl,keybuffer             ; start of buffer
    push af                     ; save keycode 
    ld a,(keycount)             ; make hl point to keycode that must be erased
    ld l,a  
    ld (hl),000h                ; clear keycode
    pop af                      ; get keycode to return
l04d3h: 
    exx                         ; restore all register pairs
    cp 058h                     ; is the keycode 'STOP'? (0x58)
    scf                         ; presume it is (set Carry)
    jr z,it_is_STOP 
    ccf                         ; not stop, clear Carry
it_is_STOP: 
    ei                          ; interrupts on
    ret

clearkey:
    xor a                       ; set keycount to 0
    ld (keycount),a 
    ret
