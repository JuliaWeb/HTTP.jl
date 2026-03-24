using PrecompileTools: @setup_workload, @compile_workload

try
    @setup_workload begin
        @compile_workload begin
            _run_precompile_workload!()
        end
    end
catch err
    @info "Ignoring an error that occurred during the precompilation workload" exception=(err, catch_backtrace())
end
