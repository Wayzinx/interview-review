#!/bin/bash
# 在登录钥匙串里生成一张只给本 App 用的自签名代码签名证书。
# 为什么：没有它时 App 用临时签名，每次重新编译 macOS 都当成新程序，录音权限要重新授权。
# 有了它，app/build.sh 会自动用它签名，授权一直有效。证书只在本机，私钥不会落盘。
set -euo pipefail
NAME="Interview Review Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "已经有「$NAME」，不用重复创建"; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg.cnf" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cfg.cnf" 2>/dev/null
P=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P" -T /usr/bin/codesign
echo "已创建「$NAME」。第一次用它签名时系统会问一次钥匙串密码，点「始终允许」。"
