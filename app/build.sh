#!/bin/zsh
# LiveMixDesktop.app (Live Mix Desktop) をビルドする (Xcode 不要、Command Line Tools の swiftc を使用)
set -eu
cd "${0:A:h}"
APP=build/LiveMixDesktop.app
# バージョンはリポジトリ直下の VERSION、ビルド番号は git のコミット数 (git がなければ 0)
VERSION=$(tr -d ' \n' < ../VERSION)
BUILD=$(git -C .. rev-list --count HEAD 2>/dev/null || echo 0)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# アイコン (Resources/AppIcon.icns は make-icon.swift から作成)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos15.0 \
  -o "$APP/Contents/MacOS/LiveMixDesktop" Sources/*.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.tomo-klotho.livemixdesktop</string>
  <key>CFBundleName</key><string>Live Mix Desktop</string>
  <key>CFBundleDisplayName</key><string>Live Mix Desktop</string>
  <key>CFBundleExecutable</key><string>LiveMixDesktop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSLocalNetworkUsageDescription</key><string>USB 接続した GV-LSMIXER/I (192.168.254.1) を操作するために使います。</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
# 署名が毎回変わるとローカルネットワークの許可がリセットされるため、Apple Development 証明書があれば使う
ID=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}
codesign --force -s "${ID:--}" "$APP"
[[ -n "${ID:-}" ]] && echo "signed with: Apple Development (${ID[1,8]}…)" || echo "signed with: ad-hoc"
echo "built: $PWD/$APP (version $VERSION, build $BUILD)"
