CC = gcc
CFLAGS = -O2 -Wall -Wextra

TARGET = shim_wrapper
SRC = shim_wrapper.c
SHIM_DIR = shim
WRAP_BIN_DIR = wrap_bin

# Tool lists
TOOLS_LONG = ar g++ gcc objdump ranlib readelf strip
TOOLS_SHORT = msgfmt msginit msgmerge xgettext python3

all: $(TARGET) setup

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(SRC) -o $(TARGET)

setup: $(TARGET)
	@echo "Setting up shims..."
	@mkdir -p $(SHIM_DIR)
	@mkdir -p $(WRAP_BIN_DIR)
	
	@# Symlink long-named tools (x86_64-gemini-linux-gnu-*)
	@for tool in $(TOOLS_LONG); do \
		ln -sf ../$(TARGET) $(SHIM_DIR)/x86_64-gemini-linux-gnu-$$tool; \
	done
	
	@# Symlink short-named tools
	@for tool in $(TOOLS_SHORT); do \
		ln -sf ../$(TARGET) $(SHIM_DIR)/$$tool; \
	done
	
	@# Symlink sh in wrap_bin (it uses shim_wrapper logic)
	@ln -sf ../$(TARGET) $(WRAP_BIN_DIR)/sh
	
	@# Create wrapper scripts for build tools
	@echo "Creating wrapper scripts..."
	
	@# Meson Wrapper
	@echo '#!/bin/bash' > $(WRAP_BIN_DIR)/meson
	@echo '# Wrapper for meson to use host meson executable' >> $(WRAP_BIN_DIR)/meson
	@echo 'exec /usr/bin/meson "$$@"' >> $(WRAP_BIN_DIR)/meson
	@chmod +x $(WRAP_BIN_DIR)/meson
	
	@# Ninja Wrapper
	@echo '#!/bin/bash' > $(WRAP_BIN_DIR)/ninja
	@echo '# Wrapper for ninja to use host ninja' >> $(WRAP_BIN_DIR)/ninja
	@echo 'exec /usr/bin/ninja "$$@"' >> $(WRAP_BIN_DIR)/ninja
	@chmod +x $(WRAP_BIN_DIR)/ninja
	
	@# Pkg-config Wrapper
	@echo '#!/bin/bash' > $(WRAP_BIN_DIR)/pkg-config
	@echo '# Wrapper for pkg-config to look in rootfs' >> $(WRAP_BIN_DIR)/pkg-config
	@echo '' >> $(WRAP_BIN_DIR)/pkg-config
	@echo 'ROOT_DIR="$$(cd "$$(dirname "$${BASH_SOURCE[0]}")/../.." && pwd)"' >> $(WRAP_BIN_DIR)/pkg-config
	@echo 'ROOTFS="$$ROOT_DIR/rootfs"' >> $(WRAP_BIN_DIR)/pkg-config
	@echo '' >> $(WRAP_BIN_DIR)/pkg-config
	@echo 'export PKG_CONFIG_DIR=""' >> $(WRAP_BIN_DIR)/pkg-config
	@echo 'export PKG_CONFIG_LIBDIR="$$ROOTFS/usr/lib64/pkgconfig:$$ROOTFS/usr/share/pkgconfig"' >> $(WRAP_BIN_DIR)/pkg-config
	@echo 'export PKG_CONFIG_SYSROOT_DIR="$$ROOTFS"' >> $(WRAP_BIN_DIR)/pkg-config
	@echo '' >> $(WRAP_BIN_DIR)/pkg-config
	@echo 'exec /usr/bin/pkg-config "$$@"' >> $(WRAP_BIN_DIR)/pkg-config
	@chmod +x $(WRAP_BIN_DIR)/pkg-config

clean:
	rm -f $(TARGET)
	rm -rf $(SHIM_DIR)
	rm -rf $(WRAP_BIN_DIR)

.PHONY: all clean setup
