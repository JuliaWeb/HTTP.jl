module ConnectionPools

export Pod, Pool, acquire, release

import Base: acquire, release

connectionid(x) = objectid(x)
_id(x) = string(connectionid(x), base=16, pad=16)

"""
    ConnectionTracker(conn::T)

Wraps a `Connection` of type `T`.
A `Connection` object must support the following interface:
  * `isopen(x)`: check if a `Connection` object is still open and can be used
  * `close(x)`: close a `Connection` object; `isopen(x)` should return false after calling `close`
  * `ConnectionPools.connectionid(x)`: optional method to distinguish `Connection` objects from each other; by default, calls `objectid(x)`, which is valid for `mutable struct` objects

The `idle_timestamp` field is a timestamp to track when a `Connection` was returned to a `Pod` and became idle_timestamp.

The `times_used` field keeps track of how many times the connection has been "used" (i.e. acquired then released).
"""
mutable struct ConnectionTracker{T}
    conn::T
    idle_timestamp::Float64
    times_used::Int
end

ConnectionTracker(conn::T) where {T} = ConnectionTracker(conn, time(), 0)

"""
    Pod(T; max_concurrent_connections::Int, idle_timeout::Int)

A threadsafe object for managing a pool of and the reuse of `Connection` objects (see [`ConnectionTracker`](@ref)).

A Pod manages a collection of `Connection`s and the following keyword arguments allow configuring the management thereof:

  * `max_concurrent_connections::Int=typemax(Int)`: controls the max # of currently acquired `Connection`s allowed
  * `idle_timeout::Int=typemax(Int)`: controls the max # of seconds a `Connection` may be idle_timeout before it should be closed and not reused

After creating a `Pod`, `Connection`s can be acquired by calling [`acquire`](@ref) and MUST
be subsequently released by calling [`release`](@ref).
"""
struct Pod{T}
    # this lock/condition protects the `conns` Vector and `active` Dict
    # no changes to either field should be made without holding this lock
    lock::Threads.Condition
    conns::Vector{ConnectionTracker{T}}
    active::Dict{Any, ConnectionTracker{T}}
    max_concurrent_connections::Int
    idle_timeout::Int
end

const MAX = typemax(Int)

function Pod(T; max_concurrent_connections::Int=MAX, idle_timeout::Int=MAX)
    return Pod(Threads.Condition(), ConnectionTracker{T}[], Dict{Any, ConnectionTracker{T}}(), max_concurrent_connections, idle_timeout)
end

# check if an idle_timeout `Connection` is still valid to be reused
function isvalid(pod::Pod{C}, conn::ConnectionTracker{C}) where {C}
    if (time() - conn.idle_timestamp) > pod.idle_timeout
        # println("$(taskid()): connection idle_timeout timeout")
        # if the connection has been idle_timeout too long, close it
        close(conn.conn)
    elseif isopen(conn.conn)
        # println("$(taskid()): found a valid connection to reuse")
        # dump(conn.conn)
        # otherwise, if the connection is open, this is a valid connection we can use!
        return true
    else
        # println("$(taskid()): connection no longer open")
    end
    return false
end

function trackconnection!(pod::Pod{C}, conn::ConnectionTracker{C}) where {C}
    conn.times_used += 1
    id = connectionid(conn.conn)
    if haskey(pod.active, id)
        error("connection to be acquired is already an active, tracked connection from the pod according to the `connectionid(conn)`")
    end
    pod.active[id] = conn
    return conn.conn
end

"""
    acquire(f, pod::Pod{C}) -> C

Check first for existing `Connection`s in a `Pod` still valid to reuse,
and if so, return one. If no existing `Connection` is available for reuse,
call the provided function `f()`, which must return a new connection instance of type `C`.
This new connection instance will be tracked by the `Pod` and MUST be returned to the `Pod`
after use by calling `release(pod, conn)`.
"""
function acquire(f, pod::Pod, forcenew::Bool=false)
    lock(pod.lock)
    try
        # if there are idle connections in the pod,
        # let's check if they're still valid and can be used again
        while !forcenew && !isempty(pod.conns)
            # Pod connections are FIFO, so grab the earliest returned connection
            # println("$(taskid()): checking idle_timeout connections for reuse")
            conn = popfirst!(pod.conns)
            if isvalid(pod, conn)
                # println("$(taskid()): found a valid connection to reuse")
                return trackconnection!(pod, conn)
            else
                # nothing, let the non-valid connection fall into GC oblivion
            end
        end
        # There were no idle connections able to be reused
        # If there are not too many already-active connections, create new
        if length(pod.active) < pod.max_concurrent_connections
            # println("$(taskid()): no idle_timeout connections to reuse; creating new")
            return trackconnection!(pod, ConnectionTracker(f()))
        end
        # If we reach here, there were no valid idle connections and too many
        # currently-active connections, so we need to wait until for a "release"
        # event, which will mean a connection has been returned that can be reused,
        # or a "slot" has opened up so we can create a new connection, otherwise,
        # we'll just need to start the loop back over and wait again
        while true
            # this `wait` call will block on our Pod `lock` condition
            # until a connection is `release`ed and the condition
            # is notified
            # println("$(taskid()): connection pool maxxed out; waiting for connection to be released to the pod")
            conn = wait(pod.lock)
            if !forcenew && conn !== nothing
                # println("$(taskid()): checking recently released connection validity for reuse")
                if isvalid(pod, conn)
                    return trackconnection!(pod, conn)
                end
            end
            # if the Connection just returned to the Pod wasn't valid, the active
            # count should have at least went down, so we should be able to create a new one
            if length(pod.active) < pod.max_concurrent_connections
                return trackconnection!(pod, ConnectionTracker(f()))
            end
            # If for some reason there were still too many active connections, let's
            # start the loop back over waiting for connections to be returned
        end
    finally
        unlock(pod.lock)
    end
end

taskid() = string(objectid(current_task()) % UInt16, base=16, pad=4)

# ability to provide an already created connection object to insert into the Pod
# if Pod is already at max_concurrent_connections, acquire will wait until an
# active connection is released back to the pod
# it will be tracked among active connections and must be released
function acquire(pod::Pod{C}, c::C) where {C}
    lock(pod.lock)
    try
        if length(pod.active) < pod.max_concurrent_connections
            return trackconnection!(pod, ConnectionTracker(c))
        else
            while true
                # wait until pod gets a connection released
                conn = wait(pod.lock)
                if conn !== nothing
                    push!(pod.conns, conn)
                else
                    conn = ConnectionTracker(c)
                end
                return trackconnection!(pod, conn)
            end
        end
    finally
        unlock(pod.lock)
    end
end

function release(pod::Pod{C}, conn::C; return_for_reuse::Bool=true) where {C}
    lock(pod.lock)
    try
        # We first want to look up the corresponding ConnectionTracker object in our
        # Pod `active` Dict that tracks active connections
        id = connectionid(conn)
        # if, for some reason, it's not in our `active` tracking Dict
        # then something is wrong; you're trying to release a `Connection`
        # that this Pod currently doesn't think is active
        if !haskey(pod.active, id)
            error("couldn't find connection id in pod's current list of active connections; invalid release call; each acquired connection should be `release`ed ONLY once")
        end
        conn_tracker = pod.active[id]
        # remove the ConnectionTracker from our `active` Dict tracker
        delete!(pod.active, id)
        if return_for_reuse && isopen(conn)
            # reset the idle_timestamp of the ConnectionTracker
            conn_tracker.idle_timestamp = time()
            # check if there are any tasks waiting to acquire a connection
            if isempty(pod.lock)
                # if not, we put the connection back in the pod idle queue
                # in this case, there's no need to notify the pod lock/condition
                # since there's no one waiting to be notified anyway
                # println("$(taskid()): returning connection (id='$(_id(id))') to pod idle_timeout queue for reuse")
                push!(pod.conns, conn_tracker)
            else
                # if there are waiters, we notify the pod condition and pass the
                # ConnectionTracker object in the notification; we ensure to pass
                # all=false, so only one waiter is woken up and receives the
                # ConnectionTracker
                # println("$(taskid()): returning connection (id='$(_id(id))') to a waiting task for reuse")
                notify(pod.lock, conn_tracker; all=false)
            end
        else
            # if the user has, for whatever reason, requested this connection not be reused
            # anymore by passing `return_for_reuse=false`, then we've still removed it from
            # the `active` tracking and want to notify the pod in case there are waiting
            # acquire tasks that can now create a new connection
            # println("$(taskid()): connection not reuseable; notifying pod that a connection has been released though")
            notify(pod.lock, nothing; all=false)
        end
    finally
        unlock(pod.lock)
    end
    return
end

"""
    Pool(T)

A threadsafe convenience object for managing multiple [`Pod`](@ref)s of connections.
A `Pod` of reuseable connections will be looked up by the `key` when calling `acquire(f, pool, key)`.
"""
struct Pool{C}
    lock::ReentrantLock
    pods::Dict{Any, Pod{C}}
end

Pool(C) = Pool(ReentrantLock(), Dict{Any, Pod{C}}())

"""
    acquire(f, pool::Pool{C}, key; max_concurrent_connections::Int, idle_timeout::Int, reuse::Int) -> C

Get a connection from a `pool`, looking up a `Pod` of reuseable connections
by the provided `key`. If no `Pod` exists for the given key yet, one will be
created and passed the `max`, `idle_timeout`, and `reuse` keyword arguments if provided.
The provided function `f` must create a new connection instance of type `C`.
The acquired connection MUST be returned to the pool by calling `release(pool, key, conn)` exactly once.
"""
function acquire(f, pool::Pool{C}, key; forcenew::Bool=false, kw...) where {C}
    pod = lock(pool.lock) do
        get!(() -> Pod(C; kw...), pool.pods, key)
    end
    return acquire(f, pod, forcenew)
end

function acquire(pool::Pool{C}, key, conn::C; kw...) where {C}
    pod = lock(pool.lock) do
        get!(() -> Pod(C; kw...), pool.pods, key)
    end
    return acquire(pod, conn)
end

"""
    release(pool::Pool{C}, key, conn::C)

Return an acquired connection to a `pool` with the same `key` provided when it was acquired.
"""
function release(pool::Pool{C}, key, conn::C; kw...) where {C}
    pod = lock(pool.lock) do
        pool.pods[key]
    end
    release(pod, conn; kw...)
    return
end

"""
    reset!(pool) -> nothing

Close all connections in a `Pool`.
"""
function reset!(pool::Pool)
    lock(pool.lock) do
        for pod in values(pool.pods)
            lock(pod.lock) do
                foreach(pod.conns) do conn
                    close(conn.conn)
                end
                empty!(pod.conns)
                for conn in values(pod.active)
                    close(conn.conn)
                end
                empty!(pod.active)
            end
        end
        empty!(pool.pods)
    end
    return
end

end # module
