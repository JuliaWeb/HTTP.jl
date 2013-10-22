
push!(DL_LOAD_PATH, "$(Pkg.dir())/HttpParser/deps/usr/lib/")
find_library(["libhttp_parser"]) == "" && error("libhttp_parser not found")
