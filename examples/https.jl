"""
Example of using HttpServer with HTTPS protocol:

1) Create a self-signed SSL Certificate
    - Generate a private key
        openssl genrsa -des3 -out server.key 1024

    - Generate a CSR (Certificate Signing Request)
        openssl req -new -key server.key -out server.csr -subj "/L=github.com/O=JuliaWeb/OU=HttpServer/CN=localhost"

    - Remove Passphrase from Key
        cp server.key server.key.org
        openssl rsa -in server.key.org -out server.key

    - Generating a Self-Signed Certificate
        openssl x509 -req -days 365 -in server.csr -signkey server.key -out server.crt

2) Add certificate/private key pair to a certificate store

3) Run server with the store which contains self-signed SSL certificate
"""

# Adding certificate/private key pair to certificate store
using GnuTLS
cert_store = GnuTLS.CertificateStore()
GnuTLS.load_certificate(cert_store, "server.crt", "server.key", true)

# Setting up simple server
using HttpServer
http = HttpHandler() do req::Request, res::Response
    Response("Hello Secure World!")
end
http.events["listen"] = (saddr) -> println("Running on https://$saddr (Press CTRL+C to quit)")

# Running server in HTTPS mode
server = Server(http)
run(server, port=8000, ssl=cert_store)