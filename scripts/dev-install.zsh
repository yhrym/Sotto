#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly REPOSITORY_ROOT=${SCRIPT_DIR:h}
readonly SIGNING_IDENTITY=${SOTTO_SIGNING_IDENTITY:-Sotto Local Development}
readonly DERIVED_DATA_PATH="${REPOSITORY_ROOT}/.build/DerivedData"
readonly BUILT_APP="${DERIVED_DATA_PATH}/Build/Products/Debug/Sotto.app"
readonly INSTALL_PARENT="/Applications"
readonly INSTALLED_APP="${INSTALL_PARENT}/Sotto.app"

typeset -g STAGE_PATH=""
typeset -g BACKUP_PATH=""
typeset -g LAUNCH_AFTER_INSTALL=1

note() {
    print -r -- "==> $*"
}

fail() {
    print -ru2 -- "エラー: $*"
    exit 1
}

safe_remove_transaction_path() {
    local path=$1
    if [[ "$path" == "${INSTALL_PARENT}/.Sotto.dev-stage."<->.<-> \
        || "$path" == "${INSTALL_PARENT}/.Sotto.dev-backup."<->.<-> ]]; then
        /bin/rm -rf -- "$path"
        return
    fi
    fail "安全でない一時パスの削除を拒否しました: ${path}"
}

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    if [[ -n "$STAGE_PATH" && -e "$STAGE_PATH" ]]; then
        safe_remove_transaction_path "$STAGE_PATH"
    fi

    if [[ -n "$BACKUP_PATH" && -e "$BACKUP_PATH" ]]; then
        if [[ ! -e "$INSTALLED_APP" ]]; then
            print -ru2 -- "更新に失敗したため、以前のSotto.appを復元します。"
            /bin/mv -- "$BACKUP_PATH" "$INSTALLED_APP"
        else
            print -ru2 -- "以前のアプリを次の場所へ残しました: ${BACKUP_PATH}"
        fi
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

if (( $# > 1 )); then
    fail "使用方法: scripts/dev-install.zsh [--no-launch]"
elif (( $# == 1 )); then
    if [[ "$1" == "--no-launch" ]]; then
        LAUNCH_AFTER_INSTALL=0
    else
        fail "不明なオプションです: $1"
    fi
fi

find_sotto_pids() {
    /usr/bin/pgrep -x Sotto 2>/dev/null || true
}

open_m4a_files() {
    local pid=$1
    /usr/sbin/lsof -nP -Fn -p "$pid" 2>/dev/null \
        | /usr/bin/sed -n 's/^n//p' \
        | /usr/bin/grep -Ei '\.m4a($| )' \
        || true
}

stop_idle_sotto_if_needed() {
    local pid
    local open_audio
    typeset -a pids
    pids=("${(@f)$(find_sotto_pids)}")
    pids=("${(@)pids:#}")

    (( ${#pids} == 0 )) && return

    for pid in "${pids[@]}"; do
        open_audio=$(open_m4a_files "$pid")
        if [[ -n "$open_audio" ]]; then
            print -ru2 -- "Sotto (PID ${pid}) が音声ファイルを使用中です:"
            print -ru2 -- "$open_audio"
            fail "録音または文字起こし中の可能性があるため、アプリを更新しません。処理終了後に再実行してください。"
        fi
    done

    # Avoid terminating an app that began recording immediately after the first check.
    /bin/sleep 0.5
    for pid in "${pids[@]}"; do
        if /bin/kill -0 "$pid" 2>/dev/null; then
            open_audio=$(open_m4a_files "$pid")
            if [[ -n "$open_audio" ]]; then
                print -ru2 -- "Sotto (PID ${pid}) が音声ファイルを使用中です:"
                print -ru2 -- "$open_audio"
                fail "録音または文字起こしが始まったため、アプリを更新しません。"
            fi
        fi
    done

    note "待機中のSottoを終了します"
    for pid in "${pids[@]}"; do
        /bin/kill -TERM "$pid" 2>/dev/null || true
    done

    local attempt
    for attempt in {1..50}; do
        [[ -z "$(find_sotto_pids)" ]] && return
        /bin/sleep 0.1
    done
    fail "Sottoが終了しませんでした。強制終了は行っていません。手動で終了してから再実行してください。"
}

verify_signing_identity() {
    if ! /usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/grep -Fq "\"${SIGNING_IDENTITY}\""; then
        fail "コード署名証明書「${SIGNING_IDENTITY}」が見つかりません。"
    fi
}

verify_app() {
    local app_path=$1
    local signature_info
    local entitlements

    /usr/bin/codesign --verify --deep --strict "$app_path"
    signature_info=$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)
    if ! print -r -- "$signature_info" \
        | /usr/bin/grep -Fq "Authority=${SIGNING_IDENTITY}"; then
        print -ru2 -- "$signature_info"
        fail "Sottoが「${SIGNING_IDENTITY}」で署名されていません。"
    fi

    entitlements=$(/usr/bin/codesign -d --entitlements - "$app_path" 2>/dev/null)
    if print -r -- "$entitlements" \
        | /usr/bin/grep -Eq 'com\.apple\.security\.network\.(client|server)'; then
        fail "ネットワークentitlementを検出したため、インストールを中止しました。"
    fi
}

install_app_transactionally() {
    local transaction_id="$(/bin/date +%s).$$"
    STAGE_PATH="${INSTALL_PARENT}/.Sotto.dev-stage.${transaction_id}"
    BACKUP_PATH="${INSTALL_PARENT}/.Sotto.dev-backup.${transaction_id}"

    [[ -e "$STAGE_PATH" || -e "$BACKUP_PATH" ]] \
        && fail "インストール用一時パスがすでに存在します。"

    note "署名済みアプリをApplicationsへ準備します"
    /usr/bin/ditto "$BUILT_APP" "$STAGE_PATH"
    verify_app "$STAGE_PATH"

    if [[ -e "$INSTALLED_APP" ]]; then
        /bin/mv -- "$INSTALLED_APP" "$BACKUP_PATH"
    fi

    /bin/mv -- "$STAGE_PATH" "$INSTALLED_APP"
    STAGE_PATH=""
    verify_app "$INSTALLED_APP"

    if [[ -e "$BACKUP_PATH" ]]; then
        safe_remove_transaction_path "$BACKUP_PATH"
    fi
    BACKUP_PATH=""
}

verify_signing_identity
stop_idle_sotto_if_needed

note "Debugビルドを作成します（署名: ${SIGNING_IDENTITY}）"
cd "$REPOSITORY_ROOT"
/usr/bin/xcodebuild \
    -project Sotto.xcodeproj \
    -scheme Sotto \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp=none \
    build

[[ -d "$BUILT_APP" ]] || fail "ビルド済みSotto.appが見つかりません: ${BUILT_APP}"
verify_app "$BUILT_APP"
install_app_transactionally

if (( LAUNCH_AFTER_INSTALL )); then
    note "Sottoを起動します"
    /usr/bin/open "$INSTALLED_APP"
fi

note "完了しました"
/usr/bin/codesign -d -r- "$INSTALLED_APP" 2>&1
