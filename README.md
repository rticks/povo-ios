# povo マネージャー — iOS

`povo-core` と `povo-android` の手元のソースを参照した、iOS 17以降向けのネイティブ移植です。SwiftUIの画面から、同じRustコアをUniFFIのSwiftバインディング経由で呼びます。AndroidアプリをWebViewに包んだものではありません。

**非公式クライアントです。KDDI / povo / Circles.lifeとは関係ありません。自分が管理するアカウントだけで使用してください。**

## 移植した機能

| Android版 | iOS版 |
|---|---|
| 複数アカウント・一括更新 | 回線ごとのRustクライアント、最大3回線並列、同一回線の更新をまとめる |
| メール/SMS OTPウィザード | サーバー指定順の認証、再送待機、追加PINの入力（PINは実通信未検証） |
| 5種のデータ残量 | 小数KB・1024基準、未知の応答で前回値を0にしない |
| 契約中トッピング・購入履歴 | 非ローカライズのQuiltページを解析、サーバーの表示文字列を維持 |
| 請求タイムライン・PDF | 過去/予定/都度課金、PDFKitで表示、暗号化された原本を共有 |
| 契約情報 | 名義・電話番号・メール・プラン・開通日・SIN・マスク済みカード |
| 公式Webページ | 支払い/メール/契約管理、回線ごとに一時的なWKWebView、認証ブリッジ |
| トッピング購入 | ライブカタログ、価格と購入回線の確認、二重送信抑止、自動再送なし |
| 3-D Secure | 公式Web画面とは別のWKWebView。ブリッジ/トークン/共有Cookieなし |
| 180日ルール | 手入力の起算日、日数/有効期限入力、停止/解除目安、1〜180日前のローカル通知 |
| Keystore | Keychain `AfterFirstUnlockThisDeviceOnly`、iCloud同期なし |
| RoomとDataStore | APIキャッシュと設定・手入力起算日を分離して永続化 |
| 一覧/円形ウィジェット | WidgetKit 2種、円形はAppIntentで回線選択、取得日時・未取得状態を表示 |
| テーマ4種 | システム/ライト/ダーク/povoカラー |
| 開発者用プロトコル画面 | Debugのみ。任意GET/確認つきPOST、認証情報を伏せて表示・共有 |
| GitHub更新 | Releasesの確認とIPAダウンロード/共有、privateの場合は認証済みブラウザでActionsへ |

### OSによる差（重要）

- **15分ごとの実行は保証できません。** `BGAppRefreshTaskRequest`に最短15分後を希望しますが、実行はiOSが決めます。アプリ起動/手動更新も用意しています。請求・購入履歴は自動更新時に55分間引きます。
- Android Keystoreの認証情報をiOSへ取り出す機能はありません。iOS版では各アカウントにあらためてOTPログインしてください。
- **iOSアプリは無署名IPAを自分でインストールできません。** 外部ツールで再署名・インストールしてください。更新機能もこの制約を迂回しません。
- **ウィジェットはApp Groupの権限が必要です。** アプリ本体と`PovoWidgets.appex`の両方を、同一のApp Groupを許可したプロファイルで再署名してください。対応しない無料署名環境ではアプリ単体のみ動作します。トークン・端末ID・誕生日・請求情報は共有コンテナに置きません。
- 購入後の3DSリターンURLだけで「決済成功」とは断定しません。購入履歴と注文番号が照合できない場合は**未確認**と表示します。通信失敗時にも勝手に再購入しません。
- 公式Web画面は、参照元で確認済みのAndroid向けWeb契約をWKWebView上の互換ブリッジで使用します。これはiOSでの実アカウント動作を保証するものではありません。

## 無署名IPAをGitHub CLIでビルド

GitHub Actionsは**非公開リポジトリ**に保存する運用です。macOS runnerの利用枠を消費する場合があります。

```bash
# GitHubに認証済みで実行
# workflow_dispatch、mainへのpush、PRでビルド
gh workflow run ios.yml -R rticks/povo-ios -f version=0.1.0 -f runner=macos-15-intel
gh run list -R rticks/povo-ios --workflow ios.yml --limit 5
# 表示された run-id に置き換える
gh run watch <run-id> -R rticks/povo-ios --exit-status
gh run download <run-id> -R rticks/povo-ios -n povo-ios-unsigned -D artifacts/<run-id>
```

成果物：

- `povo-ios-0.1.0-unsigned.ipa` — 実機用ARM64、WidgetKit拡張込み
- `*.ipa.sha256` — SHA-256
- `*.json` — Bundle ID/版/アーキテクチャ/無署名検証結果
- `ios-screenshots` artifact — UIテストで取得した画面画像
- `ios-test-evidence` artifact — XCTest結果とビルドログ

ビルドではSwiftの共通テスト、Rustテスト、実機用ビルド、Simulator上のFFI/リポジトリ/UIテストを実行します。テストは匿名化済みフィクスチャまたは合成データを使用し、OTP送信・実購入・実契約変更はしません。

Simulatorのテスト実行だけは、Keychainの権限検査に必要なアドホック署名とCI専用の仮entitlementsを使用します。Appleアカウント・証明書は不要です。配布用のRelease IPAは別の設定で署名を無効化し、署名が残っていないことをMach-Oのロードコマンドまで検査します。


## 検証済みビルド

- [成功したGitHub Actions実行](https://github.com/rticks/povo-ios/actions/runs/41937141393)（実装コミット `9c472cc9828a979176cfefeb8ee4f8961208c76f`）
- バージョン **0.1.0 / build 13**、iOS 17以降、実機ARM64、WidgetKit拡張込みの**無署名IPA**。
- 共通Swift 32件（LinuxとmacOSの両方）、Rust 27件、iOSネイティブ/Keychain/リポジトリ13件、UI 8件が全件合格。
- 画面画像12枚を出力し、主要画面のライト/ダーク表示、残量メーター、ウィジェットのプレビュー等を目視確認。
- 詳細・SHA-256・署名検査結果：[docs/BUILD-VERIFICATION.json](docs/BUILD-VERIFICATION.json)。
- この作業環境の最終成果物：`artifacts/unsigned/povo-ios-0.1.0-unsigned.ipa`（Git管理外）。

実アカウントを使った検証を行ったという意味ではありません。以下の「検証の限界」も確認してください。

## macOSでローカルビルド

必要：Xcode 16以降（iOS SDK/Simulator）、Rust stable、XcodeGen。

```bash
brew install xcodegen
rustup toolchain install stable --profile minimal
rustup default stable
swift test --package-path Packages/PovoKit
cargo test --locked --manifest-path vendor/povo-core/Cargo.toml -p povo-core
bash scripts/build-native.sh
VERSION=0.1.0 BUILD_NUMBER=1 bash scripts/build-unsigned.sh
bash scripts/test-ios.sh
```

WindowsだけではXcode/実機用iOS SDKを実行できません。GitHub ActionsのmacOS runnerでビルドしてください。共通の`PovoKit`はAppleのUIに依存しないSwift Packageです。

## 構成

```text
App/                  SwiftUI画面、Keychain、リポジトリ、バックグラウンド/通知
Shared/               アプリと拡張の共有表示、最小限のWidget用ファイル
Widgets/              WidgetKit 2種、回線選択AppIntent
Packages/PovoKit/     純粋Swiftのモデル/パーサ/日付/JWT/Webポリシーとテスト
Tests/                ネイティブFFI、Keychain、同時更新/再ログイン競合の回帰テスト
UITests/              合成データの画面テスト・スクリーンショット
vendor/povo-core/     手元のRustソースを固定コピー（未コミット修正も含む）
scripts/              UniFFI/XCFramework、無署名パッケージ、構造/署名検査
project.yml           XcodeGen定義（生成xcodeprojはGit管理しない）
```

- 原本の`povo-core`/`povo-android`は変更しません。参照コミット・ローカル修正・ハッシュは[`docs/SOURCE-PROVENANCE.json`](docs/SOURCE-PROVENANCE.json)に記録します。
- UniFFIは**unstrippedなホストDebug dylibから**生成し、配布用RustコードはRelease staticlibをリンクします。strip済みライブラリから生成して空の結果になる問題を避けます。
- デバイスはARM64、SimulatorはARM64+x86_64のXCFrameworkです。
- Bundle ID/App Group/更新先を変更する場合は`project.yml`の設定と再署名先のプロファイルを揃えてください。
- ソース・依存物の権利条件は[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)を確認してください。

## 検証の限界

CIでのコンパイル・合成データのテストと、povo実サービスでの動作は別です。実端末でのOTP、トークン更新、公式Web画面、実決済/3DS完走、BGTaskの実行、通知・App Groupを伴う再署名後のWidgetKit動作は、利用者の端末・アカウントでの確認が必要です。CIには実アカウントの認証情報を送信しません。
