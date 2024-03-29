# SPDX-License-Identifier: Apache-2.0

# Load a `.env` file if present
set dotenv-load

source_dir := env("KERNEL_SOURCE_DIR", justfile_directory() / "linux")
busybox_version := env("KERNEL_BUSYBOX", "1.35.0-x86_64-linux-musl")
# By default we use the gitignored `linux` directory within the repo to store
# Our busybox downloads and config files
stash_dir := env("KERNEL_STASH_DIR", source_dir / "linux")
qemu := env("KERNEL_QEMU", "qemu-system-x86_64")

# These CONFIX_X flags don't seem to do anything...
default_make_args := env("KERNEL_DEFAULT_MAKE_FLAGS", "\
	LLVM=y \
	CONFIG_MODULES=y \
	CONFIG_RUST=y \
	CONFIG_SAMPLES=y \
	CONFIG_SAMPLES_RUST=y \
")

# Print available commands and exit
default:
	@echo os: {{os()}} arch: {{arch()}}
	just --list

# Configure the Rust toolchain
rustavailable:
	make -C "{{source_dir}}" {{default_make_args}} rustavailable

# Configure rust-analyzer
rust-analyzer *extra_args:
	make -C "{{source_dir}}" {{default_make_args}} rust-analyzer {{extra_args}}

# Shortcut for `make menuconfig`
menuconfig *extra_args: rustavailable
	make -C "{{source_dir}}" {{default_make_args}} menuconfig {{extra_args}}

# Shortcut for `make defaultconfig`
defaultconfig *extra_args: rustavailable
	make -C "{{source_dir}}" {{default_make_args}} defaultconfig {{extra_args}}

# Run the build
build *extra_args: rustavailable
	make -C "{{source_dir}}" {{default_make_args}} "-j$(nproc)" {{extra_args}}

# Run the build with clippy
clippy *extra_args: rustavailable
	make -C "{{source_dir}}" {{default_make_args}} CLIPPY=y "-j$(nproc)" {{extra_args}}

# Just run make from the correct directory
make *args:
	make -C "{{source_dir}}"

# Clean the git directory, only removing excluded files (ignores .config)
clean:
	git -C "{{source_dir}}" clean -dfX \
	    --exclude "{{source_dir}}/linux" \
	    --exclude "{{source_dir}}/.config" \
	    --exclude "{{source_dir}}/rust-project.json"

# Run rustfmt
fmt:
	make -C "{{source_dir}}" {{default_make_args}} rustfmt "-j$(nproc)"

# Set the correct toolchain for the directory
rustup-override:
	#!/bin/sh
	cd "{{source_dir}}"
	rustup override set $("{{source_dir}}/scripts/min-tool-version.sh" rustc)
	rustup component add rust-src

# Make the linux directory where we store 
_stash_dir:
	mkdir -p "{{stash_dir}}"

# Download busybox
get-busybox: _stash_dir
	#!/bin/sh
	set -eau

	if ! [ -f "{{stash_dir}}/busybox" ]; then
		echo downloading busybox...
		wget "https://www.busybox.net/downloads/binaries/{{busybox_version}}/busybox" -P "{{stash_dir}}"
	else
		echo busybox found, skipping
	fi

# Setup files needed to create initramfs. Locates all Rust loadable modules.
setup-initramfs: build _stash_dir
	#!/bin/sh
	set -eaux

	qemu_ramfs="{{stash_dir}}/qemu-initramfs.desc"
	qemu_init="{{stash_dir}}/qemu-init.sh"

	# Set up file preludes
	cat << EOF > "$qemu_ramfs"
	dir     /bin                                          0755 0 0
	dir     /sys                                          0755 0 0
	dir     /dev                                          0755 0 0
	file    /bin/busybox  {{stash_dir}}/busybox           0755 0 0
	slink   /bin/sh       /bin/busybox                    0755 0 0
	file    /init         {{stash_dir}}/qemu-init.sh      0755 0 0

	EOF

	printf '#!/bin/sh\n\n' > "$qemu_init"

	# Just find any kernel modules with rust in the name and load them
	# Probably pretty weak, but works for now...
	find "{{source_dir}}" -name '*.ko' | grep rust | while read -r ko_path; do
		ko_name=$(basename "$ko_path")

		# Add the initramfs entry
		echo "file /${ko_name} ${ko_path#} 0755 0 0" >> "$qemu_ramfs"

		# Add shell scripts 
		cat <<- EOF >> "$qemu_init"
			busybox insmod $ko_path
			busybox  rmmod $ko_path

		EOF
	done

	# Finish up files
	cat <<- 'EOF' >> "$qemu_init"
		echo QEMU entrypoint

		# Install busybox command aliases. There has to be a better way...
		/bin/busybox --list | while read -r cmd; do
			outpath="/bin/$cmd"
			if [ -f "$outpat" ]; then
				continue
			fi

			printf "#!/bin/sh\nbusybox $cmd \$@ <&0 \n" > "$outpath"
			busybox chmod +x "$outpath"
		done

		echo Kernel version: $(uname -r)
		echo 'ctrl-a x' to exit. Modules are located at '/*.ko'.

		exec /bin/sh
		busybox reboot -f
	EOF

# Create an initramfs image
build-initramfs: build setup-initramfs get-busybox
	"{{source_dir}}/usr/gen_init_cpio" "{{stash_dir}}/qemu-initramfs.desc" >\
		"{{stash_dir}}/qemu-initramfs.img"

# Run the built kernel in qemu
run-qemu *OPTIONS="": build-initramfs
	#!/bin/sh
	set -eau

	help='Usage:
	just run-qemu [OPTIONS]

	OPTIONS:
	  --debug: run qemu with -s -S to allow attaching a debugger
	'

	for arg in {{OPTIONS}}; do
		echo $arg
		case "$arg" in
			--gdb)
				extra_args="-s -S"
				;;
			*)
				echo "$help"
				exit
				;;
		esac
	done

	{{qemu}} \
		-kernel "{{source_dir}}/arch/x86/boot/bzImage" \
		-initrd "{{stash_dir}}/qemu-initramfs.img" \
		-M pc \
		-m 4G \
		-cpu Cascadelake-Server \
		-smp $(nproc) \
		-nographic \
		-vga none \
		-no-reboot \
		-append 'console=ttyS0 nokaslr' \
		${extra_args:-}

# Attach GDB to qemu (`just run-qemu --debug` must already be running)
debug *DEBUGGER_ARGS:
	gdb "{{source_dir}}/vmlinux" -ex 'target remote localhost:1234' {{DEBUGGER_ARGS}}
