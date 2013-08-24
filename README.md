# HttpParser

This module provides access to Joyent's http-parser library: [http-parser](https://github.com/joyent/http-parser)

[![Build Status](https://travis-ci.org/[YOUR_GITHUB_USERNAME]/[YOUR_PROJECT_NAME].png)](https://travis-ci.org/[YOUR_GITHUB_USERNAME]/[YOUR_PROJECT_NAME])

## Installation

```jl
# in REQUIRE
HttpParser 0.0.1

# in REPL
julia> Pkg2.add("HttpParser")
```

## Requirements

`libhttp-parser` needs to be available as a shared library. It should be built automatically by `Pkg2`.

### Installing libhttp-parser as a shared library manually

1. clone https://github.com/joyent/http-parser
2. `cd http-parser`
3. `make library # Outputs a .so file, should be a .dylib on OS X`
4. move the libhttp_parser.so to /usr/local/lib (rename to libhttp_parser.dylib if on OS X)

## Test

5. cd back to HttpParser.jl
6. `julia src/Test.jl`
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
