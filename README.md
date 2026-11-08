# ARCE.AI

端末の中だけで動くローカルAIのチャット / コーディングアシスタントです。
Flutter で書かれていて、Android・iOS・Windows・macOS・Linux で同じ画面が動きます。

| OS | 配布物 (OS ごとの GitHub Release) | 推論エンジン | アプリ内更新 |
|---|---|---|---|
| Android | `ARCE.AI-vX.Y.Z-android.apk` | llama.cpp / LiteRT-LM（実推論） | 自動インストール |
| Windows | `ARCE.AI-vX.Y.Z-windows-x64.zip` | 未接続（デモ応答） | 自動置き換え＋再起動 |
| macOS | `ARCE.AI-vX.Y.Z-macos.zip` | 未接続（デモ応答） | 自動置き換え＋再起動 |
| Linux | `ARCE.AI-vX.Y.Z-linux-x64.tar.gz` | 未接続（デモ応答） | 自動置き換え＋再起動 |
| iOS | `ARCE.AI-vX.Y.Z-ios-unsigned.ipa`（未署名） | 未接続（デモ応答） | リリースページを開く |

Android 以外では、推論エンジンの代わりに固定のデモ応答が返ります。チャット・履歴・設定・生成物・更新機能は全 OS で動きます。

## 画面

幅 900px 以上では左サイドバーのデスクトップ配置、それより狭いとスマホ配置（下のナビゲーション）に切り替わります。

- チャット：思考プロセス・検索結果・ask_user の質問カード・コードブロック（HTML はブラウザでプレビュー）
- モデル管理：基本モデルの1タップ導入、ダウンロードの一時停止・再開、SHA-256 検証、メモリ不足の警告
- 生成物：返信の中のコードを一覧、コピー、保存
- 詳細設定：機密情報（APIキーなど）以外は全て設定できます。ローカルモデル・オンラインモデルの設定、分担モード、上限とタイムアウト、思考中のアイコン、口調、速度⇔精度、エージェント、検索、GPU/スレッド、アップデートなど
- 左上のメニューから、チャット履歴を検索
- 分担モード：plan が設計と分担数を決め、coding が担当を調べてレポートを返し、あなたの OK のあとで実装（delegate）

## 開発

```bash
git clone --recurse-submodules https://github.com/keusidan/arce.ai-gui   # llama.cpp は Android のビルドにだけ必要
flutter pub get
flutter analyze && flutter test
flutter run -d linux      # windows / macos / android / ios も同様
```

Flutter 3.47.6（Dart 3.13）で確認しています。Linux でビルドするには `clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev libwebkit2gtk-4.1-dev` が必要です（チャットの中の HTML 表示に使う WebKitGTK。実行するときは `libwebkit2gtk-4.1-0`）。
Android のビルドには Android SDK と NDK 29.0.13113456、CMake 3.22.1 が必要です（`android/app/build.gradle.kts`）。

## 構成

```
lib/core/       チャット制御・エージェント選択・プロンプト生成・ツール呼び出しの解釈・検索/天気 など
                （Kotlin 版 core/ を Dart に移したもの。テストも移植済み: test/core）
lib/engine/     InferenceEngine の実装: NativeEngine（Android の llama.cpp/LiteRT-LM）、DemoEngine
lib/services/   設定・履歴・モデル管理・更新・プレビューサーバー
lib/ui/         画面（ライト/ダークのトークンは theme.dart）
android/        ネイティブ側: llama.cpp の JNI（src/main/cpp）、エンジン、APK インストーラー
.github/        ci.yml（解析とテスト）、release-<OS>.yml（OS ごとのビルドとリリース）
```

## リリースと更新

`pubspec.yaml` の `version:` を上げて push すると、5つのワークフロー（Android・iOS・Windows・macOS・Linux）が別々に動き、プラットフォームごとの GitHub Release（`v0.4.0`、`ios-v0.4.0`、`windows-v0.4.0` …）にファイルが並びます。
アプリは起動時（と起動中は一定間隔）にこのリリースを確認し、設定の「アップデート」から更新できます。

Android の APK の署名には、リポジトリの Secrets `ARCE_KEYSTORE_BASE64`（keystore を base64 にしたもの）・`ARCE_KEYSTORE_PASSWORD`・`ARCE_KEY_ALIAS` が必要です。無いと Android のリリースは失敗します（デバッグ署名の APK では、入っているアプリを更新できないため）。

## 以前の Kotlin 版との関係

以前の Android 専用版（Jetpack Compose）からも、そのまま更新できます。
Flutter 版は、同じ `applicationId`（`ai.arce.app`）と同じ署名鍵でビルドするため、入っているアプリをそのまま上書き更新できます。
Python / Java の実行・ビルド機能（サンドボックス）と、バックグラウンド生成の前面サービスは、まだ Flutter 版に移していません。
