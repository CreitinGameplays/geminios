#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <cstring>
#include <cstdio>
#include <cstdarg>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <pwd.h>
#include <grp.h>
#include <algorithm>
#include <iomanip>
#include <utime.h>
#include <fcntl.h>
#include <zlib.h>
#include "../../../src/sys_info.h"
#include "../../../src/signals.h"

using namespace std;

// --- Debugging ---
bool g_verbose = false;
bool g_debug = false;

void DEBUG(const string& msg) {
    if (g_debug) cerr << "[TAR-DEBUG] " << msg << endl;
}

// USTAR Constants
const int BLOCK_SIZE = 512;
const char* TMAGIC = "ustar";
const char* TVERSION = "00";

// Type Flags
const char REGTYPE  = '0';
const char AREGTYPE = '\0';
const char LNKTYPE  = '1';
const char SYMTYPE  = '2';
const char CHRTYPE  = '3';
const char BLKTYPE  = '4';
const char DIRTYPE  = '5';
const char FIFOTYPE = '6';

struct TarHeader {
    char name[100];
    char mode[8];
    char uid[8];
    char gid[8];
    char size[12];
    char mtime[12];
    char chksum[8];
    char typeflag;
    char linkname[100];
    char magic[6];
    char version[2];
    char uname[32];
    char gname[32];
    char devmajor[8];
    char devminor[8];
    char prefix[155];
    char padding[12]; 
};

// --- IO Abstraction (Normal vs Gzip) ---

class ArchiveIO {
public:
    virtual ~ArchiveIO() {}
    virtual ssize_t read(void* buf, size_t count) = 0;
    virtual ssize_t write(const void* buf, size_t count) = 0;
    virtual bool eof() = 0;
    virtual void close() = 0;
};

class FileArchiveIO : public ArchiveIO {
    FILE* fp;
public:
    FileArchiveIO(const string& path, const char* mode) {
        fp = (path == "-") ? (mode[0] == 'r' ? stdin : stdout) : fopen(path.c_str(), mode);
    }
    ssize_t read(void* buf, size_t count) override {
        return fp ? fread(buf, 1, count, fp) : -1;
    }
    ssize_t write(const void* buf, size_t count) override {
        return fp ? fwrite(buf, 1, count, fp) : -1;
    }
    bool eof() override { return fp ? feof(fp) : true; }
    void close() override { if (fp && fp != stdin && fp != stdout) fclose(fp); fp = nullptr; }
    bool is_open() { return fp != nullptr; }
};

class GzipArchiveIO : public ArchiveIO {
    gzFile gz;
public:
    GzipArchiveIO(const string& path, const char* mode) {
        if (path == "-") {
            int fd = (mode[0] == 'r') ? fileno(stdin) : fileno(stdout);
            gz = gzdopen(fd, mode);
        } else {
            gz = gzopen(path.c_str(), mode);
        }
    }
    ssize_t read(void* buf, size_t count) override {
        return gz ? gzread(gz, buf, (unsigned)count) : -1;
    }
    ssize_t write(const void* buf, size_t count) override {
        return gz ? gzwrite(gz, buf, (unsigned)count) : -1;
    }
    bool eof() override { return gz ? gzeof(gz) : true; }
    void close() override { if (gz) gzclose(gz); gz = nullptr; }
    bool is_open() { return gz != nullptr; }
};

// --- Helpers ---

string get_mode_string(mode_t mode) {
    string s = "?rwxrwxrwx";
    if (S_ISREG(mode)) s[0] = '-';
    else if (S_ISDIR(mode)) s[0] = 'd';
    else if (S_ISLNK(mode)) s[0] = 'l';
    else if (S_ISCHR(mode)) s[0] = 'c';
    else if (S_ISBLK(mode)) s[0] = 'b';
    
    for (int i = 0; i < 9; i++) {
        if (!(mode & (1 << (8 - i)))) s[i + 1] = '-';
    }
    return s;
}

void string_to_field(char* field, int size, const string& str) {
    memset(field, 0, size);
    strncpy(field, str.c_str(), size);
}

void octal_to_field(char* field, int size, unsigned long value) {
    memset(field, 0, size);
    snprintf(field, size, "%0*lo", size - 1, value); // Null terminated
}

unsigned long field_to_octal(const char* field, int size) {
    string s(field, size);
    size_t end = s.find_last_not_of('\0');
    if (end == string::npos) return 0;
    s = s.substr(0, end + 1);
    end = s.find_last_not_of(' ');
    if (end != string::npos) s = s.substr(0, end + 1);
    
    if (s.empty()) return 0;
    try {
        return stoul(s, nullptr, 8);
    } catch (...) { return 0; }
}

unsigned int calculate_checksum(const TarHeader* h) {
    unsigned char* bytes = (unsigned char*)h;
    unsigned int sum = 0;
    for (int i = 0; i < BLOCK_SIZE; ++i) {
        if (i >= 148 && i < 156) sum += ' ';
        else sum += bytes[i];
    }
    return sum;
}

bool mkdir_p(const string& path) {
    string current;
    for (size_t i = 0; i < path.length(); ++i) {
        if (path[i] == '/') {
            if (!current.empty()) {
                if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) return false;
            }
        }
        current += path[i];
    }
    if (!current.empty()) {
        if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) return false;
    }
    return true;
}

string clean_path(string path) {
    while (path.length() > 0 && (path[0] == '/' || (path.length() > 1 && path[0] == '.' && path[1] == '/'))) {
        if (path[0] == '/') path = path.substr(1);
        else path = path.substr(2);
    }
    if (path.length() > 1 && path.back() == '/') path.pop_back();
    return path;
}

bool matches_exclude(const string& path, const vector<string>& excludes) {
    for (const auto& ex : excludes) {
        if (path.find(ex) != string::npos) return true;
    }
    return false;
}

// --- Create ---

void write_header(ArchiveIO* out, const string& path, const string& stored_name, const struct stat& st, char type) {
    TarHeader h;
    memset(&h, 0, sizeof(h));

    string clean_name = stored_name;
    if (type == DIRTYPE && clean_name.back() != '/') clean_name += "/";

    DEBUG("Writing header for: " + clean_name);

    if (clean_name.length() > 100) {
        size_t split = clean_name.rfind('/', 154);
        if (split != string::npos && split < clean_name.length() && (clean_name.length() - split - 1) <= 100) {
            string prefix = clean_name.substr(0, split);
            string name = clean_name.substr(split + 1);
            string_to_field(h.prefix, 155, prefix);
            string_to_field(h.name, 100, name);
        } else {
            cerr << "tar: path too long '" << clean_name << "'" << endl;
            string_to_field(h.name, 100, clean_name.substr(0, 100));
        }
    } else {
        string_to_field(h.name, 100, clean_name);
    }

    octal_to_field(h.mode, 8, st.st_mode & 0777);
    octal_to_field(h.uid, 8, st.st_uid);
    octal_to_field(h.gid, 8, st.st_gid);
    octal_to_field(h.size, 12, (type == REGTYPE) ? st.st_size : 0);
    octal_to_field(h.mtime, 12, st.st_mtime);
    h.typeflag = type;
    
    if (type == SYMTYPE) {
        char link_target[100];
        memset(link_target, 0, 100);
        readlink(path.c_str(), link_target, 99);
        string_to_field(h.linkname, 100, link_target);
    }

    string_to_field(h.magic, 6, TMAGIC);
    string_to_field(h.version, 2, TVERSION);

    struct passwd* pw = getpwuid(st.st_uid);
    if (pw) string_to_field(h.uname, 32, pw->pw_name);
    struct group* gr = getgrgid(st.st_gid);
    if (gr) string_to_field(h.gname, 32, gr->gr_name);

    octal_to_field(h.chksum, 8, calculate_checksum(&h));

    out->write((char*)&h, BLOCK_SIZE);
}

void add_to_archive(ArchiveIO* out, string path, string base_dir, const vector<string>& excludes) {
    if (matches_exclude(path, excludes)) {
        DEBUG("Excluding: " + path);
        return;
    }

    struct stat st;
    if (lstat(path.c_str(), &st) != 0) {
        perror(("tar: " + path).c_str());
        return;
    }

    if (g_verbose) cout << path << endl;

    if (S_ISDIR(st.st_mode)) {
        write_header(out, path, clean_path(path), st, DIRTYPE);
        
        DIR* dir = opendir(path.c_str());
        if (!dir) return;
        struct dirent* entry;
        while ((entry = readdir(dir)) != NULL) {
            string name = entry->d_name;
            if (name == "." || name == "..") continue;
            add_to_archive(out, path + "/" + name, base_dir, excludes);
        }
        closedir(dir);
    } else if (S_ISREG(st.st_mode)) {
        write_header(out, path, clean_path(path), st, REGTYPE);
        FILE* in = fopen(path.c_str(), "rb");
        if (in) {
            char buffer[BLOCK_SIZE];
            size_t r;
            while ((r = fread(buffer, 1, BLOCK_SIZE, in)) > 0) {
                if (r < BLOCK_SIZE) memset(buffer + r, 0, BLOCK_SIZE - r);
                out->write(buffer, BLOCK_SIZE);
            }
            fclose(in);
        }
    } else if (S_ISLNK(st.st_mode)) {
        write_header(out, path, clean_path(path), st, SYMTYPE);
    } else {
        if (g_verbose) cerr << "tar: ignoring special file " << path << endl;
    }
}

// --- Extract ---

void extract_archive(ArchiveIO* in, bool preserve_perms) {
    char buffer[BLOCK_SIZE];
    while (in->read(buffer, BLOCK_SIZE) == BLOCK_SIZE) {
        bool all_zeros = true;
        for (int i = 0; i < BLOCK_SIZE; ++i) if (buffer[i] != 0) { all_zeros = false; break; }
        if (all_zeros) return;

        TarHeader* h = (TarHeader*)buffer;
        
        unsigned int stored_sum = field_to_octal(h->chksum, 8);
        if (stored_sum != calculate_checksum(h)) {
            cerr << "tar: skipping block with invalid checksum" << endl;
            continue;
        }

        string name = h->name;
        if (h->prefix[0] != 0) {
            name = string(h->prefix) + "/" + name;
        }
        
        // Security: Prevent absolute paths or traversal
        if (name[0] == '/') name = name.substr(1);
        while(name.find("../") != string::npos) {
            name.replace(name.find("../"), 3, "");
        }

        if (g_verbose) cout << name << endl;

        unsigned long size = field_to_octal(h->size, 12);
        unsigned long mode = field_to_octal(h->mode, 8);
        unsigned long mtime = field_to_octal(h->mtime, 12);
        unsigned long uid = field_to_octal(h->uid, 8);
        unsigned long gid = field_to_octal(h->gid, 8);
        
        char type = h->typeflag ? h->typeflag : REGTYPE;

        if (type == DIRTYPE) {
            mkdir_p(name);
        } else if (type == REGTYPE || type == AREGTYPE) {
            size_t last_slash = name.find_last_of('/');
            if (last_slash != string::npos) {
                mkdir_p(name.substr(0, last_slash));
            }

            FILE* out = fopen(name.c_str(), "wb");
            if (out) {
                long remaining = size;
                char data[BLOCK_SIZE];
                while (remaining > 0) {
                    size_t to_read = BLOCK_SIZE;
                    if (in->read(data, to_read) != to_read) break;
                    
                    fwrite(data, 1, min((long)BLOCK_SIZE, remaining), out);
                    remaining -= BLOCK_SIZE;
                }
                fclose(out);
                
                if (preserve_perms) {
                    chmod(name.c_str(), mode & 0777);
                    chown(name.c_str(), uid, gid);
                }
                struct utimbuf new_times;
                new_times.actime = time(NULL);
                new_times.modtime = mtime;
                utime(name.c_str(), &new_times);
            } else {
                perror(("tar: cannot create " + name).c_str());
                long blocks = (size + BLOCK_SIZE - 1) / BLOCK_SIZE;
                for(int k=0; k<blocks; k++) in->read(buffer, BLOCK_SIZE);
            }
        } else if (type == SYMTYPE) {
             size_t last_slash = name.find_last_of('/');
            if (last_slash != string::npos) {
                mkdir_p(name.substr(0, last_slash));
            }
            symlink(h->linkname, name.c_str());
        }
    }
}

void list_archive(ArchiveIO* in) {
    char buffer[BLOCK_SIZE];
    while (in->read(buffer, BLOCK_SIZE) == BLOCK_SIZE) {
        bool all_zeros = true;
        for (int i = 0; i < BLOCK_SIZE; ++i) if (buffer[i] != 0) { all_zeros = false; break; }
        if (all_zeros) return;

        TarHeader* h = (TarHeader*)buffer;
        if (field_to_octal(h->chksum, 8) != calculate_checksum(h)) continue;

        string name = h->name;
        if (h->prefix[0] != 0) name = string(h->prefix) + "/" + name;
        
        unsigned long mode = field_to_octal(h->mode, 8);
        
        if (g_verbose) {
            cout << get_mode_string((mode & 0777) | (h->typeflag == DIRTYPE ? S_IFDIR : 0));
            cout << " " << (h->uname[0] ? h->uname : to_string(field_to_octal(h->uid, 8)));
            cout << "/" << (h->gname[0] ? h->gname : to_string(field_to_octal(h->gid, 8)));
            cout << " " << std::setw(8) << field_to_octal(h->size, 12);
            
            time_t mtime = field_to_octal(h->mtime, 12);
            char timebuf[32];
            strftime(timebuf, 32, "%Y-%m-%d %H:%M", localtime(&mtime));
            cout << " " << timebuf << " ";
        }
        
        cout << name;
        if (h->typeflag == SYMTYPE) cout << " -> " << h->linkname;
        cout << endl;
             
        unsigned long size = field_to_octal(h->size, 12);
        if (h->typeflag == REGTYPE || h->typeflag == AREGTYPE) {
            long blocks = (size + BLOCK_SIZE - 1) / BLOCK_SIZE;
            for(int k=0; k<blocks; k++) in->read(buffer, BLOCK_SIZE);
        }
    }
}

int main(int argc, char* argv[]) {
    setvbuf(stdout, NULL, _IONBF, 0);
    
    string mode;
    string filename;
    vector<string> files;
    vector<string> excludes;
    bool use_gzip = false;
    bool preserve = false;
    string change_dir;

    for (int i = 1; i < argc; ++i) {
        string arg = argv[i];
        if (arg == "--help") {
            cout << "Usage: tar [options] [files...]\n"
                 << "  -c      Create archive\n"
                 << "  -x      Extract archive\n"
                 << "  -t      List archive\n"
                 << "  -z      Compress/Decompress with gzip\n"
                 << "  -f <F>  Use archive file F (use - for stdin/stdout)\n"
                 << "  -v      Verbose\n"
                 << "  -C <D>  Change to directory D\n"
                 << "  -p      Preserve permissions (extract)\n"
                 << "  --exclude <pattern>  Exclude files\n";
            return 0;
        } else if (arg == "--version") {
            cout << "tar (" << OS_NAME << ") " << OS_VERSION << endl;
            return 0;
        } else if (arg == "--exclude" && i + 1 < argc) {
            excludes.push_back(argv[++i]);
        } else if (arg == "--verbose") {
            g_verbose = true;
        } else if (arg == "-C" && i + 1 < argc) {
            change_dir = argv[++i];
        } else if (arg[0] == '-') {
            for (size_t j = 1; j < arg.length(); ++j) {
                if (arg[j] == 'c') mode = "create";
                else if (arg[j] == 'x') mode = "extract";
                else if (arg[j] == 't') mode = "list";
                else if (arg[j] == 'v') g_verbose = true;
                else if (arg[j] == 'z') use_gzip = true;
                else if (arg[j] == 'p') preserve = true;
                else if (arg[j] == 'd') g_debug = true;
                else if (arg[j] == 'f') {
                    if (j + 1 < arg.length()) {
                        filename = arg.substr(j + 1);
                        j = arg.length(); 
                    } else if (i + 1 < argc) {
                        filename = argv[++i];
                    } else {
                        cerr << "tar: option requires an argument -- 'f'" << endl;
                        return 1;
                    }
                }
            }
        } else {
            files.push_back(arg);
        }
    }

    if (mode.empty()) {
        cerr << "tar: must specify one of -c, -x, -t" << endl;
        return 1;
    }
    
    if (filename.empty()) filename = "-";
    
    if (!change_dir.empty()) {
        if (chdir(change_dir.c_str()) != 0) {
            perror(("tar: " + change_dir).c_str());
            return 1;
        }
    }

    if (mode == "create") {
        ArchiveIO* out = nullptr;
        if (use_gzip) out = new GzipArchiveIO(filename, "wb");
        else out = new FileArchiveIO(filename, "wb");
        
        if (!out || (filename != "-" && dynamic_cast<FileArchiveIO*>(out) && !((FileArchiveIO*)out)->is_open())) {
            perror("tar: create"); return 1;
        }
        
        for (const auto& f : files) {
            add_to_archive(out, f, "", excludes);
        }
        char zeros[BLOCK_SIZE * 2];
        memset(zeros, 0, sizeof(zeros));
        out->write(zeros, sizeof(zeros));
        out->close();
        delete out;
        
    } else if (mode == "extract") {
        ArchiveIO* in = nullptr;
        if (use_gzip) in = new GzipArchiveIO(filename, "rb");
        else in = new FileArchiveIO(filename, "rb");
        
        if (!in || (filename != "-" && dynamic_cast<FileArchiveIO*>(in) && !((FileArchiveIO*)in)->is_open())) {
             perror("tar: extract"); return 1; 
        }
        extract_archive(in, preserve);
        in->close();
        delete in;
        
    } else if (mode == "list") {
        ArchiveIO* in = nullptr;
        if (use_gzip) in = new GzipArchiveIO(filename, "rb");
        else in = new FileArchiveIO(filename, "rb");
        
        if (!in || (filename != "-" && dynamic_cast<FileArchiveIO*>(in) && !((FileArchiveIO*)in)->is_open())) {
             perror("tar: list"); return 1; 
        }
        list_archive(in);
        in->close();
        delete in;
    }

    return 0;
}
