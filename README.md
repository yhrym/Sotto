# Sotto

Sotto は、macOS のメニューバーから会議のシステム音声とマイク音声を録音し、停止後に端末内で日本語文字起こしするアプリです。録音は参加者全員の同意を得たうえで使用してください。

音声、文字起こし結果、会議日時、時間、ファイル名などを外部へ送信しません。設計の詳細は [docs/DESIGN.md](docs/DESIGN.md) を参照してください。

## 動作要件

- macOS 26.0 以上
- Xcode 26.x（ソースからビルドする場合のみ）
- 日本語をオンデバイス認識できる Mac
- 画面とシステムオーディオ録音、およびマイクの許可

Developer ID 証明書、公証、配布用署名は使用しません。通常はGitHub ReleasesのZIP版を利用してください。ソースから `Sign to Run Locally` でビルドすることもできます。

## ZIP版をダウンロードして使う

Xcodeなしで使う場合の最短手順です。

1. [Releasesの最新版](https://github.com/yhrym/Sotto/releases/latest)から `Sotto-local.zip` と `Sotto-local.zip.sha256` をダウンロードします。
2. Terminalで次を実行し、`Sotto-local.zip: OK` と表示されることを確認します。

```bash
cd ~/Downloads
shasum -a 256 -c Sotto-local.zip.sha256
```

3. ZIPを展開し、`Sotto.app` をApplicationsへ移動します。
4. Sottoを一度開き、警告が出たら閉じます。
5. `システム設定 > プライバシーとセキュリティ` の「このまま開く」を押します。
6. 起動後、録音開始を押し、画面とシステムオーディオ録音・マイクを許可します。

ZIP版はDeveloper ID署名・公証を行っていないため、初回だけ手順5が必要です。管理対象のMacで「このまま開く」が禁止されている場合は、ソースからローカルビルドするか管理者へ依頼してください。

詳しい画面操作はApple公式の「[Macで提供元が不明なアプリを開く](https://support.apple.com/ja-jp/guide/mac-help/mh40616/mac)」を参照してください。

## ソースからビルドする

ZIP版を使わず、自分でビルドする場合の手順です。Apple Developer Programへの登録は必要ありません。

### Xcodeを準備する

1. macOS 26.0 以上へ更新します。
2. App Store または Apple Developer から Xcode 26.x をインストールします。
3. 初回起動時に表示されるライセンスと追加コンポーネントの確認を完了します。
4. Terminal で次を確認します。

```bash
xcodebuild -version
```

`Xcode 26.x` と表示されれば準備完了です。Command Line Tools が別の場所を指している場合は、次で完全版 Xcode を選択します。

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### Xcodeの画面からビルドする

1. ソース一式を任意のフォルダへコピーします。
2. `Sotto.xcodeproj` を Xcode で開きます。
3. Project navigator でプロジェクト `Sotto` を選び、TARGETS の `Sotto` を選択します。
4. `General` の Deployment Target が macOS 26.0 以上であることを確認します。
5. `Signing & Capabilities` を開きます。
6. Signing Certificate に `Sign to Run Locally` を選択します。
7. Developer ID 配布用 Team は設定しません。
8. App Sandbox が有効で、Outgoing Connections のようなネットワーク権限が追加されていないことを確認します。
9. Scheme `Sotto` と実行先 `My Mac` を選択します。
10. `Product > Build` または `⌘B` を実行します。

ビルド後、Xcode の左側にある Products の `Sotto.app` を右クリックし、`Show in Finder` を選びます。表示された `Sotto.app` を `/Applications` へコピーします。同名の旧版がある場合は、Sottoを終了して旧版をゴミ箱へ移してからコピーしてください。

### Terminalからビルドする

Terminal でソースのルート、つまり `Sotto.xcodeproj` と `README.md` があるフォルダへ移動して実行します。`CODE_SIGN_IDENTITY=-` が `Sign to Run Locally` の ad-hoc signing を指定します。

```bash
xcodebuild \
  -project Sotto.xcodeproj \
  -scheme Sotto \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/.build/DerivedData" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  build
```

`** BUILD SUCCEEDED **` が表示されたら、ビルド結果は次にあります。

```text
.build/DerivedData/Build/Products/Debug/Sotto.app
```

Sottoが起動中なら終了し、同名の旧版がある場合はFinderでゴミ箱へ移してから、次のコマンドでApplicationsへ配置します。

```bash
sudo ditto \
  .build/DerivedData/Build/Products/Debug/Sotto.app \
  /Applications/Sotto.app
```

署名とentitlementを確認します。

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Sotto.app
codesign -d --entitlements - /Applications/Sotto.app
```

最初のコマンドで `valid on disk` が表示され、2番目の出力に `com.apple.security.app-sandbox` があり、`com.apple.security.network.client` がないことを確認してください。

### 起動する

FinderのApplicationsからSottoを開くか、Terminalで次を実行します。

```bash
open /Applications/Sotto.app
```

SottoはDockではなくメニューバーに波形アイコンを表示します。初回実行時や再ビルド後、macOSが権限の再確認を求める場合があります。続けて「初回起動と権限」の手順を実施してください。

### 動作確認

1. YouTubeなどで音声を再生します。
2. Sottoの設定画面を開きます。
3. 録音を開始し、「入力レベル」の青いシステム音声メーターと緑のマイクメーターが反応することを確認します。
4. 10秒ほど録音して停止します。
5. `~/Music/Sotto/YYYY-MM-DD/` に同名の `.m4a` と `.md` が生成されることを確認します。
6. `.m4a` を再生し、システム音声とマイク音声の両方が聞こえることを確認します。

文字起こしが有効な場合、初回だけ日本語モデルの準備に時間がかかることがあります。モデル準備中も録音ファイルは先に安全に保存されます。

### 更新する場合

新しいソースへ差し替えた後、同じ手順で再ビルドします。実行中のSottoを終了し、`/Applications/Sotto.app` を置き換えて起動してください。`Sign to Run Locally` はビルドごとに署名が変わり得るため、macOSから求められた場合は画面とシステムオーディオ録音、マイクの許可をやり直します。

## 初回起動と権限

### 画面とシステムオーディオ録音

Sotto は ScreenCaptureKit でシステム音声を取得するため、この許可が必要です。画面の映像は保存せず、受信した映像フレームは直ちに破棄します。

1. Sotto のメニューバーアイコンをクリックします。
2. 録音開始を押します。
3. macOS の確認ダイアログで許可します。
4. 手動で設定する場合は、`システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオ録音` を開きます。
5. Sotto を許可します。
6. macOS から求められた場合は Sotto を終了して再起動します。

拒否済みの場合、Sotto のエラーダイアログにあるボタンから該当するシステム設定を開けます。

### マイク

1. 初回の録音開始時に表示されるマイクアクセス確認で許可します。
2. 手動で設定する場合は、`システム設定 > プライバシーとセキュリティ > マイク` を開きます。
3. Sotto を許可します。

### 日本語音声認識モデル

文字起こしが ON の場合、初回に日本語のオンデバイス音声認識モデルが必要になることがあります。Sotto はモデルの準備が完了するまで文字起こしジョブを待機させ、メニュー内に進捗を表示します。

モデルは Apple の Speech framework が管理するシステム資産です。会議音声、文字起こし結果、録音日時、ファイル名をモデル取得要求に渡しません。日本語のオンデバイス認識が利用できない場合、サーバー認識へ切り替えずエラーにします。

## 使い方

1. メニューバーの Sotto アイコンをクリックします。
2. メニュー内の録音開始ボタンを押します。
3. 録音中はアイコンの表示が変わり、経過時間が表示されます。
4. もう一度メニューを開き、録音停止ボタンを押します。
5. 文字起こしが ON なら、停止後にバックグラウンド処理が始まります。処理中も次の録音を開始できます。

デフォルトの保存先は次です。

```text
~/Music/Sotto/YYYY-MM-DD/
```

保存先は設定画面で変更できます。変更先はフォルダ選択ダイアログで明示的に許可され、security-scoped bookmark として保存されます。

通常録音と文字起こしは、次の名前で保存されます。

```text
2026-07-28_143012.m4a
2026-07-28_143012.md
```

## ネットワーク通信を行わない根拠

Sotto はネットワーク通信を一切行わない構成です。

- App Sandbox を有効にしています。
- 外向き接続を許可する `com.apple.security.network.client` entitlement を付与していません。
- 待ち受けを許可する `com.apple.security.network.server` entitlement も付与していません。
- 文字起こしは `SpeechAnalyzer` / `SpeechTranscriber` のオンデバイス認識だけを使用します。
- サーバー認識へのフォールバックを実装していません。
- 外部の音声認識、翻訳、要約 API を呼びません。
- URLSession などを使ったアップロード処理を実装していません。
- 外部 SPM パッケージを使用しません。
- アナリティクス、テレメトリ、クラッシュレポート、自動更新確認を組み込みません。

必要な entitlements は App Sandbox、マイク、Music フォルダの読み書き、ユーザーが選択したフォルダの読み書きに限定しています。画面とシステムオーディオ録音は macOS の TCC 許可で管理されます。

日本語音声認識モデルが未導入の場合、Apple の Speech framework が管理するモデル資産の準備が必要になることがあります。この処理に会議の音声やメタデータは渡しません。モデル準備後の文字起こしは端末内だけで行います。

## entitlement を自分で確認する

`/Applications/Sotto.app` にコピーしたアプリを確認する場合は、指定のコマンドを実行します。

```bash
codesign -d --entitlements - /Applications/Sotto.app
```

`codesign` のバージョンによっては、plist を標準出力へ明示する次の形式も使用できます。

```bash
codesign -d --entitlements :- /Applications/Sotto.app
```

出力に少なくとも次があることを確認します。

```text
com.apple.security.app-sandbox = true
com.apple.security.device.audio-input = true
com.apple.security.assets.music.read-write = true
com.apple.security.files.user-selected.read-write = true
```

出力に次のキーがないことを確認します。

```text
com.apple.security.network.client
com.apple.security.network.server
```

Xcode の DerivedData にあるビルド結果を確認する場合は、実際の `.app` のパスへ置き換えて同じコマンドを実行します。パスは Xcode の `Products` にある Sotto.app を右クリックして `Show in Finder` を選ぶと確認できます。

署名要件も含めて詳しく表示するには次を使用します。

```bash
codesign -dvvv --entitlements :- /Applications/Sotto.app
```

## 録音中に外向き通信がないことを確認する

entitlement の確認に加えて、実行時にも確認できます。最初に Sotto を起動し、Terminal で PID を取得します。

```bash
pgrep -x Sotto
```

表示された数値を、以下の `<PID>` と置き換えます。

### lsof で確認

録音中に次を数回実行します。

```bash
lsof -nP -a -p <PID> -i
```

何も表示されなければ、その時点で Sotto プロセスが持つ IPv4 / IPv6 のネットワークソケットはありません。継続監視する場合は別の Terminal で次を実行し、録音開始、数分間の録音、停止、文字起こしまで観察します。

```bash
while true; do
  date
  lsof -nP -a -p <PID> -i
  sleep 1
done
```

終了は `Control-C` です。

### nettop で確認

macOS 標準の `nettop` でも対象プロセスを監視できます。

```bash
nettop -p <PID>
```

録音開始から停止、文字起こし完了まで、Sotto に外向き接続や送受信バイトが発生しないことを確認します。終了は `q` です。

モデルが未導入の初回確認では、Speech framework が管理するシステム側プロセスの通信と Sotto 自身の通信を混同しないよう、必ず PID で Sotto プロセスだけを対象にしてください。会議中の Teams、Google Meet、ブラウザは当然ネットワークを使用するため、アプリ名または PID を限定せずに観察すると判別できません。

より厳密に確認する場合は、録音前後を含む十分な時間、`lsof` と `nettop` の両方で Sotto の PID を監視し、あわせて上記 `codesign` で `network.client` がないことを確認してください。

## トラブルシューティング

### 録音を開始できない

- 保存先ボリュームの空き容量が 1 GB 以上あるか確認してください。
- 画面とシステムオーディオ録音、およびマイクの両方が許可されているか確認してください。
- 権限を変更した直後は Sotto を再起動してください。

### 文字起こしに失敗する

メニュー内の失敗理由を確認し、再実行してください。失敗しても通常の `.m4a` は削除されません。再実行に必要な分離一時ファイルも失敗時には保持されます。

日本語オンデバイスモデルが利用できない場合、Sotto は外部サービスへフォールバックしません。

### AirPods などを切り替えた

入力デバイス変更でストリームが終了した場合、現在のファイルを閉じて `_part02` 以降の分割ファイルとして再開します。分割前の録音は保持されます。

## 保存データ

- 通常録音: 選択した保存先
- Markdown: 通常録音と同じフォルダ
- 文字起こし用の分離音声: Caches
- 設定と security-scoped bookmark: アプリのコンテナ
- 文字起こしジョブ状態: アプリのローカル Application Support

文字起こしが成功した場合、設定の「一時ファイルを残す」が OFF なら分離音声を削除します。失敗時は再実行のため保持します。通常録音は文字起こし処理によって削除されません。
