# TESTS
To verify that everything is working as intended (specifically the input and utilities), follow these steps:

Test the virtio GPU/mesa:
```
qemu-system-x86_64 -m 2G -cdrom GeminiOS.iso -device virtio-vga-gl -display sdl,gl=on -cpu host -enable-kvm -serial stdio -hda disk.qcow2 -boot d
```

Check if `xinit` runs without errors:
```
xinit
```