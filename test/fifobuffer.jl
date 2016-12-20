@testset "FIFOBuffer" begin

    f = HTTP.FIFOBuffer(0)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    f = HTTP.FIFOBuffer(1)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    @test write(f, 0x01) == 1
    @test write(f, 0x02) == 0
    @test read(f, UInt8) == (0x01, true)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    @test write(f, UInt8[0x01, 0x02]) == 1
    @test all(readavailable(f) .== UInt8[0x01])

    f = HTTP.FIFOBuffer(5)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    @test read(f, UInt8) == (0x01, true)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    write(f, 0x02)
    @test read(f, UInt8) == (0x01, true)
    @test read(f, UInt8) == (0x02, true)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    write(f, 0x02)
    @test all(readavailable(f) .== UInt8[0x01, 0x02])
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    write(f, 0x02)
    write(f, 0x03)
    write(f, 0x04)
    write(f, 0x05)
    @test read(f, UInt8) == (0x01, true)
    @test read(f, UInt8) == (0x02, true)
    @test read(f, UInt8) == (0x03, true)
    @test read(f, UInt8) == (0x04, true)
    @test read(f, UInt8) == (0x05, true)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, 0x01)
    write(f, 0x02)
    write(f, 0x03)
    write(f, 0x04)
    write(f, 0x05)
    write(f, 0x06) == 0
    @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[])
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01])
    @test read(f, UInt8) == (0x01, true)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01, 0x02])
    @test read(f, UInt8) == (0x01, true)
    @test read(f, UInt8) == (0x02, true)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01, 0x02])
    @test all(readavailable(f) .== UInt8[0x01, 0x02])
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    @test read(f, UInt8) == (0x01, true)
    @test read(f, UInt8) == (0x02, true)
    @test read(f, UInt8) == (0x03, true)
    @test read(f, UInt8) == (0x04, true)
    @test read(f, UInt8) == (0x05, true)
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    @test read(f, UInt8) == (0x00, false)
    @test isempty(readavailable(f))

    # overflow
    write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06]) == 5
    @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    @test read(f, UInt8) == (0x00, false)
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
                @test all(readavailable(f) .== UInt8[0x4a, 0x61, 0x63, 0x6f, 0x62])
            end
        end
    end

    # buffer growing
    f = HTTP.FIFOBuffer(10)
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    @test write(f, UInt8[0x06, 0x07, 0x08, 0x09, 0x0a]) == 5
    @test all(readavailable(f) .== 0x01:0x0a)
end; # testset
