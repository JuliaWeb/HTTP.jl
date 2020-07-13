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
            #open each file and read contents
            opened = open("examples/"*file)
            lines = readlines(opened, keep=true)
            index = 1
            #find doc string intro if exists
            if "\"\"\"\n" in lines
                index = findall(isequal("\"\"\"\n"), lines)[2]
                print(index)
                for i in 2:index-1
                    write(f, lines[i])
                end
                lines = lines[index+1:end]
            end
            
            write(f, "```julia")
            write(f, "\n")
            for line in lines
                write(f, line)
            end
            write(f, "\n")
            write(f, "```")
            close(opened)
        end
    end
    close(f)
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
