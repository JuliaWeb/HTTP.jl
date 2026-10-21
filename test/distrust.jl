module TestDistrust

using Test, HTTP, OpenSSL

const fixtures = joinpath(@__DIR__, "resources", "emudhra")

pem_certs(path) = [OpenSSL.X509Certificate(m.match) for m in
    eachmatch(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----"s, read(path, String))]

function has_distrusted_key(certs)
    stack = ccall((:OPENSSL_sk_new_null, OpenSSL.libcrypto), Ptr{Cvoid}, ())
    try
        GC.@preserve certs begin
            for cert in certs
                ccall((:OPENSSL_sk_push, OpenSSL.libcrypto), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), stack, cert.x509)
            end
            return HTTP.Connections.has_distrusted_key(stack)
        end
    finally
        ccall((:OPENSSL_sk_free, OpenSSL.libcrypto), Cvoid, (Ptr{Cvoid},), stack)
    end
end

@testset "Distrusted CA keys" begin
    intermediates = pem_certs(joinpath(fixtures, "intermediates.pem"))
    expected = readlines(joinpath(fixtures, "spki-sha256.txt"))
    @test length(intermediates) == length(expected) == 16
    for (cert, hash) in zip(intermediates, expected)
        spki = GC.@preserve cert HTTP.Connections.spki_sha256(cert.x509)
        @test bytes2hex(spki) == hash
        @test spki in HTTP.Connections.DISTRUSTED_SPKI_SHA256
    end

    chain = pem_certs(joinpath(fixtures, "dv-g3b-emudhra.we-have-a-problem.com.pem"))
    @test has_distrusted_key(chain)
    # The leaf alone has an unaffected key.
    @test !has_distrusted_key(chain[1:1])
    @test !has_distrusted_key(pem_certs(joinpath(@__DIR__, "resources", "cert.pem")))
end

end # module
