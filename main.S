// For __NR_*
#include <asm/unistd.h>

.global _start

.equ    O_WRONLY, 1
.equ    O_CREAT,  0100
.equ    S_RDWR,   0666
.equ    AT_FDCWD, -100
.equ    PBUF_WIDTH, 200
.equ    PBUF_HEIGHT, 100
.equ    PBUF_SIZE, 20000 // PBUF_WIDTH * PBUF_HEIGHT

.macro openFile     fname, flags
    mov     X0, #AT_FDCWD       // Search root is CWD.
    ldr     X1, =\fname         // Second paramter is the filename ptr.
    mov     X2, #\flags         // Flags
    mov     X3, S_RDWR          // R+W access
    mov     X8, #__NR_openat    // Linux system call number goes to X8.
    svc     0                   // Call linux interrupt handler to execute the command.
.endm

.macro writeFile    fd, buffer, length
    mov     X0, \fd             // Param 1
    ldr     X1, =\buffer        // Param 2
    mov     X2, \length         // Param 3
    mov     X8, #__NR_write     // Linux system call number goes to X8.
    svc     0                   // Call linux interrupt handler to execute the command.
.endm

.macro closeFile    fd
    mov     X0, \fd             // Param 1 for fsync()
    mov     X8, #__NR_fsync     // Linux system call number to X8.
    svc     0                   // Call
    mov     X0, \fd             // Param 1 for fclose(). Move again as it might have been clobbered (?).
    mov     X8, #__NR_close     // Linux system call number to X8.
    svc     0                   // Call
.endm

// Main entry point
_start:
    ldr     X0, =pbuf           // 1. parameter.
    mov     X1, #PBUF_WIDTH     // 2. parameter.
    mov     X2, #PBUF_HEIGHT    // 3. parameter.
    bl      raytrace

// File output
    openFile    filename, O_WRONLY+O_CREAT  // Open file.
    mov     X19, X0                         // Save fd for closing.
    ldr     X2, =ppm_header_sz              // Load header size address to X2.
    ldr     W2, [X2]                        // Load header size to W2 (i.e. X2 lower part).
    writeFile   X19, ppm_header, X2         // Write the header (X19=fd, X2=header size).
// Write pbuf to ppm file.
    mov     X20, #PBUF_HEIGHT
loop_rows:
    mov     X21, #PBUF_WIDTH                // Column iterator init
    mov     X22, #PBUF_HEIGHT               // Save height
    sub     X22, X22, X20                   // Current row index
    mov     X23, #PBUF_WIDTH                // Stride
    mul     X22, X22, X23                   // Row*stride
    ldr     X23, =pbuf                      // Load the pbuf address.
    add     X23, X23, X22                   // Offset rows*stride from pbuf address start.

loop_columns:
    ldrb    W24, [X23], #1 // Load single pixel data to W24 and move the pointer by one for next column.
    // Fill pixel_str buffer with an ascii string of the pixel value.
    ldr     X5, =pixel_str
    // First char
    mov     X27, X24                // Save the current pixel value
    mov     X28, #100
    udiv    X27, X27, X28           // Divide to get hundreds.
    add     X25, X27, #48           // Add '0' ascii char, so we should get either 0, 1, or 2 in ascii.
    strb    W25, [X5], #1           // Save the first char to X5 and move the pointer by one.
    // Second char
    mul     X27, X27, X28           // Calculate quotient * denominator
    sub     X27, X24, X27           // Numerator - (quotient * denominator) -> remainder
    mov     X28, #10                //
    mov     X24, X27                // Save current numerator
    udiv    X27, X27, X28           // Divide to get tens.
    add     X25, X27, #48           // Add '0' ascii char, so we should get either 0, 1, or 2 in ascii.
    strb    W25, [X5], #1           // Save the first char to X5 and move the pointer by one.
    // Third char
    mul     X27, X27, X28           // Calculate quotient * denominator
    sub     X27, X24, X27           // Numerator - (quotient * denominator) -> remainder
    add     X27, X27, #48           // Add '0' ascii char, so we should get either 0, 1, or 2 in ascii.
    strb    W27, [X5], #1           // Save the first char to X5 and move the pointer by one.

    ldr     X25, =pixel_str_sz      // Load pbuf size address to X2.
    ldr     W25, [X25]              // Load pbuf size to W2 (i.e. X2 lower part).
    writeFile   X19, pixel_str, X25 // Write the pixel buffer (X19=fd, X2=size).

    subs    X21, X21, #1            // Decrement column iterator.
    b.ne    loop_columns            // Check if we have columns left.
    subs    X20, X20, #1            // Decrement column iterator.
    b.ne    loop_rows               // Check if we have rows left.

    closeFile   X19

    mov     X0, #0          // 0 return code.
    mov     X8, #__NR_exit  // System call for exiting.
    svc     0               // Call.

.data
filename:           .asciz "outfile.ppm"
ppm_header:         .ascii "P2\n200 100\n255\n"     // Grayscale PPM.
ppm_header_sz:      .word .-ppm_header              // '.' denotes "this address" -> [this address] - [start address of the string] = size
pbuf:               .fill   PBUF_SIZE, 1, 0         // Fill buffer with zeros.
pbuf_sz:            .word .-pbuf
pixel_str:          .fill   4, 1, 0x20              // Fill with spaces
pixel_str_sz:       .word .-pixel_str
