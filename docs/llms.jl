# Generates `llms.txt` and `llms-full.txt` (https://llmstxt.org/) from the Documenter
# sources in `docs/src`, with every `@docs` block expanded to the live docstrings of
# the listed bindings. `make.jl` includes this file and calls `write_llms_files`
# after `makedocs`, so the files land in the build directory and `deploydocs`
# publishes them next to the HTML pages (`/stable/llms.txt`, `/dev/llms.txt`, ...).

using HTTP, Documenter

# Canonical site root used for every link in the generated files.
const LLMS_SITE_ROOT = "https://juliaweb.github.io/HTTP.jl/stable/"

# One-paragraph package summary for the `llms.txt` blockquote.
const LLMS_SUMMARY = "HTTP client and server library for Julia: HTTP/1.1 and HTTP/2 " *
    "requests and servers, streaming request and response bodies, cookies, forms, " *
    "proxies, retries, timeouts, WebSockets, and server-sent events, built on " *
    "Reseau's transport, resolver, and TLS stack."

# One-line notes for the `- [title](url): note` entries of `llms.txt`, keyed by the
# page path used in the `pages` of `make.jl`. A page without an entry falls back to
# the list of its `##` section headings (and a warning is printed).
const LLMS_PAGE_NOTES = Dict{String,String}(
    "index.md" => "package overview, quick start, and the documentation map.",
    "guides/client.md" => "request construction, verb helpers, streaming with `HTTP.open`, reusable `HTTP.Client` bundles, request bodies, timeouts, retries, proxies, cookies, and HTTP/2 on the client side.",
    "guides/server.md" => "request handlers, stream handlers, server lifecycle, the interactive thread pool, routing and middleware, static files, and server-sent events.",
    "guides/protocols.md" => "WebSocket client and server usage and where HTTP/2 fits into the normal client/server APIs.",
    "guides/migration-1x.md" => "what changed from HTTP.jl 1.x to 2.0 and how to update client, server, header, body, WebSocket, SSE, and streaming code.",
    "api/reference.md" => "the top-level `HTTP` module docstring and the map of the API reference pages.",
    "api/core.md" => "docstrings for `Request`, `Response`, `Headers`, `RequestContext`, error types, header helpers, body types, cookies, forms, multipart parsing, proxy configuration, and `HTTP2Settings`.",
    "api/client.md" => "docstrings for `Client`, `Transport`, `RetryBucket`, `request` and the verb helpers, `open`, connection reuse helpers, and the request trace events.",
    "api/server.md" => "docstrings for `Server`, `Stream`, `listen!`/`serve!`, static file serving, `HTTP.Handlers` routing and middleware, and server-sent events.",
    "api/websockets.md" => "docstrings for the `HTTP.WebSockets` client and server types, `open`/`send`/`receive`, and the WebSocket server lifecycle.",
)

struct LLMSPage
    path::String      # page path relative to `docs/src`, e.g. "guides/client.md"
    title::String     # first `#` heading of the page, else the title from `pages`, else the path
    url::String       # absolute site URL of the page
    note::String      # one-line description for `llms.txt`
    markdown::String  # rendered page content
end

# Opening code fence: up to three spaces, three or more backticks or tildes, then the
# info string. Documenter blocks are backtick fences whose info string starts with `@`.
const LLMS_FENCE_OPEN = r"^ {0,3}(`{3,}|~{3,})(.*)$"
# Documenter cross-reference links, `[text](@ref)` / `[text](@ref target)` /
# `[text](@extref ...)`, become their link text.
const LLMS_REF_LINK = r"\[([^\[\]]*)\]\(@(?:ref|extref)\b[^)]*\)"
# Relative links to other pages, `[text](guides/client.md#Section)`, become absolute
# site URLs. The target must be a bare `.md` path (no scheme, no leading `#`).
const LLMS_PAGE_LINK = r"\]\(([^)\s:#]+\.md)(#[^)]*)?\)"

"""
    write_llms_files(build_dir, pages; srcdir, site) -> (llms_path, full_path)

Write `llms.txt` (a short page index) and `llms-full.txt` (every page in `pages`
order, with `@docs` blocks expanded to the docstrings of the live `HTTP` module)
into `build_dir`. `pages` is the same nested `title => path` structure passed to
`Documenter.makedocs`, `srcdir` is the Documenter source directory, and `site` is
the absolute site root used for links.
"""
function write_llms_files(build_dir::AbstractString, pages;
                          srcdir::AbstractString = joinpath(@__DIR__, "src"),
                          site::AbstractString = LLMS_SITE_ROOT)
    sections = llms_sections(pages)
    rendered = Dict{String,LLMSPage}()
    for (_, entries) in sections, (title, path) in entries
        rendered[path] = llms_render_page(path, title; srcdir = srcdir, site = site)
    end

    mkpath(build_dir)
    llms_path = joinpath(build_dir, "llms.txt")
    full_path = joinpath(build_dir, "llms-full.txt")

    open(llms_path, "w") do io
        println(io, "# HTTP.jl")
        println(io)
        println(io, "> ", LLMS_SUMMARY)
        println(io)
        println(io, "This index covers HTTP.jl v", pkgversion(HTTP), ". The documentation site is ",
            site, " and the source code is at https://github.com/JuliaWeb/HTTP.jl. ",
            "The guide pages explain how the pieces fit together; the API reference ",
            "pages hold the docstrings.")
        for (name, entries) in sections
            println(io)
            println(io, "## ", name)
            println(io)
            for (_, path) in entries
                page = rendered[path]
                note = isempty(page.note) ? "" : ": " * page.note
                println(io, "- [", page.title, "](", page.url, ")", note)
            end
        end
        println(io)
        println(io, "## Optional")
        println(io)
        println(io, "- [llms-full.txt](", site, "llms-full.txt): the complete documentation ",
            "(every page above, with all docstrings expanded) as a single markdown file.")
    end

    open(full_path, "w") do io
        println(io, "# HTTP.jl documentation")
        println(io)
        println(io, "> Complete documentation for HTTP.jl v", pkgversion(HTTP), " in one markdown ",
            "file: every page of ", site, " in reading order, with all docstrings expanded. ",
            "The short page index is at ", site, "llms.txt.")
        for (_, entries) in sections, (_, path) in entries
            page = rendered[path]
            println(io)
            println(io, "---")
            println(io)
            println(io, "<!-- Page: ", page.url, " -->")
            println(io)
            println(io, page.markdown)
        end
    end

    @info "llms.txt files written" llms_path full_path
    return (llms_path, full_path)
end

# Turn the nested `pages` of `make.jl` into `section => [title => path, ...]` pairs.
# Top-level pages (such as `"Home" => "index.md"`) go into a leading "Docs" section;
# nested groups are flattened into their top-level section.
function llms_sections(pages)
    sections = Pair{String,Vector{Pair{String,String}}}[]
    top = Pair{String,String}[]
    for item in pages
        title, value = item isa Pair ? (String(item.first), item.second) : ("", item)
        if value isa AbstractString
            push!(top, title => String(value))
        else
            push!(sections, title => llms_flatten_pages(value))
        end
    end
    isempty(top) || pushfirst!(sections, "Docs" => top)
    return sections
end

function llms_flatten_pages(pages, out::Vector{Pair{String,String}} = Pair{String,String}[])
    for item in pages
        title, value = item isa Pair ? (String(item.first), item.second) : ("", item)
        if value isa AbstractString
            push!(out, title => String(value))
        else
            llms_flatten_pages(value, out)
        end
    end
    return out
end

# Documenter's `prettyurls = true` layout: `guides/client.md` -> `guides/client/`,
# `index.md` -> the site root, `guides/index.md` -> `guides/`.
function llms_page_url(path::AbstractString, site::AbstractString)
    p = replace(String(path), '\\' => '/')
    endswith(p, ".md") && (p = p[1:end-3])
    p == "index" && return site
    endswith(p, "/index") && (p = p[1:end-6])
    return site * p * "/"
end

# Split markdown lines into `(:prose, "", lines)` and `(:fence, info, lines)` chunks. A
# fence chunk includes its opening and closing fence lines; `info` is the stripped
# info string of the opening fence (e.g. "julia", "@docs", "@example name").
function llms_chunks(lines::AbstractVector{<:AbstractString})
    chunks = Tuple{Symbol,String,Vector{String}}[]
    prose = String[]
    n = length(lines)
    i = 1
    while i <= n
        m = match(LLMS_FENCE_OPEN, lines[i])
        if m === nothing
            push!(prose, String(lines[i]))
            i += 1
            continue
        end
        if !isempty(prose)
            push!(chunks, (:prose, "", prose))
            prose = String[]
        end
        marker = m.captures[1]
        j = i + 1
        while j <= n && !llms_isfenceclose(lines[j], marker)
            j += 1
        end
        j = min(j, n)
        push!(chunks, (:fence, String(strip(m.captures[2])), String[lines[k] for k in i:j]))
        i = j + 1
    end
    isempty(prose) || push!(chunks, (:prose, "", prose))
    return chunks
end

function llms_isfenceclose(line::AbstractString, marker::AbstractString)
    m = match(r"^ {0,3}(`{3,}|~{3,})\s*$", line)
    m === nothing && return false
    close = m.captures[1]
    return close[1] == marker[1] && length(close) >= length(marker)
end

# Append `line` to `out`, collapsing runs of blank prose lines (and leading blank
# lines) so that removed Documenter blocks do not leave holes. Code lines are always
# kept verbatim.
function llms_emit!(out::Vector{String}, line::AbstractString; code::Bool = false)
    if !code && isempty(strip(line)) && (isempty(out) || isempty(strip(out[end])))
        return out
    end
    push!(out, String(line))
    return out
end

"""
    llms_render_page(path, title; srcdir, site) -> LLMSPage

Render one Documenter page source to plain markdown: `@docs` blocks become the
docstrings of the listed bindings, `@meta`/`@contents`/`@index`/`@setup`/`@raw`
blocks are removed, `@example`/`@repl`/`@doctest` blocks become `julia` code
blocks, `@ref` links become their link text, and relative links to other pages
become absolute site URLs. Everything else is copied verbatim.
"""
function llms_render_page(path::AbstractString, title::AbstractString;
                          srcdir::AbstractString, site::AbstractString)
    text = read(joinpath(srcdir, path), String)
    out = String[]
    heading = ""
    sections = String[]
    current = Main   # `CurrentModule` of the page, set by `@meta` blocks
    for (kind, info, lines) in llms_chunks(split(text, '\n'))
        if kind === :prose
            for line in lines
                m = match(r"^(#{1,6})\s+(\S.*)$", line)
                if m !== nothing
                    level = length(m.captures[1])
                    level == 1 && isempty(heading) && (heading = String(strip(m.captures[2])))
                    level == 2 && push!(sections, String(strip(m.captures[2])))
                end
                llms_emit!(out, llms_render_prose_line(line, path, site))
            end
        elseif startswith(info, '@')
            block = first(split(info))
            body = lines[2:end-1]
            if block == "@meta"
                current = llms_current_module(body, current)
            elseif block == "@docs"
                for raw in body
                    entry = strip(raw)
                    (isempty(entry) || startswith(entry, '#')) && continue
                    llms_emit_docstrings!(out, entry, current, path)
                end
            elseif block in ("@example", "@repl", "@doctest")
                llms_emit!(out, "")
                llms_emit!(out, "```julia"; code = true)
                foreach(l -> llms_emit!(out, l; code = true), body)
                llms_emit!(out, "```"; code = true)
                llms_emit!(out, "")
            elseif block in ("@contents", "@index", "@setup", "@raw")
                # Navigation, hidden setup, or raw HTML/LaTeX: nothing to show.
            else
                @warn "llms: dropping unsupported Documenter block" block path
            end
        else
            foreach(l -> llms_emit!(out, l; code = true), lines)
        end
    end
    while !isempty(out) && isempty(strip(out[end]))
        pop!(out)
    end
    note = if haskey(LLMS_PAGE_NOTES, path)
        LLMS_PAGE_NOTES[path]
    else
        @warn "llms: no LLMS_PAGE_NOTES entry for page; using its section headings" path
        isempty(sections) ? "" : "sections: " * join(sections, "; ") * "."
    end
    pagetitle = !isempty(heading) ? heading : !isempty(title) ? String(title) : String(path)
    return LLMSPage(String(path), pagetitle, llms_page_url(path, site), note, join(out, '\n'))
end

function llms_render_prose_line(line::AbstractString, path::AbstractString, site::AbstractString)
    line = replace(line, LLMS_REF_LINK => s"\1")
    return replace(line, LLMS_PAGE_LINK => function (s)
        m = match(LLMS_PAGE_LINK, s)
        target = normpath(joinpath(dirname(String(path)), m.captures[1]))
        fragment = m.captures[2] === nothing ? "" : m.captures[2]
        return "](" * llms_page_url(target, site) * fragment * ")"
    end)
end

# Apply `CurrentModule = Foo.Bar` assignments from a `@meta` block.
function llms_current_module(body, current::Module)
    for line in body
        m = match(r"^\s*CurrentModule\s*=\s*(\S+)\s*$", line)
        m === nothing && continue
        current = llms_module(Meta.parse(m.captures[1]), Main)
    end
    return current
end

llms_module(ex, m::Module) = Documenter.DocSystem.getmod(m, ex)::Module
llms_binding(entry::AbstractString, current::Module) =
    Documenter.DocSystem.binding(current, Meta.parse(entry))

# Reuse Documenter's alias-aware lookup, including every method's docstring.
llms_docstrings(binding::Base.Docs.Binding) =
    Documenter.DocSystem.getdocs(binding, Union{}; compare = (<:))

# The raw markdown source of a docstring, exactly as written (no re-rendering).
function llms_docstring_text(d::Base.Docs.DocStr)
    isempty(d.text) && return string(Base.Docs.parsedoc(d))
    return sprint(io -> foreach(part -> print(io, part), d.text))
end

function llms_category(binding::Base.Docs.Binding)
    startswith(String(binding.var), '@') && return "Macro"
    Base.Docs.defined(binding) || return "Binding"
    obj = Base.Docs.resolve(binding)
    obj isa Module && return "Module"
    obj isa Type && return "Type"
    obj isa Function && return "Function"
    return "Constant"
end

# Emit `### `entry` — Category` followed by every docstring of the binding. Headings
# inside docstrings are demoted below the entry heading; code blocks are untouched.
function llms_emit_docstrings!(out::Vector{String}, entry::AbstractString, current::Module, path::AbstractString)
    binding = llms_binding(entry, current)
    docs = llms_docstrings(binding)
    if isempty(docs)
        error("llms: no docstring found for $entry in $path")
    end
    llms_emit!(out, "")
    llms_emit!(out, "### `" * entry * "` — " * llms_category(binding))
    llms_emit!(out, "")
    for d in docs
        for (kind, _, lines) in llms_chunks(split(llms_docstring_text(d), '\n'))
            if kind === :prose
                for raw in lines
                    line = replace(raw, LLMS_REF_LINK => s"\1")
                    m = match(r"^(#{1,6})(\s+\S.*)$", line)
                    m === nothing || (line = "#"^min(length(m.captures[1]) + 3, 6) * m.captures[2])
                    llms_emit!(out, line)
                end
            else
                foreach(l -> llms_emit!(out, l; code = true), lines)
            end
        end
        llms_emit!(out, "")
    end
    return out
end
