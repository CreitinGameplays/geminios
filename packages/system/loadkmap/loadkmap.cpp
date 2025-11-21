#include <iostream>
#include <fstream>
#include <vector>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/kd.h>

// Binary Keymap Loader for GeminiOS
// Reads 'bkeymap' format (compatible with BusyBox loadkmap)

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: loadkmap <path_to_bmap_file>\n";
        return 1;
    }

    std::ifstream f(argv[1], std::ios::binary);
    if (!f) {
        perror("loadkmap: open");
        return 1;
    }

    // Check Magic Header "bkeymap"
    char header[7];
    f.read(header, 7);
    if (std::string(header, 7) != "bkeymap") {
        std::cerr << "loadkmap: not a valid binary keymap file.\n";
        return 1;
    }

    // Try to find a valid console FD
    int fd = open("/dev/tty0", O_RDWR);
    if (fd < 0) fd = open("/dev/tty", O_RDWR);
    if (fd < 0) fd = STDIN_FILENO;

    // The format is simple: 
    // Loop 0 to MAX_NR_KEYMAPS (256)
    //   Read 1 byte flag (1 = exists, 0 = empty)
    //   If exists, read NR_KEYS (128) * sizeof(ushort) (2 bytes) = 256 bytes
    
    // Note: Linux NR_KEYS is 128.
    const int MAX_NR_KEYMAPS = 256;
    const int NR_KEYS = 128;

    for (int i = 0; i < MAX_NR_KEYMAPS; ++i) {
        char exists;
        if (!f.read(&exists, 1)) break;

        if (exists) {
            unsigned short entries[NR_KEYS];
            f.read((char*)entries, NR_KEYS * sizeof(unsigned short));
            
            for (int j = 0; j < NR_KEYS; ++j) {
                struct kbentry ke;
                ke.kb_table = i;
                ke.kb_index = j;
                ke.kb_value = entries[j];
                
                if (ioctl(fd, KDSKBENT, &ke) < 0) {
                    // perform silent fail on individual keys if needed, 
                    // but generally should work.
                }
            }
        }
    }

    return 0;
}
