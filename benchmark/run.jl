import Pkg
Pkg.activate(@__DIR__)
Pkg.develop(Pkg.PackageSpec(path=dirname(@__DIR__)))
Pkg.instantiate()


using BenchmarkTools
import SquashFS
import squashfs_tools_jll: mksquashfs_path; const mksquashfs = mksquashfs_path


let 
    cd(mktempdir())
    mkdir("./xdir")
    content1 = rand(Float64, 100*1000) |> string
    write("./xdir/longfile1", content1)
    content2 = rand(Float64, 1000*1000) |> string
    write("./xdir/longfile2", content2)
    n_files = 10_000
    for i in 1:n_files
        write("./xdir/smallfile$i", join([string(i) for j in 1:10], "\n"))
    end
    @time run(pipeline(`$mksquashfs xdir xdir.sqsh`, stdout=devnull))

    img = SquashFS.open("xdir.sqsh")
    b = @benchmark SquashFS.open("xdir.sqsh")
    @info "Open squashfs file" size_Mb=stat("xdir.sqsh").size/1e6 b

    b = @benchmark SquashFS.readfile($img, "/smallfile1")
    @info "Read same small file" IOPS=1/(time(b)/1e9) b
    b = @benchmark SquashFS.readfile($img, "/smallfile$(rand(1:$n_files))")
    @info "Read different small files" IOPS=1/(time(median(b))/1e9) b

    for f in ["/smallfile1", "/longfile1", "/longfile2"]
        fsize = length(SquashFS.readfile(img, f))
        b = @benchmark SquashFS.readfile($img, $f)
        @info "Read file" size_Mb=fsize/1e6 speed_Mb_s=(fsize/1e6)/(time(b)/1e9) b
    end
end
