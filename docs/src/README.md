# Overview

Read content of [SquashFS](https://en.wikipedia.org/wiki/SquashFS) filesystem images. Supports navigating the directory structure and reading files in images compressed using `gzip` (uses `CodecZlib`) or `zstd` (uses `CodecZstd`). Extended attributes and other features are not implemented and not planned for foreseeable future.

Attains good performance and may easily beat reading from the regular file system. On a laptop with SSD and a SquashFS image containing 10'000 small files: 12-50k IOPS depending on the reading pattern; 250 Mb/s for reading large files. Both IOPS and bandwidth are limited by the decompression speed. Caching may help in certain scenarios of reading small files, but this is neither implemented nor planned. See the `benchmark` directory for details.

# Example

Generate files that go into a SquashFS image, and create the sample image:

```jldoctest label
julia> orig_dir = pwd();

julia> cd(mktempdir());

julia> mkpath("./dir/subdir");

julia> write("./dir/filea.txt", "aaa");

julia> write("./dir/subdir/fileb.dat", "abc");

julia> import squashfs_tools_jll.mksquashfs_path as mksquashfs

julia> run(pipeline(`$mksquashfs dir image.sqsh`, stdout=devnull));
```

Access the generated image with functions from this package: open, list files, read textual content:

```jldoctest label
julia> import SquashFS

julia> img = SquashFS.open("image.sqsh");

julia> SquashFS.readdir(img, "/")
2-element Vector{String}:
 "subdir"
 "filea.txt"

julia> SquashFS.files_recursive(img, "/")
2-element Vector{String}:
 "filea.txt"
 "subdir/fileb.dat"

julia> SquashFS.rglob(img, r"....b")
1-element Vector{String}:
 "subdir/fileb.dat"

julia> SquashFS.readfile(img, "/filea.txt", String)
"aaa"

julia> cd(orig_dir)

```

# Reference

```@autodocs
Modules = [SquashFS]
Order   = [:function, :type]
```
