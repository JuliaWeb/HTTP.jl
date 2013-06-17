using BinDeps

depsdir = joinpath(Pkg.dir(),"HttpParser","deps")
prefix=joinpath(depsdir,"usr")
uprefix = replace(replace(prefix,"\\","/"),"C:/","/c/")
target = joinpath(prefix,"lib/libhttp_parser.$(BinDeps.shlib_ext)")

run(@build_steps begin
    ChangeDirectory(joinpath(depsdir,"src"))
    FileRule("http-parser/Makefile",`git submodule update`)
    CreateDirectory(dirname(target))
    FileRule(target,@build_steps begin
        MakeTargets(["-C","http-parser","library"])
        `cp http-parser/libhttp_parser.so $target`
    end)
end)
