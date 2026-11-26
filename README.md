# Live Mix Desktop

I-O DATA GV-LSMIXER/I（ATEN UC9020 StreamLIVE HD 系）を **Mac から操作する非公式アプリ**です。
本体を USB でつなぎ、iPad 用の公式アプリの代わりに使えます。本体のファームウェアは書き換えません。
本体が公開している RESTful API だけを使います。

> **非公式です。** I-O DATA・ATEN とは関係がなく、両社のサポート対象外です。
> 動作の保証はありません。ライブ配信の開始、設定の読み込み、工場出荷時へのリセットなど、
> 本体の状態を変える操作もできます。自己責任でお使いください。

## できること

- **本番**: Preview / Program の切り替え（CUT・AUTO、数字キー 1〜8）、音声の音量・ミュート、ライブ配信の開始・停止
- **Program モニター**: 本体の RTSP 出力を Mac で表示・録画（配信していないときだけ。下の「制限」を参照）。
  「iPad Stream」を選ぶと、iPad アプリ用の映像（720p・15fps・音声なし）で表示します。配信の設定には触りません
- **シーン設定**: 入力ウインドウの配置・切り出し、背景、画像・文字オーバーレイ、コピー・テンプレート
- **配信設定**: 配信先（RTMP / RTSP / USB 録画）、エンコード、一時停止画面
- **画像**: 本体に入れる画像の追加・削除・保存
- **本体の管理**: 設定のバックアップと復元、日時合わせ、LAN 設定
- メニューバーから開く小さな操作パネル
- USB が抜けたときの案内と自動再接続

## 動作環境

- macOS 15 以降、Apple シリコンの Mac（Intel の Mac には対応していません）
- Xcode の Command Line Tools（`xcode-select --install`）
- Program モニターを使う場合は ffmpeg（`brew install ffmpeg`）
- 確認した機器: GV-LSMIXER/I（ファームウェア V1.4.136）

## ビルドと起動

```bash
git clone https://github.com/tomo-klotho/LiveMixDesktop.git
cd LiveMixDesktop/app
./build.sh
open build/LiveMixDesktop.app
```

Apple Development の証明書があれば、その証明書で署名します。ない場合は ad-hoc 署名になり、
ビルドのたびにローカルネットワークの許可を求められることがあります。
署名する証明書は `SIGN_IDENTITY` で選べます。

起動したら、本体の管理者アカウントでログインします。工場出荷時は `administrator` / `password` です。

### 環境変数

| 変数 | 意味 |
| --- | --- |
| `LMD_HOST` | 本体のアドレス（既定 `192.168.254.1`） |
| `LMD_SECTION` | 最初に開く画面（`live` `scenes` `broadcast` `assets` `device` `settings`） |
| `LMD_NOWINDOW=1` | ウインドウを開かずにメニューバーだけで起動 |

## コマンドラインツール

`livemix.py` は Python 標準ライブラリだけで動く CLI です。

```bash
./livemix.py login
./livemix.py scenes
./livemix.py prv 3 && ./livemix.py cut
```

## 制限

- 本体は Program の配信先（RTMP 2・RTMP 3・RTSP 5・USB 録画）を同時に 1 つしか有効にできません。
  そのため、YouTube などへ配信している間は、高画質（RTSP）のモニターを使えません。
- iPad Stream のモニターは、本体の iPad Stream の送り先がこの Mac の IP アドレス（本体と直結したときの 192.168.254.2）のときだけ使えます。
  表示中は、iPad アプリ用の画面（チャンネル3）を Program の全面表示に切り替え、閉じると元に戻します。
- 配信エンジンは、本体の LAN ポートにケーブルが挿さっていないと開始できません（RTSP モニターも同じ）。
- 本体は自己署名の証明書を使うため、アプリと CLI は証明書を確かめずに接続します。USB で直接つなぐ前提です。
  `LMD_HOST` で LAN 越しの本体につなぐと、同じネットワークにいる人に通信（ログイン情報やストリームキーを含む）を盗み見・改ざんされるおそれがあります。

## 実機で試していない機能

次の機能は作ってありますが、実機ではまだ試していません。画面にも「実機未検証」と出します。
大事な設定やデータがあるときは使わないでください。

- 工場出荷リセット（実行前に今の設定を自動で書き出します）
- 本体の USB 録画と、USB ストレージのフォーマット
- RTMP 3 への配信
- 配信と USB 録画を同時に行えるか
- 配信している最中の iPad Stream モニター

## Mac に保存するもの

- ログイン情報: ログイン画面の「キーチェーンに保存して自動ログイン」がオン（既定）のとき、キーチェーンに保存
- `~/.config/livemixdesktop/`（フォルダは本人だけが開ける権限、ファイルは本人だけが読める権限で作ります）
  - `cookies.txt` … ログイン中のセッション
  - `app.log` … 動作の記録（パスワードや cookie は書きません）
  - `scene-templates.json` … シーンのテンプレート
  - `profile-backup/` … 本体の設定のバックアップ。**ストリームキーやログインパスワードも入る**ので、人に渡さないでください
  - `pause-backup/`、`monitor-restore.json` … 変更前の状態を戻すための控え

## API について

本体の API は ATEN が公開している資料に沿っています。実機で分かった違いは [docs/API.md](docs/API.md) にまとめました。

## ライセンス

MIT License。[LICENSE](LICENSE) を参照してください。

I-O DATA、GV-LSMIXER は株式会社アイ・オー・データ機器の、ATEN、StreamLIVE は ATEN International の商標または登録商標です。
