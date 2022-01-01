
<a id='Overview'></a>

<a id='Overview-1'></a>

# Overview


Read content of [SquashFS](https://en.wikipedia.org/wiki/SquashFS) filesystem images. Supports navigating the directory structure and reading files in images compressed using `gzip` (uses `CodecZlib`) or `zstd` (uses `CodecZstd`). Extended attributes and other features are not implemented and not planned for foreseeable future.


Attains good performance and may easily beat reading from the regular file system. On a laptop with SSD and a SquashFS image containing 10'000 small files: 12-50k IOPS depending on the reading pattern; 250 Mb/s for reading large files. Both IOPS and bandwidth are limited by the decompression speed. Caching may help in certain scenarios of reading small files, but this is neither implemented nor planned. See the `benchmark` directory for details.


<a id='Example'></a>

<a id='Example-1'></a>

# Example


Generate files that go into a SquashFS image, and create the sample image:


```julia-repl
julia> orig_dir = pwd();

julia> tmp = mktempdir();

julia> cd(tmp);

julia> mkpath("./dir/subdir");

julia> write("./dir/filea.txt", "aaa");

julia> write("./dir/subdir/fileb.dat", "abc");

julia> write("./dir/subdir/filec.dat", "def");

julia> import squashfs_tools_jll: mksquashfs

julia> run(pipeline(`$mksquashfs dir image.sqsh`, stdout=devnull));

julia> cd(orig_dir);
```


Open the SquashFS image and access it with common `Base` filesystem functions:


```julia-repl
julia> import SquashFS

julia> img = SquashFS.open(joinpath(tmp, "image.sqsh"));

julia> root = SquashFS.rootdir(img);

julia> readdir(root)
2-element Vector{String}:
 "filea.txt"
 "subdir"

julia> isdir(root)
true

julia> isdir(joinpath(root, "subdir"))
true

julia> [basename(f) for f in readdir(root; join=true) if isfile(f)]
1-element Vector{String}:
 "filea.txt"

julia> read(joinpath(root, "filea.txt"), String)
"aaa"

julia> readdir(joinpath(root, "subdir"))
2-element Vector{String}:
 "fileb.dat"
 "filec.dat"

julia> read.(readdir(joinpath(root, "subdir"); join=true), String)
2-element Vector{String}:
 "abc"
 "def"
```


Several specialized functions are provided as well, see reference docs below.


<a id='Reference'></a>

<a id='Reference-1'></a>

# Reference

<a id='SquashFS.files_recursive-Tuple{SquashFS.Image, AbstractString}' href='#SquashFS.files_recursive-Tuple{SquashFS.Image, AbstractString}'>#</a>
**`SquashFS.files_recursive`** &mdash; *Method*.



```julia
files_recursive(img::SquashFS.Image, path::AbstractString) -> Vector{String}

```

Return the paths of all files contained in the directory `path` within SquashFS image `img`, recursively. Returned paths are relative to the specified `path`.


<a target='_blank' href='https://github.com/aplavin/SquashFS.jl/blob/5497e837b4016b9985b152beade56976a86e34a7/src/api.jl#L70' class='documenter-source'>source</a><br>

<a id='SquashFS.open-Tuple{AbstractString}' href='#SquashFS.open-Tuple{AbstractString}'>#</a>
**`SquashFS.open`** &mdash; *Method*.



```julia
open(fname::AbstractString; threaded) -> SquashFS.Image

```

Open SquashFS image file. Immediately reads list of all inodes, directory structure, and fragments table. These are always kept in memory for implementation simplicity and performance.

`threaded` must be set to `true` to use the same image from multiple threads.


<a target='_blank' href='https://github.com/aplavin/SquashFS.jl/blob/5497e837b4016b9985b152beade56976a86e34a7/src/api.jl#L40' class='documenter-source'>source</a><br>

<a id='SquashFS.openfile-Tuple{SquashFS.Image, Any}' href='#SquashFS.openfile-Tuple{SquashFS.Image, Any}'>#</a>
**`SquashFS.openfile`** &mdash; *Method*.



```julia
openfile(img::SquashFS.Image, spec) -> IOBuffer

```

Open the file at `path` in the SquashFS image `img` and return as an `IO` object. For now just reads the whole content of the file and wraps it into an `IOBuffer`. May become more efficient in the future.


<a target='_blank' href='https://github.com/aplavin/SquashFS.jl/blob/5497e837b4016b9985b152beade56976a86e34a7/src/api.jl#L104' class='documenter-source'>source</a><br>

<a id='SquashFS.readdir-Tuple{SquashFS.Image, AbstractString}' href='#SquashFS.readdir-Tuple{SquashFS.Image, AbstractString}'>#</a>
**`SquashFS.readdir`** &mdash; *Method*.



```julia
readdir(img::SquashFS.Image, path::AbstractString; join) -> Vector{String}

```

Return the names in the directory `path` within SquashFS image `img`. When `join` is `false`, returns just the names in the directory as is; when `join` is `true`, returns `joinpath(path, name)` for each `name` so that the returned strings are full paths


<a target='_blank' href='https://github.com/aplavin/SquashFS.jl/blob/5497e837b4016b9985b152beade56976a86e34a7/src/api.jl#L59' class='documenter-source'>source</a><br>

<a id='SquashFS.readfile-Tuple{SquashFS.Image, AbstractString}' href='#SquashFS.readfile-Tuple{SquashFS.Image, AbstractString}'>#</a>
**`SquashFS.readfile`** &mdash; *Method*.



```julia
readfile(img::SquashFS.Image, path::AbstractString) -> Vector{UInt8}

```

Read content of the file at `path` in the SquashFS image `img`. Return a bytearray.


<a target='_blank' href='https://github.com/aplavin/SquashFS.jl/blob/5497e837b4016b9985b152beade56976a86e34a7/src/api.jl#L95' class='documenter-source'>source</a><br>

<a id='SquashFS.readfile-Tuple{SquashFS.Image, Any, Type{String}}' href='#SquashFS.readfile-Tuple{SquashFS.Image, Any, Type{String}}'>#</a>
**`SquashFS.readfile`** &mdash; *Method*.



```julia
readfile(img::SquashFS.Image, spec, _::Type{String}) -> String

```

Read content of the file `spec` in the SquashFS image `img`. Returns a `String`. `spec` can be a path or another supported value such as an inode number.


<a target='_blank' href='https://github.com/aplavin/SquashFS.jl/blob/5497e837b4016b9985b152beade56976a86e34a7/src/api.jl#L100' class='documenter-source'>source</a><br>

<a id='SquashFS.rglob' href='#SquashFS.rglob'>#</a>
**`SquashFS.rglob`** &mdash; *Function*.



```julia
rglob(img::SquashFS.Image, pattern) -> Vector{String}
rglob(img::SquashFS.Image, pattern, path::AbstractString) -> Vector{String}

```

Returns the paths of all files matching `pattern` in directory `path` within SquashFS image `img`, recursively. `pattern` can be any object that supports `occursin(pattern, name::String)`: e.g. `String`, `Regex`, or patterns from the `Glob.jl` package.


<a target='_blank' href='https://github.com/aplavin/SquashFS.jl/blob/5497e837b4016b9985b152beade56976a86e34a7/src/api.jl#L74' class='documenter-source'>source</a><br>

