const on_setup = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_setup(conn, error_code, fut_ptr)
    fut = unsafe_pointer_to_objref(fut_ptr)
    if error_code == AWS_IO_DNS_INVALID_NAME# || error_code == AWS_IO_TLS_ERROR_NEGOTIATION_FAILURE
        notify(fut, DontRetry(CapturedException(aws_error(error_code), Base.backtrace())))
    else
        notify(fut, CapturedException(aws_error(error_code), Base.backtrace()))
    end
    return
end

function with_connection(f::Function, client::Client)
    connectionSetup = Future{Ptr{aws_http_connection}}()
    GC.@preserve connectionSetup begin
        aws_http_connection_manager_acquire_connection(client.connection_manager, on_setup[], pointer_from_objref(connectionSetup))
        connection = wait(connectionSetup)
    end
    try
        return f(connection)
    finally
        aws_http_connection_manager_release_connection(client.connection_manager, connection)
    end
end
