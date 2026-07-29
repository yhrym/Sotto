#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly INSTALLED_APP="/Applications/Sotto.app"
readonly SMOKE_DURATION=${SOTTO_SMOKE_DURATION:-40}

if [[ "$SMOKE_DURATION" != <-> || "$SMOKE_DURATION" -lt 25 || "$SMOKE_DURATION" -gt 300 ]]; then
    print -ru2 -- "エラー: SOTTO_SMOKE_DURATIONは25〜300秒の整数で指定してください。"
    exit 1
fi

"${SCRIPT_DIR}/dev-install.zsh" --no-launch

print -r -- "Sottoを${SMOKE_DURATION}秒間の自動録音モードで起動します。"
/usr/bin/open -n "$INSTALLED_APP" \
    --args --sotto-development-smoke-test "$SMOKE_DURATION"

typeset -a recording_files
for attempt in {1..240}; do
    recording_files=(
        "${(@f)$(
            /usr/sbin/lsof -nP -Fn -c Sotto 2>/dev/null \
                | /usr/bin/sed -n 's/^n//p' \
                | /usr/bin/grep -Ei '\.m4a$' \
                || true
        )}"
    )
    recording_files=("${(@)recording_files:#}")
    (( ${#recording_files} > 0 )) && break
    /bin/sleep 0.5
done

if (( ${#recording_files} == 0 )); then
    print -ru2 -- "エラー: 120秒以内に録音開始を確認できませんでした。"
    print -ru2 -- "Sottoの権限ダイアログまたはエラー表示を確認してください。"
    exit 1
fi

mixed_file=""
for audio_file in "${recording_files[@]}"; do
    if [[ "$audio_file" != *"/Library/Caches/Sotto/Transcription/"* ]]; then
        mixed_file=$audio_file
        break
    fi
done

print -r -- "録音開始を確認しました。"
"${SCRIPT_DIR}/dev-test-audio.zsh"

print -r -- "自動停止まで、マイクに向かって話してください。"
for attempt in {1..600}; do
    if [[ -n "$mixed_file" ]]; then
        if ! /usr/sbin/lsof -nP -c Sotto 2>/dev/null \
            | /usr/bin/grep -Fq "$mixed_file"; then
            break
        fi
    elif ! /usr/sbin/lsof -nP -c Sotto 2>/dev/null \
        | /usr/bin/grep -Eq '\.m4a($| )'; then
        break
    fi
    /bin/sleep 0.5
done

if [[ -n "$mixed_file" && -s "$mixed_file" ]]; then
    print -r -- "録音ファイルを確認しました: ${mixed_file}"
    /usr/bin/afinfo "$mixed_file" \
        | /usr/bin/grep -E 'estimated duration|audio bytes|sample rate|bit rate' \
        || true
else
    print -ru2 -- "警告: 録音ファイルの確定を確認できませんでした。Sottoの表示を確認してください。"
fi

print -r -- "スモークテストが完了しました。文字起こしはSottoで継続する場合があります。"
