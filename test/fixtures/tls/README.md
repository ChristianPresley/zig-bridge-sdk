# TLS test fixtures

The HTTPS tests of the bridge use the files in this directory. The project made all keys and certificates for the tests. Do not use them for other purposes. The private keys are not secret: anyone can read them in the repository.

| File | Contents |
| --- | --- |
| `ca.crt` | The test CA. The tests trust it, for example with `--ca-file test/fixtures/tls/ca.crt`. |
| `server.crt`, `server.key` | The certificate and the P-256 key of the HTTPS fixture server. `ca.crt` signs the certificate. |
| `untrusted-ca.crt` | A second CA. The tests do not trust it. |
| `untrusted-server.crt`, `untrusted-server.key` | A server certificate and its key from `untrusted-ca.crt`, for the tests that expect a TLS failure. |
| `generate.sh` | The script that makes the files. |

Each server certificate has the names `localhost`, `127.0.0.1` and `fixture.test`. It has `127.0.0.1` as an IP address and also as a DNS name:

- The TLS client of zig-sdk compares an IP address with the IP address entries.
- The TLS client of Zig std compares each host with the DNS name entries only. The authorization server of zig-sdk uses it when it gets a client ID metadata document.

`fixture.test` is a reserved name (RFC 6761). No DNS server resolves it. A test proxy resolves it to 127.0.0.1. zig-sdk never sends a loopback host to a proxy of the environment, thus a proxy test needs a name that is not a loopback name.

Each certificate is valid from 2026-01-01 to 2049-12-31. The tests use the real time.

## How to make the fixtures again

The script needs Bash and OpenSSL 3.4 or later. Git Bash on Windows has both.

1. Open a shell in the root of the repository.
2. Run `bash test/fixtures/tls/generate.sh`.
3. Run `zig build test --test-timeout 10m`.

The script makes new keys for each run. It keeps no CA key in the repository. Thus a new server certificate needs a new CA.

## License

These files are a part of zig-bridge-sdk and have its license, Apache-2.0. They contain no third-party material. Thus `NOTICE` and `THIRD_PARTY_LICENSES.md` have no row for them.
