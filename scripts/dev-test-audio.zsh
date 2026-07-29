#!/bin/zsh

emulate -L zsh
set -euo pipefail

fail() {
    print -ru2 -- "エラー: $*"
    exit 1
}

typeset -a available_voices
typeset -a selected_voices
typeset -a preferred_voices
typeset -a utterances
typeset -a speaker_order
typeset -a speaker_labels

while IFS= read -r voice_name; do
    [[ -n "$voice_name" ]] && available_voices+=("$voice_name")
done < <(
    /usr/bin/say -v '?' \
        | /usr/bin/sed -nE 's/^(.+[^[:space:]])[[:space:]]+ja_JP[[:space:]]+#.*$/\1/p'
)

(( ${#available_voices} >= 3 )) \
    || fail "日本語音声が3種類以上必要です。システム設定で日本語の読み上げ音声を追加してください。"

preferred_voices=(
    "Kyoko"
    "Eddy (日本語（日本）)"
    "Grandpa (日本語（日本）)"
)

for preferred in "${preferred_voices[@]}"; do
    for available in "${available_voices[@]}"; do
        if [[ "$preferred" == "$available" ]]; then
            selected_voices+=("$available")
            break
        fi
    done
done

for available in "${available_voices[@]}"; do
    (( ${#selected_voices} >= 3 )) && break
    if (( ${selected_voices[(Ie)$available]} == 0 )); then
        selected_voices+=("$available")
    fi
done

(( ${#selected_voices} == 3 )) || fail "異なる日本語音声を3種類選択できませんでした。"

utterances=(
    "おはようございます。今日の進め方を確認します。"
    "最初に、録音と文字起こしの状態を確認しましょう。"
    "確認が終わったら、次の作業に進みます。"
    "それでは、今日の確認を終了します。"
)
speaker_order=(1 2 3 1)
speaker_labels=(A B C)

print -r -- "システム音声テストを開始します。"
print -r -- "候補A: ${selected_voices[1]}"
print -r -- "候補B: ${selected_voices[2]}"
print -r -- "候補C: ${selected_voices[3]}"

local_index=1
for utterance in "${utterances[@]}"; do
    speaker_index=${speaker_order[$local_index]}
    print -r -- "再生 ${local_index}/4（候補${speaker_labels[$speaker_index]}）"
    /usr/bin/say \
        -v "${selected_voices[$speaker_index]}" \
        -r 175 \
        "$utterance"
    /bin/sleep 0.8
    (( local_index += 1 ))
done

print -r -- "システム音声テストが完了しました。"
print -r -- "マイクも確認する場合は、このまま数秒間話してください。"
