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

@unix_only begin
    prefix = BinDeps.usrdir(libhttp_parser)
    target = "libhttp_parser.$(BinDeps.shlib_ext)"
    targetpath = joinpath(BinDeps.libdir(libhttp_parser),target)

    provides(SimpleBuild,
        (@build_steps begin
            ChangeDirectory(BinDeps.pkgdir(libhttp_parser))
            FileRule("deps/src/http-parser/Makefile",`git submodule update --init`)
            FileRule(targetpath, @build_steps begin
                ChangeDirectory(BinDeps.srcdir(libhttp_parser))
                CreateDirectory(dirname(targetpath))
                MakeTargets(["-C","http-parser","library"], env=Dict("SONAME"=>target))
                `cp http-parser/$target $targetpath`
            end)
        end),[libhttp_parser], os = :Unix)
end

# Windows
@windows_only begin
    provides(Binaries,
         URI("https://julialang.s3.amazonaws.com/bin/winnt/extras/libhttp_parser.zip"),
         libhttp_parser, os = :Windows)
end

@BinDeps.install Dict(:libhttp_parser => :lib)

