# HttpParser

This module provides access to Joyent's http-parser library: [http-parser](https://github.com/joyent/http-parser)

[![Build Status](https://travis-ci.org/JuliaLang/HttpParser.jl.png)](https://travis-ci.org/JuliaLang/HttpParser.jl)
[![Coverage Status](https://coveralls.io/repos/JuliaLang/HttpParser.jl/badge.png)](https://coveralls.io/r/JuliaLang/HttpParser.jl)

## Installation

```jl
# in REPL
julia> Pkg.add("HttpParser")
```

## Requirements

`libhttp-parser` needs to be available as a shared library. It should be built automatically by `Pkg` on Linux and OSX. On Windows a binary will be downloaded.

### Installing libhttp-parser as a shared library manually

1. clone https://github.com/joyent/http-parser
2. `cd http-parser`
3. `make library # Outputs a .so file, should be a .dylib on OS X`
4. move the `libhttp_parser.so` to `/usr/local/lib` (rename to `libhttp_parser.dylib` if on OS X)

## Test

5. `cd` back to `.julia/v0.3/HttpParser/`
6. `julia test/test.jl`
7. Expect to see text indicating that all assertions have passed.

## Building the Windows binaries

The current `http-parser` binary for Windows is cross-compiled using `mingw-w64`.
`mingw-w64` can be installed on Ubuntu using `sudo apt-get install mingw-w64`.
To build for yourself:
 * `git clone https://github.com/joyent/http-parser`
 * `git checkout 80819384450b5511a3d1c424dd92a5843c891364` (or whatever SHA the submodule in `HttpParser.jl/deps/src/` currently points to)
 * There are currently warnings that are treated as errors. Edit the Makefile to
   remove -Werror
 * To build 64-bit DLL: `CC=x86_64-w64-mingw32-gcc make library && mv libhttp_parser.so libhttp_parser64.dll`
 * To build 32-bit DLL: `CC=i686-w64-mingw32-gcc make library && mv libhttp_parser.so libhttp_parser32.dll`

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
