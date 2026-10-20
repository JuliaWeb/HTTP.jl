# eMudhra regression fixtures

The public certificate chains and `roots.pem` are copied from the incident report:
https://github.com/galadran/we-have-a-problem.com/tree/964944032736018999e09eaa2f2dc8ba1a664801

The test generates an unrelated ephemeral EC key in a temporary directory.
It does **not** match the public leaf certificates. The local server uses it only
to send a certificate flight. The client must reject the compromised chain before
checking the server's handshake signature. Tests assert the chain validation error
specifically, so a mismatched-signature error is not a pass. No private key is
stored with these fixtures.

Verification uses 2026-10-20 12:00:00 UTC. No external test host is contacted.
