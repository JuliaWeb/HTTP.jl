# HttpParser.jl

This package provides a Julia wrapper around Joyent's [http-parser](https://github.com/joyent/http-parser) library (v2.1).

[![Build Status](https://travis-ci.org/JuliaWeb/HttpParser.jl.svg?branch=master)](https://travis-ci.org/JuliaWeb/HttpParser.jl)
[![Coverage Status](https://coveralls.io/repos/JuliaWeb/HttpParser.jl/badge.svg?branch=master)](https://coveralls.io/r/JuliaWeb/HttpParser.jl?branch=master)
[![HttpParser](http://pkg.julialang.org/badges/HttpParser_0.3.svg)](http://pkg.julialang.org/?pkg=HttpParser&ver=release)
[![HttpParser](http://pkg.julialang.org/badges/HttpParser_0.4.svg)](http://pkg.julialang.org/?pkg=HttpParser&ver=nightly)

**Installation**: `julia> Pkg.add("HttpParser")`

`libhttp-parser` needs to be available as a shared library, but it will be built automatically on Linux and OSX, and downloaded as a binary on Windows.

### Installing libhttp-parser as a shared library manually

1. `git clone https://github.com/joyent/http-parser`
2. `cd http-parser`
3. `git checkout v2.1`
4. `make library # Outputs a .so file, should be a .dylib on OS X`
5. move the `libhttp_parser.so` to `/usr/local/lib` (rename to `libhttp_parser.dylib` if on OS X)

## Test

5. `cd` back to `.julia/v0.3/HttpParser/`
6. `julia test/runtests.jl`
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
