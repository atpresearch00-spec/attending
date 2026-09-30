#!/bin/zsh
# Creates a local self-signed code-signing identity so macOS privacy permissions
# (Accessibility, Camera, Calendar, Location) survive Attending updates. Ad-hoc
# signatures change with every build, which makes macOS forget those grants.
# The certificate is not trusted system-wide; it only gives builds a stable identity.
set -euo pipefail
cd "${0:A:h}/.."
SIGN_IDENTITY="${SIGN_IDENTITY:-Attending Local Signing}"
[[ -f scripts/local.env && -z "${ATTENDING_RELEASE:-}" ]] && source scripts/local.env
name="$SIGN_IDENTITY"
if security find-certificate -c "$name" >/dev/null 2>&1; then print "$name already exists"; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
pass=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -out "$work/id.p12" -passout "pass:$pass" 2>/dev/null
security import "$work/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$pass" -T /usr/bin/codesign >/dev/null
print "Created $name"
