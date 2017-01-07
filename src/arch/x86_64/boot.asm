;;; Based on http://blog.phil-opp.com/rust-os/multiboot-kernel.html
;;; and http://blog.phil-opp.com/rust-os/entering-longmode.html
;;;
;;; The actual boot code of our kernel.

global start
global gdt64_code_offset
global HEAP_BOTTOM
global HEAP_TOP

extern long_mode_start

;;; Our main entry point.  Invoked by out boot loader.
section .text
bits 32
start:
        mov esp, stack_top               ; Use our temporary stack.

        ;; Sanity-check our system.
        call test_multiboot
        call test_cpuid
        call test_long_mode

        ;; Turn on paging.
        call setup_page_tables
        call enable_paging

        ;; Install our GDT.
        lgdt [gdt64.pointer]

        ;; Set up our data segment registers.
        mov ax, gdt64.data
        mov ss, ax
        mov ds, ax
        mov es, ax

        ;; To set up our code segment, we need to make a jump, and
        ;; when the jump finishes, we'll be in 64-bit mode.
        jmp gdt64.code:long_mode_start

;;; Boot-time error handler.  Prints `ERR: ` and a code.
;;;
;;; al: Error code.
error:
        mov dword [0xb8000], 0x4f524f45
        mov dword [0xb8004], 0x4f3a4f52
        mov dword [0xb8008], 0x4f204f20
        mov byte  [0xb800a], al
        hlt

;;; Make sure we were loaded by multiboot.
test_multiboot:
        cmp eax, 0x2BADB002     ; Did multiboot put a magic value in eax?
        jne .no_multiboot
        ret
.no_multiboot:
        mov al, "M"
        jmp error

;;; Test for CPUID.  Copied from
;;; http://blog.phil-opp.com/rust-os/entering-longmode.html
;;; which copied from
;;; http://wiki.osdev.org/Setting_Up_Long_Mode#Detection_of_CPUID
test_cpuid:
        pushfd                  ; Store the FLAGS-register.
        pop eax                 ; Restore the A-register.
        mov ecx, eax            ; Set the C-register to the A-register.
        xor eax, 1 << 21        ; Flip the ID-bit, which is bit 21.
        push eax                ; Store the A-register.
        popfd                   ; Restore the FLAGS-register.
        pushfd                  ; Store the FLAGS-register.
        pop eax                 ; Restore the A-register.
        push ecx                ; Store the C-register.
        popfd                   ; Restore the FLAGS-register.
        xor eax, ecx            ; Do a XOR-operation on the A and C.
        jz .no_cpuid            ; The zero flag is set, no CPUID.
        ret                     ; CPUID is available for use.
.no_cpuid:
        mov al, "I"
        jmp error

;;; Test for presence of 64-bit support.  Copied from the same sources as
;;; test_cpuid.
test_long_mode:
        mov eax, 0x80000000     ; Set the A-register to 0x80000000.
        cpuid                   ; CPU identification.
        cmp eax, 0x80000001     ; Compare the A-register with 0x80000001.
        jb .no_long_mode        ; It is less, there is no long mode.
        mov eax, 0x80000001     ; Set the A-register to 0x80000001.
        cpuid                   ; CPU identification.
        ;; Test if the LM-bit, which is bit 29, is set in the D-register.
        test edx, 1 << 29
        jz .no_long_mode        ; They aren't, there is no long mode.
        ret
.no_long_mode:
        mov al, "L"
        jmp error

;;; Configure p4_table and p3_table to map a single, huge 1GB page that
;;; has the same virtual and physical addresses, located at 0x0.
setup_page_tables:
        ;; Point first entry in P4 at P3, setting appropriate flag
        ;; bits in the unused portions of the pointer.
        mov eax, p3_table
        or eax, 0b11                      ; Present & writable.
        mov [p4_table], eax

        ;; Map first entry in P3 to 0, with flag bits set.
        mov dword [p3_table], 0b10000011  ; Present & writable & huge.
        ret

;;; Turn on paging.
enable_paging:
        ;; Load P4 into cr3.
        mov eax, p4_table
        mov cr3, eax

        ;; Enable Physical Address Extension in cr4.
        mov eax, cr4
        or eax, 0x20
        mov cr4, eax

        ;; Set the long mode bit in the EFER MSR.
        mov ecx, 0xC0000080
        rdmsr
        or eax, 0x100
        wrmsr

        ;; Turn on paging in cr0.
        mov eax, cr0
        or eax, 0x80010000
        mov cr0, eax
        ret

section .bss

;;; P4 page table for configuring virtual memory.  Must be aligned on a
;;; 4096-byte boundary.
align 4096
p4_table:
        resb 4096

;;; P3 page table for configuring virtual memory.  Must be aligned on a
;;; 4096-byte boundary.
p3_table:
        resb 4096

;;; Our kernel stack.  We want to make this large enough so that we don't
;;; need to worry about overflowing it until we figure out how to set up
;;; a guard page and print errors on page faults.
stack_bottom:
        resb 8192
stack_top:

align 4096
HEAP_BOTTOM:
        resb 4*1024*1024
HEAP_TOP:

;;; Global Description Table.  Used to set segmentation to the restricted
;;; values needed for 64-bit mode.
section .rodata
gdt64:
    dq 0                                                ; Mandatory 0.
.code: equ $ - gdt64
    dq (1<<44) | (1<<47) | (1<<41) | (1<<43) | (1<<53)  ; Code segment.
.data: equ $ - gdt64
    dq (1<<44) | (1<<47) | (1<<41)                      ; Data segment.
.pointer:
    dw $ - gdt64 - 1
    dq gdt64

;;; Export selectors so Rust can access them.
gdt64_code_offset:
    dw gdt64.code
