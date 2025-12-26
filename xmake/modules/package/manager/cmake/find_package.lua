--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, Xmake Open Source Community.
--
-- @author      ruki
-- @file        find_package.lua
--

-- imports
import("core.base.option")
import("core.project.target")
import("lib.detect.find_tool")

-- exclude cmake internal definitions https://github.com/xmake-io/xmake/issues/5217
function _should_exclude(define)
    local name = define:split("=")[1]
    return table.contains({"CMAKE_INTDIR", "_DEBUG", "NDEBUG"}, name)
end

-- map xmake mode to cmake mode
function _cmake_mode(mode)
    if mode == "debug" then return "Debug"
    elseif mode == "releasedbg" then return "RelWithDebInfo"
    elseif mode == "minsizerel" then return "MinSizeRel"
    else return "Release"
    end
end

function _run_cmake(name, opt)
    os.tryrm(opt.work_dir)
    os.mkdir(opt.work_dir)
    io.writefile(path.join(opt.work_dir, "test.cpp"), "")

    -- generate CMakeLists.txt
    local filepath = path.join(opt.work_dir, "CMakeLists.txt")
    local cmakefile = io.open(filepath, "w")
    if opt.cmake_tool.version then
        cmakefile:print("cmake_minimum_required(VERSION %s)", opt.cmake_tool.version)
    end

    -- Set CMake variables that affect third-party find scripts (e.g.Boost_USE_STATIC_LIB) or the
    -- behavior of CMake itsel (e.g. CMAKE_EXPERIMENTAL_CXX_IMPORT_STD). Some presets only take
    -- effect if they are set before the call to project(), that's why we place the presets before it.
    for k, v in pairs(opt.presets) do
        if type(v) == "boolean" then
            cmakefile:print("set(%s %s)", k, v and "ON" or "OFF")
        else
            cmakefile:print("set(%s %s)", k, tostring(v))
        end
    end

    cmakefile:print("project(find_package)")

    -- e.g. OpenCV 4.1.1, Boost COMPONENTS regex system
    local requirestr = opt.pkg_name
    if opt.require_version and opt.require_version ~= "latest" then
        requirestr = requirestr .. " " .. opt.require_version
    end
    -- set search mode, e.g. config, module
    -- it will be both mode if do not set this config.
    -- e.g. https://cmake.org/cmake/help/latest/command/find_package.html#id4
    if opt.search_mode then
        requirestr = requirestr .. " " .. opt.search_mode:upper()
    end
    local componentstr = ""
    if #opt.components > 0 then
        componentstr = "COMPONENTS"
        for _, component in ipairs(opt.components) do
            componentstr = componentstr .. " " .. component
        end
    end
    for _, moduledir in ipairs(opt.moduledirs) do
        cmakefile:print("list(APPEND CMAKE_MODULE_PATH \"%s\")", (moduledir:gsub("\\", "/")))
    end
    -- https://github.com/xmake-io/xmake/issues/6296
    for _, prefixdir in ipairs(opt.prefixdirs) do
        cmakefile:print("list(APPEND CMAKE_PREFIX_PATH \"%s\")", (prefixdir:gsub("\\", "/")))
    end

    cmakefile:print("find_package(%s REQUIRED %s)", requirestr, componentstr)
    cmakefile:print("add_executable(%s test.cpp)", opt.exe_name)
    -- setup include directories
    local includedirs = ""
    if #opt.include_directories > 0 then
        includedirs = table.concat(table.wrap(opt.include_directories), " ")
    else
        includedirs = ("${%s_INCLUDE_DIR} ${%s_INCLUDE_DIRS}"):format(opt.pkg_name, opt.pkg_name)
        includedirs = includedirs .. (" ${%s_INCLUDE_DIR} ${%s_INCLUDE_DIRS}"):format(opt.pkg_name:upper(), opt.pkg_name:upper())
    end
    cmakefile:print("target_include_directories(%s PRIVATE %s)", opt.exe_name, includedirs)
    -- reserved for backword compatibility
    cmakefile:print("target_include_directories(%s PRIVATE ${%s_CXX_INCLUDE_DIRS})",
        opt.exe_name, opt.pkg_name)
    -- setup link library/target
    local linklibs = ""
    if #opt.link_libraries > 0 then
        linklibs = table.concat(table.wrap(opt.link_libraries), " ")
    else
        linklibs = ("${%s_LIBRARY} ${%s_LIBRARIES} ${%s_LIBS}"):format(opt.pkg_name, opt.pkg_name, opt.pkg_name)
        linklibs = linklibs .. (" ${%s_LIBRARY} ${%s_LIBRARIES} ${%s_LIBS}"):format(opt.pkg_name:upper(), opt.pkg_name:upper(), opt.pkg_name:upper())
    end
    cmakefile:print("target_link_libraries(%s PRIVATE %s)", opt.exe_name, linklibs)
    cmakefile:close()
    if option.get("diagnosis") then
        local cmakedata = io.readfile(filepath)
        cprint("finding it from the generated CMakeLists.txt:")
        io.write(cmakedata .. "\n")
    end

    local argv = {"-S", opt.work_dir}
    if opt.generator then
        table.insert(argv, "-G")
        table.insert(argv, opt.generator)
    end
    -- Run CMake.
    -- If the generated CMakeLists.txt fails to find the REQUIRED package, CMake will exit
    -- with code 1, os.vrunv will raise an error and the try{} block will return nil.
    -- We rely on opt.envs.CMAKE_BUILD_TYPE being set in main()
    local ok = try {function()
        os.vrunv(opt.cmake_tool.program, argv, {curdir = opt.work_dir, envs = opt.envs})
        return true
    end}
    return ok or false
end

function _parse_makefiles_flags_make(opt)
    local flagsfile = path.join(opt.work_dir, "CMakeFiles", opt.exe_name .. ".dir", "flags.make")
    if not os.isfile(flagsfile) then
        return nil
    end
    local flagsdata = io.readfile(flagsfile)
    if not flagsdata then
        return nil
    end
    if option.get("diagnosis") then
        cprint("finding includes from %s", flagsfile)
        io.write(flagsdata .. "\n")
    end
    local defines = {}
    local includedirs = {}
    for _, line in ipairs(flagsdata:split("\n", {plain = true})) do
        if line:find("CXX_INCLUDES =", 1, true) then
            local has_include = false
            local flags = os.argv(line:split("=", {plain = true})[2]:trim())
            for _, flag in ipairs(flags) do
                if has_include or (flag:startswith("-I") and #flag > 2) then
                    local includedir = has_include and flag or flag:sub(3)
                    if includedir and os.isdir(includedir) then
                        table.insert(includedirs, includedir)
                    end
                    has_include = false
                elseif flag == "-isystem" or flag == "-I" then
                    has_include = true
                end
            end
        elseif line:find("CXX_DEFINES =", 1, true) then
            local flags = os.argv(line:split("=", {plain = true})[2]:trim())
            for _, flag in ipairs(flags) do
                if flag:startswith("-D") and #flag > 2 then
                    local define = flag:sub(3)
                    if define and not _should_exclude(define) then
                        table.insert(defines, define)
                    end
                end
            end
        end
    end
    return {
        defines = defines,
        includedirs = includedirs
    }
end

function _parse_makefiles_links(opt)
    local linkfile = path.join(opt.work_dir, "CMakeFiles", opt.exe_name .. ".dir", "link.txt")
    if not os.isfile(linkfile) then
        return nil
    end
    local linkdata = io.readfile(linkfile)
    if not linkdata then
        return nil
    end
    if option.get("diagnosis") then
        cprint("finding links from %s", linkfile)
        io.write(linkdata .. "\n")
    end
    local links = {}
    local linkdirs = {}
    local libfiles = {}
    local ldflags = {}
    for _, line in ipairs(os.argv(linkdata)) do
        local is_ldflags = false
        local is_library = false
        for _, suffix in ipairs({".so", ".dylib", ".tbd", ".lib"}) do
            if line:startswith("-Wl,") then
                is_ldflags = true
                break
            elseif line:find(suffix, 1, true) then
                is_library = true
                break
            end
        end
        if is_ldflags then
            table.insert(ldflags, line)
        elseif is_library then
            -- strip library version suffix, e.g. libxxx.so.1.1 -> libxxx.so
            if line:find(".so", 1, true) then
                line = line:gsub("lib(.-)%.so%..+$", "lib%1.so")
            end

            -- get libfiles
            if os.isfile(line) then
                table.insert(libfiles, line)
            end

            -- get links and linkdirs
            local linkdir = path.directory(line)
            if linkdir ~= "." then
                table.insert(linkdirs, linkdir)
            end
            local link = target.linkname(path.filename(line))
            if link then
                table.insert(links, link)
            end
        -- is link? e.g. -lxxx
        elseif line:startswith("-l") then
            local link = line:sub(3):trim()
            table.insert(links, link)
        end
    end
    return {
        links = links,
        linkdirs = linkdirs,
        libfiles = libfiles,
        ldflags = ldflags
    }
end

function _parse_makefiles(opt)
    local parsed_flags_make = _parse_makefiles_flags_make(opt)
    if not parsed_flags_make then
        return nil
    end
    local parsed_links = _parse_makefiles_links(opt)
    if not parsed_links then
        return nil
    end
    return table.join(parsed_flags_make, parsed_links)
end

function _parse_visual_studio(opt)
    local vcprojfile = path.join(opt.work_dir, opt.exe_name .. ".vcxproj")
    if not os.isfile(vcprojfile) then
        return nil
    end
    local vcprojdata = io.readfile(vcprojfile)
    vcprojdata = vcprojdata:match("<ItemDefinitionGroup Condition=\"'$%(Configuration%)|$%(Platform%)'=='" .. opt.envs.CMAKE_BUILD_TYPE .. "|.->(.-)</ItemDefinitionGroup>")
    if not vcprojdata then
        return nil
    end

    local links = {}
    local linkdirs = {}
    local defines = {}
    local libfiles = {}
    local includedirs = {}
    for _, line in ipairs(vcprojdata:split("\n", {plain = true})) do
        local values = line:match("<AdditionalIncludeDirectories>(.+);%%%(AdditionalIncludeDirectories%)</AdditionalIncludeDirectories>")
        if values then
            table.join2(includedirs, path.splitenv(values))
        end

        values = line:match("<AdditionalDependencies>(.+)</AdditionalDependencies>")
        if values then
            for _, library in ipairs(path.splitenv(values)) do
                -- get libfiles
                if os.isfile(library) then
                    table.insert(libfiles, library)
                end

                -- get links and linkdirs
                local linkdir = path.directory(library)
                linkdir = path.translate(linkdir)
                if linkdir ~= "." and not linkdir:startswith(opt.work_dir) then
                    table.insert(linkdirs, linkdir)
                    local link = target.linkname(path.filename(library))
                    if link then
                        table.insert(links, link)
                    end
                end
            end
        end

        values = line:match("<PreprocessorDefinitions>%%%(PreprocessorDefinitions%);(.+)</PreprocessorDefinitions>")
        if values then
            values = path.splitenv(values)
            for _, value in ipairs(values) do
                if not _should_exclude(value) then
                    table.insert(defines, value)
                end
            end
        end
    end
    return {
        links = links,
        linkdirs = linkdirs,
        defines = defines,
        libfiles = libfiles,
        includedirs = includedirs
    }
end

-- find package using the cmake package manager
--
-- e.g.
--
-- find_package("cmake::ZLIB")
-- find_package("cmake::OpenCV", {require_version = "4.1.1"})
-- find_package("cmake::Boost", {configs = {components = {"regex", "system"}, presets = {Boost_USE_STATIC_LIB = true}}})
-- find_package("cmake::Foo", {configs = {moduledirs = "xxx"}})
--
-- we can use add_requires with {system = true}
--
-- add_requires("cmake::ZLIB", {system = true})
-- add_requires("cmake::OpenCV 4.1.1", {system = true})
-- add_requires("cmake::Boost", {configs = {components = {"regex", "system"}, presets = {Boost_USE_STATIC_LIB = true}}})
-- add_requires("cmake::Foo", {configs = {moduledirs = "xxx"}})
--
-- @param name  the package name
-- @param opt   the options, e.g. {verbose = true, require_version = "1.0",
--                                 configs = {
--                                      components = {"regex", "system"},
--                                      moduledirs = "xxx",
--                                      presets = {Boost_USE_STATIC_LIB = true},
--                                      envs = {CMAKE_PREFIX_PATH = "xxx"}})
--
function main(name, opt)
    local configs = opt.configs or {}
    local envs = configs.envs or opt.envs or {}
    envs.CMAKE_BUILD_TYPE = envs.CMAKE_BUILD_TYPE or _cmake_mode(opt.mode)
    local opt = {
        allow_empty_package = configs.allow_empty_package,
        cmake_tool = find_tool("cmake", {version = true}),
        components = configs.components or opt.components or {},
        envs = envs,
        exe_name = "test_" .. name,
        generator = configs.generator,
        include_directories = configs.include_directories or {},
        link_libraries = configs.link_libraries or {},
        moduledirs = configs.moduledirs or opt.moduledirs or {},
        pkg_name = name,
        prefixdirs = configs.prefixdirs or opt.prefixdirs or {},
        presets = configs.presets or opt.presets or {},
        require_version = opt.require_version,
        search_mode = configs.search_mode,
        work_dir = os.tmpfile() .. ".dir"
    }
    if not opt.cmake_tool then
        return
    end
    local parsed =
        _run_cmake(opt) and
        (
            _parse_makefiles(opt) or
            _parse_visual_studio(opt)
        )
    os.tryrm(opt.work_dir)
    if not parsed then
        return nil
    end
    if
        not opt.allow_empty_package and
        not parsed.links and
        not parsed.includedirs
    then
        return nil
    end
    return {
        links = table.reverse_unique(parsed.links),
        ldflags = table.reverse_unique(parsed.ldflags),
        linkdirs = table.unique(parsed.linkdirs),
        defines = table.unique(parsed.defines),
        libfiles = table.unique(parsed.libfiles),
        includedirs = table.unique(parsed.includedirs)
    }
end
