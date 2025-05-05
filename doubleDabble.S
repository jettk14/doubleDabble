// PROJECT  :doubleDabble
// PURPOSE  :Convert a 10-bit analogPin reading to BCD, then print
// COURSE   :ICS4U-E
// AUTHOR   :C. D'Arcy
// DATE     :2025 05 04
// MCU      :328P
// STATUS   :Working

#include  <avr/io.h>            //required to reference ports by 
#include  "Timer1Prescalers.h"  //local Timer defines
#include  "ADCPrescalers.h"     //local ADC defines
.global main                    ;bypass Arduino C requirement of setup & loop
.global TIMER1_OVF_vect         ;handles this interrupt
.global ADC_vect                ;handles this interrupt

#define     DDR    DDRC-0x20    //avr-as requires relative addressing 
#define     PORT   PORTC-0x20   //ditto
.section  .text                 ;for Program Flash

//Prep for TIMER1_SETUP & OVF_vect
.equ plHI,  0x00  ;optional preload (0xFDDD yields 120ovf/s=60Hz)
.equ plLO,  0x00  ;optional preload for TCNT1L (0xFD70=50Hz, 0xFCCC=40Hz)

//Prep for init_USART
.equ BAUD_PRESCALER, 103        ;precomputed
.equ ASYNCHRONOUS, 0<<UMSEL01 | 0<<UMSEL00
.equ PARITY_NONE,  0<<UPM01   | 0<<UPM00
.equ CHAR_SIZE8,   0<<UCSZ02  | 1<<UCSZ01 | 1<<UCSZ00   ;8-bit
.equ STOP_BITS1,   0<<USBS0

util   = 16          ;rename common registers
TX     = 17          ;"
bin0   = 18          ;"
bin1   = 19          ;"
BCD21  = 20          ;"
BCD43  = 21          ;"
offset = 22          ;"
c3h    = 23          ;"
c3l    = 24          ;"
c4l    = 25          ;"

.org  0x0000       ;base address of Interrupt Vector (jump) Table (IVT)
reset:
  rjmp   main            

.org  0x0100       ;locate the start of the code well clear of the IVT 
main:
  rcall   init_USART      ;initialize baud, char size, parity, stop bits 
  rcall   IO_SETUP        ;setup desired IO pins for "blink"
  rcall   ADC_SETUP       ;setup ADC regs for desired operation
  rcall   TIMER1_SETUP    ;Setup timer1overflow for ADC frequency

    ldi offset, 48        ;load constant registers
    ldi c4l, 0x04         ;"
    ldi c3h, 0x30         ;"
    ldi c3l, 0x03         ;"

  sei                     ;Initialize Global Interrupts
hold:                     ;wait...
  rjmp hold
ret

; PreCondition:  util is a general purpose register
; PostCondition: Contents of R24 are transmitted via the USART (should appear on the Serial Monitor)
init_USART:     ;Initialize serial communication
  ldi   util,hi8(BAUD_PRESCALER)      ;set the baud rate
  sts   UBRR0H, util                  ;"
  ldi   util,lo8(BAUD_PRESCALER)      ;"
  sts   UBRR0L, util                  ;"

  ldi   util, (1<<TXEN0)   ;enable receive and transmit
  sts   UCSR0B, util                    ;"

  ldi   util, ASYNCHRONOUS | CHAR_SIZE8 | PARITY_NONE | STOP_BITS1
  sts   UCSR0C, util                    ;set Comm. Mode  Default: 8N1 
ret

IO_SETUP:                   ;Setup Pin13 for blink
  sbi     DDRB-0x20,DDB5    ;pinMode(13,OUTPUT);
ret

; PreCondition:  util is a general purpose register, ADCPrescalers.h is attached.
; PostCondition: Internal 10-bit ADC is setup, to be activated on trigger interrupt.
ADC_SETUP:                  ;Setup ADC registers for ISR triggered conversion
  ser   util                ;r16 <- 0xFF, reset utility register
  sts   DIDR0, util         ;disable digital pins on PORTC when using ADC
//Setup ADMUX Register:
  ldi   util, ADCAVCC       ;AVCC as voltage reference (0.1uF on AREF)
  ori   util, ADC5          ;choose (arbitrarily) analog pin A0
  ori   util, (1<<ADLAR)
  sts   ADMUX,util          ;do it
//Setup ADC Control/Status Register:
  ldi   util, 1<<ADEN       ;enable ADC
  ori   util, 1<<ADSC       ;start a first dummy conversion
  ori   util, ADCps128      ;recommended prescaler to get to 125kHz
  sts   ADCSRA, util        ;do it / dummy ADC has begun
//Create an initial dummy conversion:
    dummy:
  lds   util,ADCSRA         ;wait for it to complete
  sbrs  util,ADIF           ;is the first 25-cycle conversion complete?
  rjmp  dummy               ;keep waiting....
//Dummy conversion complete, finish ADCSRA setup:
  lds   util, ADCSRA        ;prepare to clear the ADIF flag
  ori   util, 1<<ADIF       ;ADIF flag is cleared by writing a 1 to it
  ori   util, 1<<ADATE      ;enable external trigger to start a conversion
  sts   ADCSRA,util         ;do it
//Determine trigger source:
  ldi   util, ADCtsT1OVF    ;select Timer1 Overflow as Trigger Source
  sts   ADCSRB,util         ;do it
//Finalize ADCSRA setup:
  lds   util,ADCSRA        ;need to enable ADC Complete Interrupt...
  ori   util, 1<<ADIE       ;set the interrupt Enable bit...
  sts   ADCSRA,util         ;do it
ret

; PreCondition:  util is a general purpose register, Timer1Prescalers.h is attached
; PostCondition: Timer1 interrupt is setup at 1 Hz
TIMER1_SETUP:             ;determine interrupt frequency
  clr util                ;Prep utility reg for Normal Mode
  sts TCCR1A, util        ;set Normal Mode in T1 Control Reg A
  ldi util, T1ps256       ; T1:2^24/2^8/2^16 (prescale)> 1 ovf/s> 0.5Hz
  sts TCCR1B, util        ;Timer1 clock = system clock / prescale
  ldi util,1<<TOIE1       ;enable Timer/Counter1 Overflow Interrupt
  sts TIMSK1,util         ;enable Timer1 Overflow interrupts
ret

TIMER1_OVF_vect:          ;destination for TCNT1 overflow interrupt 
  ldi util,plHI           ;load TCNT1 (Timer1's 2-byte counter)
  sts TCNT1H,util         ;do it
  ldi util,plLO           ;repeat for low byte
  sts TCNT1L,util         ;at 60Hz there appears to be some flicker
reti                      ;return from interrupt

ADC_vect:                 ;ISR handler for ADC Complete 
  sbi     PINB-0x20,DDB5  ;writing a 1 to PIN13 toggles it
    CLR BCD21             ;clr BCD nibbles from prev conversion
    CLR BCD43             ;"
  lds bin0, ADCL          ;store ADC result low byte in bin0
  lds bin1, ADCH          ;store ADC result high byte in bin1

repeat:                   ;doubleDabble Algorithm
  rcall check             ;call "add 3" function
  rcall shift             ;shift
  mov r27, bin0           ;check for completion
  or r27 , bin1           ;"
  TST r27                 ;"
  brne repeat             ;repeat if not complete
rcall display             ;once complete, display on serial monitor
reti                      ;return from interrupt

; PreCondition:  None
; PostCondition: If necessary, BCD nibbles have been added 3
check:                    ;check function
  clr r30                 
  check_nibble1:          ;1s digit check begins:
    mov r30, BCD21        ;Transfer low byte to gen purpose reg 
    ANDI r30, 0x0F        ;Isolate low nibble
    cp c4l, r30           ;compare c4h - BCDn1, if greater OR equal...
    brpl check_nibble2    ;if BCDn1 < 5, check next nibble.
    ADD BCD21, c3l        ;if not, add 3                    

  check_nibble2:          ;10s digit check begins:
    mov r30, BCD21        ;Transfer low byte to gen purpose reg
    swap r30              ;swap low & high nibbles
    ANDI r30, 0x0F        ;isolate lower nibble (now 2n)
    cp c4l, r30           ;compare c4l - BCD2, if greater OR equal...
    brpl check_nibble3    ;if BCD2 < 5, check next nibble.
    ADD BCD21, c3h        ;if not, add 3  

  check_nibble3:          ;100s digit check begins:
    mov r30, BCD43        ;Transfer high byte to gen purpose reg
    ANDI r30, 0x0F        ;Isolate low nibble
    cp c4l, r30           ;compare c4h - BCDn3, if greater OR equal...
    brpl check_nibble4    ; if BCDn3 < 5, check next nibble.
    ADD BCD43, c3l        ; if not, add 3     

  check_nibble4:          ;1000s digit check begins:
    mov r30, BCD43        ;Transfer high byte to gen purpose reg
    swap r30              ;swap low & high nibbles
    ANDI r30, 0x0F        ;isolate lower nibble (now 4n)
    cp c4l, r30           ;compare c4l - BCD4, if greater OR equal
    brpl here             ;if BCD4 < 5, skip next line
    ADD BCD43, c3h        ; if not, add 3  
    here:
ret

; PreCondition:  None
; PostCondition: All "DD" bytes are shifted 1 left
shift:                    ;shift function
  lsl bin0                ;doubleDabble "Shift"
  rol bin1                ;"        
  rol BCD21               ;"
  rol BCD43               ;"
  CLC                     ;"               
ret

; PreCondition:  double dabble algorithm is complete, stored in BCD43 & BCD21
; PostCondition: Contents of BCD43 & BCD21 are displayed on the serial monitor
display:                  ;display function
  ldi   offset,'0'        ;BCD values need an ASCII '0' (48) offset
  mov   r17,BCD43         ;prepare the most significant BCD digit
  swap  r17               ;swap high and low nibbles
  andi  r17,0x0F          ;mask off the high nibble 
  add   r17,offset        ;upgrade to ASCII character value
  rcall TXCHAR            ;echo (transmit) it
  mov   r17,BCD43         ;prepare the BCD 100s digit 
  andi  r17,0x0F          ;mask off the high nibble
  add   r17,offset        ;upgrade to ASCII character value
  rcall TXCHAR            ;echo (transmit) it
  mov   r17,BCD21         ;prepare the BCD 10s digit
  swap  r17               ;swap high and low nibbles
  andi  r17,0x0F          ;mask off the high nibble
  add   r17,offset        ;upgrade to ASCII character value
  rcall TXCHAR            ;echo (transmit) it
  mov   r17,BCD21         ;prepare the BCD 1s digit 
  andi  r17,0x0F          ;mask off the high nibble
  add   r17,offset        ;upgrade to ASCII character value
  rcall TXCHAR            ;echo (transmit) it
  ldi r17, 10             ;ASCII 'LF' (.println equivalent)
  rcall TXCHAR            ;echo (transmit) it
ret

; PreCondition:  Character data (1 byte) to be transmitted is in R24
; PostCondition: Contents of R24 are transmitted via the USART (should appear on the Serial Monitor)
TXCHAR:                               
  lds   util,UCSR0A         ;determine if the transmit buffer is empty
  sbrs  util,UDRE0          ;if the flag is set, exit the loop
  rjmp  .-8                 ;loop back to the previous statement 
  sts   UDR0, TX           ;transmit data in TX
ret
