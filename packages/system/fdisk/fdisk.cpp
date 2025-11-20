#include <iostream>
#include <iomanip>
#include <unistd.h>
#include <fcntl.h>
#include <cstdint>
#include <string>
#include <vector>
#include "../../../src/sys_info.h"

struct PartitionEntry {
    uint8_t status;
    uint8_t chs_start[3];
    uint8_t type;
    uint8_t chs_end[3];
    uint32_t lba_start;
    uint32_t sector_count;
};

const char* get_type(uint8_t t) {
    switch(t) {
        case 0x00: return "Empty";
        case 0x0B: case 0x0C: return "FAT32";
        case 0x82: return "Swap";
        case 0x83: return "Linux";
        case 0x05: case 0x0F: return "Extended";
        case 0x07: return "NTFS/exFAT";
        case 0xEE: return "GPT";
        default: return "Unknown";
    }
}

void list_parts(const std::string& dev) {
    int fd = open(dev.c_str(), O_RDONLY);
    if (fd < 0) { perror(("fdisk: " + dev).c_str()); return; }

    uint8_t mbr[512];
    if (read(fd, mbr, 512) != 512) { std::cerr << "Read error\n"; close(fd); return; }
    close(fd);

    if (mbr[510] != 0x55 || mbr[511] != 0xAA) {
        std::cerr << dev << ": Invalid MBR signature.\n"; return;
    }

    std::cout << "Device     Boot      Start        End    Sectors   Size Id Type\n";
    PartitionEntry* p = (PartitionEntry*)(mbr + 446);
    for (int i=0; i<4; ++i) {
        if (p[i].type == 0) continue;
        uint64_t size = (uint64_t)p[i].sector_count * 512;
        std::string dev_name = dev;
        if (isdigit(dev_name.back())) dev_name += "p" + std::to_string(i+1);
        else dev_name += std::to_string(i+1);

        std::cout << std::left << std::setw(10) << dev_name
                  << std::setw(5) << ((p[i].status == 0x80) ? "*" : " ")
                  << std::setw(10) << p[i].lba_start
                  << std::setw(10) << (p[i].lba_start + p[i].sector_count - 1)
                  << std::setw(10) << p[i].sector_count
                  << std::setw(7) << (size/1024/1024) << "M "
                  << std::setw(3) << std::hex << (int)p[i].type << std::dec
                  << get_type(p[i].type) << "\n";
    }
}

int main(int argc, char* argv[]) {
    if (argc > 2 && std::string(argv[1]) == "-l") list_parts(argv[2]);
    else if (argc == 2 && std::string(argv[1]) == "-l") list_parts("/dev/sda");
    else std::cout << "Usage: fdisk -l [device]\n";
    return 0;
}
