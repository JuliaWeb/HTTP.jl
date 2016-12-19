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
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    tsk = @async begin
        wait(f)
        @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    end
    sleep(0.01)
    @test istaskstarted(tsk)
    @test !istaskdone(tsk)
    # when data is read in the next readavailble, a notify is sent to f.cond
    @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    sleep(0.01)
    @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05])

    tsk2 = @async begin
        wait(f)
        @test all(readavailable(f) .== UInt8[0x01, 0x02, 0x03, 0x04, 0x05])
    end
    sleep(0.01)
    @test istaskstarted(tsk2)
    @test !istaskdone(tsk2)
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    sleep(0.01)
    @test isempty(readavailable(f))

    # buffer growing
    f = HTTP.FIFOBuffer(10)
    @test write(f, UInt8[0x01, 0x02, 0x03, 0x04, 0x05]) == 5
    @test write(f, UInt8[0x06, 0x07, 0x08, 0x09, 0x0a]) == 5
    @test all(readavailable(f) .== 0x01:0x0a)
end; # testset
