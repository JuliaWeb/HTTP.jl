# eMudhra CA compromise fixtures

Public certificates from the incident report, captured on 20 October 2026:
https://emudhra.we-have-a-problem.com/

Copied from Reseau.jl's fixtures (JuliaServices/Reseau.jl#190), whose source snapshot is
https://github.com/galadran/we-have-a-problem.com/tree/964944032736018999e09eaa2f2dc8ba1a664801

- `intermediates.pem`: the 16 impacted intermediate certificates (eight compromised keys,
  each with two issuers).
- `spki-sha256.txt`: the published SHA-256 of each certificate's DER SubjectPublicKeyInfo,
  in the same order.
- `dv-g3b-emudhra.we-have-a-problem.com.pem`: an unmodified server chain (leaf and intermediates).

These files contain no private keys.
