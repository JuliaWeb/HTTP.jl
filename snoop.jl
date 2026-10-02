using SnoopCompile

### Log the compiles
# This only needs to be run once (to generate "/tmp/images_compiles.csv")

SnoopCompile.@snoop "http_compiles.csv" begin
    include(Pkg.dir("HTTP", "test","runtests.jl"))
end

### Parse the compiles and generate precompilation scripts
# This can be run repeatedly to tweak the scripts

# IMPORTANT: we must have the module(s) defined for the parcelation
# step, otherwise we will get no precompiles for the Images module
using HTTP

data = SnoopCompile.read("http_compiles.csv")

# Use these two lines if you want to create precompile functions for
# individual packages
pc, discards = SnoopCompile.parcel(data[end:-1:1,2])
SnoopCompile.write("src/precompile", pc)