# HttpParser

This module provides a Julia wrapper around Joyent's http-parser library: [http-parser](https://github.com/joyent/http-parser)

You can look at the code of HttpSever.jl as an example of using HttpParser.jl.

## Installation

    :::julia
    julia> Pkg.add("HttpParser")

### Requirements

`libhttp-parser` needs to be available as a shared library. It should be built automatically by `Pkg`.

#### Installing libhttp-parser as a shared library manually

1. clone https://github.com/joyent/http-parser
2. `cd http-parser`
3. `make library # Outputs a .so file, should be a .dylib on OS X`
4. move the libhttp_parser.so to /usr/local/lib (rename to libhttp_parser.dylib if on OS X)

## Test

1. Move to `~/.julia/HttpParser/`
2. Run `julia src/Test.jl`
3. Expect to see text indicating that all assertions have passed.
