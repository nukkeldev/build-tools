# `<nukkeldev/build-tools>`

Tools for managing multi-language builds with Zig's build system.

## Tools

Tooling is invoked from a meta-command `bt` for convinience.

### `source-graph` / `sg`

Given a C/C++ source file and include directories, it attempts to resolve all additional include paths and C/C++ source files.

#### Usage

```
bt sg example.cpp -I include/ -o example.cpp.zon
```
- `bt sg` invokes the `source-graph` tool using it's alias `sg`.
- `sg` requires one unnamed argument that refers to the source file to construct the source graph off of.
- `-I include/` tells `sg` to use `include/` to discover header files if necessary. 
    - `-I` may be repeated multiple times.
- `-o example.cpp.zon` outputs the resultant source graph as a comptime struct stored in a `.zon` file that may be imported by the user's `build.zig`.

#### Tips

- Add your `.zon` indexes to a VCS.
- While globbing may work for some projects, particularly complex ones that define
  multiple targets (executables or libraries) that require varying amounts of the
  source files (especially with platform-specific sources) are tedious to work with
  (I'd imagine).