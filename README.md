## Requirements

* libhttp-parser needs to be available as a shared library on your system.

### Installing libhttp-parser as a shared library

1. clone https://github.com/joyent/http-parser
2. `cd http-parser`
3. `make library`
4. `ln -s libhttp-parser.so /usr/local/lib/libhttp-parser.dylib`

## Test

5. cd back to HttpParser.jl
6. `julia src/Test.jl`

call joyent/http-parser in julia

brought to you by [Hacker School](http://www.hackerschool.com)
