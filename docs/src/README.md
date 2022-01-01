# Overview

Read content of [SquashFS](https://en.wikipedia.org/wiki/SquashFS) filesystem images. Supports navigating the directory structure and reading files in images compressed using `gzip` (uses `CodecZlib`) or `zstd` (uses `CodecZstd`). Extended attributes and other features are not implemented and not planned for foreseeable future.

Attains good performance and may easily beat reading from the regular file system. On a laptop with SSD and a SquashFS image containing 10'000 small files: 12-50k IOPS depending on the reading pattern; 250 Mb/s for reading large files. Both IOPS and bandwidth are limited by the decompression speed. Caching may help in certain scenarios of reading small files, but this is neither implemented nor planned. See the `benchmark` directory for details.

# Example

Generate files that go into a SquashFS image, and create the sample image:

```jldoctest label
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

```jldoctest label
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

# Reference

```@autodocs
Modules = [SquashFS]
Order   = [:function, :type]
```
