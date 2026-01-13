# GeminiOS Init System Improvement Plan

## Goal
Decouple `ginit` into modular components to improve robustness and follow standard Linux practices (separating Init, Getty, Login, and Shell).

## Phase 1: New Components

### 1. [x] Create `src/gsh.cpp` (Gemini Shell)
Extract the shell implementation from `src/ginit.cpp` into a standalone shell binary.
- **Responsibilities**:
    - Command parsing (tokenize, parse input, job control).
    - Execution engine (pipelines, redirections, built-ins).
    - `readline` implementation and tab completion.
    - Interactive loop (`start_shell`).
- **Implementation Details**:
    - Move `Command`, `Job`, `Redirection` structs.
    - Move `tokenize_input`, `parse_input`, `execute_pipeline`, `readline`.
    - Main function should just initialize signals and call `start_shell`.

### 2. [x] Create `src/login.cpp`
Create a standalone login program.
- **Responsibilities**:
    - Authenticate users.
    - Setup session (UID/GID, Groups, Environment).
    - Exec the user's shell.
- **Implementation Details**:
    - Use `src/user_mgmt.cpp` for loading users and checking passwords.
    - Prompt for username (if not provided) and password.
    - Set environment: `HOME`, `USER`, `SHELL`, `TERM`, `PATH`.
    - `setgid()`, `initgroups()`, `setuid()`.
    - `execv(shell_path, ...)`
    - Handle login failures with a delay.

### 3. [x] Create `src/getty.cpp`
Create a standalone TTY manager.
- **Responsibilities**:
    - Open specific TTY device.
    - Configure terminal attributes (baud rate, etc - usually handled by kernel for virtual consoles, but good to ensure).
    - Output `/etc/issue` or banner.
    - Prompt for Login Name.
    - `exec("/bin/login", ...)`
- **Implementation Details**:
    - `open(tty, O_RDWR)`.
    - `dup2` to 0, 1, 2.
    - `ioctl(0, TIOCSCTTY, 1)`.
    - Print "GeminiOS Login: ".
    - Read username and pass to `login` args.

## Phase 2: Refactor Init

### 4. [x] Simplify `src/ginit.cpp`
Reduce `ginit` to a system initializer and process supervisor.
- **Responsibilities**:
    - Mount filesystems (`/proc`, `/sys`, `/dev`, etc.).
    - Initialize devices (`udev`, `dbus`).
    - Spawn `getty` instances on defined terminals (`tty1`...`tty4`).
    - **Reap zombies** (`waitpid(-1, ...)`).
    - **Respawn** dead `getty` processes.
- **Changes**:
    - Remove all shell logic.
    - Remove all login logic.
    - Remove `run_shell` function.
    - In the supervision loop, if a child dies, check which TTY it was and respawn `getty`.

## Phase 3: Build & Integrate

### 5. [x] Update `ports/geminios_core/build.sh`
- Compile `gsh` -> install to `/bin/gsh`.
- Symlink `/bin/sh` -> `/bin/gsh`.
- Compile `login` -> install to `/bin/login` (link `user_mgmt`, `signals`, `crypt`).
- Compile `getty` -> install to `/sbin/getty`.
- Compile `ginit` -> install to `/bin/init` (link `signals`, `network`, etc.).
- Update `/etc/passwd` to set root shell to `/bin/gsh`.

### 6. Verify
- Rebuild `geminios_core`.
- Test boot process:
    - Init starts.
    - Gettys spawn.
    - Login prompt appears.
    - Authentication works.
    - Shell works.


### Ginit Service Management (Systemd-style) [IMPLEMENTED]
A proposed enhancement for `ginit` to manage background services and daemons using structured configuration files.
- [x] Implement `.gservice` file parser (`src/gservice_parser.cpp`).
- [x] Implement service manager logic (`src/gservice_manager.cpp`).
- [x] Integrate service manager into `ginit` supervision loop.
- [ ] Implement robust IPC for CLI commands (status, enable, disable).

**Storage Locations:**
- System Services: `/etc/ginit/services/system/<service>.gservice`
- User Services: `/etc/ginit/services/user/<service>.gservice`

**Command Interface:**
```bash
ginit <service> enable   [--user | --system]
ginit <service> disable  [--user | --system]
ginit <service> status   [--user | --system]
ginit <service> remove   [--user | --system]
```

**Service Configuration Template (`.gservice`):**
```
service "dummy-app" {
    // Metadata and Dependencies (single line comment)
    meta {
        description = "Dummy High-Performance Backend Application"
        docs = "https://dummy-app.com/docs"
        
        // Dependency chain
        deps {
            after    = ["network-online.target", "postgresql.service"]
            wants    = ["redis.service"]
            requires = ["postgresql.service"]
        }
    }

    // Main Service Logic
    process {
        type = "notify"
        user = "dummy-user"
        group = "dummy-group"
        work_dir = "/opt/dummy-app"

        commands {
            start_pre = "/opt/dummy-app/bin/cleanup.sh"
            start     = "/opt/dummy-app/bin/server --config /etc/dummy.conf"
            reload    = "/bin/kill -HUP $MAINPID"
            stop      = "/opt/dummy-app/bin/shutdown.sh"
        }

        lifecycle {
            restart_policy = "on-failure"
            restart_delay  = "5s"
            stop_timeout   = "10s"
        }
    }

    // Environment Configuration
    env {
        load_file = "/etc/default/dummy-app"
        vars = {
            NODE_ENV = "production"
            PORT     = 8080
        }
    }

    // Security Sandbox
    security {
        no_new_privileges = true
        protect_system    = "full"
        protect_home      = true
        private_tmp       = true
        rw_paths          = ["/var/log/dummy-app", "/run/dummy-app"]
    }

    // Resource Constraints
    resources {
        ulimit_nofile = 65536
        memory_max    = "1G"
        cpu_quota     = "50%"
    }

    // Installation Targets
    install {
        wanted_by = ["multi-user.target"]
        alias     = "dummy.service"
    }
}
```

