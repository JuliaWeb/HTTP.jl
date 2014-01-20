using BinDeps

@BinDeps.setup

aliases = []
@windows_only begin
    if WORD_SIZE == 64
        aliases = ["libhttp_parser64"]
    else
        aliases = ["libhttp_parser32"]
    end
end

libhttp_parser = library_dependency("libhttp_parser", aliases=aliases)

println(libhttp_parser)
@unix_only begin
    depsdir = joinpath(Pkg.dir(),"HttpParser","deps")
    prefix=joinpath(depsdir,"usr")
    uprefix = replace(replace(prefix,"\\","/"),"C:/","/c/")
    target = joinpath(prefix,"lib/libhttp_parser.$(BinDeps.shlib_ext)")

    provides(SimpleBuild,
        (@build_steps begin
            ChangeDirectory(Pkg.Dir.path("HttpParser"))
            FileRule("deps/src/http-parser/Makefile",`git submodule update --init`)
            FileRule(target,@build_steps begin
                ChangeDirectory(Pkg.Dir.path("HttpParser","deps","src"))
                CreateDirectory(dirname(target))
                MakeTargets(["-C","http-parser","library"])
                `cp http-parser/libhttp_parser.so $target`
            end)
        end),[libhttp_parser], os = :Unix)
end

# Windows
@windows_only begin
    provides(Binaries,
         URI("https://dl.dropboxusercontent.com/u/19359560/libhttp_parser.zip"),
         libhttp_parser, os = :Windows)
end

@BinDeps.install [:libhttp_parser => :lib]