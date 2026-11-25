# 本体 API の実機メモ

ATEN が公開している資料に沿っていますが、実機（GV-LSMIXER/I, FW V1.4.136）では違う点があります。
資料そのものはここに含めていません。ATEN のサイトから入手してください。

- StreamLIVE RESTful API（完全版）: https://assets.aten.com/product/manual/StreamLIVE_restful_api_2021-09-11.pdf

ベース URL は `https://192.168.254.1/api/v2.0`（USB 接続時）。証明書は自己署名です。
書き込み系のリクエストには `"sender": "<任意の名前>"` を付けると、ほかの端末に送り元が通知されます。

## 認証

- `POST /auth/login` 本文は **小文字** の `{"authorization": base64("user:pass")}`（資料の `Authorization` だと 400）
- 応答の `Set-Cookie: session=...` を以後のリクエストに付ける

## シーンと切り替え

- `GET /scenes` … 1〜8 が利用者のシーン。9 以降は公式アプリの画面用
- `PATCH /channels/1 {"sceneId": n}` で Preview にシーンを割り当て、`POST /transition {"mode": "cut"}` で Program と入れ替え
- `GET/PATCH /layouts/:id` … ウインドウ配置（`windowInfo[]`、`location` と `srcMap` は 0〜1 の比率）、背景
- `GET/PATCH /overlays/:id` … 画像・文字オーバーレイ（`assetConfig[]`）
- レイアウトとオーバーレイの PATCH は **下書き** です。`POST /scenes/:id/commit` で確定し、`POST /scenes/:id/revoke` で最後の確定に戻ります
- 文字オーバーレイは本体が文字を描きません。透過 PNG を描いてアップロードし、`properties.source` に入れます

## アセット

- `POST /assets/upload`（multipart）: `type`（`image` / `qml` / `font`）と `file` だけを送る。`id` を付けると 2010004 で失敗します
- `DELETE /assets/:id` … 本文なしで送る（`Content-Type: application/json` を付けると 400）
- アセット 1・2 は本体の QML 部品なので消さないこと

## 配信

- `GET /streams` … スロット固定（1 = iPad 用 RTP、2・3 = RTMP、4 = USB 録画、5 = RTSP）。追加はできません
- Program（channel 2）の配信先は同時に 1 つだけ。RTSP 5 を有効にすると RTMP 2 が自動で無効になり、元には戻りません
- `POST /streamer/start|stop|pause|resume`、状態は `GET /streamer/status`
- RTSP 5 を有効にして開始すると `rtsp://192.168.254.1:554/session` で Program を受信できます（H.264 1080p30 + AAC）
- 停止直後に配信先を変えると 2010255。停止が終わるのを待ってから変更します
- 入力のサムネイル: `GET https://192.168.254.1/static/snapshots/{HDMI1,HDMI2A,HDMI2B}.png`（cookie が必要）

## 本体の管理

- 日時: `GET/PATCH /datetime`（資料の `/video/datetime` は 404）
- 設定の書き出し: `POST /profile/export` → 返った URL から tar を取得 → `DELETE /profile/export`
- 設定の読み込み: `POST /profile/import` → `POST /profile/upload` → 進み具合は Socket.IO の `/profile/import`
