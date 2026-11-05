#!/bin/sh

VMCTL_VERSION=0.1.0
STATE_DIR=${VMCTL_STATE_DIR:-$VMCTL_ROOT/.vmctl}
RUNTIME_DIR=${VMCTL_RUNTIME_DIR:-$VMCTL_ROOT/runtime}
IMAGES_DIR=$STATE_DIR/images
IMAGE_OBJECTS_DIR=$IMAGES_DIR/objects
IMAGE_REFS_DIR=$IMAGES_DIR/refs
INSTANCES_DIR=$STATE_DIR/instances
SSH_DIR=$STATE_DIR/ssh
TMP_DIR=$STATE_DIR/tmp
LOCKS_DIR=$STATE_DIR/locks

TAB=$(printf '\t')
NL='
'

say() { printf '%s\n' "$*"; }
info() { printf 'info: %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
vmctl - portable Ubuntu virtual machine manager

Usage:
  vmctl doctor
  vmctl image pull [22.04|24.04]
  vmctl image list
  vmctl create NAME [options]
  vmctl start NAME
  vmctl stop NAME [--force]
  vmctl restart NAME [--force]
  vmctl resize NAME (--cpus N | --memory MIB | --memory-max MIB | --disk GIB)
  vmctl status [NAME]
  vmctl list
  vmctl ssh NAME [-- COMMAND...]
  vmctl logs NAME
  vmctl delete NAME [--yes]
  vmctl share add NAME --source PATH [--target PATH] [--read-write]
  vmctl share list NAME
  vmctl share remove NAME --target PATH

Create options:
  --ubuntu VERSION        24.04 (default) or 22.04
  --cpus N                vCPU count (default: 2)
  --memory MIB            RAM in MiB (default: 2048)
  --memory-max MIB        balloon ceiling (default: initial RAM; allocated at boot)
  --disk GIB              virtual disk size in GiB (default: 20)
  --ssh-port PORT|auto    host SSH port (default: auto)
  --forward SPEC          tcp:HOST_PORT:GUEST_PORT; repeatable
  --bind IPV4             forwarding bind address (default: 127.0.0.1)
  --share SPEC            HOST[:GUEST[:ro|rw]]; repeatable
  --strict-kvm            fail instead of falling back to TCG
  --no-start              create without starting

Resize accepts one resource per call and persists successful changes.
Running VM: CPU increase only; memory balloon target <= boot ceiling; disk grow only.
Stopped VM: CPU/memory changes; --memory-max changes; disk grow only.
Balloon targets are asynchronous. Disk partitions/filesystems need Guest-side growth.
EOF
}

init_state() {
    umask 077
    mkdir -p "$IMAGE_OBJECTS_DIR" "$IMAGE_REFS_DIR" "$INSTANCES_DIR" \
        "$SSH_DIR" "$TMP_DIR" "$LOCKS_DIR"
}

tool_path() {
    local name
    name=$1
    if [ -x "$RUNTIME_DIR/bin/$name" ]; then
        printf '%s\n' "$RUNTIME_DIR/bin/$name"
        return 0
    fi
    if [ "${VMCTL_ALLOW_HOST_TOOLS:-0}" = 1 ]; then
        command -v "$name" 2>/dev/null && return 0
    fi
    return 1
}

need_tool() {
    local name path
    name=$1
    path=$(tool_path "$name") || die "portable runtime is missing '$name'; run tools/build-runtime.sh"
    printf '%s\n' "$path"
}

has_tool() {
    tool_path "$1" >/dev/null 2>&1
}

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_range() {
    local label value min max
    label=$1 value=$2 min=$3 max=$4
    is_uint "$value" || die "$label must be an integer"
    [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] ||
        die "$label must be between $min and $max"
}

validate_name() {
    local name
    name=${1:-}
    [ -n "$name" ] || die "instance name is required"
    [ "${#name}" -le 63 ] || die "instance name must be at most 63 characters"
    case "$name" in
        [A-Za-z0-9]*)
            case "$name" in *[!A-Za-z0-9._-]*) die "invalid instance name: $name" ;; esac
            ;;
        *) die "instance name must begin with a letter or digit" ;;
    esac
}

validate_text_field() {
    local label value
    label=$1 value=$2
    case "$value" in
        *"$TAB"*|*"$NL"*) die "$label may not contain tabs or newlines" ;;
    esac
}

instance_dir() {
    local name
    name=$1
    validate_name "$name"
    printf '%s/%s\n' "$INSTANCES_DIR" "$name"
}

require_instance() {
    local dir
    dir=$(instance_dir "$1")
    [ -d "$dir" ] || die "instance '$1' does not exist"
    printf '%s\n' "$dir"
}

config_get_file() {
    local file wanted key value
    file=$1 wanted=$2
    [ -f "$file" ] || return 1
    while IFS="$TAB" read -r key value; do
        if [ "$key" = "$wanted" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$file"
    return 1
}

config_get() {
    config_get_file "$1/config.tsv" "$2"
}

config_put_line() {
    local key value
    key=$1 value=$2
    validate_text_field "$key" "$value"
    printf '%s\t%s\n' "$key" "$value"
}

# Replace one non-executable configuration record atomically.
config_set() {
    local dir key value tmp
    dir=$1 key=$2 value=$3
    validate_text_field "$key" "$value"
    tmp=$dir/config.tsv.tmp.$$
    awk -F "$TAB" -v key="$key" '$1 != key' "$dir/config.tsv" > "$tmp"
    config_put_line "$key" "$value" >> "$tmp"
    mv "$tmp" "$dir/config.tsv"
}

# QMP emits one JSON object per line. Correlate the response by ID so greetings,
# events and the capability response cannot be mistaken for command success.
qmp_request() {
    local dir command arguments socat_bin output response
    dir=$1 command=$2 arguments=$3
    [ -S "$dir/qmp.sock" ] ||
        { [ "${VMCTL_TESTING:-0}" = 1 ] && [ -e "$dir/qmp.sock" ]; } || {
        warn "QMP socket unavailable; restart the instance"
        return 1
    }
    socat_bin=$(need_tool socat)
    output=$(printf '%s\n%s\n' \
        '{"execute":"qmp_capabilities","id":"vmctl-capabilities"}' \
        "{\"execute\":\"$command\",\"arguments\":$arguments,\"id\":\"vmctl-command\"}" |
        "$socat_bin" -t 2 -T 5 - "UNIX-CONNECT:$dir/qmp.sock" 2>&1) || {
        warn "QMP transport failed; inspect live state before retrying: $output"
        return 1
    }
    response=$(printf '%s\n' "$output" | grep '"id"[[:space:]]*:[[:space:]]*"vmctl-command"' || true)
    if ! printf '%s\n' "$response" | grep -q '"return"[[:space:]]*:' ||
        printf '%s\n' "$response" | grep -q '"error"[[:space:]]*:'; then
        warn "QMP $command failed or returned no acknowledgement: $output"
        return 1
    fi
}

cmd_resize() {
    local name option value dir state key old ceiling driver index cpu_limit
    name=${1:-}
    [ "$#" -eq 3 ] || die "usage: vmctl resize NAME (--cpus N | --memory MIB | --memory-max MIB | --disk GIB)"
    option=$2 value=$3
    case "$option" in
        --cpus) key=cpus; validate_range CPU "$value" 1 256 ;;
        --memory) key=memory_mib; validate_range memory "$value" 256 1048576 ;;
        --memory-max) key=memory_max_mib; validate_range "memory ceiling" "$value" 256 1048576 ;;
        --disk) key=disk_gib; validate_range disk "$value" 2 1048576 ;;
        *) die "unknown resize option: $option" ;;
    esac
    value=$(printf '%s\n' "$value" | sed 's/^0*//')
    init_state
    dir=$(require_instance "$name")
    acquire_lock "instance-$name"
    state=$(instance_state "$dir")
    old=$(config_get "$dir" "$key" || true)
    if [ "$option" = --disk ] && [ "$value" -lt "$old" ]; then
        die "disk shrinking is not supported"
    fi
    if [ "$option" = --memory-max ]; then
        [ "$state" = stopped ] || die "changing the memory ceiling requires a stopped instance"
        [ "$value" -ge "$(config_get "$dir" memory_mib)" ] || die "memory ceiling must be at least the configured memory"
    fi
    if [ "$old" = "$value" ]; then
        release_lock
        info "resource already configured at $value"
        return
    fi
    if [ "$state" = stopped ]; then
        if [ "$option" = --disk ]; then
            "$(need_tool qemu-img)" resize -q "$dir/disk.qcow2" "${value}G" || die "disk resize failed; configuration unchanged"
        elif [ "$option" = --memory ]; then
            ceiling=$(config_get "$dir" memory_max_mib || printf '%s\n' "$old")
            if [ "$value" -gt "$ceiling" ]; then config_set "$dir" memory_max_mib "$value"; fi
        fi
        config_set "$dir" "$key" "$value"
    else
        case "$option" in
            --cpus)
                [ "$value" -gt "$old" ] || die "reducing CPU count requires a stopped instance"
                driver=$(config_get_file "$dir/resources.tsv" cpu_driver || true)
                case "$driver" in host-x86_64-cpu|max-x86_64-cpu) ;; *) die "restart instance once to enable CPU hotplug" ;; esac
                cpu_limit=$(config_get_file "$dir/resources.tsv" cpu_max || true)
                [ -n "$cpu_limit" ] && [ "$value" -le "$cpu_limit" ] ||
                    die "CPU target exceeds the boot hotplug ceiling; stop the instance to set this count"
                index=$old
                while [ "$index" -lt "$value" ]; do
                    qmp_request "$dir" device_add "{\"driver\":\"$driver\",\"id\":\"cpu$index\",\"socket-id\":$index,\"core-id\":0,\"thread-id\":0}" ||
                        die "CPU hotplug failed; earlier successful additions are saved; inspect live state before retrying"
                    index=$((index + 1))
                    config_set "$dir" cpus "$index"
                done
                info "CPUs attached; Guest must online the new CPUs if it does not do so automatically"
                ;;
            --memory)
                ceiling=$(config_get_file "$dir/resources.tsv" memory_max_mib || true)
                [ -n "$ceiling" ] || die "restart instance once to enable memory ballooning"
                [ "$value" -le "$ceiling" ] || die "memory exceeds boot ceiling ${ceiling} MiB; stop and increase --memory-max first"
                qmp_request "$dir" balloon "{\"value\":$((value * 1048576))}" || die "balloon request failed; configuration unchanged"
                config_set "$dir" "$key" "$value"
                info "memory target accepted; balloon adjustment is asynchronous and depends on the Guest driver"
                ;;
            --disk)
                qmp_request "$dir" block_resize "{\"device\":\"root\",\"size\":$((value * 1073741824))}" || die "disk resize failed; configuration unchanged"
                config_set "$dir" "$key" "$value"
                ;;
        esac
    fi
    release_lock
    info "$name: $key set to $value"
    if [ "$option" = --disk ]; then
        info "disk image expanded; grow the partition and filesystem inside the Guest to use the space"
    fi
}

acquire_lock() {
    local lock attempts
    lock=$LOCKS_DIR/$1.lock
    attempts=0
    while ! mkdir "$lock" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 10 ] || die "timed out waiting for lock '$1'"
        sleep 1
    done
    ACTIVE_LOCK=$lock
    export ACTIVE_LOCK
}

release_lock() {
    if [ -n "${ACTIVE_LOCK:-}" ] && [ -d "$ACTIVE_LOCK" ]; then
        rmdir "$ACTIVE_LOCK" 2>/dev/null || true
    fi
    ACTIVE_LOCK=
}

cleanup_on_exit() {
    release_lock
    if [ -n "${ACTIVE_VIRTIOFS_DIR:-}" ] && [ -d "$ACTIVE_VIRTIOFS_DIR" ]; then
        cleanup_virtiofs "$ACTIVE_VIRTIOFS_DIR"
    fi
    if [ -n "${ACTIVE_CREATE_DIR:-}" ] && [ -d "$ACTIVE_CREATE_DIR" ]; then
        rm -rf "$ACTIVE_CREATE_DIR"
    fi
}

trap cleanup_on_exit EXIT HUP INT TERM

canonical_dir() {
    local path realpath_bin
    path=$1
    [ -d "$path" ] || die "shared source is not a directory: $path"
    realpath_bin=$(need_tool realpath)
    "$realpath_bin" "$path"
}

path_overlaps() {
    local left right
    left=$1 right=$2
    case "$left/" in "$right/"*) return 0 ;; esac
    case "$right/" in "$left/"*) return 0 ;; esac
    return 1
}

validate_share_source() {
    local source root state runtime
    source=$1
    root=$(canonical_dir "$VMCTL_ROOT")
    state=$(canonical_dir "$STATE_DIR")
    runtime=
    [ ! -d "$RUNTIME_DIR" ] || runtime=$(canonical_dir "$RUNTIME_DIR")

    path_overlaps "$source" "$state" &&
        die "refusing to share vmctl state, its contents, or a parent directory"
    if [ -n "$runtime" ] && path_overlaps "$source" "$runtime"; then
        die "refusing to share the portable runtime, its contents, or a parent directory"
    fi
    [ "$source" != "$root" ] ||
        die "refusing to share the project root because it contains VM credentials and state"
}

validate_guest_target() {
    local target
    target=$1
    validate_text_field "guest mount target" "$target"
    case "$target" in /*) ;; *) die "guest mount target must be an absolute path" ;; esac
    case "$target/" in
        //*|/etc/*|/usr/*|/boot/*|/var/lib/cloud/*)
            die "unsafe guest mount target: $target"
            ;;
    esac
    case "$target" in
        *[!A-Za-z0-9/._-]*) die "guest mount target contains unsupported characters: $target" ;;
    esac
}

portable_source_record() {
    local source root
    source=$1
    root=$(canonical_dir "$VMCTL_ROOT")
    case "$source" in
        "$root"/*)
            printf 'relative\t%s\n' "${source#"$root"/}"
            ;;
        *)
            printf 'absolute\t%s\n' "$source"
            ;;
    esac
}

resolve_source_record() {
    local kind value
    kind=$1 value=$2
    case "$kind" in
        relative) canonical_dir "$VMCTL_ROOT/$value" ;;
        absolute) canonical_dir "$value" ;;
        *) die "invalid stored share path kind: $kind" ;;
    esac
}

share_default_target() {
    local source base safe
    source=$1
    base=${source##*/}
    [ -n "$base" ] || base=share
    safe=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')
    printf '/mnt/%s\n' "$safe"
}

share_next_id() {
    local file index candidate
    file=$1 index=0
    while [ "$index" -lt 256 ]; do
        candidate=fs$index
        if [ ! -f "$file" ] || ! awk -F "$TAB" -v id="$candidate" '$1 == id { found=1 } END { exit found ? 0 : 1 }' "$file"; then
            printf '%s\n' "$candidate"
            return
        fi
        index=$((index + 1))
    done
    die "too many shares for one instance"
}

share_add_record() {
    local dir source_input target_input mode source target file id record kind value
    dir=$1 source_input=$2 target_input=${3:-} mode=${4:-ro}
    validate_text_field "shared source" "$source_input"
    case "$mode" in ro|rw) ;; *) die "share mode must be ro or rw" ;; esac
    case "$source_input" in
        /*) source=$(canonical_dir "$source_input") ;;
        *) source=$(canonical_dir "$VMCTL_ROOT/$source_input") ;;
    esac
    validate_share_source "$source"
    target=${target_input:-$(share_default_target "$source")}
    validate_guest_target "$target"
    file=$dir/shares.tsv
    if [ -f "$file" ] && awk -F "$TAB" -v target="$target" '$4 == target { found=1 } END { exit found ? 0 : 1 }' "$file"; then
        die "guest mount target is already configured: $target"
    fi
    id=$(share_next_id "$file")
    record=$(portable_source_record "$source")
    kind=${record%%"$TAB"*}
    value=${record#*"$TAB"}
    validate_text_field "shared source" "$value"
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$value" "$target" "$mode" >> "$file"
    if [ "$mode" = rw ]; then
        warn "read-write share '$source' lets the guest modify host files"
    fi
}

parse_share_spec() {
    local spec mode source target
    spec=$1
    validate_text_field "share specification" "$spec"
    mode=ro
    case "$spec" in
        *:rw) mode=rw; spec=${spec%:rw} ;;
        *:ro) mode=ro; spec=${spec%:ro} ;;
    esac
    case "$spec" in
        *:/*)
            source=${spec%%:/*}
            target=/${spec#*:\/}
            ;;
        *)
            source=$spec
            target=
            ;;
    esac
    [ -n "$source" ] || die "share source is empty"
    printf '%s\t%s\t%s\n' "$source" "$target" "$mode"
}

pid_is_running() {
    local dir pid cmdline
    dir=$1
    [ -s "$dir/qemu.pid" ] || return 1
    pid=$(sed -n '1p' "$dir/qemu.pid")
    is_uint "$pid" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [ "${VMCTL_TESTING:-0}" != 1 ] && [ -r "/proc/$pid/cmdline" ]; then
        cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline")
        case "$cmdline" in *"$dir/disk.qcow2"*) ;; *) return 1 ;; esac
    fi
    return 0
}

instance_state() {
    local dir pid id _kind _value _target _mode vpid
    dir=$1
    if ! pid_is_running "$dir"; then
        printf 'stopped\n'
        return
    fi
    if [ -s "$dir/shares.tsv" ]; then
        while IFS="$TAB" read -r id _kind _value _target _mode; do
            [ -n "$id" ] || continue
            if [ ! -s "$dir/virtiofs-$id.pid" ]; then
                printf 'degraded\n'
                return
            fi
            vpid=$(sed -n '1p' "$dir/virtiofs-$id.pid")
            if ! is_uint "$vpid" || ! kill -0 "$vpid" 2>/dev/null; then
                printf 'degraded\n'
                return
            fi
        done < "$dir/shares.tsv"
    fi
    printf 'running\n'
}

require_stopped() {
    local dir state
    dir=$1
    state=$(instance_state "$dir")
    [ "$state" = stopped ] || die "instance must be stopped (current state: $state)"
}

vmctl_main() {
    local command
    command=${1:-help}
    [ "$#" -eq 0 ] || shift
    case "$command" in
        help|-h|--help) usage ;;
        version|--version) say "vmctl $VMCTL_VERSION" ;;
        doctor) cmd_doctor "$@" ;;
        image) cmd_image "$@" ;;
        create) cmd_create "$@" ;;
        start) cmd_start "$@" ;;
        stop) cmd_stop "$@" ;;
        restart) cmd_restart "$@" ;;
        resize) cmd_resize "$@" ;;
        status) cmd_status "$@" ;;
        list) cmd_list "$@" ;;
        ssh) cmd_ssh "$@" ;;
        logs) cmd_logs "$@" ;;
        delete) cmd_delete "$@" ;;
        share) cmd_share "$@" ;;
        *) usage >&2; die "unknown command: $command" ;;
    esac
}

doctor_row() {
    local label status detail
    label=$1 status=$2 detail=$3
    printf '%-18s %-8s %s\n' "$label" "$status" "$detail"
}

userns_available() {
    local unshare_bin
    unshare_bin=$(tool_path unshare) || return 1
    "$unshare_bin" -Ur true >/dev/null 2>&1
}

cmd_doctor() {
    local failures arch required name path kvm_detail userns_detail free_kib curl_bin
    local kernel virtiofs_bin virtiofs_help
    [ "$#" -eq 0 ] || die "doctor takes no arguments"
    init_state
    failures=0
    arch=$(uname -m)
    if [ "$arch" = x86_64 ] || [ "$arch" = amd64 ]; then
        doctor_row architecture ok "$arch"
    else
        doctor_row architecture failed "$arch (x86_64 required)"
        failures=$((failures + 1))
    fi

    kernel=$(uname -sr)
    if [ "$(uname -s)" = Linux ]; then
        doctor_row kernel ok "$kernel"
    else
        doctor_row kernel failed "$kernel (Linux required)"
        failures=$((failures + 1))
    fi

    required='busybox qemu-system-x86_64 qemu-img virtiofsd curl gpgv xorriso ssh ssh-keygen socat unshare realpath'
    for name in $required; do
        if path=$(tool_path "$name"); then
            doctor_row "runtime/$name" ok "$path"
        else
            doctor_row "runtime/$name" failed "missing"
            failures=$((failures + 1))
        fi
    done

    if [ -f "$RUNTIME_DIR/SHA256SUMS" ]; then
        if (cd "$RUNTIME_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
            doctor_row runtime-integrity ok "all bundled files match SHA-256 manifest"
        else
            doctor_row runtime-integrity failed "bundled file checksum mismatch"
            failures=$((failures + 1))
        fi
    else
        doctor_row runtime-integrity failed "runtime/SHA256SUMS is missing"
        failures=$((failures + 1))
    fi

    virtiofs_bin=$(tool_path virtiofsd 2>/dev/null || true)
    virtiofs_help=
    [ -z "$virtiofs_bin" ] || virtiofs_help=$("$virtiofs_bin" --help 2>&1 || true)
    for name in --socket-path --shared-dir --sandbox --readonly --translate-uid --translate-gid; do
        case "$virtiofs_help" in *"$name"*) ;; *) virtiofs_help= ;; esac
        [ -n "$virtiofs_help" ] || break
    done
    if [ -n "$virtiofs_help" ]; then
        doctor_row virtiofs ok "sandbox, read-only, and UID/GID translation available"
    else
        doctor_row virtiofs failed "bundled virtiofsd lacks required capabilities"
        failures=$((failures + 1))
    fi

    if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        kvm_detail="/dev/kvm is accessible"
        doctor_row kvm ok "$kvm_detail"
    elif [ -e /dev/kvm ]; then
        doctor_row kvm warning "/dev/kvm exists but is not accessible; TCG fallback will be used"
    else
        doctor_row kvm warning "/dev/kvm is absent; TCG fallback will be used"
    fi

    if userns_available; then
        userns_detail="rootless VirtioFS sandbox is available"
        doctor_row user-namespace ok "$userns_detail"
    else
        doctor_row user-namespace warning "directory sharing is unavailable without unprivileged user namespaces"
    fi

    free_kib=$(df -Pk "$STATE_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
    if is_uint "${free_kib:-}" && [ "$free_kib" -ge 2097152 ]; then
        doctor_row disk-space ok "$((free_kib / 1024)) MiB free"
    else
        doctor_row disk-space warning "${free_kib:-unknown} KiB free; at least 2 GiB is recommended"
    fi

    if curl_bin=$(tool_path curl); then
        if "$curl_bin" --silent --show-error --fail --head --max-time 8 \
            --proto '=https' https://cloud-images.ubuntu.com/ >/dev/null 2>&1; then
            doctor_row network ok "Ubuntu cloud image service reachable"
        else
            doctor_row network warning "offline or Ubuntu cloud image service unreachable"
        fi
    fi

    [ "$failures" -eq 0 ] || return 1
}

ubuntu_release_info() {
    local version
    version=$1
    case "$version" in
        24.04)
            printf '%s\t%s\t%s\n' noble \
                https://cloud-images.ubuntu.com/releases/noble/release \
                ubuntu-24.04-server-cloudimg-amd64.img
            ;;
        22.04)
            printf '%s\t%s\t%s\n' jammy \
                https://cloud-images.ubuntu.com/releases/jammy/release \
                ubuntu-22.04-server-cloudimg-amd64.img
            ;;
        *) die "unsupported Ubuntu version: $version (expected 22.04 or 24.04)" ;;
    esac
}

download_file() {
    local url output curl_bin
    url=$1 output=$2
    curl_bin=$(need_tool curl)
    "$curl_bin" --fail --location --retry 3 --retry-delay 2 \
        --proto '=https' --tlsv1.2 --output "$output" "$url"
}

image_pull() {
    local version release base filename tmp keyring gpgv_bin expected actual object ref
    version=$1
    init_state
    acquire_lock "image-$version"
    release=$(ubuntu_release_info "$version")
    base=$(printf '%s' "$release" | awk -F "$TAB" '{print $2}')
    filename=$(printf '%s' "$release" | awk -F "$TAB" '{print $3}')
    tmp=$TMP_DIR/image-$version-$$
    rm -rf "$tmp"
    mkdir -p "$tmp"
    info "downloading signed image metadata for Ubuntu $version"
    download_file "$base/SHA256SUMS" "$tmp/SHA256SUMS"
    download_file "$base/SHA256SUMS.gpg" "$tmp/SHA256SUMS.gpg"
    keyring=$RUNTIME_DIR/share/keyrings/ubuntu-cloudimage-keyring.gpg
    [ -r "$keyring" ] || die "portable runtime is missing the Ubuntu cloud image signing keyring"
    gpgv_bin=$(need_tool gpgv)
    "$gpgv_bin" --keyring "$keyring" "$tmp/SHA256SUMS.gpg" "$tmp/SHA256SUMS" ||
        die "Ubuntu image checksum signature verification failed"
    expected=$(awk -v file="$filename" '$2 == "*" file || $2 == file { print $1; exit }' "$tmp/SHA256SUMS")
    [ -n "$expected" ] || die "official checksum list does not contain $filename"
    object=$IMAGE_OBJECTS_DIR/$expected.img
    if [ ! -f "$object" ]; then
        info "downloading Ubuntu $version cloud image"
        download_file "$base/$filename" "$tmp/$filename.part"
        actual=$(sha256sum "$tmp/$filename.part" | awk '{print $1}')
        [ "$actual" = "$expected" ] || die "image SHA-256 mismatch: expected $expected, got $actual"
        mv "$tmp/$filename.part" "$object"
        chmod 0444 "$object"
    else
        info "verified image is already cached"
    fi
    printf '%s\n' "$expected" > "$IMAGE_REFS_DIR/$version"
    rm -rf "$tmp"
    release_lock
    say "$version $expected"
}

image_ref() {
    local version ref sha object
    version=$1
    ref=$IMAGE_REFS_DIR/$version
    if [ ! -s "$ref" ]; then
        image_pull "$version" >/dev/null
    fi
    sha=$(sed -n '1p' "$ref")
    case "$sha" in ''|*[!0-9a-f]*) die "invalid cached image reference for Ubuntu $version" ;; esac
    object=$IMAGE_OBJECTS_DIR/$sha.img
    [ -f "$object" ] || die "cached image object is missing for Ubuntu $version; run 'vmctl image pull $version'"
    printf '%s\n' "$sha"
}

cmd_image() {
    local sub version versions ref sha object size
    sub=${1:-}
    [ "$#" -eq 0 ] || shift
    case "$sub" in
        pull)
            version=${1:-24.04}
            [ "$#" -le 1 ] || die "usage: vmctl image pull [22.04|24.04]"
            ubuntu_release_info "$version" >/dev/null
            image_pull "$version"
            ;;
        list)
            version=${1:-}
            [ "$#" -le 1 ] || die "usage: vmctl image list [22.04|24.04]"
            if [ -n "$version" ]; then
                ubuntu_release_info "$version" >/dev/null
                versions=$version
            else
                versions='24.04 22.04'
            fi
            init_state
            printf '%-8s %-64s %s\n' VERSION SHA256 SIZE
            for version in $versions; do
                ref=$IMAGE_REFS_DIR/$version
                [ -s "$ref" ] || continue
                sha=$(sed -n '1p' "$ref")
                object=$IMAGE_OBJECTS_DIR/$sha.img
                size=missing
                [ ! -f "$object" ] || size=$(du -h "$object" | awk '{print $1}')
                printf '%-8s %-64s %s\n' "$version" "$sha" "$size"
            done
            ;;
        *) die "usage: vmctl image pull|list [VERSION]" ;;
    esac
}

port_used_by_instances() {
    local wanted dir port file _proto host _guest
    wanted=$1
    for dir in "$INSTANCES_DIR"/*; do
        [ -d "$dir" ] || continue
        port=$(config_get "$dir" ssh_port 2>/dev/null || true)
        [ "$port" != "$wanted" ] || return 0
        file=$dir/forwards.tsv
        [ -f "$file" ] || continue
        while IFS="$TAB" read -r _proto host _guest; do
            [ "$host" != "$wanted" ] || return 0
        done < "$file"
    done
    return 1
}

port_listening() {
    local port nc_bin
    port=$1
    nc_bin=$(tool_path nc) || return 1
    "$nc_bin" -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1
}

port_available() {
    ! port_used_by_instances "$1" && ! port_listening "$1"
}

allocate_port() {
    local port
    port=22000
    while [ "$port" -le 22999 ]; do
        if port_available "$port"; then
            printf '%s\n' "$port"
            return
        fi
        port=$((port + 1))
    done
    die "no free port found in 22000-22999"
}

validate_bind_address() {
    local address old_ifs a b c d extra
    address=$1
    old_ifs=$IFS
    IFS=.
    set -- $address
    IFS=$old_ifs
    [ "$#" -eq 4 ] || die "bind address must be an IPv4 address"
    a=$1 b=$2 c=$3 d=$4 extra=
    for extra in "$a" "$b" "$c" "$d"; do
        validate_range "IPv4 octet" "$extra" 0 255
    done
}

parse_forward_spec() {
    local spec proto host guest rest
    spec=$1
    validate_text_field "forward specification" "$spec"
    proto=${spec%%:*}
    rest=${spec#*:}
    host=${rest%%:*}
    guest=${rest#*:}
    [ "$guest" != "$rest" ] || die "forward must use tcp:HOST_PORT:GUEST_PORT"
    [ "$proto" = tcp ] || die "only TCP forwarding is supported"
    validate_range "host port" "$host" 1 65535
    validate_range "guest port" "$guest" 1 65535
    printf '%s\t%s\t%s\n' "$proto" "$host" "$guest"
}

ensure_project_ssh_key() {
    local key keygen
    key=$SSH_DIR/id_ed25519
    if [ ! -s "$key" ] || [ ! -s "$key.pub" ]; then
        keygen=$(need_tool ssh-keygen)
        umask 077
        "$keygen" -q -t ed25519 -N '' -C vmctl-portable -f "$key"
    fi
    chmod 600 "$key"
    printf '%s\n' "$key"
}

write_cloud_init() {
    local dir name pub hostname id kind value target mode tag options xorriso_bin
    dir=$1 name=$2
    pub=$(sed -n '1p' "$SSH_DIR/id_ed25519.pub")
    hostname=$(printf '%s' "$name" | tr -c 'A-Za-z0-9-' '-')
    {
        printf '#cloud-config\n'
        printf 'hostname: %s\n' "$hostname"
        printf 'manage_etc_hosts: true\n'
        printf 'ssh_pwauth: false\n'
        printf 'disable_root: true\n'
        printf 'users:\n'
        printf '  - name: ubuntu\n'
        printf '    groups: [adm, sudo]\n'
        printf '    shell: /bin/bash\n'
        printf '    sudo: ["ALL=(ALL) NOPASSWD:ALL"]\n'
        printf '    lock_passwd: true\n'
        printf '    ssh_authorized_keys:\n'
        printf '      - %s\n' "$pub"
        if [ -s "$dir/shares.tsv" ]; then
            printf 'mounts:\n'
            while IFS="$TAB" read -r id kind value target mode; do
                tag=vmctl_$id
                options=defaults,nofail,x-systemd.automount
                [ "$mode" != ro ] || options=$options,ro
                printf '  - [%s, %s, virtiofs, "%s", "0", "0"]\n' \
                    "$tag" "$target" "$options"
            done < "$dir/shares.tsv"
        fi
        printf 'package_update: false\n'
        printf 'package_upgrade: false\n'
        printf 'final_message: "vmctl cloud-init complete"\n'
    } > "$dir/user-data"
    {
        printf 'instance-id: vmctl-%s\n' "$name"
        printf 'local-hostname: %s\n' "$hostname"
    } > "$dir/meta-data"
    xorriso_bin=$(need_tool xorriso)
    "$xorriso_bin" -as mkisofs -quiet -output "$dir/seed.iso" \
        -volid cidata -joliet -rock "$dir/user-data" "$dir/meta-data"
}

write_instance_config() {
    local dir name version cpus memory disk ssh_port bind strict sha
    dir=$1 name=$2 version=$3 cpus=$4 memory=$5 disk=$6
    ssh_port=$7 bind=$8 strict=$9 sha=${10}
    {
        config_put_line name "$name"
        config_put_line ubuntu "$version"
        config_put_line cpus "$cpus"
        config_put_line memory_mib "$memory"
        config_put_line disk_gib "$disk"
        config_put_line ssh_port "$ssh_port"
        config_put_line bind "$bind"
        config_put_line strict_kvm "$strict"
        config_put_line base_sha "$sha"
        config_put_line machine_type pc-q35-11.0
        config_put_line created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$dir/config.tsv"
}

cmd_create() {
    local name version cpus memory disk ssh_port bind strict start_after memory_max
    local forward_specs share_specs spec parsed host_port sha key tmp final qemu_img
    name=${1:-}
    [ "$#" -eq 0 ] || shift
    validate_name "$name"
    version=24.04
    cpus=2
    memory=2048
    memory_max=
    disk=20
    ssh_port=auto
    bind=127.0.0.1
    strict=0
    start_after=1
    forward_specs=
    share_specs=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ubuntu|--cpus|--memory|--memory-max|--disk|--ssh-port|--forward|--bind|--share)
                [ "$#" -ge 2 ] || die "$1 requires a value"
                case "$1" in
                    --ubuntu) version=$2 ;;
                    --cpus) cpus=$2 ;;
                    --memory) memory=$2 ;;
                    --memory-max) memory_max=$2 ;;
                    --disk) disk=$2 ;;
                    --ssh-port) ssh_port=$2 ;;
                    --forward) forward_specs=$forward_specs$NL$2 ;;
                    --bind) bind=$2 ;;
                    --share) share_specs=$share_specs$NL$2 ;;
                esac
                shift 2
                ;;
            --strict-kvm) strict=1; shift ;;
            --no-start) start_after=0; shift ;;
            *) die "unknown create option: $1" ;;
        esac
    done
    ubuntu_release_info "$version" >/dev/null
    validate_range "vCPU count" "$cpus" 1 256
    validate_range "memory" "$memory" 256 1048576
    memory_max=${memory_max:-$memory}
    validate_range "memory ceiling" "$memory_max" "$memory" 1048576
    validate_range "disk size" "$disk" 2 1048576
    cpus=$(printf '%s\n' "$cpus" | sed 's/^0*//')
    memory=$(printf '%s\n' "$memory" | sed 's/^0*//')
    memory_max=$(printf '%s\n' "$memory_max" | sed 's/^0*//')
    disk=$(printf '%s\n' "$disk" | sed 's/^0*//')
    validate_bind_address "$bind"
    case "$ssh_port" in
        auto) ;;
        *) validate_range "SSH port" "$ssh_port" 1 65535 ;;
    esac

    init_state
    sha=$(image_ref "$version")
    key=$(ensure_project_ssh_key)
    [ -s "$key.pub" ] || die "failed to create project SSH public key"
    acquire_lock create
    final=$(instance_dir "$name")
    [ ! -e "$final" ] || die "instance '$name' already exists"
    tmp=$INSTANCES_DIR/.create-$name-$$
    rm -rf "$tmp"
    mkdir -p "$tmp"
    ACTIVE_CREATE_DIR=$tmp
    export ACTIVE_CREATE_DIR

    if [ "$ssh_port" = auto ]; then
        ssh_port=$(allocate_port)
    else
        port_available "$ssh_port" || die "SSH port is already in use: $ssh_port"
    fi

    if [ -n "$forward_specs" ]; then
        printf '%s\n' "$forward_specs" |
        while IFS= read -r spec; do
            [ -n "$spec" ] || continue
            parsed=$(parse_forward_spec "$spec")
            host_port=$(printf '%s' "$parsed" | awk -F "$TAB" '{print $2}')
            [ "$host_port" != "$ssh_port" ] || die "forward host port conflicts with SSH port: $host_port"
            port_available "$host_port" || die "forward host port is already in use: $host_port"
            if [ -f "$tmp/forwards.tsv" ] &&
               awk -F "$TAB" -v port="$host_port" '$2 == port { found=1 } END { exit found ? 0 : 1 }' "$tmp/forwards.tsv"; then
                die "duplicate forward host port: $host_port"
            fi
            printf '%s\n' "$parsed" >> "$tmp/forwards.tsv"
        done
    fi

    if [ -n "$share_specs" ]; then
        printf '%s\n' "$share_specs" |
        while IFS= read -r spec; do
            [ -n "$spec" ] || continue
            parsed=$(parse_share_spec "$spec")
            share_add_record "$tmp" \
                "$(printf '%s' "$parsed" | awk -F "$TAB" '{print $1}')" \
                "$(printf '%s' "$parsed" | awk -F "$TAB" '{print $2}')" \
                "$(printf '%s' "$parsed" | awk -F "$TAB" '{print $3}')"
        done
    fi

    write_instance_config "$tmp" "$name" "$version" "$cpus" "$memory" "$disk" \
        "$ssh_port" "$bind" "$strict" "$sha"
    config_set "$tmp" memory_max_mib "$memory_max"
    qemu_img=$(need_tool qemu-img)
    (
        cd "$tmp"
        "$qemu_img" create -q -f qcow2 -F qcow2 \
            -b "../../images/objects/$sha.img" disk.qcow2
        "$qemu_img" resize -q disk.qcow2 "${disk}G"
    )
    write_cloud_init "$tmp" "$name"
    : > "$tmp/console.log"
    : > "$tmp/qemu.log"
    mv "$tmp" "$final"
    ACTIVE_CREATE_DIR=
    release_lock
    info "created instance '$name' (SSH 127.0.0.1:$ssh_port)"
    if [ "$start_after" = 1 ]; then
        cmd_start "$name"
    fi
}

kvm_available() {
    [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]
}

cleanup_virtiofs() {
    local dir file pid attempts
    dir=$1
    for file in "$dir"/virtiofs-*.pid; do
        [ -f "$file" ] || continue
        pid=$(sed -n '1p' "$file")
        if is_uint "$pid" && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            attempts=0
            while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 3 ]; do
                sleep 1
                attempts=$((attempts + 1))
            done
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$file"
    done
    rm -f "$dir"/virtiofs-*.sock
}

start_one_virtiofs() {
    local dir id kind value target mode source socket log pidfile daemon uid gid attempts
    dir=$1 id=$2 kind=$3 value=$4 target=$5 mode=$6
    source=$(resolve_source_record "$kind" "$value")
    validate_share_source "$source"
    socket=$dir/virtiofs-$id.sock
    log=$dir/virtiofs-$id.log
    pidfile=$dir/virtiofs-$id.pid
    daemon=$(need_tool virtiofsd)
    uid=$(id -u)
    gid=$(id -g)
    rm -f "$socket" "$pidfile"
    if [ "$mode" = ro ]; then
        "$daemon" --socket-path "$socket" --shared-dir "$source" \
            --sandbox namespace \
            --translate-uid "squash-guest:0:$uid:4294967295" \
            --translate-gid "squash-guest:0:$gid:4294967295" \
            --readonly >> "$log" 2>&1 &
    else
        "$daemon" --socket-path "$socket" --shared-dir "$source" \
            --sandbox namespace \
            --translate-uid "squash-guest:0:$uid:4294967295" \
            --translate-gid "squash-guest:0:$gid:4294967295" \
            >> "$log" 2>&1 &
    fi
    printf '%s\n' "$!" > "$pidfile"
    attempts=0
    while [ "$attempts" -lt 10 ]; do
        if [ -S "$socket" ] || { [ "${VMCTL_TESTING:-0}" = 1 ] && [ -e "$socket" ]; }; then
            return
        fi
        pid=$(sed -n '1p' "$pidfile")
        kill -0 "$pid" 2>/dev/null || {
            warn "virtiofsd log:"
            tail -n 20 "$log" >&2 || true
            die "VirtioFS daemon failed for $target"
        }
        attempts=$((attempts + 1))
        sleep 1
    done
    die "timed out waiting for VirtioFS socket for $target"
}

start_virtiofs_all() {
    local dir id kind value target mode
    dir=$1
    [ -s "$dir/shares.tsv" ] || return 0
    userns_available || die "directory sharing requires enabled unprivileged user namespaces"
    cleanup_virtiofs "$dir"
    while IFS="$TAB" read -r id kind value target mode; do
        [ -n "$id" ] || continue
        if ! start_one_virtiofs "$dir" "$id" "$kind" "$value" "$target" "$mode"; then
            cleanup_virtiofs "$dir"
            return 1
        fi
    done < "$dir/shares.tsv"
}

ssh_connect_host() {
    local bind
    bind=$1
    case "$bind" in
        0.0.0.0) printf '127.0.0.1\n' ;;
        *) printf '%s\n' "$bind" ;;
    esac
}

run_instance_ssh() {
    local dir ssh_bin port bind host
    dir=$1
    shift
    ssh_bin=$(need_tool ssh)
    port=$(config_get "$dir" ssh_port)
    bind=$(config_get "$dir" bind)
    host=$(ssh_connect_host "$bind")
    "$ssh_bin" -i "$SSH_DIR/id_ed25519" -p "$port" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o UserKnownHostsFile="$SSH_DIR/known_hosts" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 -o ServerAliveInterval=15 \
        "ubuntu@$host" "$@"
}

wait_for_ssh() {
    local dir timeout waited
    dir=$1
    timeout=${VMCTL_SSH_TIMEOUT:-180}
    waited=0
    while [ "$waited" -lt "$timeout" ]; do
        pid_is_running "$dir" || return 1
        if run_instance_ssh "$dir" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

sync_guest_fstab() {
    local dir block id kind value target mode options
    dir=$1
    block=$dir/fstab.managed
    {
        printf '# BEGIN VMCTL SHARES\n'
        if [ -s "$dir/shares.tsv" ]; then
            while IFS="$TAB" read -r id kind value target mode; do
                options=defaults,nofail,x-systemd.automount
                [ "$mode" != ro ] || options=$options,ro
                printf 'vmctl_%s %s virtiofs %s 0 0\n' "$id" "$target" "$options"
            done < "$dir/shares.tsv"
        fi
        printf '# END VMCTL SHARES\n'
    } > "$block"

    {
        printf 'set -eu\n'
        printf 'tmp=$(mktemp)\n'
        printf "sed '/^# BEGIN VMCTL SHARES$/,/^# END VMCTL SHARES$/d' /etc/fstab > \"\$tmp\"\n"
        printf "cat >> \"\$tmp\" <<'VMCTL_FSTAB'\n"
        sed -n '1,$p' "$block"
        printf 'VMCTL_FSTAB\n'
        printf 'cat "$tmp" > /etc/fstab\n'
        printf 'rm -f "$tmp"\n'
        printf 'systemctl daemon-reload\n'
        if [ -s "$dir/shares.tsv" ]; then
            while IFS="$TAB" read -r id kind value target mode; do
                printf "mkdir -p '%s'\n" "$target"
                printf "mountpoint -q '%s' || mount '%s'\n" "$target" "$target"
            done < "$dir/shares.tsv"
        fi
    } | run_instance_ssh "$dir" sudo sh
}

cmd_start() {
    local name dir state cpus memory bind ssh_port strict machine qemu netdev
    local proto host guest id kind value target mode qmp_socket memory_max cpu_driver cpu_limit
    name=${1:-}
    [ "$#" -eq 0 ] || shift
    [ "$#" -eq 0 ] || die "usage: vmctl start NAME"
    init_state
    dir=$(require_instance "$name")
    state=$(instance_state "$dir")
    [ "$state" = stopped ] || die "instance '$name' is already $state"
    acquire_lock "instance-$name"
    require_stopped "$dir"
    rm -f "$dir/qemu.pid" "$dir/qmp.sock" "$dir/resources.tsv"
    ACTIVE_VIRTIOFS_DIR=$dir
    export ACTIVE_VIRTIOFS_DIR
    start_virtiofs_all "$dir" || {
        cleanup_virtiofs "$dir"
        die "failed to start directory shares"
    }
    cpus=$(config_get "$dir" cpus)
    # Avoid requiring APIC ID 255 / extended x2APIC support on ordinary hosts.
    # Preserve the existing ability to explicitly boot with 256 vCPUs.
    cpu_limit=255
    [ "$cpus" -le "$cpu_limit" ] || cpu_limit=$cpus
    memory=$(config_get "$dir" memory_mib)
    memory_max=$(config_get "$dir" memory_max_mib || printf '%s\n' "$memory")
    bind=$(config_get "$dir" bind)
    ssh_port=$(config_get "$dir" ssh_port)
    strict=$(config_get "$dir" strict_kvm)
    machine=$(config_get "$dir" machine_type)
    qemu=$(need_tool qemu-system-x86_64)
    netdev=user,id=net0,hostfwd=tcp:$bind:$ssh_port-:22
    if [ -s "$dir/forwards.tsv" ]; then
        while IFS="$TAB" read -r proto host guest; do
            netdev=$netdev,hostfwd=$proto:$bind:$host-:$guest
        done < "$dir/forwards.tsv"
    fi

    set -- "$qemu" -name "$name" -machine "$machine" -nodefaults -no-user-config \
        -smp "$cpus,sockets=$cpu_limit,cores=1,threads=1,maxcpus=$cpu_limit" -m "$memory_max" -display none \
        -device virtio-balloon-pci,id=balloon0 \
        -drive "if=none,id=root,file=$dir/disk.qcow2,format=qcow2,cache=writeback,discard=unmap" \
        -device virtio-blk-pci,drive=root \
        -drive "if=none,id=seed,file=$dir/seed.iso,format=raw,readonly=on" \
        -device virtio-blk-pci,drive=seed \
        -netdev "$netdev" -device virtio-net-pci,netdev=net0 \
        -serial "file:$dir/console.log" \
        -qmp "unix:$dir/qmp.sock,server=on,wait=off" \
        -pidfile "$dir/qemu.pid" -D "$dir/qemu.log" -daemonize \
        -L "$RUNTIME_DIR/share/qemu"
    if kvm_available; then
        cpu_driver=host-x86_64-cpu
        set -- "$@" -accel kvm -cpu host
        info "starting '$name' with KVM acceleration"
    else
        if [ "$strict" = 1 ]; then
            cleanup_virtiofs "$dir"
            die "KVM is unavailable and this instance requires --strict-kvm"
        fi
        cpu_driver=max-x86_64-cpu
        set -- "$@" -accel tcg,thread=multi -cpu max
        warn "KVM is unavailable; starting '$name' with slow TCG software emulation"
    fi
    if [ -s "$dir/shares.tsv" ]; then
        set -- "$@" \
            -object "memory-backend-memfd,id=vmctlmem,size=${memory_max}M,share=on" \
            -numa node,memdev=vmctlmem
        while IFS="$TAB" read -r id kind value target mode; do
            qmp_socket=$dir/virtiofs-$id.sock
            set -- "$@" \
                -chardev "socket,id=char_$id,path=$qmp_socket" \
                -device "vhost-user-fs-pci,chardev=char_$id,tag=vmctl_$id,queue-size=1024"
        done < "$dir/shares.tsv"
    fi
    if ! "$@"; then
        cleanup_virtiofs "$dir"
        warn "QEMU log:"
        tail -n 30 "$dir/qemu.log" >&2 || true
        die "QEMU failed to start instance '$name'"
    fi
    {
        config_put_line cpu_driver "$cpu_driver"
        config_put_line cpu_max "$cpu_limit"
        config_put_line memory_max_mib "$memory_max"
    } > "$dir/resources.tsv"
    ACTIVE_VIRTIOFS_DIR=
    release_lock
    if ! wait_for_ssh "$dir"; then
        warn "serial console tail:"
        tail -n 30 "$dir/console.log" >&2 || true
        die "instance started but SSH did not become ready within ${VMCTL_SSH_TIMEOUT:-180}s"
    fi
    # Do not block stop/resize while waiting for Guest boot. Re-read the target
    # under the lock so a concurrent resize is not overwritten by startup.
    acquire_lock "instance-$name"
    [ "$(instance_state "$dir")" != stopped ] || die "instance stopped while waiting for readiness"
    memory=$(config_get "$dir" memory_mib)
    memory_max=$(config_get_file "$dir/resources.tsv" memory_max_mib)
    if [ "$memory" -lt "$memory_max" ]; then
        qmp_request "$dir" balloon "{\"value\":$((memory * 1048576))}" ||
            die "instance is running, but initial balloon target could not be applied"
    fi
    release_lock
    if ! sync_guest_fstab "$dir"; then
        warn "instance is running, but persistent directory mount synchronization failed"
        return 1
    fi
    info "instance '$name' is ready; run: ./vmctl ssh $name"
}

force_stop_pid() {
    local pid attempts
    pid=$1
    kill "$pid" 2>/dev/null || true
    attempts=0
    while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 5 ]; do
        sleep 1
        attempts=$((attempts + 1))
    done
    kill -9 "$pid" 2>/dev/null || true
}

cmd_stop() {
    local name force dir state pid socat_bin attempts
    name=${1:-}
    [ "$#" -eq 0 ] || shift
    force=0
    if [ "${1:-}" = --force ]; then
        force=1
        shift
    fi
    [ "$#" -eq 0 ] || die "usage: vmctl stop NAME [--force]"
    init_state
    dir=$(require_instance "$name")
    state=$(instance_state "$dir")
    if [ "$state" = stopped ]; then
        cleanup_virtiofs "$dir"
        info "instance '$name' is already stopped"
        return
    fi
    acquire_lock "instance-$name"
    pid=$(sed -n '1p' "$dir/qemu.pid")
    if [ "$force" = 0 ]; then
        [ -S "$dir/qmp.sock" ] ||
            die "QMP control socket is unavailable; retry with --force"
        socat_bin=$(need_tool socat)
        printf '%s\n%s\n' \
            '{"execute":"qmp_capabilities"}' \
            '{"execute":"system_powerdown"}' |
            "$socat_bin" - "UNIX-CONNECT:$dir/qmp.sock" >/dev/null 2>&1 || true
        attempts=0
        while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 30 ]; do
            sleep 1
            attempts=$((attempts + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            release_lock
            die "guest did not shut down within 30 seconds; retry with --force"
        fi
    else
        force_stop_pid "$pid"
    fi
    cleanup_virtiofs "$dir"
    rm -f "$dir/qemu.pid" "$dir/qmp.sock"
    release_lock
    info "stopped instance '$name'"
}

cmd_restart() {
    local name force
    name=${1:-}
    [ "$#" -eq 0 ] || shift
    force=
    if [ "${1:-}" = --force ]; then
        force=--force
        shift
    fi
    [ "$#" -eq 0 ] || die "usage: vmctl restart NAME [--force]"
    cmd_stop "$name" ${force:+"$force"}
    cmd_start "$name"
}

cmd_status() {
    local name dir state version cpus memory port bind host
    name=${1:-}
    [ "$#" -le 1 ] || die "usage: vmctl status [NAME]"
    init_state
    if [ -z "$name" ]; then
        cmd_list
        return
    fi
    dir=$(require_instance "$name")
    state=$(instance_state "$dir")
    version=$(config_get "$dir" ubuntu)
    cpus=$(config_get "$dir" cpus)
    memory=$(config_get "$dir" memory_mib)
    port=$(config_get "$dir" ssh_port)
    bind=$(config_get "$dir" bind)
    host=$(ssh_connect_host "$bind")
    printf 'name\t%s\nstate\t%s\nubuntu\t%s\ncpus\t%s\nmemory_mib\t%s\nssh\t%s:%s\n' \
        "$name" "$state" "$version" "$cpus" "$memory" "$host" "$port"
}

cmd_list() {
    local dir name state version cpus memory port found
    [ "$#" -eq 0 ] || die "list takes no arguments"
    init_state
    printf '%-20s %-10s %-8s %-5s %-10s %s\n' NAME STATE UBUNTU CPUS MEMORY SSH
    found=0
    for dir in "$INSTANCES_DIR"/*; do
        [ -d "$dir" ] || continue
        case "${dir##*/}" in .create-*) continue ;; esac
        name=$(config_get "$dir" name 2>/dev/null || continue)
        state=$(instance_state "$dir")
        version=$(config_get "$dir" ubuntu)
        cpus=$(config_get "$dir" cpus)
        memory=$(config_get "$dir" memory_mib)
        port=$(config_get "$dir" ssh_port)
        printf '%-20s %-10s %-8s %-5s %-10s 127.0.0.1:%s\n' \
            "$name" "$state" "$version" "$cpus" "${memory}MiB" "$port"
        found=1
    done
    [ "$found" -eq 1 ] || info "no instances"
}

cmd_ssh() {
    local name dir state
    name=${1:-}
    [ "$#" -eq 0 ] || shift
    [ "${1:-}" != -- ] || shift
    dir=$(require_instance "$name")
    state=$(instance_state "$dir")
    [ "$state" = running ] || [ "$state" = degraded ] ||
        die "instance '$name' is not running"
    run_instance_ssh "$dir" "$@"
}

cmd_logs() {
    local name dir file
    name=${1:-}
    [ "$#" -le 1 ] || die "usage: vmctl logs NAME"
    dir=$(require_instance "$name")
    for file in "$dir/qemu.log" "$dir/console.log" "$dir"/virtiofs-*.log; do
        [ -f "$file" ] || continue
        printf '\n==> %s <==\n' "${file##*/}"
        tail -n 100 "$file"
    done
}

cmd_delete() {
    local name yes dir answer
    name=${1:-}
    [ "$#" -eq 0 ] || shift
    yes=0
    if [ "${1:-}" = --yes ]; then
        yes=1
        shift
    fi
    [ "$#" -eq 0 ] || die "usage: vmctl delete NAME [--yes]"
    init_state
    dir=$(require_instance "$name")
    require_stopped "$dir"
    if [ "$yes" != 1 ]; then
        printf "Delete instance '%s' and its virtual disk? [y/N] " "$name" >&2
        IFS= read -r answer || answer=
        case "$answer" in y|Y|yes|YES) ;; *) info "delete cancelled"; return ;; esac
    fi
    acquire_lock "instance-$name"
    rm -rf "$dir"
    release_lock
    info "deleted instance '$name'; its overlay disk is not recoverable"
}

share_source_for_display() {
    local kind value path
    kind=$1 value=$2
    case "$kind" in
        relative) path=$VMCTL_ROOT/$value ;;
        absolute) path=$value ;;
        *) path="<invalid:$kind>" ;;
    esac
    printf '%s\n' "$path"
}

cmd_share_add() {
    local name source target mode dir
    name=${1:-}
    [ "$#" -eq 0 ] || shift
    source=
    target=
    mode=ro
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source|--target)
                [ "$#" -ge 2 ] || die "$1 requires a value"
                if [ "$1" = --source ]; then source=$2; else target=$2; fi
                shift 2
                ;;
            --read-write) mode=rw; shift ;;
            *) die "unknown share add option: $1" ;;
        esac
    done
    [ -n "$source" ] || die "share add requires --source PATH"
    init_state
    dir=$(require_instance "$name")
    require_stopped "$dir"
    acquire_lock "instance-$name"
    share_add_record "$dir" "$source" "$target" "$mode"
    release_lock
    info "share added; it will be attached on the next start"
}

cmd_share_list() {
    local name dir state id kind value target mode source portability daemon pid
    name=${1:-}
    [ "$#" -le 1 ] || die "usage: vmctl share list NAME"
    dir=$(require_instance "$name")
    state=$(instance_state "$dir")
    printf '%-7s %-9s %-10s %-10s %-24s %s\n' ID MODE PORTABLE DAEMON TARGET SOURCE
    [ -s "$dir/shares.tsv" ] || {
        info "no directory shares"
        return
    }
    while IFS="$TAB" read -r id kind value target mode; do
        source=$(share_source_for_display "$kind" "$value")
        [ "$kind" = relative ] && portability=yes || portability=no
        daemon=stopped
        if [ "$state" != stopped ] && [ -s "$dir/virtiofs-$id.pid" ]; then
            pid=$(sed -n '1p' "$dir/virtiofs-$id.pid")
            if is_uint "$pid" && kill -0 "$pid" 2>/dev/null; then
                daemon=running
            else
                daemon=failed
            fi
        fi
        [ -d "$source" ] || daemon=missing
        printf '%-7s %-9s %-10s %-10s %-24s %s\n' \
            "$id" "$mode" "$portability" "$daemon" "$target" "$source"
    done < "$dir/shares.tsv"
}

cmd_share_remove() {
    local name target dir file tmp matches
    name=${1:-}
    [ "$#" -eq 0 ] || shift
    target=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target)
                [ "$#" -ge 2 ] || die "--target requires a value"
                target=$2
                shift 2
                ;;
            *) die "unknown share remove option: $1" ;;
        esac
    done
    [ -n "$target" ] || die "share remove requires --target PATH"
    validate_guest_target "$target"
    init_state
    dir=$(require_instance "$name")
    require_stopped "$dir"
    file=$dir/shares.tsv
    [ -f "$file" ] || die "instance has no directory shares"
    matches=$(awk -F "$TAB" -v target="$target" '$4 == target { count++ } END { print count+0 }' "$file")
    [ "$matches" -eq 1 ] || die "share target is not configured: $target"
    acquire_lock "instance-$name"
    tmp=$dir/shares.tsv.tmp.$$
    awk -F "$TAB" -v target="$target" '$4 != target' "$file" > "$tmp"
    if [ -s "$tmp" ]; then mv "$tmp" "$file"; else rm -f "$tmp" "$file"; fi
    release_lock
    info "share removed; Guest fstab will be synchronized on the next start"
}

cmd_share() {
    local sub
    sub=${1:-}
    [ "$#" -eq 0 ] || shift
    case "$sub" in
        add) cmd_share_add "$@" ;;
        list) cmd_share_list "$@" ;;
        remove) cmd_share_remove "$@" ;;
        *) die "usage: vmctl share add|list|remove ..." ;;
    esac
}
