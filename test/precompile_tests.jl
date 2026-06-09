@testset "HTTP precompile workload cleanup" begin
    @test HTTP._precompile_host_resolver_available() isa Bool
    @test HTTP._run_precompile_workload!() === nothing
    @test HTTP._precompile_shutdown!() === nothing
end
