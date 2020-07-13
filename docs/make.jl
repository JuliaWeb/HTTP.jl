using Documenter, HTTP
#intro to document thrrough doc string
#create examples, generate mark down, create code and headers
#mark down

function generateExamples()
    f = open("src/examples.md", "w")
    write(f, "# Examples")
    write(f, "\nSome examples that may prove potentially useful for those using 
    `HTTP.jl`. The code for these examples can also be found on Github
     in the docs folder, in an inner folder called examples.")
     for (root, dirs, files) in walkdir("examples")
        for file in files
            #extract title from example
            write(f, "\n")
            title = file
            title = replace(title, "_"=>" ")
            title = replace(title, ".jl"=>"")
            title = titlecase(title)
            title = "## "*title*"\n"
            write(f, title)
            #find doc string intro if exists
            opened = open("examples/"*file)
            lines = readlines(opened, keep=true)
            write(f, "```julia")
            write(f, "\n")
            #lines = readlines(opened, keep=true)
            for line in lines
                write(f, line)
            end
            write(f, "\n")
            write(f, "```")
            close(opened)
        end
    end
    close(f)
    #add intro with doc string
    #add headers
    #run through examples and add to doc
end

generateExamples()

makedocs(
    modules = [HTTP],
    sitename = "HTTP.jl",
    pages = [
             "Home" => "index.md",
             "public_interface.md",
             "internal_architecture.md",
             "internal_interface.md",
             "examples.md"
             ],
)

deploydocs(
    repo = "github.com/JuliaWeb/HTTP.jl.git",
)
