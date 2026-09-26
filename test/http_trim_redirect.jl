using HTTP

function check_redirect_target(base::String, location::String, expected::String)::Bool
    _, _, target, _ = HTTP._resolve_redirect_target("a:80", false, location, base, "a")
    return target == expected
end

function @main(args::Vector{String})::Cint
    if isempty(args)
        for (base, location, expected) in (
            ("/a/b?old", "?q=1#fragment", "/a/b?q=1"),
            ("/a/b?old", "?", "/a/b?"),
            ("/a/b?", "#fragment", "/a/b?"),
            ("/a/b", "../c//d/..", "/c//"),
            ("/", "http://next/a/./b/../c?", "/a/c?"),
            ("/", "//next/%2e//c/..", "/%2e//"),
        )
            check_redirect_target(base, location, expected) || return 1
        end
    else
        length(args) == 3 || return 2
        check_redirect_target(args[1], args[2], args[3]) || return 1
    end
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
