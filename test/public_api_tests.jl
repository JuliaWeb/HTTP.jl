using Test
using HTTP

# Every name documented in docs/src/api/*.md must be reachable as public API —
# either `export`ed or declared `public` (Julia 1.11+). This guards against a
# newly-documented entry point being left unmarked, and against the `public`
# list drifting from the docs.
@testset "public API declarations match the documented API" begin
    if VERSION >= v"1.11.0-DEV.469"
        apidir = joinpath(dirname(dirname(pathof(HTTP))), "docs", "src", "api")
        isdir(apidir) || @warn "api docs dir not found; skipping" apidir
        checked = 0
        for file in (isdir(apidir) ? readdir(apidir; join=true) : String[])
            endswith(file, ".md") || continue
            inblock = false
            for raw in eachline(file)
                line = strip(raw)
                if startswith(line, "```@docs")
                    inblock = true; continue
                elseif line == "```"
                    inblock = false; continue
                end
                (inblock && startswith(line, "HTTP")) || continue
                parts = split(line, '.')
                length(parts) >= 2 || continue          # skip the bare `HTTP` entry
                # walk the module path (e.g. HTTP.WebSockets.send -> mod=WebSockets, name=send)
                mod = HTTP
                resolved = true
                for p in parts[2:(end - 1)]
                    sym = Symbol(p)
                    if isdefined(mod, sym) && getfield(mod, sym) isa Module
                        mod = getfield(mod, sym)
                    else
                        resolved = false; break
                    end
                end
                resolved || continue
                name = Symbol(parts[end])
                isdefined(mod, name) || continue          # (macros resolve fine: @client)
                ispub = Base.ispublic(mod, name) || (name in Base.names(mod; all = false))
                @test ispub
                ispub || @info "documented but not public/exported" mod name
                checked += 1
            end
        end
        @test checked > 80   # the bulk of the documented surface was actually checked
    else
        @test true   # `public` unsupported before 1.11; nothing to assert
    end

    # Internals must stay private regardless of Julia version.
    @test !Base.ispublic(HTTP, :_retryable_request_error)
    @test !Base.ispublic(HTTP, :_normalize_local_addr)
    @test !Base.ispublic(HTTP.WebSockets, :_ws_mask_into!)
end
