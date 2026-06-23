#!/bin/zsh --no-rcs
#
# Copyright 2017-Present Erik Gomez.
# Copyright 2026 Kevin M. Cox.
#
# Licensed under the Apache License, Version 2.0 (the 'License');
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an 'AS IS' BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# InstallApplications (shell port)
# Downloads a bootstrap.json from --jsonurl and installs the packages /
# scripts it describes during a macOS DEP bootstrap. Uses curl for HTTP,
# jq for JSON parsing, shasum for hash validation, and logger for
# Console.app visibility.
#
# This file was rewritten in zsh in 2026; the prior Python implementation
# (installapplications.py + gurl.py) lives in the git history of the
# upstream project at https://github.com/erikng/installapplications.

emulate -L zsh
setopt no_unset pipe_fail
autoload -Uz is-at-least
zmodload zsh/datetime  # provides $EPOCHREALTIME (float seconds since epoch)

# Defaults for CLI flags
JSONURL=""
DRY_RUN=0
FOLLOW_REDIRECTS=0
HEADERS=""
IAPATH="/Library/installapplications"
LAIDENTIFIER="com.erikng.installapplications.user"
LDIDENTIFIER="com.erikng.installapplications"
REBOOT=0
SKIP_VALIDATION=0
USERSCRIPT_MODE=0

ialog() {
    local msg="$*"
    /usr/bin/logger -t InstallApplications -- "$msg"
    print -r -- "[InstallApplications] $msg"
}

usage() {
    cat <<EOF
Usage: installapplications [options]

  --jsonurl URL         Required (unless --userscript): URL to bootstrap.json.
  --dry-run             Skip actual installs / script execution (for testing).
  --follow-redirects    Follow HTTP redirects when downloading.
  --headers VALUE       Authorization header value (e.g., "Basic <base64>").
  --iapath PATH         InstallApplications directory.
                        (default: /Library/installapplications)
  --laidentifier ID     LaunchAgent identifier.
                        (default: com.erikng.installapplications.user)
  --ldidentifier ID     LaunchDaemon identifier.
                        (default: com.erikng.installapplications)
  --reboot              Reboot the Mac after cleanup.
  --skip-validation     Do not re-download bootstrap.json if it already exists.
  --userscript          Run pending user scripts from the userscripts/ dir
                        (used by the LaunchAgent; not for direct invocation).
  -h, --help            Show this help and exit.
EOF
}

parse_args() {
    local flag
    while (( $# > 0 )); do
        flag="$1"
        case "$flag" in
            --jsonurl|--headers|--iapath|--laidentifier|--ldidentifier)
                if [[ -z "${2:-}" ]]; then
                    print -r -- "$flag requires a value" >&2
                    usage >&2
                    exit 1
                fi
                case "$flag" in
                    --jsonurl)      JSONURL="$2" ;;
                    --headers)      HEADERS="$2" ;;
                    --iapath)       IAPATH="$2" ;;
                    --laidentifier) LAIDENTIFIER="$2" ;;
                    --ldidentifier) LDIDENTIFIER="$2" ;;
                esac
                shift 2
                ;;
            --dry-run)          DRY_RUN=1; shift ;;
            --follow-redirects) FOLLOW_REDIRECTS=1; shift ;;
            --reboot)           REBOOT=1; shift ;;
            --skip-validation)  SKIP_VALIDATION=1; shift ;;
            --userscript)       USERSCRIPT_MODE=1; shift ;;
            -h|--help)          usage; exit 0 ;;
            *)
                print -r -- "Unknown argument: $flag" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

is_apple_silicon() {
    [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]]
}

validate_skip_if() {
    local criteria="$1"
    case "$criteria" in
        *arm64*|*apple_silicon*) is_apple_silicon ;;
        *x86_64*|*intel*)        ! is_apple_silicon ;;
        *)                       return 1 ;;
    esac
}

gethash() {
    [[ -f "$1" ]] || { print -r -- "NOT A FILE"; return 0; }
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

checkreceipt() {
    local pkgid="$1" version=""
    version=$(/usr/sbin/pkgutil --pkg-info-plist "$pkgid" 2>/dev/null \
              | /usr/bin/plutil -extract pkg-version raw -o - - 2>/dev/null)
    [[ -n "$version" ]] || version="0.0.0.0.0"
    print -r -- "$version"
}

# Returns 0 if version $1 >= version $2 (zsh built-in: is-at-least required have).
version_ge() {
    is-at-least "$2" "$1"
}

get_console_user() {
    /usr/bin/stat -f "%Su" /dev/console 2>/dev/null
}

get_console_uid() {
    local user; user=$(get_console_user)
    [[ -n "$user" ]] || return 1
    /usr/bin/id -u "$user" 2>/dev/null
}

downloadfile() {
    local url="$1" out="$2"
    local -a args
    args=(--silent --show-error --fail --connect-timeout 30 --max-time 3600)
    (( FOLLOW_REDIRECTS )) && args+=(--location)
    [[ -n "$HEADERS" ]] && args+=(--header "Authorization: $HEADERS")
    args+=(--output "$out" -- "$url")
    ialog "Starting download: $url"
    # Capture curl's exit code BEFORE any `if`. In zsh, `if cmd; then ...; fi`
    # returns 0 when cmd fails and no else clause exists (per the zsh manual:
    # "The return status is zero if no test succeeded"). Reading $? after the
    # `fi` would always get 0, masking the actual curl exit code.
    /usr/bin/curl "${args[@]}"
    local rc=$?
    if (( rc == 0 )); then
        return 0
    fi
    ialog "Download failed (curl exit $rc): $url"
    return $rc
}

# Args: file url name expected_hash retries retrywait type
download_if_needed() {
    local file="$1" url="$2" name="$3" expected_hash="$4"
    local retries="$5" retrywait="$6" type="$7"

    if [[ -f "$file" ]] && [[ "$(gethash "$file")" == "$expected_hash" ]]; then
        return 0
    fi

    downloadfile "$url" "$file" || true
    /bin/sleep 0.5

    local fails_left=$retries actual_hash
    while actual_hash=$(gethash "$file"); [[ "$actual_hash" != "$expected_hash" ]]; do
        ialog "Hash failed for $name - received: $actual_hash expected: $expected_hash"
        ialog "Waiting $retrywait seconds before attempting download again..."
        /bin/sleep "$retrywait"
        downloadfile "$url" "$file" || true
        (( fails_left-- ))
        if (( fails_left <= 0 )); then
            ialog "Hash retry failed for $name: exiting!"
            cleanup 1
        fi
    done

    ialog "Hash validated for $name"

    case "$file" in
        *.pkg) ;;
        *)     /bin/chmod 0755 "$file" ;;
    esac
    [[ "$type" == "userscript" ]] && /bin/chmod 0777 "$file"
    return 0
}

installpackage() {
    local pkg="$1"
    if (( DRY_RUN )); then
        ialog "Dry run installing package: $pkg"
        return 0
    fi
    # Use plain -verbose (not -verboseR). Background: the Python 2.x version
    # used -verboseR with text-replacement for `%` field separators and
    # truncation ellipses (U+2026). When IAS migrated to embedded Python 3
    # in v2.0, the 2to3 conversion silently broke installpackage's logging:
    # subprocess.communicate() began returning bytes, .split("\n") raised
    # TypeError, and a bare `except: pass` swallowed the failure. Every
    # 2.0.x release through 2.0.4 logged zero installer output as a result.
    # Pkgs still installed; admins relied on /var/log/install.log instead.
    # In v3.0 we restore installer output to the daemon log using plain
    # -verbose, which emits human-readable lines without the `%`/`…` mess.
    /usr/sbin/installer -verbose -pkg "$pkg" -target / 2>&1 | while IFS= read -r line; do
        [[ -n "$line" ]] && ialog "$line"
    done
    return ${pipestatus[1]}
}

# Args: path donotwait
runrootscript() {
    local path="$1" donotwait="$2"
    if (( DRY_RUN )); then
        ialog "Dry run executing root script: $path"
        return 0
    fi
    if [[ "$donotwait" == "true" ]]; then
        ialog "Do not wait triggered"
        ialog "Running Script: $path"
        "$path" >/dev/null 2>&1 &
        disown
        return 0
    fi
    ialog "Running Script: $path"
    local output rc=0
    output=$("$path" 2>&1) || rc=$?
    [[ -n "$output" ]] && ialog "Output: $output"
    if (( rc != 0 )); then
        ialog "Received non-zero exit code: $rc"
        return $rc
    fi
    return 0
}

# Runs the first script in the user scripts directory, then removes it.
runuserscript() {
    local dir="$1" script output rc
    for script in "$dir"/*(N); do
        [[ -e "$script" ]] || continue
        if (( DRY_RUN )); then
            ialog "Dry run executing user script: $script"
            /bin/rm -f "$script"
            return 0
        fi
        ialog "Running Script: $script"
        rc=0
        output=$("$script" 2>&1) || rc=$?
        [[ -n "$output" ]] && ialog "Output: $output"
        /bin/rm -f "$script"
        if (( rc != 0 )); then
            ialog "Received non-zero exit code: $rc"
            return $rc
        fi
        return 0
    done
    ialog "No user scripts found!"
    return 1
}

cleanup() {
    local exit_code="$1"

    ialog "Attempting to remove LaunchDaemon: $IALDPATH"
    /bin/rm -f "$IALDPATH" 2>/dev/null || true

    ialog "Attempting to remove LaunchAgent: $IALAPATH"
    /bin/rm -f "$IALAPATH" 2>/dev/null || true

    local userid
    if userid=$(get_console_uid); then
        ialog "Targeting user id for LaunchAgent removal: $userid"
        ialog "Attempting to remove LaunchAgent: $LAIDENTIFIER"
        /bin/launchctl asuser "$userid" /bin/launchctl remove "$LAIDENTIFIER" 2>/dev/null || true
    fi

    if (( REBOOT )); then
        ialog "Triggering reboot"
        /usr/bin/osascript \
            -e 'delay 5' \
            -e 'tell application "System Events" to restart' \
            >/dev/null 2>&1 &
        disown
    fi

    ialog "Attempting to remove InstallApplications directory: $IAPATH"
    /bin/rm -rf "$IAPATH" 2>/dev/null || true

    ialog "Attempting to remove LaunchDaemon: $LDIDENTIFIER"
    /bin/launchctl remove "$LDIDENTIFIER" 2>/dev/null || true

    ialog "Cleanup done. Exiting."
    exit "$exit_code"
}

write_item_runtime() {
    local stage="$1" name="$2" start="$3"
    local runtime
    runtime=$(printf '%.2f' "$(( EPOCHREALTIME - start ))")
    ialog "$name item ran for $runtime seconds"
    RUNTIMES_JSON=$(print -r -- "$RUNTIMES_JSON" \
        | /usr/bin/jq --arg s "$stage" --arg n "$name" --argjson rt "$runtime" \
            '.[$s][$n] = $rt')
    print -r -- "$RUNTIMES_JSON" \
        | /usr/bin/plutil -convert xml1 -o "$RUNTIMES_PLIST" - 2>/dev/null \
        || ialog "Failed to write runtimes plist: $RUNTIMES_PLIST"
}

main() {
    parse_args "$@"

    if (( DRY_RUN )); then
        :
    elif (( USERSCRIPT_MODE )); then
        :
    elif [[ "$(/usr/bin/id -u)" != "0" ]]; then
        print -r -- "InstallApplications requires root!"
        exit 1
    fi

    # Path globals (used by ialog/cleanup/main)
    IAUSERSCRIPTPATH="$IAPATH/userscripts"
    IATMPPATH="/var/tmp/installapplications"
    IALOGPATH="/var/log/installapplications"
    IALDPATH="/Library/LaunchDaemons/${LDIDENTIFIER}.plist"
    IALAPATH="/Library/LaunchAgents/${LAIDENTIFIER}.plist"
    JSONPATH="$IAPATH/bootstrap.json"
    USERSCRIPT_TOUCHPATH="$IATMPPATH/.userscript"
    RUNTIMES_PLIST="$IALOGPATH/ia_item_runtimes.plist"
    RUNTIMES_JSON='{"preflight":{},"setupassistant":{},"userland":{}}'

    ialog "Beginning InstallApplications run"
    ialog "InstallApplications path: $IAPATH"
    ialog "InstallApplications LaunchDaemon path: $IALDPATH"
    ialog "InstallApplications LaunchAgent path: $IALAPATH"

    # Userscript mode: triggered by the LaunchAgent via the .userscript touch file.
    if (( USERSCRIPT_MODE )); then
        ialog "Running in userscript mode"
        if runuserscript "$IAUSERSCRIPTPATH"; then
            /bin/rm -f "$USERSCRIPT_TOUCHPATH"
            exit 0
        else
            ialog "Failed to run user script!"
            /bin/rm -f "$USERSCRIPT_TOUCHPATH"
            exit 1
        fi
    fi

    if [[ -z "$JSONURL" ]]; then
        ialog "No JSON URL specified!"
        exit 1
    fi

    if [[ ! -x /usr/bin/jq ]]; then
        ialog "/usr/bin/jq is required but not present!"
        exit 1
    fi

    # Make log dir world-writable so the LaunchAgent (user context) can append.
    [[ -d "$IALOGPATH" ]] && /bin/chmod 0777 "$IALOGPATH"

    for dir in "$IAUSERSCRIPTPATH" "$IATMPPATH"; do
        if [[ ! -d "$dir" ]]; then
            /bin/mkdir -p "$dir"
            /bin/chmod 0777 "$dir"
        fi
    done
    [[ -d "$IAPATH" ]] || /bin/mkdir -p "$IAPATH"

    ialog "InstallApplications json path: $JSONPATH"

    if (( SKIP_VALIDATION == 0 )) && [[ -f "$JSONPATH" ]]; then
        ialog "Removing and redownloading bootstrap.json"
        /bin/rm -f "$JSONPATH"
    fi

    while [[ ! -f "$JSONPATH" ]]; do
        downloadfile "$JSONURL" "$JSONPATH" || true
        /bin/sleep 0.5
    done

    if ! /usr/bin/jq empty "$JSONPATH" >/dev/null 2>&1; then
        ialog "bootstrap.json is not valid JSON: $JSONPATH"
        exit 1
    fi

    local stage item_count i item_json
    local file name type expected_hash url retries retrywait donotwait
    local packageid version pkg_required skip_if installed_version item_start
    local cu

    for stage in preflight setupassistant userland; do
        ialog "Beginning $stage"
        item_count=$(/usr/bin/jq -r "(.${stage} // []) | length" "$JSONPATH")
        if [[ "$stage" == "preflight" ]] && (( item_count == 0 )); then
            ialog "No preflight stage found: skipping."
            continue
        fi

        for (( i = 0; i < item_count; i++ )); do
            item_json=$(/usr/bin/jq -c ".${stage}[$i]" "$JSONPATH")

            file=$(print -r -- "$item_json"          | /usr/bin/jq -r '.file // ""')
            name=$(print -r -- "$item_json"          | /usr/bin/jq -r '.name // ""')
            type=$(print -r -- "$item_json"          | /usr/bin/jq -r '.type // ""')
            expected_hash=$(print -r -- "$item_json" | /usr/bin/jq -r '.hash // ""')
            url=$(print -r -- "$item_json"           | /usr/bin/jq -r '.url // ""')
            retries=$(print -r -- "$item_json"       | /usr/bin/jq -r '.retries // 3')
            retrywait=$(print -r -- "$item_json"     | /usr/bin/jq -r '.retrywait // 5')
            donotwait=$(print -r -- "$item_json"     | /usr/bin/jq -r '.donotwait // false')

            if [[ -z "$file" || -z "$name" || -z "$type" ]]; then
                ialog "Invalid item: $item_json"
                continue
            fi

            ialog "$stage processing $type $name at $file"

            # Wait for a real user session before installing userland items.
            if [[ "$stage" == "userland" ]]; then
                while true; do
                    cu=$(get_console_user)
                    if [[ -n "$cu" && "$cu" != "loginwindow" && "$cu" != "_mbsetupuser" ]]; then
                        break
                    fi
                    ialog "Detected SetupAssistant in userland stage - delaying install until user session."
                    /bin/sleep 1
                done
            fi

            item_start=$EPOCHREALTIME

            case "$type" in
                package)
                    packageid=$(print -r -- "$item_json"    | /usr/bin/jq -r '.packageid // ""')
                    version=$(print -r -- "$item_json"      | /usr/bin/jq -r '.version // ""')
                    pkg_required=$(print -r -- "$item_json" | /usr/bin/jq -r '.required // false')
                    skip_if=$(print -r -- "$item_json"      | /usr/bin/jq -r '.skip_if // ""')

                    installed_version=$(checkreceipt "$packageid")

                    if [[ "$pkg_required" != "true" ]] && version_ge "$installed_version" "$version"; then
                        ialog "Skipping $name - already installed."
                    elif [[ -n "$skip_if" ]] && validate_skip_if "$skip_if"; then
                        ialog "Skipping $name - passes skip_if criteria: $skip_if"
                    else
                        download_if_needed "$file" "$url" "$name" "$expected_hash" "$retries" "$retrywait" "$type"
                        ialog "Installing $name from $file"
                        installpackage "$file"
                    fi
                    ;;

                rootscript)
                    if [[ -n "$url" ]]; then
                        download_if_needed "$file" "$url" "$name" "$expected_hash" "$retries" "$retrywait" "$type"
                    fi
                    ialog "Starting root script: $file"
                    if [[ "$stage" == "preflight" ]]; then
                        if runrootscript "$file" "$donotwait"; then
                            ialog "Preflight passed all checks. Skipping run."
                            cleanup 0
                        else
                            ialog "Preflight did not pass all checks. Continuing run."
                            continue
                        fi
                    fi
                    runrootscript "$file" "$donotwait"
                    ;;

                userscript)
                    if [[ -n "$url" ]]; then
                        download_if_needed "$file" "$url" "$name" "$expected_hash" "$retries" "$retrywait" "$type"
                    fi
                    if [[ "$stage" == "setupassistant" ]]; then
                        ialog "Detected setupassistant and user script. User scripts cannot work in setupassistant stage! Removing $file"
                        /bin/rm -f "$file"
                        continue
                    fi
                    ialog "Triggering LaunchAgent for user script: $file"
                    /usr/bin/touch "$USERSCRIPT_TOUCHPATH"
                    /bin/chmod 0777 "$USERSCRIPT_TOUCHPATH"
                    while [[ -f "$USERSCRIPT_TOUCHPATH" ]]; do
                        ialog "Waiting for user script to complete: $file"
                        /bin/sleep 0.5
                    done
                    ;;

                *)
                    ialog "Unknown item type: $type"
                    ;;
            esac

            write_item_runtime "$stage" "$name" "$item_start"
        done
    done

    cleanup 0
}

main "$@"
