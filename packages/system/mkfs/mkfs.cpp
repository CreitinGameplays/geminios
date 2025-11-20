#include <iostream>
#include <vector>
#include <cstdint>
#include <cerrno>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/fs.h>
#include <ctime>
#include <cstdlib>
#include <cmath>
#include <iomanip>
#include <algorithm>
#include "../../../src/sys_info.h"

// --- Ext2 Constants & Structures ---
#define EXT2_SUPER_MAGIC  0xEF53
#define EXT2_ROOT_INO     2
#define EXT2_S_IFDIR      0x4000

struct ext2_superblock {
    uint32_t s_inodes_count;
    uint32_t s_blocks_count;
    uint32_t s_r_blocks_count;
    uint32_t s_free_blocks_count;
    uint32_t s_free_inodes_count;
    uint32_t s_first_data_block;
    uint32_t s_log_block_size;
    uint32_t s_log_frag_size;
    uint32_t s_blocks_per_group;
    uint32_t s_frags_per_group;
    uint32_t s_inodes_per_group;
    uint32_t s_mtime;
    uint32_t s_wtime;
    uint16_t s_mnt_count;
    uint16_t s_max_mnt_count;
    uint16_t s_magic;
    uint16_t s_state;
    uint16_t s_errors;
    uint16_t s_minor_rev_level;
    uint32_t s_lastcheck;
    uint32_t s_checkinterval;
    uint32_t s_creator_os;
    uint32_t s_rev_level;
    uint16_t s_def_resuid;
    uint16_t s_def_resgid;
    uint32_t s_first_ino;
    uint16_t s_inode_size;
    uint16_t s_block_group_nr;
    uint32_t s_feature_compat;
    uint32_t s_feature_incompat;
    uint32_t s_feature_ro_compat;
    uint8_t  s_uuid[16];
    char     s_volume_name[16];
    char     s_last_mounted[64];
    uint32_t s_algo_bitmap;
    uint8_t  s_prealloc_blocks;
    uint8_t  s_prealloc_dir_blocks;
    uint16_t s_padding1;
    uint8_t  s_journal_uuid[16];
    uint32_t s_journal_inum;
    uint32_t s_journal_dev;
    uint32_t s_last_orphan;
    uint32_t s_hash_seed[4];
    uint8_t  s_def_hash_version;
    uint8_t  s_reserved_char_pad;
    uint16_t s_reserved_word_pad;
    uint32_t s_default_mount_opts;
    uint32_t s_first_meta_bg;
    uint8_t  s_reserved[760];
} __attribute__((packed));

struct ext2_group_desc {
    uint32_t bg_block_bitmap;
    uint32_t bg_inode_bitmap;
    uint32_t bg_inode_table;
    uint16_t bg_free_blocks_count;
    uint16_t bg_free_inodes_count;
    uint16_t bg_used_dirs_count;
    uint16_t bg_pad;
    uint32_t bg_reserved[3];
} __attribute__((packed));

struct ext2_inode {
    uint16_t i_mode;
    uint16_t i_uid;
    uint32_t i_size;
    uint32_t i_atime;
    uint32_t i_ctime;
    uint32_t i_mtime;
    uint32_t i_dtime;
    uint16_t i_gid;
    uint16_t i_links_count;
    uint32_t i_blocks;
    uint32_t i_flags;
    uint32_t i_osd1;
    uint32_t i_block[15];
    uint32_t i_generation;
    uint32_t i_file_acl;
    uint32_t i_dir_acl;
    uint32_t i_faddr;
    uint8_t  i_osd2[12];
} __attribute__((packed));

struct ext2_dir_entry_2 {
    uint32_t inode;
    uint16_t rec_len;
    uint8_t  name_len;
    uint8_t  file_type;
    char     name[];
} __attribute__((packed));

// --- Globals & Config ---
bool g_verbose = false;
std::string g_device;
std::string g_label;

void log(const std::string& msg) {
    if (g_verbose) std::cout << "[mkfs] " << msg << std::endl;
}

void error_exit(const std::string& msg) {
    std::cerr << "[mkfs] Error: " << msg << std::endl;
    exit(1);
}

uint64_t get_device_size(int fd) {
    uint64_t size = 0;
    if (ioctl(fd, BLKGETSIZE64, &size) == 0) {
        return size;
    }
    // Fallback for files
    struct stat st;
    if (fstat(fd, &st) == 0) {
        return st.st_size;
    }
    return 0;
}

// Generate a random UUID
void generate_uuid(uint8_t* uuid) {
    for (int i = 0; i < 16; ++i) {
        uuid[i] = rand() % 255;
    }
    // Variant 1 (DCE 1.1)
    uuid[8] = (uuid[8] & 0x3F) | 0x80;
    // Version 4 (Random)
    uuid[6] = (uuid[6] & 0x0F) | 0x40;
}

int main(int argc, char* argv[]) {
    srand(time(NULL));

    // 1. Parse Arguments
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-v") g_verbose = true;
        else if (arg == "-L" && i + 1 < argc) {
            g_label = argv[++i];
        }
        else if (arg.length() > 0 && arg[0] == '-') {
            std::cout << "Unknown option: " << arg << std::endl;
        }
        else {
            g_device = arg;
        }
    }

    if (g_device.empty()) {
        std::cout << "Usage: mkfs [-v] [-L label] <device>\n";
        return 1;
    }

    if (g_label.length() > 16) {
        std::cout << "Warning: Label truncated to 16 characters.\n";
        g_label = g_label.substr(0, 16);
    }

    // 2. Open Device
    int fd = open(g_device.c_str(), O_RDWR);
    if (fd < 0) {
        // Print detailed error to stderr
        std::cerr << "[mkfs] Failed to open " << g_device << ": " << strerror(errno) << std::endl;
        error_exit("Could not open device: " + g_device);
    }

    uint64_t dev_size = get_device_size(fd);
    if (dev_size == 0) error_exit("Could not determine device size.");

    // 3. Calculate Geometry
    // We default to 4096 block size for larger disks, 1024 for very small ones (< 512MB)
    uint32_t block_size = (dev_size < 512 * 1024 * 1024) ? 1024 : 4096;
    uint32_t blocks_count = dev_size / block_size;
    
    // Enforce some limits
    if (blocks_count < 64) error_exit("Device too small for Ext2.");

    uint32_t blocks_per_group = 8 * block_size; // Bitmap limit (e.g. 8192 for 1K blocks, 32768 for 4K)
    uint32_t groups_count = (blocks_count + blocks_per_group - 1) / blocks_per_group;

    uint32_t inodes_per_group = blocks_per_group / 4; // 1 inode per 4 blocks (heuristic)
    // Align inodes per group to 8 (for bitmaps)
    if (inodes_per_group % 8 != 0) inodes_per_group += (8 - (inodes_per_group % 8));
    uint32_t inodes_count = inodes_per_group * groups_count;

    if (g_verbose) {
        std::cout << "Geometry:\n";
        std::cout << "  Size:   " << dev_size << " bytes\n";
        std::cout << "  Block:  " << block_size << " bytes\n";
        std::cout << "  Blocks: " << blocks_count << "\n";
        std::cout << "  Groups: " << groups_count << "\n";
        std::cout << "  Inodes: " << inodes_count << "\n";
        std::cout << "  Label:  " << (g_label.empty() ? "<none>" : g_label) << "\n";
    }

    // 4. Prepare In-Memory Structures

    // Superblock
    ext2_superblock sb;
    memset(&sb, 0, sizeof(sb));
    sb.s_inodes_count = inodes_count;
    sb.s_blocks_count = blocks_count;
    sb.s_r_blocks_count = blocks_count / 20; // 5% reserved
    sb.s_free_blocks_count = blocks_count; // Will decrement as we allocate
    sb.s_free_inodes_count = inodes_count;
    sb.s_first_data_block = (block_size == 1024) ? 1 : 0; // 1 for 1k blocks (boot block 0)
    sb.s_log_block_size = (uint32_t)(log2(block_size) - 10); // 0=1024, 1=2048, 2=4096
    sb.s_log_frag_size = sb.s_log_block_size;
    sb.s_blocks_per_group = blocks_per_group;
    sb.s_frags_per_group = blocks_per_group;
    sb.s_inodes_per_group = inodes_per_group;
    sb.s_mtime = 0;
    sb.s_wtime = time(NULL);
    sb.s_mnt_count = 0;
    sb.s_max_mnt_count = -1;
    sb.s_magic = EXT2_SUPER_MAGIC;
    sb.s_state = 1; // Clean
    sb.s_errors = 1; // Continue
    sb.s_minor_rev_level = 0;
    sb.s_lastcheck = time(NULL);
    sb.s_checkinterval = 0;
    sb.s_creator_os = 0; // Linux
    sb.s_rev_level = 1; // Dynamic
    sb.s_def_resuid = 0;
    sb.s_def_resgid = 0;
    sb.s_first_ino = 11; // First non-reserved
    sb.s_inode_size = 128; // Standard
    if (!g_label.empty()) strncpy(sb.s_volume_name, g_label.c_str(), 16);
    generate_uuid(sb.s_uuid);

    // 5. Allocate Groups
    // We need to compute the positions of metadata for EACH group.
    // For simplicity, we won't use "sparse_super", so SB and GDT are in every group.
    // It's less efficient for space, but much simpler and more robust.

    std::vector<ext2_group_desc> gdt(groups_count);
    
    // Metadata overhead per group
    uint32_t blocks_for_gdt = (groups_count * sizeof(ext2_group_desc) + block_size - 1) / block_size;
    uint32_t blocks_for_inode_table = (inodes_per_group * sizeof(ext2_inode) + block_size - 1) / block_size;

    for (uint32_t i = 0; i < groups_count; ++i) {
        uint32_t group_start_block = sb.s_first_data_block + i * blocks_per_group;
        
        // Layout in Group:
        // 1. Superblock (1 block)
        // 2. GDT (N blocks)
        // 3. Block Bitmap (1 block)
        // 4. Inode Bitmap (1 block)
        // 5. Inode Table (N blocks)
        // 6. Data...
        
        uint32_t cursor = group_start_block;
        
        // SB Backup
        cursor++; 
        
        // GDT
        cursor += blocks_for_gdt;

        gdt[i].bg_block_bitmap = cursor++;
        gdt[i].bg_inode_bitmap = cursor++;
        gdt[i].bg_inode_table = cursor;
        cursor += blocks_for_inode_table;

        // Calculate Free Blocks
        // Total in group - metadata blocks
        uint32_t metadata_blocks = 1 + blocks_for_gdt + 1 + 1 + blocks_for_inode_table; // SB + GDT + BB + IB + IT
        
        uint32_t blocks_in_this_group = blocks_per_group;
        if (i == groups_count - 1) {
            // Last group might be smaller
            blocks_in_this_group = blocks_count - group_start_block;
        }

        if (blocks_in_this_group > metadata_blocks) {
            gdt[i].bg_free_blocks_count = blocks_in_this_group - metadata_blocks;
        } else {
             gdt[i].bg_free_blocks_count = 0; // Should not happen on healthy sizes
        }

        gdt[i].bg_free_inodes_count = inodes_per_group;
        gdt[i].bg_used_dirs_count = 0;
    }

    // 6. Setup Root Directory
    // Root is in Group 0.
    // We need to allocate 1 block for Root Dir data.
    // Update Group 0 descriptor
    if (gdt[0].bg_free_blocks_count > 0) {
        gdt[0].bg_free_blocks_count--;
    }
    if (gdt[0].bg_free_inodes_count > 0) {
        gdt[0].bg_free_inodes_count--; // For Inode 2 (Root)
        // Note: Inodes 1-10 are reserved. We must mark them used in bitmap but they don't count as "allocated" from the free pool usually?
        // Actually, free_inodes_count usually excludes reserved ones if they are pre-marked.
        // Let's just decrement for the Root inode specifically for now.
        // Standard mkfs counts reserved inodes as used.
        gdt[0].bg_free_inodes_count -= 10; // Reserve 1-10
    }
    gdt[0].bg_used_dirs_count = 1;

    // Update Superblock totals
    sb.s_free_blocks_count -= (groups_count * (1 + blocks_for_gdt + 1 + 1 + blocks_for_inode_table) + 1); // All metadata + 1 root block
    sb.s_free_inodes_count -= 11; // 10 reserved + root

    // 7. Write Groups
    char* zero_block = (char*)calloc(1, block_size);

    for (uint32_t i = 0; i < groups_count; ++i) {
        if (g_verbose) std::cout << "Writing Group " << i << "..." << std::flush;
        
        uint32_t group_start_block = sb.s_first_data_block + i * blocks_per_group;
        off_t group_offset = (off_t)group_start_block * block_size;

        // A. Write Superblock
        lseek(fd, group_offset, SEEK_SET);
        // SB is always 1024 bytes. If block size > 1024, it sits at offset 0 of block (except block 0 where it is at 1024)
        // But strictly: "The superblock is always located at byte offset 1024 from the beginning of the volume"
        // For Group 0: Offset 1024.
        // For Group > 0: It is the first block of the group.
        
        if (i == 0) {
             // Special case: Boot block is first 1024 bytes. SB is next 1024.
             lseek(fd, 1024, SEEK_SET);
             write(fd, &sb, sizeof(sb));
             // Pad rest of block if block_size > 1024 (e.g. 4096)
             if (block_size > 1024) {
                 int padding = block_size - 1024 - 1024; // First 1024 boot, Second 1024 SB.
                 if (padding < 0) padding = block_size - 1024; // Logic check
                 // If block size is 4096, block 0 contains Boot(1k) + SB(1k) + Padding(2k).
                 // Current seek is at 1024. Write 1024. Pos is 2048. Write 2048 zeros.
             }
        } else {
             write(fd, &sb, sizeof(sb));
             // Pad remainder of block
             if (block_size > sizeof(sb)) {
                 int pad = block_size - sizeof(sb);
                 char* p = (char*)calloc(1, pad);
                 write(fd, p, pad);
                 free(p);
             }
        }

        // B. Write GDT
        // GDT immediately follows SB block
        off_t gdt_offset = (off_t)(group_start_block + 1) * block_size;
        lseek(fd, gdt_offset, SEEK_SET);
        write(fd, gdt.data(), groups_count * sizeof(ext2_group_desc));
        
        // Clear remaining GDT blocks
        // (Already implicitly cleared by seeking past? No, we should zero them to be clean)
        // We won't iterate all zero blocks for speed, just critical metadata.

        // C. Block Bitmap
        // Mark metadata blocks as used.
        uint32_t metadata_blocks = 1 + blocks_for_gdt + 1 + 1 + blocks_for_inode_table;
        if (i == 0) metadata_blocks++; // Root data block
        
        // Construct Bitmap
        uint8_t* block_bitmap = (uint8_t*)calloc(1, block_size);
        for (uint32_t b = 0; b < metadata_blocks; ++b) {
            block_bitmap[b / 8] |= (1 << (b % 8));
        }
        // Padding at end of group (if blocks count not aligned)
        // Ext2 requires padding bits to be 1
        uint32_t blocks_in_group = (i == groups_count - 1) ? (blocks_count - group_start_block) : blocks_per_group;
        for (uint32_t b = blocks_in_group; b < blocks_per_group; ++b) {
            block_bitmap[b / 8] |= (1 << (b % 8));
        }

        off_t bb_offset = (off_t)gdt[i].bg_block_bitmap * block_size;
        lseek(fd, bb_offset, SEEK_SET);
        write(fd, block_bitmap, block_size);
        free(block_bitmap);

        // D. Inode Bitmap
        uint8_t* inode_bitmap = (uint8_t*)calloc(1, block_size);
        if (i == 0) {
            // Reserve 1-10 and 11 (if needed, but 11 is usually Lost+Found, we skip that for now)
            // Mark Root (2) as used.
            // Mark 1-10 as used.
            for (int n = 1; n <= 10; ++n) {
                inode_bitmap[(n-1) / 8] |= (1 << ((n-1) % 8));
            }
        }
        
        // Padding for unexistent inodes
        for (uint32_t n = inodes_per_group; n < (block_size * 8); ++n) {
            inode_bitmap[n / 8] |= (1 << (n % 8));
        }

        off_t ib_offset = (off_t)gdt[i].bg_inode_bitmap * block_size;
        lseek(fd, ib_offset, SEEK_SET);
        write(fd, inode_bitmap, block_size);
        free(inode_bitmap);

        // E. Inode Table
        // We need to clear it (zero out)
        off_t it_offset = (off_t)gdt[i].bg_inode_table * block_size;
        lseek(fd, it_offset, SEEK_SET);
        
        if (i == 0) {
            // Initialize Root Inode
            ext2_inode table[inodes_per_group];
            memset(table, 0, sizeof(table));
            
            // Inode 2: Root
            // Index 1 in table
            ext2_inode& root = table[1];
            root.i_mode = EXT2_S_IFDIR | 0755;
            root.i_uid = 0;
            root.i_gid = 0;
            root.i_size = block_size; // 1 block
            root.i_atime = root.i_ctime = root.i_mtime = time(NULL);
            root.i_links_count = 2; // . and ..
            root.i_blocks = 2; // 512-byte sectors? Ext2 i_blocks is in 512-byte sectors usually. 1 block (1024) = 2 sectors.
            if (block_size == 4096) root.i_blocks = 8;
            
            // Point to data block
            // The data block for root is the one AFTER the inode table in group 0
            uint32_t root_data_block = gdt[0].bg_inode_table + blocks_for_inode_table;
            root.i_block[0] = root_data_block;

            write(fd, table, inodes_per_group * sizeof(ext2_inode));
        } else {
            // Just zero out
            // Writing large chunks of zeros can be slow, but for <20GB it's acceptable.
            // Optimize: allocate buffer once
            char* huge_zero = (char*)calloc(inodes_per_group, sizeof(ext2_inode));
            write(fd, huge_zero, inodes_per_group * sizeof(ext2_inode));
            free(huge_zero);
        }
        
        if (g_verbose) std::cout << " Done.\n";
    }

    // 8. Write Root Directory Content
    uint32_t root_data_block_idx = gdt[0].bg_inode_table + blocks_for_inode_table;
    off_t root_dir_offset = (off_t)root_data_block_idx * block_size;
    
    char* dir_block = (char*)calloc(1, block_size);
    
    // Entry 1: "."
    ext2_dir_entry_2* entry = (ext2_dir_entry_2*)dir_block;
    entry->inode = EXT2_ROOT_INO;
    entry->name_len = 1;
    entry->file_type = 2; // Directory
    entry->name[0] = '.';
    entry->rec_len = 12; // Align 4

    // Entry 2: ".."
    entry = (ext2_dir_entry_2*)(dir_block + 12);
    entry->inode = EXT2_ROOT_INO;
    entry->name_len = 2;
    entry->file_type = 2; 
    entry->name[0] = '.'; entry->name[1] = '.';
    entry->rec_len = block_size - 12; // Fill rest of block

    lseek(fd, root_dir_offset, SEEK_SET);
    write(fd, dir_block, block_size);
    free(dir_block);
    free(zero_block);

    close(fd);
    
    if (g_verbose) std::cout << "[mkfs] Filesystem created successfully.\n";
    else std::cout << "Filesystem created.\n";
    
    return 0;
}
