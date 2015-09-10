HttpServer.jl v0.1.2 Release notes
=============

MbedTLS is now used in place of GnuTLS
-------

* The Julia web stack has migrated to MbedTLS 2.1. As a consequence, the `ssl` parameter of `run` now takes an object representing an MbedTLS configuration (MbedTLS.SSLConfig) that is expected to have one or more certificates already configured.  
There is also a convenience option to pass a tuple `{MbedTLS.CRT, MbedTLS.PKContext}` representing a single certificate and private key for the `ssl` parameter, in which case a reasonable default configuration with the given certificate will be created automatically.
See `runtests.jl` for an example of loading a PEM-format certificate and key.
