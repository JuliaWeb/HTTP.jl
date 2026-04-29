#=
A simple example of creating a server with HTTP.jl. It handles creating, deleting, 
updating, and retrieving Animals from a dictionary through 4 different routes
=#
using HTTP, JSON, UUIDs
using StructUtils: @noarg

# modified Animal struct to associate with specific user
@noarg mutable struct Animal
    id::Int
    userId::UUID
    type::String
    name::String
end

# use a plain `Dict` as a "data store"
const ANIMALS = Dict{Int, Animal}()
const NEXT_ID = Ref(0)
function getNextId()
    id = NEXT_ID[]
    NEXT_ID[] += 1
    return id
end

animal_from_json(body) = JSON.parse(String(body), Animal)

# "service" functions to actually do the work
function createAnimal(req::HTTP.Request)
    animal = animal_from_json(req.body)
    animal.id = getNextId()
    ANIMALS[animal.id] = animal
    return HTTP.Response(200, JSON.json(animal))
end

function getAnimal(req::HTTP.Request)
    animalId = HTTP.getparams(req)["id"]
    animal = ANIMALS[parse(Int, animalId)]
    return HTTP.Response(200, JSON.json(animal))
end

function updateAnimal(req::HTTP.Request)
    animal = animal_from_json(req.body)
    ANIMALS[animal.id] = animal
    return HTTP.Response(200, JSON.json(animal))
end

function deleteAnimal(req::HTTP.Request)
    animalId = parse(Int, HTTP.getparams(req)["id"])
    delete!(ANIMALS, animalId)
    return HTTP.Response(200)
end

# define REST endpoints to dispatch to "service" functions
const ANIMAL_ROUTER = HTTP.Router()
HTTP.register!(ANIMAL_ROUTER, "POST", "/api/zoo/v1/animals", createAnimal)
# note the use of `*` to capture the path segment "variable" animal id
HTTP.register!(ANIMAL_ROUTER, "GET", "/api/zoo/v1/animals/{id}", getAnimal)
HTTP.register!(ANIMAL_ROUTER, "PUT", "/api/zoo/v1/animals", updateAnimal)
HTTP.register!(ANIMAL_ROUTER, "DELETE", "/api/zoo/v1/animals/{id}", deleteAnimal)

server = HTTP.serve!(ANIMAL_ROUTER, "127.0.0.1", 8080)

# using our server
x = Animal()
x.id = 0
x.userId = uuid4()
x.type = "cat"
x.name = "pete"
# create 1st animal
resp = HTTP.post("http://localhost:8080/api/zoo/v1/animals", [], JSON.json(x))
x2 = animal_from_json(resp.body)
# retrieve it back
resp = HTTP.get("http://localhost:8080/api/zoo/v1/animals/$(x2.id)")
x3 = animal_from_json(resp.body)

# close the server which will stop the HTTP server from listening
HTTP.forceclose(server)
wait(server)
