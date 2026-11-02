#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"


# ------------------------------------------------------- version diagnostics ---

VERSION_DIAGNOSTIC="${WORKSPACE}/kernel-version-diagnostic.txt"

# Write a complete diagnostic report. Safe to call before or after compilation.
write_version_diagnostic() {
    local state=${1:-UNKNOWN}
    local reason=${2:-none}
    local release=${3:-not-calculated}
    local file

    mkdir -p "$WORKSPACE"

    {
        echo "========== Kernel Version Diagnostic =========="
        printf 'Status: %s\n' "$state"
        printf 'Reason: %s\n' "$reason"
        printf 'Calculated Release: %s\n' "$release"
        echo

        printf 'Kernel Source: %s\n' "${KERNEL_SOURCE:-unknown}"
        printf 'Kernel Branch: %s\n' "${KERNEL_SOURCE_BRANCH:-unknown}"
        printf 'Kernel Version: %s\n' "${KERNEL_VERSION:-unknown}"
        printf 'Original Commit: %s\n' "${KERNEL_SOURCE_BASE_COMMIT:-not-captured}"
        printf 'Build Snapshot Commit: %s\n' "${KERNEL_SOURCE_BUILD_COMMIT:-not-captured}"
        echo

        printf 'KernelSU Variant: %s\n' "${KSU_VARIANT:-unknown}"
        printf 'KernelSU Ref: %s\n' "${KSU_REF_RESOLVED:-${KSU_REF:-unknown}}"

        if [ -d "${KERNEL_DIR}/${KSU_DIR:-KernelSU}" ]; then
            printf 'KernelSU Commit: '
            git -C "${KERNEL_DIR}/${KSU_DIR:-KernelSU}" rev-parse HEAD 2>/dev/null || true
        fi

        printf 'SUSFS Branch: %s\n' "${SUSFS_BRANCH_RESOLVED:-${SUSFS_BRANCH:-unknown}}"

        if [ -d "${WORKSPACE}/susfs4ksu" ]; then
            printf 'SUSFS Commit: '
            git -C "${WORKSPACE}/susfs4ksu" rev-parse HEAD 2>/dev/null || true
        fi

        echo
        echo "========== Git Status (Tracked Files) =========="
        git -C "$KERNEL_DIR" status --short --untracked-files=no 2>&1 || true

        echo
        echo "========== Git Status (All Files) =============="
        git -C "$KERNEL_DIR" status --short --untracked-files=all 2>&1 || true

        echo
        echo "========== Git Diff Statistics ================="
        git -C "$KERNEL_DIR" diff --stat HEAD 2>&1 || true

        echo
        echo "========== setlocalversion Dirty Check ========="
        sed -n '/# Check for uncommitted changes\./,/^[[:space:]]*# All done with git/p' \
            "${KERNEL_DIR}/scripts/setlocalversion" 2>/dev/null || true

        echo
        echo "========== SCMVERSION =========================="
        if [ -f "${KERNEL_DIR}/.scmversion" ]; then
            cat "${KERNEL_DIR}/.scmversion"
        else
            echo "(absent)"
        fi

        echo
        echo "========== LOCALVERSION ========================"
        printf 'Environment LOCALVERSION: %s\n' "${LOCALVERSION-<unset>}"

        for file in "${KERNEL_DIR}"/localversion* "${OUT}"/localversion*; do
            [ -f "$file" ] || continue
            printf '\n--- %s ---\n' "$file"
            cat "$file"
        done

        echo
        echo "========== Kconfig LOCALVERSION ================"
        grep -E '^CONFIG_LOCALVERSION=|^CONFIG_LOCALVERSION_AUTO=' \
            "${OUT}/.config" 2>/dev/null || true

        echo
        echo "========== Final Result ========================"
        echo "================================================"
    } > "$VERSION_DIAGNOSTIC"
}

# Restore the real Git dirty marker.
# Only the known incorrect placeholder ':' is repaired automatically.
restore_git_dirty_detection() {
    local version_script="${KERNEL_DIR}/scripts/setlocalversion"
    local start_count end_count git_block
    local dirty_count colon_count tmp

    [ -f "$version_script" ] || {
        write_version_diagnostic "FAILED" "setlocalversion missing"
        die "scripts/setlocalversion not found"
    }

    start_count=$(grep -Fc '# Check for uncommitted changes.' "$version_script" || true)
    end_count=$(grep -Fc '# All done with git' "$version_script" || true)

    if [ "$start_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
        write_version_diagnostic "FAILED" "Unknown setlocalversion layout"
        die "unsupported setlocalversion layout"
    fi

    git_block=$(sed -n '/# Check for uncommitted changes\./,/^[[:space:]]*# All done with git/p' "$version_script")

    dirty_count=$(printf '%s\n' "$git_block" | grep -Ec '^[[:space:]]*printf.*-dirty' || true)
    colon_count=$(printf '%s\n' "$git_block" | grep -Ec '^[[:space:]]*:[[:space:]]*$' || true)

    if [ "$dirty_count" -eq 1 ] && [ "$colon_count" -eq 0 ]; then
        info "Git dirty detection is already enabled"

    elif [ "$dirty_count" -eq 0 ] && [ "$colon_count" -eq 1 ]; then
        info "Found disabled Git dirty detection; restoring it"

        tmp=$(mktemp "${version_script}.ksuaction.XXXXXX") || {
            write_version_diagnostic "FAILED" "Cannot create temporary setlocalversion"
            die "cannot create temporary version script"
        }

        if ! awk '
            /# Check for uncommitted changes\./ { in_git = 1 }
            in_git && /^[[:space:]]*:[[:space:]]*$/ {
                indent = $0
                sub(/[^[:space:]].*$/, "", indent)
                print indent "printf '\''%s'\'' -dirty"
                changed++
                next
            }
            { print }
            /^[[:space:]]*# All done with git/ { in_git = 0 }
            END { if (changed != 1) exit 1 }
        ' "$version_script" > "$tmp"; then
            rm -f "$tmp"
            write_version_diagnostic "FAILED" "Cannot restore Git dirty marker"
            die "failed to restore Git dirty detection"
        fi

        chmod --reference="$version_script" "$tmp" || {
            rm -f "$tmp"
            write_version_diagnostic "FAILED" "Cannot preserve script permissions"
            die "cannot preserve setlocalversion permissions"
        }

        mv "$tmp" "$version_script" || {
            rm -f "$tmp"
            write_version_diagnostic "FAILED" "Cannot replace setlocalversion"
            die "cannot update setlocalversion"
        }

        ok "Restored standard printf -dirty detection"

    else
        write_version_diagnostic "FAILED" \
            "Unexpected dirty-check structure: printf=${dirty_count}, colon=${colon_count}"
        die "unexpected setlocalversion dirty-check structure"
    fi

    git_block=$(sed -n '/# Check for uncommitted changes\./,/^[[:space:]]*# All done with git/p' "$version_script")
    dirty_count=$(printf '%s\n' "$git_block" | grep -Ec '^[[:space:]]*printf.*-dirty' || true)
    colon_count=$(printf '%s\n' "$git_block" | grep -Ec '^[[:space:]]*:[[:space:]]*$' || true)

    if [ "$dirty_count" -ne 1 ] || [ "$colon_count" -ne 0 ]; then
        write_version_diagnostic "FAILED" "Dirty marker verification failed"
        die "Git dirty detection restoration verification failed"
    fi

    ok "Git dirty detection verified"
}


# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"
	write_version_diagnostic "STARTED" "Kernel version preflight pending"
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "$DEFCONFIG_PATH" "$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			# patch_linux resolves symbols at runtime, so kallsyms must be complete.
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi

	# Overlayfs backs KernelSU's module mounts and system-partition writes.
	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

	# Kept as a standalone switch for kernels that need kprobes for their own
	# reasons, independent of the hook mode.
	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR

	# Free-form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	# Keep the optional device label independent from Git version suffix handling.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
	fi

	# Restore the real Git dirty detection instead of suppressing it.
	restore_git_dirty_detection

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}


# ------------------------------------------------------ source snapshot ---

create_local_source_snapshot() {
    group "Creating local kernel source snapshot"

    local base_head snapshot ksu_dir path tracked_status
    local actual_target expected_target

    base_head=$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null) || {
        write_version_diagnostic "FAILED" "Cannot read kernel HEAD"
        die "kernel Git HEAD is unavailable"
    }

    export_env KERNEL_SOURCE_BASE_COMMIT "$base_head"

    # Remove only an untracked generated SCM cache.
    # A tracked .scmversion is preserved and verified later.
    if [ -f "${KERNEL_DIR}/.scmversion" ] &&
       ! git -C "$KERNEL_DIR" ls-files --error-unmatch -- .scmversion >/dev/null 2>&1; then
        info "Removing stale generated .scmversion"
        rm -f "${KERNEL_DIR}/.scmversion"
    fi

    # Stage modifications to files already tracked by the kernel repository.
    # Do not use git add -A: KernelSU is an independent nested repository.
    git -C "$KERNEL_DIR" add -u -- . || {
        write_version_diagnostic "FAILED" "Cannot stage tracked source changes"
        die "failed to stage kernel source changes"
    }

    # Explicitly include the SUSFS core files when they are newly copied
    # into a clean kernel source tree.
    for path in \
        fs/susfs.c \
        include/linux/susfs.h \
        include/linux/susfs_def.h
    do
        if [ -f "${KERNEL_DIR}/${path}" ]; then
            git -C "$KERNEL_DIR" add -- "$path" || {
                write_version_diagnostic "FAILED" "Cannot stage ${path}"
                die "failed to stage SUSFS source file: ${path}"
            }
        fi
    done

    # The selected KernelSU tree is an independent Git repository.
    # Keep it separate and record its commit in the diagnostic report.
    ksu_dir=${KSU_DIR:-KernelSU}

    while IFS= read -r path; do
        case "$path" in
            "$ksu_dir" | "$ksu_dir/"*)
                ;;

            drivers/kernelsu)
                # Allow only the expected KernelSU symlink.
                [ -L "${KERNEL_DIR}/drivers/kernelsu" ] || {
                    write_version_diagnostic "FAILED" "KernelSU link is not a symlink"
                    die "invalid drivers/kernelsu path"
                }

                actual_target=$(readlink -f "${KERNEL_DIR}/drivers/kernelsu") || {
                    write_version_diagnostic "FAILED" "Cannot resolve KernelSU symlink"
                    die "cannot resolve drivers/kernelsu"
                }

                expected_target=$(readlink -f "${KERNEL_DIR}/${ksu_dir}/kernel") || {
                    write_version_diagnostic "FAILED" "Cannot resolve KernelSU kernel directory"
                    die "cannot resolve expected KernelSU kernel directory"
                }

                [ -n "$actual_target" ] &&
                [ -n "$expected_target" ] &&
                [ "$actual_target" = "$expected_target" ] || {
                    write_version_diagnostic "FAILED" "KernelSU symlink target mismatch"
                    die "drivers/kernelsu points to an unexpected location"
                }
                ;;

            *)
                write_version_diagnostic "FAILED" "Unexpected untracked kernel path: ${path}"
                die "unexpected untracked source file: ${path}"
                ;;
        esac
    done < <(git -C "$KERNEL_DIR" ls-files --others --exclude-standard)

    # Create a local-only commit if the integration changed the source tree.
    if ! git -C "$KERNEL_DIR" diff --cached --quiet; then
        git -C "$KERNEL_DIR" \
            -c user.name="KSUAction CI" \
            -c user.email="ksuaction-ci@localhost" \
            commit --no-gpg-sign \
            -m "KSUAction: snapshot integrated kernel sources" || {
                write_version_diagnostic "FAILED" "Local source snapshot commit failed"
                die "failed to create local kernel source snapshot"
            }
    fi

    tracked_status=$(git -C "$KERNEL_DIR" status --porcelain --untracked-files=no)

	if [ -n "$tracked_status" ]; then
		write_version_diagnostic "FAILED" "Tracked kernel files remain modified after snapshot"
		die "kernel tracked working tree is not clean after snapshot"
	fi

	snapshot=$(git -C "$KERNEL_DIR" rev-parse HEAD)

	export_env KERNEL_SOURCE_BUILD_COMMIT "$snapshot"

	write_version_diagnostic "SNAPSHOT_READY" "none" "not-calculated"

	ok "Original kernel commit: ${base_head}"
	ok "Local build snapshot: ${snapshot}"
	ok "Tracked kernel working tree is clean"

	summary "| Original kernel commit | \`${base_head}\` |"
	summary "| Local build snapshot | \`${snapshot}\` |"

	endgroup
}


# ------------------------------------------------------ release verification ---

verify_kernel_release() {
    group "Verifying kernel release"

    local release log_file tracked_status

    log_file="${WORKSPACE}/kernelrelease-check.log"

    if ! release=$(make -s O=out ARCH="${ARCH}" kernelrelease 2>"${log_file}"); then
        write_version_diagnostic "FAILED" \
            "make kernelrelease failed: $(cat "$log_file")"
        die "cannot calculate kernel release"
    fi

    release=$(printf '%s\n' "$release" | tail -n1)

    info "Calculated kernel release: ${release}"

    if [[ "$release" == *-dirty* ]]; then
        write_version_diagnostic "FAILED" \
            "Unexpected -dirty suffix detected" "$release"

        die "kernel release contains -dirty; diagnostic report generated"
    fi

    tracked_status=$(git -C "$KERNEL_DIR" status --porcelain --untracked-files=no)

    if [ -n "$tracked_status" ]; then
        write_version_diagnostic "FAILED" \
            "Tracked source changed after snapshot" "$release"

        die "kernel source changed after local snapshot"
    fi

    export_env KERNEL_RELEASE "$release"

    write_version_diagnostic "PREBUILD_PASS" "none" "$release"

	ok "Kernel release verified: ${release}"
	summary "| Pre-build kernel release | \`${release}\` |"

	endgroup
}


# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}"  ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}"      ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}"      ] && printf ' %s' "$GCC_32"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
		[ -n "${GCC_64:-}" ] || printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}
	# DISABLE_LTO is this action's boolean configuration switch, but several
	# Android kernel trees use the same Make variable for compiler flags (for
	# example, "-fno-lto").  Leaving our value in the environment makes a
	# non-LTO build invoke `clang ... false ...`, treating "false" as an input
	# file.  prepare_defconfig() has already consumed the action setting, so let
	# Kbuild own the name from this point on.
	unset DISABLE_LTO

	# Custom manager signature, when the user builds their own manager APK.
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	local cc="clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	cd "$KERNEL_DIR"

	# Snapshot all source integration changes before Kbuild starts.
	create_local_source_snapshot

	info "make ${args} ${KERNEL_CONFIG}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC=clang $args "${KERNEL_CONFIG}" || {
		write_version_diagnostic "FAILED" \
			"defconfig generation failed" "${KERNEL_RELEASE:-not-calculated}"
		die "defconfig generation failed"
	}

	# Calculate and verify the actual kernel release before compilation.
	verify_kernel_release
	group "Final SUSFS configuration"

	if [ -f "${OUT}/.config" ]; then
		grep -E '^(CONFIG_KSU_SUSFS[A-Z_]*=|# CONFIG_KSU_SUSFS[A-Z_]* is not set)' \
			"${OUT}/.config" || true

		info "SUSFS enabled count: $(grep -cE '^CONFIG_KSU_SUSFS[A-Z_]*=y$' "${OUT}/.config" || true)"
		info "SUSFS disabled count: $(grep -cE '^# CONFIG_KSU_SUSFS[A-Z_]* is not set$' "${OUT}/.config" || true)"
	else
		warn "Final .config not found; cannot verify SUSFS options"
	fi

	endgroup

	info "make ${args}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args || {
		write_version_diagnostic "FAILED" \
			"kernel build failed" "${KERNEL_RELEASE:-not-calculated}"
		die "kernel build failed"
	}

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || {
		write_version_diagnostic "FAILED" "expected kernel image not found: ${image}"
		die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."
	}

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] || die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	# KPM rewrites the image in place, so it has to happen after the build and
	# before packaging.
	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	# Record and verify the release string actually compiled into the kernel.
	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel

		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' \
			"${OUT}/include/generated/utsrelease.h")

		if [[ "$rel" == *-dirty* ]]; then
			write_version_diagnostic "FAILED" \
				"Final UTS_RELEASE contains -dirty" "$rel"

			die "compiled kernel contains unexpected -dirty suffix"
		fi

		if [ -n "${KERNEL_RELEASE:-}" ] && [ "$rel" != "$KERNEL_RELEASE" ]; then
			write_version_diagnostic "FAILED" \
				"Pre-build and final kernel release mismatch" "$rel"

			die "final kernel release differs from pre-build verification"
		fi

		export_env KERNEL_RELEASE "$rel"

		write_version_diagnostic "PASS" "none" "$rel"

		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	else
		write_version_diagnostic "FAILED" "Final UTS_RELEASE header not found: ${OUT}/include/generated/utsrelease.h"
		die "final kernel UTS_RELEASE header not found"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
