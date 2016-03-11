# HttpParser.jl

This package provides a Julia wrapper around Joyent's [http-parser](https://github.com/joyent/http-parser) library (v2.6.2).

[![Build Status](https://travis-ci.org/JuliaWeb/HttpParser.jl.svg?branch=master)](https://travis-ci.org/JuliaWeb/HttpParser.jl)
[![Coverage Status](https://coveralls.io/repos/JuliaWeb/HttpParser.jl/badge.svg?branch=master)](https://coveralls.io/r/JuliaWeb/HttpParser.jl?branch=master)

[![HttpParser](http://pkg.julialang.org/badges/HttpParser_0.3.svg)](http://pkg.julialang.org/?pkg=HttpParser&ver=0.3)
[![HttpParser](http://pkg.julialang.org/badges/HttpParser_0.4.svg)](http://pkg.julialang.org/?pkg=HttpParser&ver=0.4)

**Installation**: `julia> Pkg.add("HttpParser")`

`libhttp-parser` shared library will be built automatically on Linux and OSX, and downloaded as a binary on Windows.

## Building the Windows binaries

The current `http-parser` binary for Windows is cross-compiled using `mingw-w64`.
`mingw-w64` can be installed on Ubuntu using `sudo apt-get install mingw-w64`.
To build for yourself:
 * `git clone https://github.com/joyent/http-parser`
 * `cd http-parser`
 * `git checkout v2.6.2`
 * There are currently warnings that are treated as errors. Edit the Makefile to remove -Werror
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
