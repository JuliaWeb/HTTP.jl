"""
Server example that takes after the simple server, however
handles dealing with CORS preflight headers when dealing with more
than just a simple request
"""

using HTTP

# modified Animal struct to associate with specific user
mutable struct Animal
    id::Int
    userId::Base.UUID
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

#CORS headers that show what kinds of complex requests are allowed to API
headers = [
    "Access-Control-Allow-Origin" => "*",
    "Access-Control-Allow-Headers" => "*",
    "Access-Control-Allow-Methods" => "POST;GET;OPTIONS"
]

#= 
JSONHandler minimizes code by automatically converting the request body
to JSON to pass to the other service functions automatically. JSONHandler
recieves the body the response from the other service funtions 
=#
function JSONHandler(req::HTTP.Request)
    # first check if there's any request body
    body = IOBuffer(HTTP.payload(req))
    if eof(body)
        # no request body
        response_body = handle(ANIMAL_ROUTER, req)
    else
        # there's a body, so pass it on to the handler we dispatch to
        response_body = handle(ANIMAL_ROUTER, req, JSON2.read(body, Animal))
    end
    return HTTP.Response(200, JSON2.write(response_body))
end

#= CorsHandler: handles preflight request with the OPTIONS flag
If a request was recieved with the correct headers, then a Response will be 
sent back with a 200 code, if the correct headers were not specified in the request,
then a CORS error will be recieved on the client side

Since each request passes throught the CORS Handler, then if the request is 
not a preflight request, it will simply go to the JSONHandler to be passed to the
correct service function =#
function CorsHandler(req)
    if HTTP.hasheader(req, "OPTIONS")
        return HTTP.Response(200, headers = headers)
    else 
        return JSONHandler(req)
    end


# **simplified** "service" functions
function createAnimal(req::HTTP.Request, animal)
    animal.id = getNextId()
    ANIMALS[animal.id] = animal
    return animal
end

function getAnimal(req::HTTP.Request)
    animalId = HTTP.URIs.splitpath(req.target)[5] # /api/zoo/v1/animals/10, get 10
    return ANIMALS[animalId]
end

function updateAnimal(req::HTTP.Request, animal)
    ANIMALS[animal.id] = animal
    return animal
end

function deleteAnimal(req::HTTP.Request)
    animalId = HTTP.URIs.splitpath(req.target)[5] # /api/zoo/v1/animals/10, get 10
    delete!(ANIMALS, animal.id)
    return ""
end

# add an additional endpoint for user creation
HTTP.@register(ANIMAL_ROUTER, "POST", "/api/zoo/v1/users", createUser)
# modify service endpoints to have user pass UUID in
HTTP.@register(ANIMAL_ROUTER, "GET", "/api/zoo/v1/users/*/animals/*", getAnimal)
HTTP.@register(ANIMAL_ROUTER, "DELETE", "/api/zoo/v1/users/*/animals/*", deleteAnimal)


HTTP.serve(CorsHandler, ip"127.0.0.1", 8080)