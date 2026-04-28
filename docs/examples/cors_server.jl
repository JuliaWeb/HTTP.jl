#=
Server example that takes after the simple server, however,
handles dealing with CORS preflight headers when dealing with more
than just a simple request. For CORS details, see e.g. https://cors-errors.info/
=#

using HTTP, JSON3, StructTypes, UUIDs

# modified Animal struct to associate with specific user
mutable struct Animal
    id::Int
    userId::UUID
    type::String
    name::String
    Animal() = new()
end

StructTypes.StructType(::Type{Animal}) = StructTypes.Mutable()

# use a plain `Dict` as a "data store", outer Dict maps userId to user-specific Animals
const ANIMALS = Dict{UUID, Dict{Int, Animal}}()
const NEXT_ID = Ref(0)
function getNextId()
    id = NEXT_ID[]
    NEXT_ID[] += 1
    return id
end

function request_body(req::HTTP.Request)
    out = IOBuffer()
    buf = Vector{UInt8}(undef, 8192)
    while true
        n = HTTP.body_read!(req.body, buf)
        n == 0 && break
        write(out, @view buf[1:n])
    end
    return take!(out)
end

# CORS preflight headers that show what kinds of complex requests are allowed to API
const CORS_OPT_HEADERS = [
    "Access-Control-Allow-Origin" => "*",
    "Access-Control-Allow-Headers" => "*",
    "Access-Control-Allow-Methods" => "POST, GET, OPTIONS"
]

# CORS response headers that set access right of the recepient
const CORS_RES_HEADERS = ["Access-Control-Allow-Origin" => "*"]

#= 
JSONMiddleware minimizes code by automatically converting the request body
to JSON to pass to the other service functions automatically. JSONMiddleware
recieves the body of the response from the other service funtions and sends
back a success response code
=#
function JSONMiddleware(handler)
    # Middleware functions return *Handler* functions
    return function(req::HTTP.Request)
        # We slightly change the Handler interface here because we know our
        # handler methods will either return nothing or a JSON-serializable
        # value.
        ret = handler(req)
        # return a Response, if its a response already (from 404 and 405 handlers)
        if ret isa HTTP.Response
            return ret
        else # otherwise serialize any Animal as json string and wrap it in Response
            return HTTP.Response(200, CORS_RES_HEADERS, ret === nothing ? "" : JSON3.write(ret))
        end
    end
end

#= CorsMiddleware: handles preflight request with the OPTIONS flag
If a request was recieved with the correct headers, then a response will be 
sent back with a 200 code, if the correct headers were not specified in the request,
then a CORS error will be recieved on the client side

Since each request passes throught the CORS Handler, then if the request is 
not a preflight request, it will simply go to the JSONMiddleware to be passed to the
correct service function =#
function CorsMiddleware(handler)
    return function(req::HTTP.Request)
        if req.method == "OPTIONS"
            return HTTP.Response(200, CORS_OPT_HEADERS)
        else 
            return handler(req)
        end
    end
end

# **simplified** "service" functions
function createAnimal(req::HTTP.Request)
    animal = JSON3.read(request_body(req), Animal)
    animal.id = getNextId()
    ANIMALS[animal.userId][animal.id] = animal
    return animal
end

function getAnimal(req::HTTP.Request)
    # retrieve our matched path parameters from registered route
    animalId = parse(Int, HTTP.getparams(req)["id"])
    userId = UUID(HTTP.getparams(req)["userId"])
    return ANIMALS[userId][animalId]
end

function updateAnimal(req::HTTP.Request)
    animal = JSON3.read(request_body(req), Animal)
    ANIMALS[animal.userId][animal.id] = animal
    return animal
end

function deleteAnimal(req::HTTP.Request)
    # retrieve our matched path parameters from registered route
    animalId = parse(Int, HTTP.getparams(req)["id"])
    userId = UUID(HTTP.getparams(req)["userId"])
    delete!(ANIMALS[userId], animalId)
    return nothing
end

function createUser(req::HTTP.Request)
    userId = uuid4()
    ANIMALS[userId] = Dict{Int, Animal}()
    return userId
end

# CORS handlers for error responses
cors404(::HTTP.Request) = HTTP.Response(404, CORS_RES_HEADERS, "")
cors405(::HTTP.Request) = HTTP.Response(405, CORS_RES_HEADERS, "")

# add an additional endpoint for user creation
const ANIMAL_ROUTER = HTTP.Router(cors404, cors405)
HTTP.register!(ANIMAL_ROUTER, "POST", "/api/zoo/v1/users", createUser)
# modify service endpoints to have user pass UUID in
HTTP.register!(ANIMAL_ROUTER, "POST", "/api/zoo/v1/users/{userId}/animals", createAnimal)
HTTP.register!(ANIMAL_ROUTER, "GET", "/api/zoo/v1/users/{userId}/animals/{id}", getAnimal)
HTTP.register!(ANIMAL_ROUTER, "DELETE", "/api/zoo/v1/users/{userId}/animals/{id}", deleteAnimal)

server = HTTP.serve!(ANIMAL_ROUTER |> JSONMiddleware |> CorsMiddleware, "127.0.0.1", 8080)

# using our server
resp = HTTP.post("http://localhost:8080/api/zoo/v1/users")
userId = JSON3.read(resp.body, UUID)
x = Animal()
x.userId = userId
x.type = "cat"
x.name = "pete"
# create 1st animal
resp = HTTP.post("http://localhost:8080/api/zoo/v1/users/$(userId)/animals", [], JSON3.write(x))
x2 = JSON3.read(resp.body, Animal)
# retrieve it back
resp = HTTP.get("http://localhost:8080/api/zoo/v1/users/$(userId)/animals/$(x2.id)")
x3 = JSON3.read(resp.body, Animal)
# try bad path
resp = HTTP.get("http://localhost:8080/api/zoo/v1/badpath")

# close the server which will stop the HTTP server from listening
HTTP.forceclose(server)
wait(server)
