struct Path
    image::Image
    path::String
end

Base.basename(p::Path) = basename(p.path)
Base.dirname(p::Path) = Path(p.image, dirname(p.path))
Base.readdir(p::Path; join=false, sort=true) = if join
    paths = Path.(Ref(p.image), SquashFS.readdir(p.image, p.path; join=true))
    if sort
        sort!(paths, by=p -> p.path)
    end
else
    paths = SquashFS.readdir(p.image, p.path)
    if sort
        sort!(paths)
    end
    paths
end
Base.joinpath(p::Path, parts::AbstractString...) = Path(p.image, joinpath(p.path, parts...))
Base.isdir(p::Path) = try
    directory_by_path(p.image, p.path)
    return true
catch e
    e isa KeyError && return false
    rethrow()
end
Base.isfile(p::Path) = try
    file_inode_by_path(p.image, p.path)
    return true
catch e
    e isa KeyError && return false
    rethrow()
end
Base.read(p::Path, args...) = readfile(p.image, p.path, args...)

rootdir(img::Image) = Path(img, "/")
