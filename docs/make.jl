cd(@__DIR__)
import Pkg
Pkg.activate(".")
Pkg.develop(path="../")
Pkg.instantiate()
push!(LOAD_PATH, "../src/")
using Documenter, DocumenterMarkdown, SquashFS

makedocs(format=Markdown(), modules=[SquashFS], workdir="..")
mv("./build/README.md", "../README.md", force=true)
