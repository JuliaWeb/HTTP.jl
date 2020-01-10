
@testset "Multipart" begin
	@testset "show" begin
		# testing that there is no error in printing when nothing is set for filename
		str = sprint(show, (HTTP.Multipart(nothing, IOBuffer("some data"), "plain/text", "", "testname")))
		@test findfirst("contenttype=\"plain/text\"", str) != nothing
	end


	@testset "constructor" begin
		@testset "don't allow String for data" begin
			@test_throws MethodError HTTP.Multipart(nothing, "some data", "plain/text", "", "testname")
		end
	end
end
