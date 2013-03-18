This module provides access to Joyent's http-parser library: [http-parser](https://github.com/joyent/http-parser)

## Requirements

* libhttp-parser needs to be available as a shared library on your system.

### Installing libhttp-parser as a shared library

1. clone https://github.com/joyent/http-parser
2. `cd http-parser`
3. `make library # Outputs a .so file, should be a .dylib on OS X`
4. move the libhttp_parser.so to /usr/local/lib (rename to libhttp_parser.dylib if on OS X)

## Test

5. cd back to HttpParser.jl
6. `julia src/Test.jl`

