# Public localhost TLS test fixture

`localhost.crt` and `localhost.key` are deliberately public, disposable test
materials for `xb_update_https_routing_test.dart`. They contain no production
identity or credentials and must never be used outside local automated tests.
The certificate names only `localhost` and `127.0.0.1`.

Generated once by the test author with:

```sh
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout localhost.key -out localhost.crt -days 36500 \
  -subj '/CN=localhost/OU=PUBLIC TEST FIXTURE ONLY' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'
```

Tests load the committed fixture directly; CI does not need OpenSSL. The release
Dio factory's existing test connection policy accepts this self-signed
certificate. Every listening and connected socket is IPv4 loopback.
