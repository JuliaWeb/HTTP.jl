using BinDeps

find_library("HttpParser", "libhttp_parser", ["libhttp_parser", "libcairo"]) || error("libhttp_parser not found")
