#!/bin/bash
# One-time setup: creates a local code-signing certificate called "Undertone Dev"
# in your login keychain. build.sh then signs with it, so macOS keeps Undertone's
# screen & system audio recording permission across rebuilds.
set -euo pipefail
NAME="Undertone Dev"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "✓ 이미 있음: $NAME — 그냥 ./build.sh 하면 돼"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "▶ 서명용 인증서 만드는 중…"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

PASS="undertone-temp"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" -out "$TMP/id.p12"

security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ 완료: '$NAME' 인증서가 키체인에 추가됨"
  echo "  첫 빌드 때 키체인 접근을 물어보면 맥 로그인 비밀번호 입력 → '항상 허용'"
else
  echo "✗ 인증서를 못 찾음. 출력을 Claude에게 보여줘."
  exit 1
fi
