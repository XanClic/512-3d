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
; Genau hier sind 32 Bytes vorüber, der perfekte Platz für SSE-Daten.


;Vertices
vertex1:
dd  0.0,  1.0, 0.0, 1.0

vertex2:
dd -1.0, -0.8, 0.0, 1.0

vertex3:
dd  1.0, -0.8, 0.0, 1.0

output_vertex1 = 0x8000
output_vertex2 = 0x8010
output_vertex3 = 0x8020
st_div         = 0x8030


; Translation by ( 0 | 0 | -5 )
; FOV: 30°; Aspect: 320/200; zNear: 1; zFar: 100
modelview_projection_matrix:
dd 2.33253, 0.0    ,  0.0    ,  0.0
dd 0.0    , 3.73205,  0.0    ,  0.0
dd 0.0    , 0.0    , -1.0202 , -1.0
dd 0.0    , 0.0    ,  3.08081,  5.0

single_zero = $ - 16

disp_transformation:
dd 160.0, 100.0, 1.0, 1.0

single_one = $ - 4


; Rotation matrix (3x3, 1° around ( 0.3 | 1 | 0.1 ))
mult:
dd  0.99986   ,  0.00170556, -0.0166361
dd -0.00162249,  0.999986  ,  0.00500591
dd  0.0166444 , -0.00497822,  0.999849


_start:

xor     ax,ax
mov     ds,ax
mov     es,ax
mov     ss,ax
mov     sp,ax


push    word 0xA000
pop     fs



main_loop:

mov     bx,modelview_projection_matrix
mov     bp,mult

mov     di,0x9000
push    di

; Multiplies the first, second and third row of the modelview projection
; matrix with the values given in mult and adds them together
; matrix: { a[4] b[4] c[4] d[4] } is multiplied by m[0] to m[8]:
; { a * m[0] + b * m[1] + c * m[2]   a * m[3] + b * m[4] + c * m[5]   a * m[6] + b * m[7] + c * m[8]   d }
mult_loop:
xorps   xmm0,xmm0
xor     si,si

mult_inner_loop:
movaps  xmm1,[bx + si]
movss   xmm2,[bp]
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

pop     si
mov     di,bx
mov     cx,24
rep     movsw



movaps  xmm0,[bx - 48]
movaps  xmm1,[bx - 32]
movaps  xmm2,[bx - 16]


call    matrix_dot_vector
call    matrix_dot_vector
call    matrix_dot_vector

call    norm_vector
call    norm_vector
call    norm_vector


xor     di,di
xor     eax,eax
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
pshufd  xmm1,xmm1,0x00
movaps  [st_div],xmm1

; xmm6:  vec1
; xmm7: ~vec2


rasterize:
cvtsi2ss xmm0,eax
cvtsi2ss xmm1,edx
punpckldq xmm0,xmm1

movaps  xmm1,[disp_transformation]
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
; xmm5: bv
; xmm6: vec1
; xmm7: vec2

hsubps  xmm0,xmm1

;xmm0: x * vec2.y - y * vec2.x | ... | y * vec1.x - x * vec1.y | ...

divps   xmm0,[st_div]

pshufd  xmm1,xmm0,0xAA

; xmm0: (x * vec2.y - y * vec2.x) / st_div = s
; xmm1: (y * vec1.x - x * vec1.y) / st_div = t

movss   xmm2,xmm0
addss   xmm2,xmm1
; xmm2: s + t

mov     byte [fs:di],0

movss   xmm3,[single_zero]
comiss  xmm0,xmm3
jb      cull
comiss  xmm1,xmm3
jb      cull
comiss  xmm2,[single_one]
ja      cull

mov     byte [fs:di],15

cull:

inc     ax
cmp     ax,320
jb      go_on
xor     ax,ax
dec     dx
jz      main_loop
go_on:

inc     di

jmp     rasterize



shuf_vectors:
movaps  xmm0,xmm1
movaps  xmm1,xmm2
movaps  xmm2,xmm3
ret


matrix_dot_vector:
mov     di,48           ; i = 3
xorps   xmm3,xmm3
matrix_dot_vector_loop:
pshufd  xmm4,xmm0,0xFF  ; vector[i]
pslldq  xmm0,4          ; shift that out
mulps   xmm4,[bx + di]  ; matrix[i]
addps   xmm3,xmm4
sub     di,16           ; i--
jnc     matrix_dot_vector_loop

jmp     shuf_vectors


norm_vector:
pshufd  xmm3,xmm0,0xFF  ; W
divps   xmm0,xmm3
movaps  xmm3,xmm0

jmp     shuf_vectors


times 510-($-$$) db 0

dw 0xAA55
