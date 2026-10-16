#=
Server example that takes after the simple server, however,
handles dealing with CORS preflight headers when dealing with more
than just a simple request. For CORS details, see e.g. https://cors-errors.info/
=#

using HTTP, JSON, UUIDs
using StructUtils: @noarg

# Each animal belongs to the user identified by `userId`
@noarg mutable struct Animal
    id::Int
    userId::UUID
    type::String
    name::String
end

# use a plain `Dict` as a "data store", outer Dict maps userId to user-specific Animals
const ANIMALS = Dict{UUID, Dict{Int, Animal}}()
const NEXT_ID = Ref(0)
function getNextId()
    id = NEXT_ID[]
    NEXT_ID[] += 1
    return id
end

animal_from_json(body) = JSON.parse(String(body), Animal)

# CORS preflight headers that show what kinds of complex requests are allowed to API
const CORS_OPT_HEADERS = [
    "Access-Control-Allow-Origin" => "*",
    "Access-Control-Allow-Headers" => "*",
    "Access-Control-Allow-Methods" => "POST, GET, OPTIONS"
]

# CORS header sent with every other response
const CORS_RES_HEADERS = ["Access-Control-Allow-Origin" => "*"]

# JSONMiddleware turns a service function's return value into a 200 JSON
# response, so the service functions do not build responses themselves.
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
            return HTTP.Response(200, CORS_RES_HEADERS, ret === nothing ? "" : JSON.json(ret))
        end
    end
end

# CorsMiddleware answers CORS preflight (OPTIONS) requests and passes every
# other request on to the wrapped handler.
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
    animal = animal_from_json(req.body)
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
    animal = animal_from_json(req.body)
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
userId = UUID(JSON.parse(String(resp.body)))
x = Animal()
x.id = 0
x.userId = userId
x.type = "cat"
x.name = "pete"
# create 1st animal
resp = HTTP.post("http://localhost:8080/api/zoo/v1/users/$(userId)/animals", [], JSON.json(x))
x2 = animal_from_json(resp.body)
# retrieve it back
resp = HTTP.get("http://localhost:8080/api/zoo/v1/users/$(userId)/animals/$(x2.id)")
x3 = animal_from_json(resp.body)
# try bad path
resp = HTTP.get("http://localhost:8080/api/zoo/v1/badpath"; status_exception=false)

# close the server which will stop the HTTP server from listening
HTTP.forceclose(server)
wait(server)
