#include <iostream>
#include <vector>
#include <string>
#include <cstring>
#include <cstdio>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <utime.h>
#include <zlib.h>
#include <dirent.h>
#include <iomanip>
#include <algorithm>
#include "../../../src/sys_info.h"

using namespace std;

// --- Globals & Config ---
bool g_decompress = false;
bool g_stdout = false;
bool g_force = false;
bool g_keep = false;
bool g_recursive = false;
bool g_verbose = false;
bool g_list = false;
bool g_test = false;
int g_level = Z_DEFAULT_COMPRESSION;
string g_suffix = ".gz";

// --- Helpers ---

bool file_exists(const string& path) {
    return access(path.c_str(), F_OK) == 0;
}

bool is_dir(const string& path) {
    struct stat s;
    if (stat(path.c_str(), &s) == 0) return S_ISDIR(s.st_mode);
    return false;
}

off_t get_size(const string& path) {
    struct stat s;
    if (stat(path.c_str(), &s) == 0) return s.st_size;
    return 0;
}

unsigned long get_uncompressed_size(const string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return 0;
    if (fseek(f, -4, SEEK_END) != 0) { fclose(f); return 0; }
    unsigned char buf[4];
    if (fread(buf, 1, 4, f) != 4) { fclose(f); return 0; }
    fclose(f);
    
    unsigned long size = buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24);
    return size;
}

// --- List ---
void list_file(const string& path) {
    off_t comp_size = get_size(path);
    unsigned long uncomp_size = get_uncompressed_size(path);
    
    double ratio = 0.0;
    if (uncomp_size > 0) {
        ratio = 100.0 * ((double)(uncomp_size - comp_size) / (double)uncomp_size);
    }
    if (ratio < 0) ratio = 0; 

    cout << setw(20) << comp_size 
         << setw(20) << uncomp_size 
         << setw(6) << fixed << setprecision(1) << ratio << "%"
         << " " << path << endl;
}

// --- Test ---
void test_file(const string& path) {
    gzFile in = gzopen(path.c_str(), "rb");
    if (!in) {
        perror(("gzip: " + path).c_str());
        return;
    }

    char buf[16384];
    while (true) {
        int len = gzread(in, buf, sizeof(buf));
        if (len < 0) {
            int err;
            const char* msg = gzerror(in, &err);
            cerr << "gzip: " << path << ": " << msg << endl;
            gzclose(in);
            return;
        }
        if (len == 0) break;
    }
    gzclose(in);
    if (g_verbose) cout << path << ": OK" << endl;
}

// --- Compression ---

void compress_file(const string& src) {
    if (src.size() > g_suffix.size() && src.substr(src.size() - g_suffix.size()) == g_suffix) {
        if (!g_force) {
            cerr << "gzip: " << src << " already has " << g_suffix << " suffix -- unchanged" << endl;
            return;
        }
    }

    struct stat st;
    if (stat(src.c_str(), &st) != 0) {
        perror(("gzip: " + src).c_str());
        return;
    }

    string dst = src + g_suffix;
    if (g_stdout) dst = "";

    if (!g_stdout && file_exists(dst) && !g_force) {
        cerr << "gzip: " << dst << " already exists; do you wish to overwrite (y/n)? ";
        char ans;
        cin >> ans;
        if (ans != 'y' && ans != 'Y') {
            cerr << "\tnot overwritten" << endl;
            return;
        }
    }

    FILE* in = fopen(src.c_str(), "rb");
    if (!in) {
        perror(("gzip: " + src).c_str());
        return;
    }

    gzFile out;
    char mode[10];
    snprintf(mode, sizeof(mode), "wb%d", g_level);

    if (g_stdout) {
        out = gzdopen(fileno(stdout), mode);
    } else {
        out = gzopen(dst.c_str(), mode);
    }

    if (!out) {
        cerr << "gzip: failed to open output" << endl;
        fclose(in);
        return;
    }

    char buf[16384];
    while (true) {
        size_t len = fread(buf, 1, sizeof(buf), in);
        if (len > 0) {
            int written = gzwrite(out, buf, (unsigned)len);
            if (written == 0) {
                cerr << "gzip: write error" << endl;
                gzclose(out);
                fclose(in);
                if (!g_stdout) remove(dst.c_str());
                return;
            }
        }
        if (len < sizeof(buf)) {
            if (ferror(in)) {
                perror("gzip: read error");
                gzclose(out);
                fclose(in);
                if (!g_stdout) remove(dst.c_str());
                return;
            }
            break; 
        }
    }

    fclose(in);
    gzclose(out);

    if (!g_stdout) {
        struct utimbuf new_times;
        new_times.actime = st.st_atime;
        new_times.modtime = st.st_mtime;
        utime(dst.c_str(), &new_times);

        if (!g_keep) {
            unlink(src.c_str());
        }
        if (g_verbose) {
            off_t c = get_size(dst);
            double r = 0;
            if (st.st_size > 0) r = 100.0 * (1.0 - (double)c / st.st_size);
            cout << src << ":\t " << fixed << setprecision(1) << r << "% -- replaced with " << dst << endl;
        }
    }
}

// --- Decompression ---

void decompress_file(const string& src) {
    string dst;
    if (src.size() > g_suffix.size() && src.substr(src.size() - g_suffix.size()) == g_suffix) {
        dst = src.substr(0, src.size() - g_suffix.size());
    } else {
        if (!g_force && !g_stdout) {
            cerr << "gzip: " << src << ": unknown suffix -- ignored" << endl;
            return;
        }
        dst = src + ".out"; 
    }

    if (g_stdout) dst = "";

    struct stat st;
    if (stat(src.c_str(), &st) != 0) {
        perror(("gzip: " + src).c_str());
        return;
    }

    if (!g_stdout && file_exists(dst) && !g_force) {
        cerr << "gzip: " << dst << " already exists; do you wish to overwrite (y/n)? ";
        char ans;
        cin >> ans;
        if (ans != 'y' && ans != 'Y') return;
    }

    gzFile in = gzopen(src.c_str(), "rb");
    if (!in) {
        perror(("gzip: " + src).c_str());
        return;
    }

    FILE* out = NULL;
    if (g_stdout) {
        out = stdout;
    } else {
        out = fopen(dst.c_str(), "wb");
        if (!out) {
            perror(("gzip: " + dst).c_str());
            gzclose(in);
            return;
        }
    }

    char buf[16384];
    while (true) {
        int len = gzread(in, buf, sizeof(buf));
        if (len < 0) {
            cerr << "gzip: " << src << ": invalid compressed data" << endl;
            if (!g_stdout) fclose(out);
            gzclose(in);
            return;
        }
        if (len == 0) break; 

        if (fwrite(buf, 1, len, out) != (size_t)len) {
            perror("gzip: write error");
            if (!g_stdout) fclose(out);
            gzclose(in);
            return;
        }
    }

    gzclose(in);
    if (!g_stdout) fclose(out);

    if (!g_stdout) {
        struct utimbuf new_times;
        new_times.actime = st.st_atime;
        new_times.modtime = st.st_mtime;
        utime(dst.c_str(), &new_times);

        if (!g_keep) {
            unlink(src.c_str());
        }
        if (g_verbose) {
             cout << src << ":\t replaced with " << dst << endl;
        }
    }
}

// --- Traversal ---

void process_path(const string& path) {
    struct stat s;
    if (lstat(path.c_str(), &s) != 0) {
        perror(("gzip: " + path).c_str());
        return;
    }

    if (S_ISDIR(s.st_mode)) {
        if (g_recursive) {
            DIR* dir = opendir(path.c_str());
            if (!dir) {
                perror(("gzip: " + path).c_str());
                return;
            }
            struct dirent* entry;
            while ((entry = readdir(dir)) != NULL) {
                string name = entry->d_name;
                if (name == "." || name == "..") continue;
                process_path(path + "/" + name);
            }
            closedir(dir);
        } else {
            cerr << "gzip: " << path << " is a directory -- ignored" << endl;
        }
    } else if (S_ISREG(s.st_mode)) {
        if (g_list) {
            list_file(path);
        } else if (g_test) {
            test_file(path);
        } else if (g_decompress) {
            decompress_file(path);
        } else {
            compress_file(path);
        }
    }
}

int main(int argc, char* argv[]) {
    vector<string> files;

    for (int i = 1; i < argc; ++i) {
        string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            cout << "Usage: gzip [options] [files...]\n"
                 << "  -c, --stdout      Write on standard output, keep original files unchanged\n"
                 << "  -d, --decompress  Decompress\n"
                 << "  -f, --force       Force overwrite of output file and compress links\n"
                 << "  -h, --help        Give this help\n"
                 << "  -k, --keep        Keep (don't delete) input files\n"
                 << "  -l, --list        List compressed file contents\n"
                 << "  -t, --test        Test compressed file integrity\n"
                 << "  -r, --recursive   Operate recursively on directories\n"
                 << "  -v, --verbose     Verbose mode\n"
                 << "  -1..-9            Compression level\n";
            return 0;
        }
        else if (arg == "--version") {
            cout << "gzip (" << OS_NAME << ") " << OS_VERSION << endl;
            return 0;
        }
        else if (arg == "-c" || arg == "--stdout") g_stdout = true;
        else if (arg == "-d" || arg == "--decompress") g_decompress = true;
        else if (arg == "-f" || arg == "--force") g_force = true;
        else if (arg == "-k" || arg == "--keep") g_keep = true;
        else if (arg == "-r" || arg == "--recursive") g_recursive = true;
        else if (arg == "-v" || arg == "--verbose") g_verbose = true;
        else if (arg == "-l" || arg == "--list") g_list = true;
        else if (arg == "-t" || arg == "--test") g_test = true;
        else if (arg.size() == 2 && arg[0] == '-' && isdigit(arg[1])) {
            g_level = arg[1] - '0';
        }
        else if (arg[0] == '-') {
             for (size_t j = 1; j < arg.length(); ++j) {
                char c = arg[j];
                if (c == 'c') g_stdout = true;
                else if (c == 'd') g_decompress = true;
                else if (c == 'f') g_force = true;
                else if (c == 'k') g_keep = true;
                else if (c == 'r') g_recursive = true;
                else if (c == 'v') g_verbose = true;
                else if (c == 'l') g_list = true;
                else if (c == 't') g_test = true;
                else if (isdigit(c)) g_level = c - '0';
                else {
                    cerr << "gzip: invalid option -- '" << c << "'" << endl;
                    return 1;
                }
             }
        }
        else {
            files.push_back(arg);
        }
    }

    if (g_list) {
        cout << "  compressed  uncompressed  ratio uncompressed_name" << endl;
    }

    if (files.empty()) {
        // Stdin/Stdout mode
        if (isatty(STDIN_FILENO) && !g_force && !g_list) {
             // Warn if needed
        }
        g_stdout = true;

        if (g_list) {
            cerr << "gzip: --list requires file arguments" << endl;
            return 1;
        }

        if (g_decompress) {
            gzFile gzin = gzdopen(fileno(stdin), "rb");
            if (!gzin) { perror("gzip: stdin"); return 1; }
            
            char buf[16384];
            while (true) {
                int len = gzread(gzin, buf, sizeof(buf));
                if (len < 0) { cerr << "gzip: stdin: invalid data" << endl; return 1; }
                if (len == 0) break;
                fwrite(buf, 1, len, stdout);
            }
        } else {
            char mode[10];
            snprintf(mode, sizeof(mode), "wb%d", g_level);
            gzFile gzout = gzdopen(fileno(stdout), mode);
            if (!gzout) { perror("gzip: stdout"); return 1; }
            
            char buf[16384];
            while (true) {
                size_t len = fread(buf, 1, sizeof(buf), stdin);
                if (len > 0) gzwrite(gzout, buf, (unsigned)len);
                if (len < sizeof(buf)) break;
            }
            gzclose(gzout);
        }

        return 0;
    }

    for (const auto& file : files) {
        process_path(file);
    }

    return 0;
}
