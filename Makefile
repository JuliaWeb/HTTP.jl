changelog:
	julia -e 'using Changelog; Changelog.generate(Changelog.CommonMark(), "CHANGELOG.md"; repo = "JuliaWeb/HTTP.jl")'
