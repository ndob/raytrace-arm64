//
// Raytrace a scene.
//
// X0: Pixel buffer address.
// X1: Pixel buffer width.
// X2: Pixel buffer height.
//

.global raytrace                    // Export function.

raytrace:
    mov     X8, X2        // Row iterator init

rt_loop_rows:
    mov     X9, X1         // Column iterator init
    sub     X10, X2, X8             // Current row index: height - row-iterator
    mul     X10, X10, X1            // Row*stride (==width in this case).
    add     X10, X0, X10            // Offset rows*stride from pbuf address start.

rt_loop_columns:
    mov     X11, X8                  // Pixel value. Row iterator for testing purposes, so we get a gradient.
    strb    W11, [X10], #1            // Save the pixel and move the pointer by one.
    subs    X9, X9, #1              // Decrement column iterator.
    b.ne    rt_loop_columns         // Check if we have columns left.
    subs    X8, X8, #1              // Decrement column iterator.
    b.ne    rt_loop_rows            // Check if we have rows left.

    ret                             // Return to caller
