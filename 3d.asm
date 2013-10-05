;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Copyright (c) 2011 Hanna Reitz                                               ;
;                                                                              ;
; Permission is hereby granted, free of charge, to any person obtaining a copy ;
; of this software and  associated documentation files  (the  "Software"),  to ;
; deal in the  Software without restriction,  including without limitation the ;
; rights to use, copy, modify, merge,  publish, distribute, sublicense, and/or ;
; sell copies of the Software,  and to permit  persons to whom the Software is ;
; furnished to do so, subject to the following conditions:                     ;
;                                                                              ;
; The above copyright notice and this  permission notice  shall be included in ;
; all copies or substantial portions of the Software.                          ;
;                                                                              ;
; THE SOFTWARE IS PROVIDED "AS IS",  WITHOUT WARRANTY OF ANY KIND,  EXPRESS OR ;
; IMPLIED,  INCLUDING BUT NOT  LIMITED TO THE  WARRANTIES OF  MERCHANTABILITY, ;
; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE ;
; AUTHORS  OR COPYRIGHT  HOLDERS BE  LIABLE FOR  ANY CLAIM,  DAMAGES OR  OTHER ;
; LIABILITY,  WHETHER IN AN  ACTION OF CONTRACT,  TORT OR  OTHERWISE,  ARISING ;
; FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS ;
; IN THE SOFTWARE.                                                             ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


use16

org 0x7C00


mov     eax,cr0
and     ax,0xFFF3
or      ax,0x0022
mov     cr0,eax

mov     eax,cr4
or      ax,0x0600
mov     cr4,eax


mov     ax,0x13
int     0x10


cld

jmp     far 0x0000:_start
; 32 bytes have passed, so this is the perfect place for SSE data


;Vertices
vertices:
dd  0.0, 1.0, -1.0, -1.0


; Translation by ( 0 | 0 | -5 )
; FOV: 30°; Aspect: 320/200; zNear: 1; zFar: 100
; Source matrix of the "compressed" data is:
; ( 2.33253     0       0       0   )
; (    0    3.73205     0       0   )
; (    0        0   -1.0202     0   )
; (    0        0      5.0  3.08081 )
; Normally, the last field in the third row would be -1.0 rather than 0. This
; introduces a constant offset for the depth coordinate, so it will be in the
; range of [-1.0, 1.0]. This, however, is not desirable in this case, since it
; has to be mapped back to [0. 1.0], if perspective correction should be used.
; In fact, any range [0, x] with any non-zero x is fine (even negative x);
; therefore, we just omit the -1.0 there in favor of a 0, eliminating the
; offset and getting a depth coordinate in [0, x] with some unknown x (but we
; don't have to care about it anyway, since the weights are normalized after
; factoring in the depth).
modelview_projection_matrix = 0x7bc0
mpm_data:
dd 2.33253, 3.73205, -1.0202, 5.0, 3.08081

; half of width and height, respectively
disp_transformation:
dd 160.0, 100.0


; Rotation matrix (3x3, 1° around ( 0.3 | 1 | 0.1 ))
mult:
dd  0.99986   ,  0.00170556, -0.0166361
dd -0.00162249,  0.999986  ,  0.00500591
dd  0.0166444 , -0.00497822,  0.999849

; must be aligned at 16 byte boundary
seven:
dd 7.0


_start:

xor     cx,cx
mov     ds,cx
mov     es,cx
mov     ss,cx
mov     sp,cx


; "decompress" the modelview-projection matrix
mov     di,modelview_projection_matrix
mov     bx,di
mov     si,mpm_data

mov     al,4
init_mpm:
movsd
mov     cl,8
; This will overwrite the beginning of this file, but who cares - the code's
; been executed already.
rep     stosw
dec     al
jnz     init_mpm

; copy the one non-diagonal value
sub     di,24
movsd


; Creates a nearly BRG 2:3:3 (MSb to LSb) 8 bit palette (not exactly, but close enough).
palette_loop:
mov     dx,0x3C8
out     dx,al
inc     dx
push    ax
mov     cl,3
palette_inner_loop:
out     dx,al
rol     al,3
loop    palette_inner_loop
pop     ax
inc     al
jnz     palette_loop



main_loop:

mov     bp,mult

mov     di,0x8000
push    di

; Multiplies the first, second and third row of the modelview projection
; matrix with the values given in mult and adds them together
; matrix: { a[4] b[4] c[4] d[4] } is multiplied by m[0] to m[8]:
; { a * m[0] + b * m[1] + c * m[2]   a * m[3] + b * m[4] + c * m[5]   a * m[6] + b * m[7] + c * m[8]   d }
mult_loop:
xorps   xmm0,xmm0
xor     si,si

mult_inner_loop:
movaps  xmm1,[bx+si]
; One byte shorter than movss, but achieves the same thing in the end (loading dword [bp] to xmm2)
movups  xmm2,[ds:bp]
add     bp,4
pshufd  xmm2,xmm2,0x00
mulps   xmm2,xmm1
addps   xmm0,xmm2

add     si,16
; First  time: 00010000 -> parity cleared
; Second time: 00100000 -> parity cleared
; Third  time: 00110000 -> parity set
jnp     mult_inner_loop

movaps  [di],xmm0
add     di,16
; Same here
jnp     mult_loop


push    cs
pop     es
pop     si
push    si
mov     di,bx
mov     cx,24
rep     movsw



mov     si,0x60
mat_norm_loop:
movups  xmm0,[bx+si]
shufps  xmm0,[bx+0x60],0x44

mov     di,48           ; i = 3
xorps   xmm3,xmm3
matrix_dot_vector_loop:
pshufd  xmm4,xmm0,0xFF  ; vector[i]
pslldq  xmm0,4          ; shift that out
mulps   xmm4,[bx+di]  ; matrix[i]
addps   xmm3,xmm4
sub     di,16           ; i--
jnc     matrix_dot_vector_loop


pshufd  xmm0,xmm3,0xFF  ; W
divps   xmm3,xmm0

movaps  xmm0,xmm1
movaps  xmm1,xmm2
movaps  xmm2,xmm3
add     si,4
; First round: 0x0064 (odd); second: 0x0068 (odd); third (final): 0x006c (even)
jnp     mat_norm_loop

; Store all XMM registers in memory, especially xmm0, xmm1 and xmm2 (the three vertices)
pop     si
fxsave  [si]

xor     di,di
xor     eax,eax
; Sets the high word of EDX to zero
cdq
mov     dx,200


movaps  xmm5,xmm0
movaps  xmm6,xmm1

subps   xmm6,xmm5
subps   xmm2,xmm5

; xmm5: bv
; xmm6: vec1
; xmm2: vec2

; swap lower singles
pshufd  xmm7,xmm2,0xE1

; xmm7: ~vec2 (xy swapped)
movaps  xmm1,xmm7
mulps   xmm1,xmm6

; xmm1: vec1.x * vec2.y | vec1.y * vec2.x
hsubps  xmm1,xmm1

; xmm1: vec1.x * vec2.y - vec1.y * vec2.x = st_div | ...
pshufd  xmm4,xmm1,0x00

; xmm6:  vec1
; xmm7: ~vec2


rasterize:
cvtsi2ss xmm0,eax
cvtsi2ss xmm1,edx
punpckldq xmm0,xmm1

push    ax

movups  xmm1,[disp_transformation]
subps   xmm0,xmm1
divps   xmm0,xmm1

subps   xmm0,xmm5
pshufd  xmm1,xmm0,0xE1

; xmm0: x, y in [-1, 1]
; xmm1: y, x in [-1, 1]

mulps   xmm0,xmm7
mulps   xmm1,xmm6

; xmm0: xy * ~vec2
; xmm1: yx *  vec1
; xmm4: st_div
; xmm5: bv
; xmm6:  vec1
; xmm7: ~vec2

hsubps  xmm0,xmm1

;xmm0: x * vec2.y - y * vec2.x | ... | y * vec1.x - x * vec1.y | ...

divps   xmm0,xmm4

pshufd  xmm1,xmm0,0xAA

; xmm0: (x * vec2.y - y * vec2.x) / st_div = s
; xmm1: (y * vec1.x - x * vec1.y) / st_div = t

; movss/addss would take two bytes more, the result is the same – s + t in
; the lowest single.
movaps  xmm3,xmm0
addps   xmm3,xmm1
; xmm3: s + t

xor     al,al

; That would be zero.
xorps   xmm2,xmm2
comiss  xmm0,xmm2
jb      cull
comiss  xmm1,xmm2
jb      cull
; W coordinate of all vertices (should be 1...)
movups  xmm2,[bx+0x64]
comiss  xmm3,xmm2
ja      cull


; 1 - (s + t) is weight of first vertex
; s is that of second, t that of third
subps   xmm2,xmm3

; Now, xmm0, xmm1 and xmm2 contain the weight of the second, third and first
; vertex color, respectively. Multiply them by their respective vertex's depth
; for perspective correction (the memory address refers to the fxsave location).
; Those addresses aren't aligned, therefore we can't use mulps.
mulss   xmm0,[si+0xb8]
mulss   xmm1,[si+0xc8]
mulss   xmm2,[si+0xa8]

; summarize all weights for normalization
movaps  xmm3,xmm0
addps   xmm3,xmm1
addps   xmm3,xmm2

; multiply each weight by 7 (divide the normalization divisor by 7)
divps   xmm3,[bx+seven-modelview_projection_matrix]
divps   xmm2,xmm3
cvtss2si eax,xmm2
; first vertex is blue, must be shifted right by 1, because the blue share of
; the 8 bit color is only two bits in size (instead of three)
shr     al,1
xor     bp,bp
; second vertex is red, third is blue
cvt_loop:
divps   xmm0,xmm3
cvtss2si ecx,xmm0
movaps  xmm0,xmm1
shl     al,3
or      al,cl
dec     bp
jp      cvt_loop

cull:

; output color
push    word 0xA000
pop     es
stosb

pop     ax

inc     ax
cmp     ax,320
jb      go_on
xor     ax,ax
dec     dx
jz      main_loop
go_on:

jmp     rasterize



times 510-($-$$) db 0

dw 0xAA55
