# Sotto 設計書

## 1. 目的と前提

Sotto は、参加者全員の同意を得た社内会議を録音する macOS メニューバーアプリである。Teams、Google Meet などの特定アプリには依存せず、ScreenCaptureKit でシステム全体の音声とマイク音声を取得する。録音停止後、Speech framework のオンデバイス認識だけを使って日本語文字起こしを行う。

本アプリは開発者自身の Mac 上でのみ使用する。Developer ID による配布、公証、自動更新は行わず、Xcode の `Sign to Run Locally`（ad-hoc signing）で実行する。

最優先の安全要件は、音声、文字起こし結果、および会議メタデータをネットワークへ送らないことである。App Sandbox を有効にし、`com.apple.security.network.client` と `com.apple.security.network.server` は付与しない。外部ライブラリ、分析、テレメトリ、クラッシュレポート、自動更新、外部 API は組み込まない。

## 2. 対象環境

- Swift / SwiftUI
- Xcode プロジェクト（`.xcodeproj`）
- Deployment Target: macOS 26.0
- メニューバー: SwiftUI `MenuBarExtra`
- キャプチャ: ScreenCaptureKit `SCStream`
- エンコード: AVFoundation `AVAssetWriter`
- 文字起こし: Speech `SpeechAnalyzer` / `SpeechTranscriber`
- 外部パッケージ: なし

`MenuBarExtra` の公開 API では、メニューバーアイコン自体のクリックを録音トグルとして扱えない。このため MenuBarExtra を優先し、アイコンのクリックでメニューを開き、メニュー内の録音ボタンで開始または停止する。

## 3. ディレクトリ構成

```text
Sotto.xcodeproj/
Sotto/
├── App/
│   ├── SottoApp.swift
│   ├── AppModel.swift
│   └── AppDelegate.swift
├── Capture/
│   ├── ScreenCaptureSession.swift
│   ├── CapturePermissionController.swift
│   ├── AudioDeviceMonitor.swift
│   └── SleepAssertion.swift
├── Audio/
│   ├── CapturedAudioChunk.swift
│   ├── AudioFormatNormalizer.swift
│   ├── PCMDistributor.swift
│   ├── TimelineRingBuffer.swift
│   ├── TimestampedAudioMixer.swift
│   ├── AssetWriterSink.swift
│   └── RecordingPipeline.swift
├── Recording/
│   ├── RecordingCoordinator.swift
│   ├── RecordingState.swift
│   └── RecordingManifest.swift
├── Transcription/
│   ├── SpeechModelManager.swift
│   ├── TranscriptionQueue.swift
│   ├── SpeechFileTranscriber.swift
│   ├── TranscriptMerger.swift
│   ├── MarkdownTranscriptWriter.swift
│   └── TranscriptionJobStore.swift
├── Storage/
│   ├── RecordingStorage.swift
│   ├── SecurityScopedBookmarkStore.swift
│   └── DiskSpaceChecker.swift
├── Services/
│   ├── LoginItemController.swift
│   └── FinderController.swift
├── UI/
│   ├── MenuBarContentView.swift
│   ├── MenuBarLabel.swift
│   ├── SettingsView.swift
│   ├── FailureDetailView.swift
│   └── PermissionAlertPresenter.swift
├── Models/
│   └── AppSettings.swift
├── Resources/
│   ├── Info.plist
│   └── Sotto.entitlements
SottoTests/
├── TimestampedAudioMixerTests.swift
├── AudioFormatNormalizerTests.swift
├── TranscriptMergerTests.swift
├── RecordingNamingTests.swift
└── FragmentedAssetWriterTests.swift
README.md
docs/
└── DESIGN.md
```

実装時にファイルを統合または分割しても、後述する責務境界は維持する。

## 4. 主要な型と責務

### 4.1 アプリケーション

- `SottoApp`: `MenuBarExtra` と Settings scene のエントリーポイント。
- `AppModel`: UI に公開する録音、文字起こし、権限、エラー、設定の状態を集約する。
- `AppDelegate`: AppKit が必要な権限ダイアログ、Finder 表示、終了処理を橋渡しする。

### 4.2 録音

- `RecordingCoordinator`: 録音状態を所有する actor。開始、停止、ストリーム障害からの分割再開を直列化する。
- `ScreenCaptureSession`: `SCStream` を構成し、`.audio`、`.microphone`、`.screen` を受信する。映像サンプルは即座に破棄する。
- `RecordingPipeline`: 1 セグメント分のフォーマット変換、購読、ミックス、ファイル書き出しを構築し、正常に閉じる。
- `SleepAssertion`: 録音中だけ `kIOPMAssertPreventUserIdleSystemSleep` を保持する。ディスプレイスリープは妨げない。
- `AudioDeviceMonitor`: 入力デバイス変更や `SCStream` 停止を検知し、コーディネーターへ通知する。

### 4.3 PCM 処理

- `CapturedAudioChunk`: 音源種別、PTS、実フォーマット、PCM データを表す値型。
- `AudioFormatNormalizer`: 各入力を Float32 interleaved/non-interleaved の内部標準表現、48 kHz、2 ch へ変換する。
- `PCMDistributor`: ミックス前の系統別 PCM を複数の購読者へ配る。録音中に全体を保持せず、上限付きバッファを使う。
- `TimelineRingBuffer`: 48 kHz の絶対フレーム位置をキーにサンプルを保持する固定上限リングバッファ。
- `TimestampedAudioMixer`: 2 系統を PTS で整列し、欠損を無音補完してゲインを掛け、クランプしたステレオ PCM を生成する。
- `AssetWriterSink`: PCM を AAC に逐次変換し、`AVAssetWriter` へ append する。出力ファイルごとに専用 writer を持つ。

### 4.4 文字起こし

- `SpeechModelManager`: 日本語ロケールの対応確認、モデル資産の導入要求、ダウンロード進捗、予約と解放を管理する。
- `TranscriptionQueue`: 録音系から独立した直列ジョブキュー。処理中も新しい録音を許可する。
- `SpeechFileTranscriber`: `SpeechTranscriber` と `SpeechAnalyzer` で 1 音源をオンデバイス認識する。
- `TranscriptMerger`: 系統別の結果に `会議` / `自分` を付け、開始時刻で安定ソートする。
- `MarkdownTranscriptWriter`: 同名の `.md` を一時ファイル経由で atomic に保存する。
- `TranscriptionJobStore`: 未完了、失敗、完了したジョブの最小 manifest を Application Support に永続化する。

### 4.5 保存と OS 連携

- `RecordingStorage`: 保存先解決、日付ディレクトリ作成、重複しない名前生成を担当する。
- `SecurityScopedBookmarkStore`: ユーザーが選択したフォルダの bookmark を保存、復元する。
- `DiskSpaceChecker`: 録音開始前に対象ボリュームの空き容量を検査する。
- `LoginItemController`: `SMAppService.mainApp.register()` / `unregister()` を設定に同期する。
- `FinderController`: 保存フォルダを開く、直前の録音を Finder で選択表示する。

## 5. 録音の状態遷移

```text
idle
  └─ start requested
      → preflighting
          ├─ 保存先、空き容量、権限に問題あり
          │    → idle + user-visible error
          └─ OK
               → starting
                   ├─ failure → idle + user-visible error
                   └─ success → recording
                       ├─ stop requested
                       │    → stopping
                       │       → finalizing
                       │          → enqueue transcription
                       │             → idle
                       └─ stream/device failure
                            → rollingOver
                               → finalize current segment
                               → starting next segment
                                  └─ recording
```

`recording` というユーザーの意図と、個々の `SCStream` / ファイルセグメントの寿命を分ける。AirPods の切断などでストリームが落ちたとき、現在の writer を終了してから新しいセグメントで再開する。再開不能の場合はエラーを表示し、それまでに確定した録音を保持する。

ファイル名は録音開始時刻を固定して使用する。

```text
2026-07-28_143012.m4a
2026-07-28_143012_part02.m4a
2026-07-28_143012_part03.m4a
```

各セグメントを独立して文字起こしし、同名の Markdown を生成する。

## 6. キャプチャ構成

`SCShareableContent` から display を 1 つ選び、特定アプリに限定しない最小の `SCContentFilter` を作る。Sotto 自身の音は `excludesCurrentProcessAudio = true` で除外する。

主な `SCStreamConfiguration` は次のとおり。

```swift
configuration.capturesAudio = true
configuration.captureMicrophone = true
configuration.sampleRate = 48_000
configuration.channelCount = 2
configuration.excludesCurrentProcessAudio = true
configuration.queueDepth = 1
configuration.showsCursor = false
```

`.audio` はシステム音声、`.microphone` はマイク音声として別々の serial queue で受ける。音声のみでも映像ストリーム構成が必要なため、最小解像度と低いフレームレートを指定する。`.screen` の callback はピクセルバッファをコピーせず即座に戻り、録画や画像処理をしない。

SDK の仕様上、マイク入力が設定した sample rate / channel count と異なる実フォーマットで到着する場合がある。両系統の実フォーマットを起動時と変更時にローカルログへ残し、`AudioFormatNormalizer` で必ず内部標準形式へ変換する。ログに会議名、音声内容、文字起こし内容は記録しない。

## 7. 2 系統の同期とミックス

### 7.1 内部時刻

到着順ではなく `CMSampleBuffer.presentationTimeStamp` を基準にする。最初に観測した共通 epoch から、各チャンクの PTS を次式で 48 kHz のフレーム位置へ変換する。

```text
frameIndex = round((PTS - epoch) × 48,000)
```

フォーマット変換による端数はチャンクごとに切り捨てず、変換器の継続状態または剰余を保持して累積ドリフトを防ぐ。

### 7.2 リングバッファと watermark

システム音声とマイク音声は別々の `TimelineRingBuffer` に入れる。各要素は絶対フレーム範囲を持つ。ミキサーは固定長ブロック単位で次の出力位置を進める。

両系統のチャンクが揃っている範囲は即時処理する。一方が未着でも、遅延許容 watermark を超えた範囲は欠損系統を無音として確定する。遅れて届いた過去のフレームは差し込まず破棄し、以降のタイムラインをずらさない。

バッファは録音時間に比例して増やさず、許容遅延と writer の backpressure を吸収する固定上限にする。上限超過は無制限のメモリ消費を避けるため、セグメントの安全な終了と再開、または録音停止エラーとして扱う。

### 7.3 ミックス

設定値 `systemGain` と `microphoneGain` はデフォルトをそれぞれ 0.7 とする。チャンネルごとに次式で処理する。

```text
mixed[n] = clamp(
    system[n] * systemGain + microphone[n] * microphoneGain,
    -1.0 ... 1.0
)
```

ミックスは保存用出力であり、分離音源を破壊しない。正規化後の PCM を `PCMDistributor` が次のように配る。

```text
system PCM ─┬─ TimestampedAudioMixer ── mixed AssetWriterSink
            └─ system temporary AssetWriterSink

mic PCM ────┬─ TimestampedAudioMixer
            └─ microphone temporary AssetWriterSink
```

文字起こし OFF の場合は一時ファイル用購読者を作らない。

### 7.4 テスト可能性

`TimestampedAudioMixer` は ScreenCaptureKit と AVAssetWriter に依存させない。PTS 付き PCM ブロックを入力し、出力 PCM ブロックを取得できる純粋な境界を持たせる。最低限、次をユニットテストする。

- 同一 PTS の 2 系統をゲイン付きで加算する
- 同時発話の値を ±1.0 にクランプする
- 片方がない区間を無音として処理する
- 逆順到着でも PTS 順に出力する
- 遅着サンプルで確定済み時刻がずれない
- 長時間相当のチャンク列でサンプル数と時刻がドリフトしない
- mono / 異 sample rate 入力を 48 kHz stereo へ変換する

## 8. ファイル書き出し

通常録音は次へ保存する。

```text
~/Music/Sotto/YYYY-MM-DD/2026-07-28_143012.m4a
```

ユーザーが保存先を変更した場合は、そのフォルダ配下に `YYYY-MM-DD` を作る。フォルダは `NSOpenPanel` で選択し、security-scoped bookmark を保存する。

文字起こし ON の場合だけ、分離音源を Caches に作る。

```text
~/Library/Caches/<bundle-id>/<job-id>-system.m4a
~/Library/Caches/<bundle-id>/<job-id>-microphone.m4a
```

3 本の出力はそれぞれ独立した `AVAssetWriter` を持ち、AAC、48 kHz、ステレオ、設定されたビットレートで逐次 append する。録音全体をメモリへ保持しない。writer が ready でない間のキューには小さな上限を設ける。

中断耐性を上げるため fragmented writing を有効にする。初回 fragment を短くし、その後も定期的に fragment を確定する。異常終了前に確定した fragment を再生できることを実機テストする。ただし、最初の fragment が完成する前のプロセス強制終了に対し、再生可能性を完全には保証できない。

正常停止時は入力を mark finished し、`finishWriting()` の完了を待ってからジョブを投入する。文字起こし失敗時も通常録音は変更も削除もしない。

## 9. 録音前検査と権限フロー

録音開始要求ごとに次の順で検査する。

1. 保存先を解決する。bookmark 使用時は security scope を開始する。
2. 日付フォルダを作成可能か確認する。
3. 対象ボリュームの空き容量を確認する。
4. 空き容量が 1 GB 未満なら警告し、録音を開始しない。
5. `CGPreflightScreenCaptureAccess()` で画面とシステムオーディオ録音権限を確認する。
6. 未決定なら `CGRequestScreenCaptureAccess()` で要求する。
7. マイク権限を確認し、未決定なら要求する。
8. 拒否済みの場合は、該当する「プライバシーとセキュリティ」設定ペインを開くボタン付きダイアログを表示する。
9. `SCShareableContent` と `SCStream` を準備する。
10. writer の開始後に stream を開始し、録音状態へ遷移する。

権限ダイアログの再表示可否は OS が管理する。すでに拒否済みならアプリ内で繰り返し要求せず、システム設定への案内を表示する。画面収録権限の変更後、OS の要求に応じてアプリ再起動を案内する。

`Info.plist` には日本語の用途説明を含める。

```text
NSScreenCaptureUsageDescription
会議のシステム音声を録音するために画面とシステムオーディオへのアクセスを使用します。

NSMicrophoneUsageDescription
会議で自分の音声を録音するためにマイクを使用します。

NSSpeechRecognitionUsageDescription
録音した会議音声を端末内で文字起こしするために使用します。
```

## 10. スリープとデバイス変更

録音開始時に `IOPMAssertionCreateWithName` で `kIOPMAssertPreventUserIdleSystemSleep` を取得し、すべての停止、開始失敗、異常終了の経路で解放する。ディスプレイスリープを抑止する assertion は使わない。

入力デバイス変更、`SCStream` の停止、出力 callback のエラーを検知したら、次の順序を守る。

1. 新規サンプル受け付けを停止する。
2. ミキサーの確定可能範囲を flush する。
3. writer inputs を完了する。
4. `finishWriting()` を待ち、現セグメントを閉じる。
5. 文字起こし対象なら現セグメントのジョブを保存する。
6. ユーザーの録音意思が継続中なら、新しい `SCStream` と writer で `partNN` を開始する。

短時間に変更通知が連続しても多重再開しないよう、処理は `RecordingCoordinator` actor で直列化し、generation ID で古い callback を無視する。

## 11. 文字起こし

### 11.1 オンデバイス限定

文字起こしには `SpeechTranscriber` と `SpeechAnalyzer` のみを使用する。`SFSpeechRecognizer`、`DictationTranscriber`、外部 API、サーバー認識へのフォールバックは実装しない。

概念的な構成は次のとおり。

```swift
let locale = await SpeechTranscriber.supportedLocale(
    equivalentTo: Locale(identifier: "ja-JP")
)

let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [],
    attributeOptions: [.audioTimeRange]
)

let analyzer = SpeechAnalyzer(modules: [transcriber])
```

実装時は使用中 Xcode SDK の宣言を再確認する。日本語ロケール、オンデバイス transcriber、または必要なモデルが利用できない場合は、別方式へフォールバックせず失敗として記録する。API 仕様上サーバー送信を排除できないことが判明した場合は文字起こしを実装せず、作業を止めて報告する。

### 11.2 モデル管理

必要なモデル資産は `AssetInventory.assetInstallationRequest(supporting:)` から要求する。要求が返った場合は `Progress.fractionCompleted` を監視し、メニューにダウンロード進捗を表示する。全ジョブはモデル準備完了まで `waitingForModel` で待機する。

モデル導入は OS が管理する Speech 資産に対する操作であり、会議音声やメタデータを渡さない。Sotto 自身にはネットワーク client entitlement がない。モデルの予約と解放は SDK の `reserve(locale:)` / `release(reservedLocale:)` に合わせ、アプリ終了や処理完了で解放する。

### 11.3 ジョブ状態

```text
recording
  → queued
  → waitingForModel
  → transcribingSystem
  → transcribingMicrophone
  → merging
  → writingMarkdown
  → succeeded
  → cleanup
```

失敗時:

```text
任意の処理状態
  → failed(errorDescription, retryable)
  → ユーザーが「再実行」
  → queued
```

ジョブは録音から独立した actor で直列処理する。文字起こし中も録音開始、停止、および次ジョブの投入を許可する。アプリ終了後も再試行可能にするため、ジョブ ID、通常録音 URL への参照、2 一時ファイル URL、開始日時、継続時間、状態、失敗理由をローカル manifest に保存する。

失敗理由はメニューから確認できるようにする。再実行では既存の分離一時ファイルを使用し、通常録音を上書きしない。一時ファイルが存在しない場合は理由を明示して再実行不可とする。

### 11.4 進捗

認識中は結果の audio time range とファイル duration から概算進捗を算出する。進捗時刻が得られない間は不確かな数値を表示せず indeterminate とする。2 系統全体の進捗は各ファイルの duration で重み付けする。

録音中かつ文字起こし中の場合、メニューバーラベルでは録音時間を優先し、処理中バッジを併記する。詳細なモデルまたは認識進捗はメニュー内に表示する。

### 11.5 マージと出力

各認識結果を次の内部形式へ変換する。

```swift
struct TranscriptEntry {
    let startTime: Duration
    let speaker: Speaker // meeting / self
    let text: String
    let sequence: Int
}
```

system の結果に `会議`、microphone の結果に `自分` を付ける。開始時刻で昇順に安定ソートし、同一時刻の場合は元の sequence で順序を固定する。空白だけの結果は除外し、文字列を正規化して Markdown の 1 項目とする。

音声と同じフォルダへ、一時ファイルから atomic replace して保存する。

```markdown
# 2026-07-28 14:30:12 (52分13秒)

- [00:00:03] 会議: おはようございます
- [00:00:07] 自分: よろしくお願いします
```

両系統の認識と Markdown 保存が成功した後だけ cleanup へ進む。「一時ファイルを残す」が OFF なら分離ファイルを削除し、ON なら保持する。失敗時は設定に関係なく一時ファイルを保持する。通常録音はどの経路でも削除しない。

## 12. UI

### 12.1 メニューバー

停止中は通常アイコン、録音中は塗りまたは赤い状態表示と経過時間を表示する。

```text
停止中: waveform
録音中: ● 12:34
録音中・文字起こしあり: ● 12:34 + processing badge
停止中・文字起こし中: waveform 42%
```

メニューには最低限、次を置く。

- 録音開始 / 録音停止
- 現在の録音時間
- 文字起こしジョブと進捗
- 直近の失敗理由と再実行
- 保存フォルダを開く
- 直前の録音を Finder で表示
- 設定
- 終了

録音開始または停止はメニュー内の主ボタン 1 回で完了する。

### 12.2 設定

- 保存先
- AAC ビットレート
- ログイン時に自動起動
- システム音声ゲイン
- マイクゲイン
- 文字起こし ON / OFF
- 一時ファイルを残す

文字起こしを OFF に変更しても、すでに実行中のジョブは安全に完了させる。次回の録音から分離一時ファイルを作らない。失敗ジョブの手動削除は本スコープに含めず、既存録音を暗黙に削除しない。

## 13. ログイン時の自動起動

別 helper executable は作らず、メインアプリから `SMAppService.mainApp` を使う。設定 ON で `register()`、OFF で `unregister()` を呼ぶ。OS の承認状態や登録エラーは設定画面に表示し、登録失敗を録音失敗として扱わない。

## 14. Sandbox と entitlements

entitlements は次に限定する。

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.assets.music.read-write</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

次は付与しない。

- `com.apple.security.network.client`
- `com.apple.security.network.server`
- Apple Events
- Downloads、Pictures、Movies など不要なフォルダ権限
- Address Book、Calendar、Photos など不要な個人情報権限

画面とシステムオーディオ録音は TCC の許可を使う。App Sandbox と ScreenCaptureKit のシステム音声取得が実機で両立しない場合、Sandbox を外したり権限を追加したりせず、実装を止めて理由を報告する。

## 15. エラー処理の原則

- 通常録音ファイルをエラー回復や cleanup の対象として削除しない。
- 開始前エラーでは出力ファイルを作らない。
- writer 開始後のエラーでは、可能な限り `finishWriting()` して確定済み部分を残す。
- UI 向けエラーはユーザーが取れる行動を含む日本語にする。
- 内部エラーには段階、日時、関連するローカル job ID を含めるが、音声内容や文字起こし本文をログへ出さない。
- 権限不足、ディスク不足、モデル非対応、一時ファイル消失、writer failure を区別する。
- ネットワークを必要とする回避策へフォールバックしない。

## 16. テスト計画

### 16.1 自動テスト

- PTS 同期、無音補完、逆順到着、遅着破棄
- ゲインとクランプ
- 音声フォーマット変換
- ファイル名と part 番号
- 文字起こし結果の安定マージ
- Markdown の時刻、継続時間、エスケープ
- bookmark の保存と stale bookmark 更新
- ジョブ状態の永続化と再開
- 文字起こし OFF 時に一時 writer を作らない
- 正常時と失敗時の一時ファイル cleanup 条件

### 16.2 実機テスト

1. App Sandbox 有効、network client なしで起動する。
2. 画面収録とマイクを許可する。
3. システム音声とマイクを同じ `SCStream` から受信できる。
4. 両系統の実フォーマットを確認する。
5. 10 秒以上録音し、混合 `.m4a` を再生できる。
6. system / microphone 一時 `.m4a` を個別再生できる。
7. 日本語モデルを準備し、2 系統をオンデバイス認識できる。
8. 同名 `.md` が生成され、時刻順とラベルが正しい。
9. 文字起こし中に次の録音を開始できる。
10. AirPods 接続、切断で確定済みファイルが壊れず、part ファイルへ再開する。
11. 録音中のアプリ強制終了後、確定済み fragment を再生できる。
12. 空き容量 1 GB 未満のボリュームで開始を拒否する。
13. 権限拒否時に対応するシステム設定を開ける。
14. カスタム保存先が再起動後も security-scoped bookmark で利用できる。
15. ログイン項目の ON / OFF が OS 設定へ反映される。
16. `codesign` で Sandbox と必要 entitlement のみを確認する。
17. 録音中に Sotto プロセスの外向き接続がないことを確認する。

## 17. 実装順序と停止条件

1. `.xcodeproj`、Info.plist、Sandbox entitlements、ad-hoc signing を作る。
2. App Sandbox 下で ScreenCaptureKit の system / microphone 入力を 10 秒取得する。
3. 2 系統の実フォーマットを確認し、混合と 3 ファイル書き出しを通す。
4. ミキサーを自動テストする。
5. Speech の日本語モデル準備とオンデバイス認識を通す。
6. ジョブキュー、マージ、Markdown を実装する。
7. デバイス変更、分割再開、fragment、失敗復元を実装する。
8. MenuBarExtra、設定、権限案内、ログイン項目を仕上げる。
9. README の手順に従い、署名と通信を検証する。

次のいずれかが判明した場合は、セキュリティ条件を緩めず作業を停止して報告する。

- App Sandbox と ScreenCaptureKit のシステム音声キャプチャが両立しない。
- `SpeechTranscriber` のオンデバイス処理を保証できない。
- Speech がサーバー認識へフォールバックする可能性を無効化できない。
- 実装上、外向きネットワーク entitlement または外部依存が必要になる。

## 18. 受け入れ条件

- `Sign to Run Locally` でビルドし、macOS 26.0 以上で起動する。
- MenuBarExtra から録音を開始、停止できる。
- システム音声とマイクを同期して混合したステレオ AAC `.m4a` が生成される。
- 文字起こし ON 時だけ分離一時ファイルが生成される。
- 停止後にオンデバイス日本語文字起こしが走り、話者ラベル付き `.md` が生成される。
- 文字起こし中も新しい録音を開始できる。
- 文字起こし失敗時に通常録音と分離一時ファイルが残り、理由表示と再実行ができる。
- 権限、低ディスク容量、デバイス変更を安全に処理する。
- 長時間録音で音声全体をメモリへ保持しない。
- App Sandbox が有効で `com.apple.security.network.client` が存在しない。
- 外部 API、テレメトリ、自動更新、外部依存が存在しない。
