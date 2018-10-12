using Test 

include("../src/Nibbles.jl")

@testset "Nibbles" begin

@test collect(Nibbles.Iterator(UInt8[0x12, 0x34, 0x56, 0x78, 0x90])) ==
                               UInt8[1, 2, 3, 4, 5, 6, 7, 8, 9, 0]

@test collect(Nibbles.Iterator(UInt8[0x10, 0x30, 0x50, 0x70, 0x90])) ==
                              UInt8[1, 0, 3, 0, 5, 0, 7, 0, 9, 0]

@test collect(Nibbles.Iterator(UInt8[0x02, 0x04, 0x06, 0x08, 0x00])) ==
                               UInt8[0, 2, 0, 4, 0, 6, 0, 8, 0, 0]

let f = 0xf
@test collect(Nibbles.Iterator(UInt8[0xF2, 0xF4, 0xF6, 0xF8, 0xF0])) ==
                               UInt8[f, 2, f, 4, f, 6, f, 8, f, 0]

@test collect(Nibbles.Iterator(UInt8[0x1f, 0x3f, 0x5f, 0x7f, 0x9f])) ==
                               UInt8[1, f, 3, f, 5, f, 7, f, 9, f]
end

n = Nibbles.Iterator(UInt8[0x12, 0x34, 0x56, 0x78, 0x90])
@test map(i->getindex(n, i), 1:10) == collect(n)

end # @testset Nibbles
