# Sotto 開発時の反復テスト

## 目的

Debugビルドを同じローカル証明書で署名し、macOSが更新後も同じSottoとして
認識できる状態を維持する。公開Releaseのadhoc署名設定は変更しない。

## 初回準備

ログインキーチェーンに、次のコード署名identityが必要。

```text
Sotto Local Development
```

確認:

```bash
security find-identity -v -p codesigning
```

初回ビルド時にキーチェーンが秘密鍵の使用許可を求めた場合は、内容を確認して
`常に許可`を選ぶ。初めてこの署名へ切り替えたときは、マイクと
画面・システムオーディオ録音を一度だけ再承認する可能性がある。

証明書名を変えた場合は環境変数で指定できる。

```bash
SOTTO_SIGNING_IDENTITY="別の証明書名" scripts/dev-install.zsh
```

## ビルド・更新・起動

```bash
scripts/dev-install.zsh
```

このスクリプトは次を行う。

1. ローカル署名identityを確認
2. 起動中のSottoが`.m4a`を開いていないか確認
3. 安定した署名でDebugビルド
4. 署名とネットワークentitlement不在を検証
5. `/Applications/Sotto.app`をトランザクション形式で更新
6. 更新したSottoを起動

録音または文字起こし中と判断した場合は、起動中のSottoを終了せず更新を拒否する。
待機中のSottoだけを通常終了し、強制終了は行わない。更新に失敗した場合は、
可能な限り以前のApplications版を復元する。

プロジェクトのRelease署名設定は変更せず、証明書名はコマンドラインから
Debugビルドだけへ渡す。

## 合成音声を使った確認

YouTubeやネットワークを使わず、macOSにインストール済みの日本語読み上げ音声を
3種類使って、複数話者に相当するシステム音声を再生できる。

```bash
scripts/dev-test-audio.zsh
```

同じ音声を冒頭と最後に使うため、将来の話者分離で同一話者へまとまるかも確認できる。
マイク入力は実際の入力デバイスを確認する必要があるため、合成音声の再生後に
数秒間話して確認する。

ビルド、更新、起動、合成音声の案内を一度に行う場合:

```bash
scripts/dev-smoke.zsh
```

Debug版だけで有効な明示的起動引数を使い、録音開始と停止も自動で行う。
通常起動およびReleaseビルドではこの起動引数は機能しない。標準の録音時間は40秒で、
必要なら25〜300秒の範囲で変更できる。

```bash
SOTTO_SMOKE_DURATION=60 scripts/dev-smoke.zsh
```

AccessibilityやApple Eventsの権限は使用しない。初回のマイクおよび
画面・システムオーディオ録音の承認だけは、macOSのダイアログで手動許可する。

## 署名の確認

Applications版がローカル証明書で署名されていることを確認する。

```bash
codesign -dv --verbose=4 /Applications/Sotto.app
codesign -d -r- /Applications/Sotto.app
```

`Authority=Sotto Local Development`が表示され、複数回のビルドでdesignated
requirementが変わらないことを確認する。
