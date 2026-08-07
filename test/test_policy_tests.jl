using Test

@testset "test synchronization does not depend on wall-clock timing" begin
    forbidden = [
        r"\bsleep\s*\(" => "sleep-based coordination",
        r"\btimedwait\s*\(" => "deadline polling",
        r"\btime_ns\s*\(" => "monotonic-clock reads",
        r"\btime\s*\(" => "wall-clock reads",
        r"@elapsed\b" => "elapsed-time assertions",
        r"\bTimer\s*\(" => "timer-based coordination",
        r"\bnow\s*\(" => "current-date reads",
        r"\bpollint\s*=" => "polling intervals",
        r"\btimeout_s\s*=" => "test-helper timeouts",
    ]
    policy_file = abspath(@__FILE__)
    for path in sort(filter(path -> endswith(path, ".jl"), readdir(@__DIR__; join=true)))
        abspath(path) == policy_file && continue
        source = read(path, String)
        for (pattern, description) in forbidden
            occursin(pattern, source) && error("$(basename(path)) uses forbidden $(description)")
        end
    end
    @test true
end
