@testset "FIFOBuffer" begin

    f = HTTP.FIFOBuffer()
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    f = HTTP.FIFOBuffer()
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    @test write(f, 0x01) == 1
    @test write(f, 0x02) == 1
    @test read(f, Tuple{UInt8,Bool}) == (0x01, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x02, true)
    @test isempty(readavailable(f))

    @test write(f, UInt8[0x01, 0x02]) == 2
    @test all(readavailable(f) .== UInt8[0x01, 0x02])

    f = HTTP.FIFOBuffer()
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    @test read(f, Tuple{UInt8,Bool}) == (0x01, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    write(f, 0x02)
    @test read(f, Tuple{UInt8,Bool}) == (0x01, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x02, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    write(f, 0x02)
    @test all(readavailable(f) .== UInt8[0x01, 0x02])
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    write(f, 0x02)
    write(f, 0x03)
    write(f, 0x04)
    write(f, 0x05)
    @test read(f, Tuple{UInt8,Bool}) == (0x01, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x02, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x03, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x04, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x05, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    write(f, 0x02)
    write(f, 0x03)
    write(f, 0x04)
    write(f, 0x05)
    write(f, 0x06)
    @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[])
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01])
    @test read(f, Tuple{UInt8,Bool}) == (0x01, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01, 0x02])
    @test read(f, Tuple{UInt8,Bool}) == (0x01, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x02, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01, 0x02])
    @test all(readavailable(f) .== UInt8[0x01, 0x02])
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    @test read(f, Tuple{UInt8,Bool}) == (0x01, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x02, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x03, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x04, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x05, true)
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    # overflow
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06]) == 6
    @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
    @test read(f, Tuple{UInt8,Bool}) == (0x00, false)
    @test isempty(readavailable(f))

    # condition notification
    # fill the buffer up
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    # a write task is started asynchronously, which means it will wait for a
    # notify from a read that there's space to write again
    tsk = @async begin
        @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    end
    # when data is read in the next readavailble, a notify is sent to f.cond
    # which wakes up `tsk` to write it's data
    @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    # meanwhile, we start the next `readavailable` asynchronously, which will block
    # until `tsk` is done writing
    @sync @async @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    @sync begin
        N = 100
        tsk1 = @async begin
            for i = 1:N
                @test write(f, UInt8[0x4a, 0x61, 0x63, 0x6f, 0x62]) == 5
            end
        end
        tsk2 = @async begin
            for i = 1:N
                @test all(read(f, 5) .== UInt8[0x4a, 0x61, 0x63, 0x6f, 0x62])
            end
        end
    end

    # buffer growing
    f = HTTP.FIFOBuffer()
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    @test write(f, UInt8[0x06, 0x07, 0x08, 0x09, 0x0a]) == 5
    @test all(readavailable(f) .== 0x01:0x0a)

    # read
    f = HTTP.FIFOBuffer()
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    @test all(read(f, 5) .== 0x01:0x05)
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    @test all(read(f, 5) .== 0x01:0x05)
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    @test isempty(read(f, 0))
    @test all(read(f, 2) .== 0x01:0x02)
    @test write(f, 0x01) == 1
    @test all(read(f, 4) .== UInt8[0x03, 0x04, 0x05, 0x01])
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    @test all(read(f, 2) .== 0x01:0x02)
    r = read(f, 3)
    @test all(r .== 0x03:0x05)


    f2 = HTTP.FIFOBuffer(f)
    @test f == f2

    f = HTTP.FIFOBuffer()
    @test isempty(read(f, 0))
    t = @async read(f, 1)
    write(f, 0x01)
    @test wait(t) == [0x01]

    @test write(f, [0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    @test write(f, [0x01, 0x02]) == 2

    @test readavailable(f) == [0x01, 0x02, 0x03, 0x04, 0x05, 0x01, 0x02]

    # ensure we're in a wrap-around state
    f = HTTP.FIFOBuffer()
    @test write(f, [0x01, 0x02, 0x03]) == 3
    @test readavailable(f) == [0x01, 0x02, 0x03]
    @test write(f, [0x01, 0x02, 0x03, 0x04]) == 4
#    @test f.f > f.l

    @test write(f, [0x05]) == 1
    @test readavailable(f) == [0x01, 0x02, 0x03, 0x04, 0x05]

    @test write(f, [0x01, 0x02, 0x03, 0x04]) == 4
    @test write(f, [0x05, 0x06]) == 2
    @test readavailable(f) == [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]

    # ensure that `read(..., ::Type{UInt8})` returns a `UInt8`
    # https://github.com/JuliaWeb/HTTP.jl/issues/41
    f = HTTP.FIFOBuffer()
    b = Array{UInt8}(3)
    @test write(f, [0x01, 0x02, 0x03, 0x04]) == 4
    close(f)
    @test readbytes!(f, b) == 3
    @test b == [0x01, 0x02, 0x03]
    @test read(f, UInt8) == 0x04
    @test_throws EOFError read(f, UInt8)

    # ensure we return eof == false if there are still bytes to be read
    f = HTTP.FIFOBuffer()
    write(f, [0x01, 0x02, 0x03, 0x04])
    close(f)
    @async begin
        @test !eof(f)
    end

    # Issue #45
    # Ensure that we don't encounter an EOF when reading before data is written
    f = HTTP.FIFOBuffer()
    bytes = [0x01, 0x02, 0x03, 0x04]
    @async begin
        @test !eof(f)
    end
    @sync begin
        @async begin
            bytes_read = UInt8[]
            while !eof(f)
                push!(bytes_read, read(f, UInt8))
            end
            @test bytes_read == bytes
        end
        yield()
        write(f, bytes)
        close(f)
    end
    @test eof(f)
end; # testset
