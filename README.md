# HttpParser

This module provides access to Joyent's http-parser library: [http-parser](https://github.com/joyent/http-parser)

[![Build Status](https://travis-ci.org/JuliaLang/HttpParser.jl.png)](https://travis-ci.org/JuliaLang/HttpParser.jl)

## Installation

```jl
# in REQUIRE
HttpParser

# in REPL
julia> Pkg.add("HttpParser")
```

## Requirements

`libhttp-parser` needs to be available as a shared library. It should be built automatically by `Pkg`.

### Installing libhttp-parser as a shared library manually

1. clone https://github.com/joyent/http-parser
2. `cd http-parser`
3. `make library # Outputs a .so file, should be a .dylib on OS X`
4. move the `libhttp_parser.so` to `/usr/local/lib` (rename to `libhttp_parser.dylib` if on OS X)

## Test

5. `cd` back to `.julia/HttpParser/`
6. `julia test/test.jl`
7. Expect to see text indicating that all assertions have passed.

~~~~
:::::::::::::
::         ::
:: Made at ::
::         ::
:::::::::::::
     ::
Hacker School
:::::::::::::
~~~~
