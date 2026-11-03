#!/bin/sh
# Eenmalig: een eigen certificaat om HintMeet mee te ondertekenen. Met ad-hoc ondertekenen herkent macOS de app
# alleen aan een hash van het programma; die verandert bij elke build, dus vraagt macOS na elke build opnieuw om de
# microfoon. Met een vast certificaat blijft de toestemming staan. build-app.sh gebruikt het vanzelf.
#
#   app/make-signing-cert.sh            (zet het in je login-sleutelhanger)
#   app/make-signing-cert.sh <keychain> (een andere sleutelhanger, voor tests)
set -e
NAME="HintMeet Local Signing"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Certificaat \"$NAME\" bestaat al in $KEYCHAIN"
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
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
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -passout "pass:$PASS" -out "$TMP/id.p12"
# -T: codesign mag de sleutel gebruiken zonder elke keer te vragen
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Certificaat \"$NAME\" staat in $KEYCHAIN. Bouw opnieuw met app/build-app.sh;"
echo "macOS vraagt dan nog één keer om de microfoon en onthoudt het daarna."
