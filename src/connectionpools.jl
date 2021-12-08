module ConnectionPools

export Pod, Pool, acquire, release

import Base: acquire, release

connectionid(x) = objectid(x)

"""
    ConnectionTracker(conn::T)

Wraps a `Connection` of type `T`.
A `Connection` object must support the following interface:
  * `isopen(x)`: check if a `Connection` object is still open and can be used
  * `close(x)`: close a `Connection` object; `isopen(x)` should return false after calling `close`
  * `ConnectionPools.connectionid(x)`: optional method to distinguish `Connection` objects from each other; by default, calls `objectid(x)`, which is valid for `mutable struct` objects

The `idle` field is a timestamp to track when a `Connection` was returned to a `Pod` and became idle.

The `count` field keeps track of how many times the connection has been used.
"""
mutable struct ConnectionTracker{T}
    conn::T
    idle::Float64
    count::Int
end

ConnectionTracker(conn::T) where {T} = ConnectionTracker(conn, time(), 1)

"""
    Pod(T; max::Int, idle::Int, reuse::Int)

A threadsafe object for managing a pool of and the reuse of `Connection` objects (see [`ConnectionTracker`](@ref)).

A Pod manages a collection of `Connection`s and the following keyword arguments allow configuring the management thereof:

  * `max::Int=typemax(Int)`: controls the max # of currently acquired `Connection`s allowed
  * `idle::Int=typemax(Int)`: controls the max # of seconds a `Connection` may be idle before it should be closed and not reused
  * `reuse::Int=typemax(Int)`: controls the max # of times a `Connection` may be reused before it should be closed

After creating a `Pod`, `Connection`s can be acquired by calling [`acquire`](@ref) and MUST
be subsequently released by calling [`release`](@ref).
"""
struct Pod{T}
    # this lock/condition protects the `conns` Vector and `active` Dict
    # no changes to either field should be made without holding this lock
    lock::Threads.Condition
    conns::Vector{ConnectionTracker{T}}
    active::Dict{Any, ConnectionTracker{T}}
    max::Int
    idle::Int
    reuse::Int
end

const MAX = typemax(Int)

function Pod(T; max::Int=MAX, idle::Int=MAX, reuse::Int=MAX)
    return Pod(Threads.Condition(), ConnectionTracker{T}[], Dict{Any, ConnectionTracker{T}}(), max, idle, reuse)
end

# check if an idle `Connection` is still valid to be reused
function isvalid(pod::Pod{C}, conn::ConnectionTracker{C}) where {C}
    if (time() - conn.idle) > pod.idle
        # println("connection idle timeout")
        # if the connection has been idle too long, close it
        close(conn.conn)
    elseif conn.count >= pod.reuse
        # println("connection over reuse limit")
        # if the connection has been used too many times, close it
        close(conn.conn)
    elseif isopen(conn.conn)
        # println("found a valid connection to reuse")
        # dump(conn.conn)
        # otherwise, if the connection is open, this is a valid connection we can use!
        return true
    else
        # println("connection no longer open")
    end
    return false
end

"""
    acquire(f, pod::Pod{C}) -> C

Check first for existing `Connection`s in a `Pod` still valid to reuse,
and if so, return one. If no existing `Connection` is available for reuse,
call the provided function `f()`, which must return a new connection instance of type `C`.
This new connection instance will be tracked by the `Pod` and MUST be returned to the `Pod`
after use by calling `release(pod, conn)`.
"""
function acquire(f, pod::Pod)
    lock(pod.lock)
    try
        # if there are already connections in the pod that have been
        # returned, let's check if they're still valid and can be used directly
        while !isempty(pod.conns)
            # Pod connections are FIFO, so grab the earliest returned connection
            # println("checking idle connections for reuse")
            conn = popfirst!(pod.conns)
            if isvalid(pod, conn)
                # connection is valid! increment its usage count
                # and move the ConnectionTracker to the `active` Dict tracker
                conn.count += 1
                id = connectionid(conn.conn)
                # println("returning connection (id='$(id)')")
                pod.active[id] = conn
                return conn.conn
            end
        end
        # There were no existing connections able to be reused
        # If there are not too many already-active connections, create new
        if length(pod.active) < pod.max
            # println("no idle connections to reuse; creating new")
            conn = ConnectionTracker(f())
            id = connectionid(conn.conn)
            # println("returning connection (id='$(id)')")
            pod.active[id] = conn
            return conn.conn
        end
        # If we reach here, there were no valid idle connections and too many
        # currently-active connections, so we need to wait until a connection
        # is released back to the Pod
        while true
            # this `wait` call will block on our Pod `lock` condition
            # until a connection is `release`ed and the condition
            # is notified
            # println("connection pool maxxed out; waiting for connection to be released to the pod")
            conn = wait(pod.lock)
            if conn !== nothing
                # println("checking recently released connection validity for reuse")
                if isvalid(pod, conn)
                    # println("connection just released to the Pod is valid and can be reused")
                    conn.count += 1
                    id = connectionid(conn.conn)
                    # println("returning connection (id='$(id)')")
                    pod.active[id] = conn
                    return conn.conn
                end
            end
            # if the Connection just returned to the Pod wasn't valid, the active
            # count at least went down, so we should be able to create a new one
            if length(pod.active) < pod.max
                # println("connection just returned wasn't valid; creating new")
                conn = ConnectionTracker(f())
                id = connectionid(conn.conn)
                # println("returning connection (id='$(id)')")
                pod.active[id] = conn
                return conn.conn
            end
            # If for some reason there were still too many active connections, let's
            # start the loop back over waiting for idle connections to be returned
            # Hey, we get it, writing threadsafe code can be hard
        end
    finally
        unlock(pod.lock)
    end
end

function release(pod::Pod{C}, conn::C; return_for_reuse::Bool=true) where {C}
    lock(pod.lock)
    try
        # We first want to look up this connection object in our
        # Pod `active` Dict that tracks active connections
        id = connectionid(conn)
        # if, for some reason, it's not in our `active` tracking Dict
        # then something is wrong; you're trying to release a `Connection`
        # that this Pod currently doesn't think is active
        if !haskey(pod.active, id)
            error("invalid connection pool release call; each acquired connection should be `release`ed ONLY once")
        end
        cp_conn = pod.active[id]
        # remove the ConnectionTracker from our `active` Dict tracker
        delete!(pod.active, id)
        if return_for_reuse && isopen(conn)
            # reset the idle timestamp of the ConnectionTracker
            cp_conn.idle = time()
            # check if there are any tasks waiting on a connection
            if isempty(pod.lock)
                # if not, we put the connection back in the pod idle queue
                # println("returning connection (id='$(id)') to pod idle queue for reuse")
                push!(pod.conns, cp_conn)
            else
                # and notify our Pod condition that a connection has been returned
                # in order to "wake up" any `wait`ers looking for a new connection
                # println("returning connection (id='$(id)') to a waiting task for reuse")
                notify(pod.lock, cp_conn; all=false)
            end
        else
            # println("connection not reuseable; notifying pod that a connection has been released though")
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
    acquire(f, pool::Pool{C}, key; max::Int, idle::Int, reuse::Int) -> C

Get a connection from a `pool`, looking up a `Pod` of reuseable connections
by the provided `key`. If no `Pod` exists for the given key yet, one will be
created and passed the `max`, `idle`, and `reuse` keyword arguments if provided.
The provided function `f` must create a new connection instance of type `C`.
The acquired connection MUST be returned to the pool by calling `release(pool, key, conn)` exactly once.
"""
function acquire(f, pool::Pool{C}, key; kw...) where {C}
    pod = lock(pool.lock) do
        get!(() -> Pod(C; kw...), pool.pods, key)
    end
    return acquire(f, pod)
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
