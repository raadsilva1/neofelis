#!/bin/ksh

set -u

PROJECT="neofelis"
SOURCE_FILE="neofelis.pl"
DESKTOP_FILE="neofelis.desktop"

BIN_DIR="/usr/local/bin"
APP_DIR="/usr/local/share/applications"
BIN_TARGET="${BIN_DIR}/${PROJECT}"
DESKTOP_TARGET="${APP_DIR}/${PROJECT}.desktop"

REQUIRED_PACKAGES="perl perl-gtk3"

SCRIPT_DIR=""
SOURCE_PATH=""
DESKTOP_PATH=""
HAS_DESKTOP=0

WORKDIR=""
STAGE_DIR=""
BACKUP_DIR=""
CHANGED_BIN=0
CHANGED_DESKTOP=0

log() {
    printf '%s\n' "[${PROJECT}-install] $*"
}

warn() {
    printf '%s\n' "[${PROJECT}-install][warn] $*" >&2
}

cleanup() {
    if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
        rm -rf -- "${WORKDIR}"
    fi
}

restore_previous_install() {
    if [ -n "${BACKUP_DIR}" ] && [ -d "${BACKUP_DIR}" ]; then
        if [ "${CHANGED_BIN}" -eq 1 ]; then
            if [ -f "${BACKUP_DIR}/bin.previous" ]; then
                install -d -m 0755 -- "${BIN_DIR}" >/dev/null 2>&1 || true
                cp -f -- "${BACKUP_DIR}/bin.previous" "${BIN_TARGET}" >/dev/null 2>&1 || true
                chmod 0755 -- "${BIN_TARGET}" >/dev/null 2>&1 || true
            else
                rm -f -- "${BIN_TARGET}" >/dev/null 2>&1 || true
            fi
        fi

        if [ "${CHANGED_DESKTOP}" -eq 1 ]; then
            if [ -f "${BACKUP_DIR}/desktop.previous" ]; then
                install -d -m 0755 -- "${APP_DIR}" >/dev/null 2>&1 || true
                cp -f -- "${BACKUP_DIR}/desktop.previous" "${DESKTOP_TARGET}" >/dev/null 2>&1 || true
                chmod 0644 -- "${DESKTOP_TARGET}" >/dev/null 2>&1 || true
            else
                rm -f -- "${DESKTOP_TARGET}" >/dev/null 2>&1 || true
            fi
        fi
    fi
}

fail() {
    printf '%s\n' "[${PROJECT}-install][error] $*" >&2
    restore_previous_install
    cleanup
    exit 1
}

on_signal() {
    fail "interrupted"
}

trap 'on_signal' INT TERM HUP
trap 'cleanup' EXIT

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "run this installer as root"
}

verify_tools() {
    command -v pacman >/dev/null 2>&1 || fail "pacman is required"
    command -v perl >/dev/null 2>&1 || warn "perl is not currently installed; installer will try to install it"
    command -v install >/dev/null 2>&1 || fail "install is required"
    command -v mktemp >/dev/null 2>&1 || fail "mktemp is required"
    command -v uname >/dev/null 2>&1 || fail "uname is required"
}

verify_platform() {
    [ "$(uname -m 2>/dev/null)" = "x86_64" ] || fail "target architecture must be x86_64"

    if [ ! -r /etc/artix-release ] && ! grep -qi '^ID=artix' /etc/os-release 2>/dev/null; then
        fail "this installer targets Artix Linux only"
    fi

    [ -d /run/openrc ] || [ -x /sbin/openrc ] || [ -x /bin/openrc ] || [ -x /usr/bin/openrc ] || fail "this installer targets OpenRC only"
}

resolve_local_paths() {
    SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)" || fail "could not resolve installer directory"

    SOURCE_PATH="${SCRIPT_DIR}/${SOURCE_FILE}"
    DESKTOP_PATH="${SCRIPT_DIR}/${DESKTOP_FILE}"

    [ -f "${SOURCE_PATH}" ] || fail "required source file not found: ${SOURCE_PATH}"
    [ -r "${SOURCE_PATH}" ] || fail "required source file is not readable: ${SOURCE_PATH}"

    if [ -f "${DESKTOP_PATH}" ]; then
        [ -r "${DESKTOP_PATH}" ] || fail "desktop file exists but is not readable: ${DESKTOP_PATH}"
        HAS_DESKTOP=1
    else
        HAS_DESKTOP=0
    fi
}

install_dependencies() {
    typeset pkg missing=""
    for pkg in ${REQUIRED_PACKAGES}; do
        if ! pacman -Q -- "${pkg}" >/dev/null 2>&1; then
            pacman -Si -- "${pkg}" >/dev/null 2>&1 || fail "required package is not visible to pacman: ${pkg}"
            missing="${missing} ${pkg}"
        fi
    done

    if [ -n "${missing}" ]; then
        log "installing packages:${missing}"
        pacman -S --needed --noconfirm ${missing} || fail "dependency installation failed"
    else
        log "required packages already installed"
    fi
}

validate_source() {
    perl -e 'use strict; use warnings; use Gtk3; exit 0;' >/dev/null 2>&1 || fail "Perl Gtk3 module load test failed"
    perl -c "${SOURCE_PATH}" >/dev/null || fail "Perl syntax validation failed for ${SOURCE_PATH}"

    if [ "${HAS_DESKTOP}" -eq 1 ] && command -v desktop-file-validate >/dev/null 2>&1; then
        desktop-file-validate "${DESKTOP_PATH}" || fail "desktop file validation failed"
    fi
}

prepare_staging() {
    WORKDIR="$(mktemp -d "/tmp/${PROJECT}.install.XXXXXX")" || fail "could not create temporary workspace"
    STAGE_DIR="${WORKDIR}/stage"
    BACKUP_DIR="${WORKDIR}/backup"

    install -d -m 0700 -- "${STAGE_DIR}" "${BACKUP_DIR}" || fail "could not initialize temporary directories"
    install -d -m 0755 -- "${STAGE_DIR}/bin" "${STAGE_DIR}/applications" || fail "could not initialize stage layout"
}

backup_existing_install() {
    if [ -f "${BIN_TARGET}" ]; then
        cp -f -- "${BIN_TARGET}" "${BACKUP_DIR}/bin.previous" || fail "could not back up existing binary"
    fi

    if [ -f "${DESKTOP_TARGET}" ]; then
        cp -f -- "${DESKTOP_TARGET}" "${BACKUP_DIR}/desktop.previous" || fail "could not back up existing desktop file"
    fi
}

stage_local_files() {
    install -m 0755 -- "${SOURCE_PATH}" "${STAGE_DIR}/bin/${PROJECT}" || fail "could not stage executable"

    if [ "${HAS_DESKTOP}" -eq 1 ]; then
        install -m 0644 -- "${DESKTOP_PATH}" "${STAGE_DIR}/applications/${PROJECT}.desktop" || fail "could not stage desktop file"
    fi
}

install_files() {
    install -d -m 0755 -- "${BIN_DIR}" || fail "could not create ${BIN_DIR}"
    install -m 0755 -- "${STAGE_DIR}/bin/${PROJECT}" "${BIN_TARGET}" || fail "could not install binary"
    CHANGED_BIN=1

    if [ "${HAS_DESKTOP}" -eq 1 ]; then
        install -d -m 0755 -- "${APP_DIR}" || fail "could not create ${APP_DIR}"
        install -m 0644 -- "${STAGE_DIR}/applications/${PROJECT}.desktop" "${DESKTOP_TARGET}" || fail "could not install desktop entry"
        CHANGED_DESKTOP=1
    fi
}

verify_install() {
    [ -x "${BIN_TARGET}" ] || fail "installed binary is not executable"
    perl -c "${BIN_TARGET}" >/dev/null || fail "installed binary failed syntax validation"

    if [ "${HAS_DESKTOP}" -eq 1 ] && command -v desktop-file-validate >/dev/null 2>&1; then
        desktop-file-validate "${DESKTOP_TARGET}" || fail "installed desktop file validation failed"
    fi
}

print_result() {
    log "installation completed"
    log "source used: ${SOURCE_PATH}"
    log "binary: ${BIN_TARGET}"

    if [ "${HAS_DESKTOP}" -eq 1 ]; then
        log "desktop entry: ${DESKTOP_TARGET}"
    else
        log "desktop entry: skipped (no ${DESKTOP_FILE} beside installer)"
    fi

    log "run with: ${PROJECT}"
}

main() {
    require_root
    verify_tools
    verify_platform
    resolve_local_paths
    install_dependencies
    validate_source
    prepare_staging
    backup_existing_install
    stage_local_files
    install_files
    verify_install
    print_result
}

main "$@"
