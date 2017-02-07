@testset "utils.jl" begin

@test HTTP.escapeHTML("&\"'<>") == "&amp;&quot;&#39;&lt;&gt;"

@test HTTP.isurlchar('\u81')
@test !HTTP.isurlchar('\0')

for c = '\0':'\x7f'
    if c in ('.', '-', '_', '~')
        @test HTTP.ishostchar(c)
        @test HTTP.ismark(c)
        @test HTTP.isuserinfochar(c)
    elseif c in ('-', '_', '.', '!', '~', '*', '\'', '(', ')')
        @test HTTP.ismark(c)
        @test HTTP.isuserinfochar(c)
    else
        @test !HTTP.ismark(c)
    end
end

@test HTTP.isalphanum('a')
@test HTTP.isalphanum('1')
@test !HTTP.isalphanum(']')

@test HTTP.ishex('a')
@test HTTP.ishex('1')
@test !HTTP.ishex(']')

end