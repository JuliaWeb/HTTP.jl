@testset "HTTP precompile workload cleanup" begin
    @test HTTP._precompile_host_resolver_available() isa Bool
    withenv("HTTP_PRECOMPILE_WORKLOAD" => "0") do
        @test !HTTP._precompile_workload_enabled()
    end
    @test HTTP._run_precompile_workload!() === nothing
    @test HTTP._precompile_shutdown!() === nothing
end
