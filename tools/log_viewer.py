#!/usr/bin/env python3
import os
import sys
import time
import glob
from datetime import datetime

# Configuration
LOG_DIR = "/home/creitin/Documents/geminios/logs/"
REFRESH_RATE = 0.1
IDLE_THRESHOLD = 300
ACTIVE_THRESHOLD = 1  # seconds

class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    WHITE = '\033[97m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'
    # Backgrounds
    BG_BLUE = '\033[44m'
    BG_RESET = '\033[49m'

def get_latest_log():
    try:
        files = glob.glob(os.path.join(LOG_DIR, "*.log"))
        if not files:
            return None
        # Sort by mtime, newest first
        latest = max(files, key=os.path.getmtime)
        return latest
    except Exception:
        return None

def clear_screen():
    print("\033[H\033[J", end="")

def print_header(pkg_name, status="Active"):
    cols = 80
    try:
        cols = os.get_terminal_size().columns
    except:
        pass
    
    timestamp = datetime.now().strftime("%H:%M:%S")
    
    # Top Bar
    bar_content = f" GeminiOS Log Monitor | {timestamp} "
    padding = cols - len(bar_content)
    if padding < 0: padding = 0
    
    print(f"{Colors.BG_BLUE}{Colors.BOLD}{Colors.WHITE}{bar_content}{' ' * padding}{Colors.ENDC}")
    
    # Info Line
    if pkg_name:
        status_color = Colors.GREEN if status == "Active" else Colors.YELLOW
        print(f" {Colors.BOLD}Package:{Colors.ENDC} {Colors.CYAN}{pkg_name:<20}{Colors.ENDC} {Colors.BOLD}Status:{Colors.ENDC} {status_color}{status}{Colors.ENDC}")
    else:
        print(f" {Colors.BOLD}Status:{Colors.ENDC} {Colors.YELLOW}Waiting for logs...{Colors.ENDC}")
    
    # Separator
    print(f"{Colors.BLUE}{'─' * cols}{Colors.ENDC}")
    sys.stdout.flush()

def main():
    if not os.path.exists(LOG_DIR):
        print(f"{Colors.RED}Error: Log directory not found at {LOG_DIR}{Colors.ENDC}")
        return

    current_file = None
    file_handle = None
    last_pos = 0
    current_pkg_name = None

    print(f"{Colors.CYAN}Starting log monitor...{Colors.ENDC}")
    time.sleep(1)

    try:
        while True:
            latest = get_latest_log()
            
            should_switch = False
            
            if latest and latest != current_file:
                # We found a new file. Is it active?
                # Check age
                mtime = os.path.getmtime(latest)
                age = time.time() - mtime
                
                # If we are currently watching nothing, AND this file is fresh enough, switch.
                # OR if we are watching something, but this file is NEWER and FRESH, switch.
                if age < ACTIVE_THRESHOLD:
                    should_switch = True
                
            if should_switch:
                if file_handle:
                    file_handle.close()
                
                current_file = latest
                current_pkg_name = os.path.basename(current_file).replace(".log", "")
                
                try:
                    file_handle = open(current_file, 'r', errors='replace')
                    clear_screen()
                    print_header(current_pkg_name, "Active")
                except Exception as e:
                    print(f"{Colors.RED}Error opening file: {e}{Colors.ENDC}")
                    current_file = None
                    time.sleep(1)
                    continue

            # If we have an open file, read from it
            if file_handle:
                while True:
                    line = file_handle.readline()
                    if line:
                        sys.stdout.write(line)
                        if not line.endswith('\n'):
                             sys.stdout.write('\n')
                    else:
                        break
                sys.stdout.flush()
                
                # Update status check
                # Verify if file is still 'fresh'
                try:
                    mtime = os.path.getmtime(current_file)
                    age = time.time() - mtime
                    if age > ACTIVE_THRESHOLD:
                         # The current file has stopped updating.
                         # We don't close it yet, we loop to see if a NEW file appears.
                         # But maybe we update the header?
                         # Not doing it to avoid flickering header usually.
                         pass
                except:
                    pass

            else:
                # No file active, just show waiting header occasionally?
                # To avoid spamming clear_screen, we only update time if needed or just wait
                pass

            time.sleep(REFRESH_RATE)
            
    except KeyboardInterrupt:
        print(f"\n{Colors.YELLOW}Monitor stopped by user.{Colors.ENDC}")
        if file_handle:
            file_handle.close()

if __name__ == "__main__":
    main()
