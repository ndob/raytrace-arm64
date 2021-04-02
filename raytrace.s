.global raytrace                    // Export function.

.equ RT_STACK_PBUF_ADDR, 0          // Stack offset for pbuffer address.
.equ RT_STACK_PBUF_WIDTH, 8         // Stack offset for pbuffer width.
.equ RT_STACK_PBUF_HEIGHT, 12       // Stack offset for pbuffer height.
.equ RT_STACK_ROW_ITERATOR, 16      // Stack offset for pbuffer row iterator.
.equ RT_STACK_COLUMN_ITERATOR, 20   // Stack offset for pbuffer column iterator.

// Hit world stack.
.equ HITW_STACK_DIRECTION, 0
.equ HITW_STACK_ORIGIN, 16
.equ HITW_STACK_HIT0_NORMAL, 32
.equ HITW_STACK_HIT0_POINT, 48
.equ HITW_STACK_HIT0_T, 64
.equ HITW_STACK_HIT0_TRUE, 68

.macro funcProlog
    str     LR, [SP, #-16]!         // Push link register on to stack.
.endm

.macro funcEpilog
    ldr     LR, [SP], #16           // Pop link register from the stack.
    ret                             // Return to caller.
.endm

// Dot prod result is in destReg.4S[0]
.macro dot_prod_neon destReg, srcReg0, srcReg1
    fmul    \destReg, \srcReg0, \srcReg1    // Multiply elementwise.
    faddp   \destReg, \destReg, \destReg    // Reduce sums to first two elements.
    faddp   \destReg, \destReg, \destReg    // Reduce the final dot product to first 32 element of V5
.endm

//
// Raytrace a scene.
//
// X0: Pixel buffer address.
// X1: Pixel buffer width.
// X2: Pixel buffer height.
//
raytrace:
    funcProlog
    sub     SP, SP, #32                         // Allocate space for address (8), w(4)+h(4), row (4)+column(4) iterators
    str     X0, [SP, #RT_STACK_PBUF_ADDR]       // Save address.
    str     W1, [SP, #RT_STACK_PBUF_WIDTH]      // Save width.
    str     W2, [SP, #RT_STACK_PBUF_HEIGHT]     // Save height.
    ldr     W8, [SP, #RT_STACK_PBUF_HEIGHT]     // Row iterator init (4byte word)

rt_loop_rows:
    ldr     W9, [SP, #RT_STACK_PBUF_WIDTH]      // Column iterator init
    ldr     W2, [SP, #RT_STACK_PBUF_HEIGHT]     // Load height.
    sub     X10, X2, X8                         // Current row index: height - row-iterator
    mul     X10, X10, X1                        // Row*stride (==width in this case).
    ldr     X0, [SP, #RT_STACK_PBUF_ADDR]       // Load pbuffer start address.
    add     X10, X0, X10                        // Offset rows*stride from pbuf address start -> start address of the current row.

rt_loop_columns:
    // Prepare and call get_pixel_val
    str     W8, [SP, #RT_STACK_ROW_ITERATOR]    // Save iterator
    str     W9, [SP, #RT_STACK_COLUMN_ITERATOR] // Save iterator
    fmov    S0, W9                              // Param 1: Cur pixel x
    fmov    S1, W8                              // Param 2: Cur pixel y
    ldr     W2, [SP, #RT_STACK_PBUF_WIDTH]
    ldr     W3, [SP, #RT_STACK_PBUF_HEIGHT]
    fmov    S2, W2                              // Param 3: Width
    fmov    S3, W3                              // Param 4: Height
    bl      get_pixel_val                       // Call function.
    // Handle return value.
    ldr     W8, [SP, #RT_STACK_ROW_ITERATOR]    // Restore iterator from the stack.
    ldr     W9, [SP, #RT_STACK_COLUMN_ITERATOR] // Restore iterator from the stack.
    mov     X11, X0                             // Returned pixel value.
    strb    W11, [X10], #1                      // Save the pixel and move the pointer by one.
    subs    X9, X9, #1                          // Decrement column iterator.
    b.ne    rt_loop_columns                     // Check if we have columns left.
    subs    X8, X8, #1                          // Decrement column iterator.
    b.ne    rt_loop_rows                        // Check if we have rows left.

    add     SP, SP, #32                         // Deallocate stack.
    funcEpilog

//
// Calculate pixel value.
// S0: Pixel x
// S1: Pixel y
// S2: Width
// S3: Height
//
// Returns pixel value [0,255] in X0.
get_pixel_val:
    funcProlog
    // Calculate UV
    fdiv    S0, S0, S2                          // U = x / width
    fdiv    S1, S1, S3                          // V = y / height

    mov     V0.4S[0], V0.4S[0]                  // Vector for U: V0 (Q0) [U, 0, 0, 0]
    mov     V1.4S[1], V1.4S[0]                  // Vector for V: V1 (Q1) [0, V, 0, 0]
    mov     X0, #0                              //
    mov     V1.4S[0], W0                        // Clear first element of V1.
    ldr     X0, =screen_bottom_left             //
    ldr     Q2, [X0]                            // Load bottom left coordinate V2 (Q2).
    ldr     X0, =x_size                         //
    ldr     Q3, [X0]                            // Load x size to V3 (Q3).
    ldr     X0, =y_size                         //
    ldr     Q4, [X0]                            // Load y size to V4 (Q4).
    // Calculate direction ray.
    fmul    V0.4S, V0.4S, V3.4S                 // U * xSize
    fmul    V1.4S, V1.4S, V4.4S                 // V * ySize
    fadd    V0.4S, V0.4S, V1.4S                 // (U * xSize) + (V * ySize)
    fadd    V0.4S, V0.4S, V2.4S                 // screenLowerLeft + (U * xSize) + (V * ySize)
    bl      normalize_neon                      // Normalize coordinate. We have it in V0 (Q0).
    ldr     X0, =ray_origin                     //
    ldr     Q1, [X0]                            // Load ray origin to V1 (Q1).
    bl      trace                               // Call with Q0 = dir, Q1: origin
    ldr     X0, =intensity_multiplier           //
    ldr     S3, [X0]                            // Load 255.0 to FPU.
    fmul    S0, S0, S3                          // Pixel intensity conversion from [0, 1] to [0, 255]. S0 has the result.
    fcvtas  W0, S0                              // Convert to signed integer [0, 255].
    funcEpilog

//
// Calculate vector normal with NEON instructions.
// Q0 (V0): Modify in place to contain the normalized value.
//
normalize_neon:
    funcProlog
    fmul    V1.4S, V0.4S, V0.4S     // Power 2.
    faddp   V1.4S, V1.4S, V1.4S     // Add x^2 + y^2 + z^2 and store to first 2 32bit element of V1.
    faddp   V1.4S, V1.4S, V1.4S     // Reduce the length (i.e. sum) to first 32bit element of V1.
    fsqrt   S1, S1                  // Length in S1.
    dup     V1.4S, V1.4S[0]         // Duplicate length to all elements.
    fdiv    V0.4S, V0.4S, V1.4S     // Divide the individual elements by the length.
    funcEpilog

//
// Calculate vector normal.
// S0-S2: Modify in place to contain the normalized value.
//
normalize:
    funcProlog
    fmul    S3, S0, S0          // x^2.
    fmul    S4, S1, S1          // y^2
    fmul    S5, S2, S2          // z^2
    fadd    S3, S3, S4          // Add x^2 + y^2
    fadd    S3, S3, S5          // Add z^2
    fsqrt   S3, S3              // Length in S3
    fdiv    S0, S0, S3          // x / length
    fdiv    S1, S1, S3          // y / length
    fdiv    S2, S2, S3          // z / length
    funcEpilog

//
// Trace a ray.
// Q0 (V0): Direction xyz as 32bit floats (last channel empty)
// Q1 (V1): Origin xyz as 32bit floats (last channel empty)
//
// Returns
// S0: intensity
//
trace:
    funcProlog
    // Q0 (direction) and Q1 (origin) are already set by the caller.
    bl      hit_world               // Call function.
    cmp     X0, 0                   // Check if we got a hit.
    b.le    ret_default_val         // If the result is 1 we got a hit.
    fadd    V0.4S, V1.4S, V0.4S     // New target point: hitpoint + normal + random
    ldr     X0, =random_placeholder // Use random placeholder for now. TODO: Real pseudorandom.
    ldr     Q7, [X0]                // Load the placeholder.
    fadd    V0.4S, V0.4S, V7.4S     // Final target.
    // Hitpoint is the new origin. It is already in Q1.
    bl      trace                   // Call trace recursively for next intensity.
    ldr     X0, =hit_multiplier     //
    ldr     S1, [X0]                // Load multiplier to S1.
    fmul    S0, S0, S1              // Multiplier * intensity.
    funcEpilog
ret_default_val:
    ldr     X0, =default_bg_val     //
    ldr     S0, [X0]                // Load default background value to return address and return.
    funcEpilog

//
// Trace a ray through the world elements.
// Q0 (V0): Direction xyz as 32bit floats (last channel empty)
// Q1 (V1): Origin xyz as 32bit floats (last channel empty)
//
// Returns
// S0: intensity
//
hit_world:
    funcProlog
    // Save dir + origin onto the stack.
    sub     SP, SP, #80                     // Allocate space for direction (16), origin (16), hit0-normal (16), hit0-hp(16), hit0-t(4), hit-truefalse (8)
    str     Q0, [SP, #HITW_STACK_DIRECTION] // Save direction vector.
    str     Q1, [SP, #HITW_STACK_ORIGIN]    // Save origin vector.

    // Q0 (direction) and Q1 (origin) are already set by the caller.
    ldr     X0, =sphere0_pos        //
    ldr     Q2, [X0]                // Load sphere position (vec3).
    ldr     X0, =sphere0_radius     //
    ldr     S3, [X0]                // Load sphere radius.
    bl      hit_sphere              // Call function.
    // Save the hit data of sphere0
    str     Q0, [SP, #HITW_STACK_HIT0_NORMAL]   // Save hit0 normal.
    str     Q1, [SP, #HITW_STACK_HIT0_POINT]    // Save hit0 hitpoint.
    str     S2, [SP, #HITW_STACK_HIT0_T]        // Save hit0 t.
    str     X0, [SP, #HITW_STACK_HIT0_TRUE]     // Save hit0 true/false.

    // sphere1 test
    ldr     Q0, [SP, #HITW_STACK_DIRECTION] // Load direction vector.
    ldr     Q1, [SP, #HITW_STACK_ORIGIN]    // Load origin vector.
    ldr     X0, =sphere1_pos                //
    ldr     Q2, [X0]                        // Load sphere position (vec3).
    ldr     X0, =sphere1_radius             //
    ldr     S3, [X0]                        // Load sphere radius.
    bl      hit_sphere                      // Call function.
    cmp     X0, #0                          // Check if sphere1 was a hit.
    b.le    use_sphere0                     //
    ldr     X5, [SP, #HITW_STACK_HIT0_TRUE] // Load hit0 true/false.
    cmp     X5, #0                          // Check if sphere0 was a hit.
    b.le    use_sphere1                     //
    ldr     S5, [SP, #HITW_STACK_HIT0_T]    // Load hit0 t.
    fcmp    S2, S5                          // Both were hit so compare hits.
    b.gt    use_sphere0                     // If sphere0 is nearer use that.
use_sphere1:
    add     SP, SP, #80                     // Deallocate stack.
    funcEpilog                              // Registers are already set properly.
use_sphere0:
    // Set sphere0 data:
    ldr     X0, [SP, #HITW_STACK_HIT0_TRUE]     // Load hit0 true/false.
    ldr     Q0, [SP, #HITW_STACK_HIT0_NORMAL]   // Load hit0 normal.
    ldr     Q1, [SP, #HITW_STACK_HIT0_POINT]    // Load hit0 hitpoint.
    ldr     S2, [SP, #HITW_STACK_HIT0_T]        // Load hit0 t.
    add     SP, SP, #80                         // Deallocate stack.
    funcEpilog


//
// Try if the ray hit a sphere.
// Q0: Direction xyz as 32bit floats (last channel empty). Vec3 B = r.direction;
// Q1: Origin xyz as 32bit floats (last channel empty)
// Q2: Sphere position xyz as 32bit floats (last channel empty)
// S3: Sphere radius
//
// Returns
// X0: Was hit true/false.
// Q0: Hit point normal xyz as 32bit floats (last channel empty)
// Q1: Hit point xyz as 32bit floats (last channel empty)
// S2: 't'
//
// Basically implements the following C++-code:
// {
//    Vec3 AC = (ray.origin - sphere_pos);
//    Vec3 B = ray.direction;
//
//    float a = dot(B, B);
//    float b = 2 * dot(AC, B);
//    float c = dot(AC, AC) - (sphere_radius * sphere_radius);
//    float discriminant = (b * b) - (4 * a * c);
//
//    if (discriminant > 0.f)
//    {
//        float t = (-b - std::sqrt(discriminant)) / (2 * a);
//        if (t < 0.0)
//        {
//            return false;
//        }
//
//        result.hitPoint = ray.point_at_t(t);
//        result.normal = normal(result.hitPoint - sphere_pos);
//        result.t = t;
//        return true;
//    }
//    return false;
//}
//
hit_sphere:
    funcProlog
    fsub            V4.4S, V1.4S, V2.4S     // Vec3 AC = (r.origin - pos);                  -> V4
    dot_prod_neon   V5.4S, V0.4S, V0.4S     // float a = dot(B, B);                         -> S5 (V5)
    dot_prod_neon   V6.4S, V4.4S, V0.4S     // dot(AC, B);
    fmov            S7, #2.0                // 2.0f
    fmul            S6, S7, S6              // float b = 2 * dot(AC, B);                    -> S6 (V6)
    dot_prod_neon   V7.4S, V4.4S, V4.4S     // dot(AC, AC)
    fmul            S3, S3, S3              // (radius * radius)
    fsub            S7, S7, S3              // float c = dot(AC, AC) - (radius * radius);   -> S7 (V7)
    fmul            S8, S6, S6              // (b * b)
    fmov            S15, #4.0               // 4.0 to S15
    fmul            S9, S5, S15             // 4.0 * a
    fmul            S9, S9, S7              // (4 * a * c)
    fsub            S10, S8, S9             // float discriminant = (b * b) - (4 * a * c);  -> S10
    fcmp            S10, #0.0               // Check if discriminant is positive -> we have solutions.
    mov             X0, 0                   // Default return code: false
    b.le            hit_exit                // Exit if we didn't get a hit
    // Calculate 't'
    fsqrt           S10, S10                // Sqrt discriminant (overwrites original).
    fneg            S6, S6                  // -b (overwrites original)
    fmov            S8, #2.0                // 2.0 to S8.
    fmul            S5, S5, S8              // 2 * a (overwrites original)
    fsub            S10, S6, S10            // (-b - std::sqrt(discriminant))
    fdiv            S10, S10, S5            // S10 = t
    fcmp            S10, #0.0               // Check if t > 0.
    mov             X0, 0                   // Default return code: false
    b.le            hit_exit                // Exit if we didn't get a hit
    // Prepare return values
    mov             X0, 1                   // Return: True
    dup             V10.4S, V10.4S[0]       // Duplicate t to all elements.
    fmul            V0.4S, V0.4S, V10.4S    // direction * t
    fadd            V4.4S, V1.4S, V0.4S     // Hitpoint intermediate register (origin + direction * t)
    fsub            V0.4S, V4.4S, V2.4S     // Calculate normal direction vector. (hitpoint - sphere center)
    bl              normalize_neon          // Return: hitpoint normal. Normalize in place (Q0).
    mov             V1.16B, V4.16B          // Return: hitpoint
    fmov            S2, S10                 // Return: t
    // Fall through to exit
hit_exit:
    funcEpilog


.data
ray_origin:             .single 0.0, 0.0, 0.0, 0.0          // Ray origin position.
screen_bottom_left:     .single -2.0, -1.0, -1.0, 0.0       // Camera bottom left coordinate.
x_size:                 .single 4.0, 0.0, 0.0, 0.0          // Camera viewport X size.
y_size:                 .single 0.0, 2.0, 0.0, 0.0          // Camera viewport Y size.
default_bg_val:         .single 0.9                         // Default intensity if no hit.
hit_multiplier:         .single 0.2                         // Hit multiplier.
sphere0_pos:            .single 0.0, 0.0, -1.0, 0.0         // Sphere0 position.
sphere0_radius:         .single 0.5                         // Sphere0 radius.
sphere1_pos:            .single 0.0, -100.5, -1.0, 0.0      // Sphere1 position.
sphere1_radius:         .single 100.0                       // Sphere1 radius.
intensity_multiplier:   .single 255.0                       // Multiplier from normalized values [0, 1] to [0, 255].
random_placeholder:     .single 0.8, 0.8, 0.3, 0.0          // Placeholder vector, before random is implemented.
