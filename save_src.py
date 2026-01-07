#!/usr/bin/env python3
"""
Export project files into a single text file in the format:

--- Full File List (Including Excluded Files) ---
/path/to/file1
/path/to/dir/file2
...

File: path/to/file

1 |first line
2 |second line


File: path/to/second/file

1 | testing...


This tool tries to be robust: it skips binary files, very large files,
permission-denied files, and common virtual env / git directories
FOR THE CONTENT EXPORT. However, the file list at the top includes everything.

Usage:
    python export_project_files.py --root /path/to/project --out export.txt

"""
from __future__ import annotations
import argparse
import os
import sys
from pathlib import Path
from typing import Iterable, Tuple
import logging
import fnmatch

# Configurable defaults
DEFAULT_MAX_FILE_SIZE = 5 * 1024 * 1024  # 5 MB
TEXT_CHECK_BYTES = 8192
NON_TEXT_RATIO_THRESHOLD = 0.30
SKIP_DIR_NAMES = {'.git', '.venv', 'venv', '.venv', '__pycache__', 'node_modules', 'build', 'dist', '.mypy_cache'}
SKIP_EXTENSIONS = {'.iso', '.bin', '.exe', '.dll', '.so', '.o', '.a', '.zip', '.gz', '.tar', '.png', '.jpg', '.jpeg', '.gif', '.class'}

logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(message)s')
logger = logging.getLogger("exporter")


def is_probably_text_file_bytes(b: bytes) -> bool:
    """Return True if bytes appear to be text, using a few heuristics."""
    if not b:
        return True
    if b.find(b"\x00") != -1:
        return False
    # Count non-text-like bytes
    non_text = 0
    total = 0
    for c in b:
        total += 1
        # allow tab, newline, carriage return
        if c in (9, 10, 13):
            continue
        # printable ASCII range
        if 32 <= c <= 126:
            continue
        # treat other bytes as non-text for this heuristic
        non_text += 1
    if total == 0:
        return True
    ratio = non_text / total
    return ratio <= NON_TEXT_RATIO_THRESHOLD


def is_text_file(path: Path, max_check_bytes: int = TEXT_CHECK_BYTES) -> bool:
    """Quickly test whether a file is text by reading a chunk of bytes."""
    try:
        with path.open('rb') as f:
            chunk = f.read(max_check_bytes)
    except Exception:
        return False
    return is_probably_text_file_bytes(chunk)


def iter_files(root: Path, max_size: int, exclude_dirs: set[str] = None, exclude_files: set[Path] = None, exclude_patterns: list[str] = None) -> Iterable[Path]:
    """Yield files under root, skipping directories and patterns (Used for Content Export)."""
    if exclude_dirs is None:
        exclude_dirs = set()
    if exclude_files is None:
        exclude_files = set()
    if exclude_patterns is None:
        exclude_patterns = []
    exclude_files_resolved = {p.resolve() for p in exclude_files}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        # Filter dirnames with patterns as well
        dirnames[:] = [
            d for d in dirnames
            if d not in SKIP_DIR_NAMES
            and d not in exclude_dirs
            and not any(fnmatch.fnmatch(d, pat) for pat in exclude_patterns)
        ]
        for name in filenames:
            try:
                p = Path(dirpath) / name
            except Exception:
                continue
            # Always skip excluded files
            try:
                if p.resolve() in exclude_files_resolved:
                    continue
            except Exception:
                continue
            # Skip by extension early
            if p.suffix.lower() in SKIP_EXTENSIONS:
                continue
            # Skip by pattern
            if any(fnmatch.fnmatch(name, pat) for pat in exclude_patterns):
                continue
            # Skip too large files
            try:
                size = p.stat().st_size
            except Exception:
                continue
            if size > max_size:
                continue
            yield p


def write_full_file_list(root: Path, out_f):
    """
    Writes a list of ALL files in the directory to the output file, 
    ignoring all exclusions, size limits, and checks.
    """
    out_f.write("--- Full File List (Including Excluded Files) ---\n")
    
    # We use a raw os.walk here without modifying dirnames, so it traverses everything
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            try:
                full_path = Path(dirpath) / name
                try:
                    rel_path = full_path.relative_to(root)
                except ValueError:
                    # Should not happen if walking root, but just in case
                    rel_path = full_path
                
                # Format: /path/to/file (POSIX style)
                path_str = f"/{rel_path.as_posix()}"
                out_f.write(f"{path_str}\n")
            except Exception:
                continue
    
    out_f.write("\n" + "="*50 + "\n\n")


def export_file(path: Path, out_f, rel_root: Path) -> bool:
    """Write a single file's contents to out_f using the numbered-line format."""
    # Determine relative path for header
    try:
        rel = path.relative_to(rel_root)
    except Exception:
        rel = path
    # Normalize path to POSIX-style for output readability
    rel_str = str(rel).replace('\\', '/')

    # Quick text check
    if not is_text_file(path):
        logger.debug(f"Skipping binary/unreadable file: {path}")
        return False

    try:
        # Try opening as text (utf-8), fallback to latin-1
        try:
            text = path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            text = path.read_text(encoding='latin-1')
    except Exception as e:
        logger.debug(f"Failed to read {path}: {e}")
        return False

    # Write header
    out_f.write(f"File: {rel_str}:\n\n")
    # Write numbered lines
    lines = text.splitlines()
    if not lines:
        # preserve an empty file with a single numbered empty line
        out_f.write("1 |\n\n")
        return True
    for idx, line in enumerate(lines, start=1):
        # Avoid embedding CRLF weirdness; keep content but strip trailing newlines
        out_f.write(f"{idx} |{line}\n")
    out_f.write("\n\n")
    return True


def build_export(root: Path, out_path: Path, max_size: int, exclude_dirs: set[str], exclude_files: set[Path], exclude_patterns: list[str]) -> Tuple[int, int]:
    """Walk and export files. Returns (written_count, skipped_count)."""
    written = 0
    skipped = 0
    # Ensure parent dir exists for output
    out_path.parent.mkdir(parents=True, exist_ok=True)
    
    with out_path.open('w', encoding='utf-8', newline='\n') as out_f:
        # 1. Write the generic header
        out_f.write(f"This is the full source code in a single text file just for the context.\n\n")
        
        # 2. Write the Tree View (ignores exclusions)
        logger.info("Generating full file list (ignoring exclusions)...")
        write_full_file_list(root, out_f)
        
        # 3. Write the actual content (respects exclusions)
        logger.info("Exporting file contents (respecting exclusions)...")
        for p in iter_files(root, max_size=max_size, exclude_dirs=exclude_dirs, exclude_files=exclude_files, exclude_patterns=exclude_patterns):
            try:
                ok = export_file(p, out_f, rel_root=root)
            except Exception as e:
                logger.debug(f"Failed while exporting {p}: {e}")
                ok = False
            if ok:
                written += 1
            else:
                skipped += 1
    return written, skipped


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Export text files from a project into one numbered file.")
    p.add_argument('--root', '-r', type=str, default='.', help='Project root directory to walk (default: current directory)')
    p.add_argument('--out', '-o', type=str, default='project_export.txt', help='Output file path')
    p.add_argument('--max-size', '-m', type=int, default=DEFAULT_MAX_FILE_SIZE, help=f'Max file size to include in bytes (default: {DEFAULT_MAX_FILE_SIZE})')
    p.add_argument('--verbose', '-v', action='store_true', help='Verbose logging')
    p.add_argument('--exclude', '-x', type=str, nargs='*', default=[], help='Directory names to exclude (in addition to built-in skips)')
    p.add_argument('--extra-excludes', nargs='*', help='Additional exclude patterns (wildcards supported)')
    return p.parse_args()


def main(argv: list[str] | None = None) -> int:
    args = parse_args() if argv is None else parse_args()
    if getattr(args, 'verbose', False):
        logger.setLevel(logging.DEBUG)
    root = Path(args.root).resolve()
    out_path = Path(args.out).resolve()
    exclude_dirs = set(args.exclude)
    # Always exclude the output file and this script itself
    script_path = Path(__file__).resolve()
    exclude_files = {out_path, script_path}
    # Collect wildcard patterns from positional args (extra_excludes)
    exclude_patterns = list(args.extra_excludes) if args.extra_excludes else []
    # Always exclude the output file by name pattern as well
    exclude_patterns.append(out_path.name)

    if not root.exists() or not root.is_dir():
        logger.error(f"Root path does not exist or is not a directory: {root}")
        return 2

    logger.info(f"Exporting files under: {root}")
    logger.info(f"Output will be written to: {out_path}")
    
    written, skipped = build_export(
        root, out_path,
        max_size=args.max_size,
        exclude_dirs=exclude_dirs,
        exclude_files=exclude_files,
        exclude_patterns=exclude_patterns
    )
    logger.info(f"Completed: written={written}, skipped={skipped}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
    