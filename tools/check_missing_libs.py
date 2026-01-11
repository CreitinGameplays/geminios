import os
import subprocess
import re

ROOTFS = os.path.abspath("rootfs")

def build_file_cache(directory):
    cache = {}
    for root, dirs, files in os.walk(directory):
        for file in files:
            path = os.path.join(root, file)
            cache[file] = cache.get(file, [])
            cache[file].append(path)
    return cache

def get_elf_files(directory):
    elf_files = []
    for root, dirs, files in os.walk(directory):
        for file in files:
            path = os.path.join(root, file)
            if os.path.islink(path):
                # We should check if the link target exists, but it's not an ELF file itself
                continue
            try:
                with open(path, 'rb') as f:
                    magic = f.read(4)
                    if magic == b'\x7fELF':
                        elf_files.append(path)
            except Exception:
                continue
    return elf_files

def check_dependencies(file_path, file_cache):
    missing = []
    try:
        result = subprocess.run(['readelf', '-d', file_path], capture_output=True, text=True)
        needed = re.findall(r'\(NEEDED\)\s+Shared library:\s+\[(.+?)\]', result.stdout)
        
        result_interp = subprocess.run(['readelf', '-l', file_path], capture_output=True, text=True)
        interp_match = re.search(r'\[Requesting program interpreter: (.+?)\]', result_interp.stdout)
        if interp_match:
            needed.append(interp_match.group(1))

        for lib in needed:
            lib_name = os.path.basename(lib)
            found = False
            
            if lib_name in file_cache:
                for found_path in file_cache[lib_name]:
                    # Check if it's within rootfs
                    if found_path.startswith(ROOTFS):
                        found = True
                        break
            
            if not found:
                missing.append(lib)
    except Exception as e:
        print(f"Error checking {file_path}: {e}")
    
    return missing

def main():
    print("Building file cache...")
    file_cache = build_file_cache(ROOTFS)
    
    print("Finding ELF files...")
    elf_files = get_elf_files(ROOTFS)
    print(f"Found {len(elf_files)} ELF files.")
    
    all_missing = {}
    for elf in elf_files:
        missing = check_dependencies(elf, file_cache)
        if missing:
            rel_path = os.path.relpath(elf, ROOTFS)
            all_missing[rel_path] = missing
            print(f"File: {rel_path} is missing: {', '.join(missing)}")

    if not all_missing:
        print("No missing libraries found!")
    else:
        print(f"\nTotal files with missing dependencies: {len(all_missing)}")
        
    # Also check for broken symlinks in lib directories
    print("\nChecking for broken symlinks in lib directories...")
    lib_dirs = [
        os.path.join(ROOTFS, 'lib'),
        os.path.join(ROOTFS, 'lib64'),
        os.path.join(ROOTFS, 'usr/lib'),
        os.path.join(ROOTFS, 'usr/lib64')
    ]
    for lib_dir in lib_dirs:
        if not os.path.exists(lib_dir):
            continue
        for root, dirs, files in os.walk(lib_dir):
            for file in files + dirs:
                path = os.path.join(root, file)
                if os.path.islink(path):
                    target = os.readlink(path)
                    if not os.path.isabs(target):
                        target = os.path.join(os.path.dirname(path), target)
                    if not os.path.exists(target):
                        print(f"Broken symlink: {os.path.relpath(path, ROOTFS)} -> {os.readlink(path)}")

if __name__ == "__main__":
    main()