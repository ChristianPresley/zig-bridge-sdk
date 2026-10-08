#!/usr/bin/env bash
# Make the TLS fixtures of the HTTPS tests again. Needs OpenSSL 3.4 or later.
# Run it from the root of the repository:
#
#   bash test/fixtures/tls/generate.sh
#
# The script makes two CAs, each with a new P-256 key, and one server certificate from each
# CA. The tests trust only ca.crt. untrusted-ca.crt and its server certificate are for the
# tests that expect a TLS failure. The script keeps no CA key: run it again to make new
# certificates. Each certificate is valid from 2026-01-01 to 2049-12-31.
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash: keep "/CN=..." as it is

out=test/fixtures/tls
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A native Windows openssl does not know the paths of Git Bash.
if command -v cygpath >/dev/null; then work=$(cygpath -m "$work"); fi

not_before=20260101000000Z
not_after=20491231235959Z

# The server certificates name 127.0.0.1 twice. The TLS client of zig-sdk compares an IP
# address with the iPAddress entries. The TLS client of Zig std compares each host with the
# dNSName entries only, and the authorization server of zig-sdk fetches a client ID metadata
# document with it. fixture.test is a reserved name (RFC 6761) that only a test proxy
# resolves: zig-sdk never sends a loopback host to a proxy of the environment.
cat >"$work/ext.cnf" <<'EOF'
[ca_ext]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash

[server_ext]
basicConstraints = CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, DNS:127.0.0.1, IP:127.0.0.1, DNS:fixture.test
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

# ec_key <path>
ec_key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1"; }

# ca <certificate> <key> <subject>
ca() {
  openssl req -x509 -new -key "$2" -subj "$3" -sha256 -not_before $not_before -not_after $not_after \
    -config "$work/ext.cnf" -extensions ca_ext -out "$1"
}

# server <certificate> <key> <issuer certificate> <issuer key> <serial>
server() {
  openssl req -new -key "$2" -subj "/CN=localhost" -out "$work/request.csr"
  openssl x509 -req -in "$work/request.csr" -CA "$3" -CAkey "$4" -set_serial "$5" -sha256 \
    -not_before $not_before -not_after $not_after -extfile "$work/ext.cnf" -extensions server_ext -out "$1"
}

ec_key "$work/ca.key"
ca "$out/ca.crt" "$work/ca.key" "/CN=zig-bridge-sdk test CA"
ec_key "$out/server.key"
server "$out/server.crt" "$out/server.key" "$out/ca.crt" "$work/ca.key" 0x1001

ec_key "$work/untrusted-ca.key"
ca "$out/untrusted-ca.crt" "$work/untrusted-ca.key" "/CN=zig-bridge-sdk untrusted test CA"
ec_key "$out/untrusted-server.key"
server "$out/untrusted-server.crt" "$out/untrusted-server.key" "$out/untrusted-ca.crt" "$work/untrusted-ca.key" 0x2001

# Only the certificates and the keys of the servers stay in the repository.
openssl verify -CAfile "$out/ca.crt" "$out/server.crt"
openssl verify -CAfile "$out/untrusted-ca.crt" "$out/untrusted-server.crt"
