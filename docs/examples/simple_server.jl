"""
A simple example of creating a server with HTTP.jl. It handles creating, deleting, 
updating, and retrieving Animals from a dictionary through 4 different routes
"""
using HTTP, JSON3, StructTypes, Sockets

# modified Animal struct to associate with specific user
mutable struct Animal
    id::Int
    userId::Base.UUID
    type::String
    name::String
    Animal() = new()
end

StructTypes.StructType(::Type{Animal}) = StructTypes.Mutable()

# use a plain `Dict` as a "data store"
const ANIMALS = Dict{Int, Animal}()
const NEXT_ID = Ref(0)
function getNextId()
    id = NEXT_ID[]
    NEXT_ID[] += 1
    return id
end

# "service" functions to actually do the work
function createAnimal(req::HTTP.Request)
    animal = JSON3.read(req.body, Animal)
    animal.id = getNextId()
    ANIMALS[animal.id] = animal
    return HTTP.Response(200, JSON3.write(animal))
end

function getAnimal(req::HTTP.Request)
    animalId = HTTP.getparams(req)["id"]
    animal = ANIMALS[parse(Int, animalId)]
    return HTTP.Response(200, JSON3.write(animal))
end

function updateAnimal(req::HTTP.Request)
    animal = JSON3.read(req.body, Animal)
    ANIMALS[animal.id] = animal
    return HTTP.Response(200, JSON3.write(animal))
end

function deleteAnimal(req::HTTP.Request)
    animalId = HTTP.getparams(req)["id"]
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

server = HTTP.serve!(ANIMAL_ROUTER, Sockets.localhost, 8080)

# using our server
x = Animal()
x.type = "cat"
x.name = "pete"
# create 1st animal
resp = HTTP.post("http://localhost:8080/api/zoo/v1/animals", [], JSON3.write(x))
x2 = JSON3.read(resp.body, Animal)
# retrieve it back
resp = HTTP.get("http://localhost:8080/api/zoo/v1/animals/$(x2.id)")
x3 = JSON3.read(resp.body, Animal)

# close the server which will stop the HTTP server from listening
close(server)
@assert istaskdone(server.task)
