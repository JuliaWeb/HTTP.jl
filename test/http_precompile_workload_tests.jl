using Test
using HTTP

const HT = HTTP

@testset "HTTP shared precompile workload" begin
    @test HT._run_precompile_workload!() === nothing
end
