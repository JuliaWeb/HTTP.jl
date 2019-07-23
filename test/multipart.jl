
@testset "Multipart" begin
	@testset "show" begin
		# testing that there is no error in printing when nothing is set for filename
		try
			show(HTTP.Multipart(nothing, IOBuffer("some data"), "plain/text", "", "testname"))
			println("")
			@test true
		catch exception
			@error "" typeof(exception) exception
			@test false
		end
	end
end
