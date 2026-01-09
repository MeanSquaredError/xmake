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
-- @author      ruki, MeanSquaredError
-- @file        run_cmake.lua
--

-- imports
import("core.base.option")
import("lib.detect.find_tool")

function main(opt)
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
        includedirs = ("${%s_INCLUDE_DIR} ${%s_INCLUDE_DIRS} ${%s_INCLUDE_DIR} ${%s_INCLUDE_DIRS}"):format(
            opt.pkg_name,
            opt.pkg_name,
            opt.pkg_name:upper(),
            opt.pkg_name:upper()
        )
    end
    cmakefile:print("target_include_directories(%s PRIVATE %s)", opt.exe_name, includedirs)
    -- reserved for backword compatibility
    cmakefile:print("target_include_directories(%s PRIVATE ${%s_CXX_INCLUDE_DIRS})", opt.exe_name, opt.pkg_name)
    -- setup link library/target
    local linklibs = ""
    if #opt.link_libraries > 0 then
        linklibs = table.concat(table.wrap(opt.link_libraries), " ")
    else
        linklibs = ("${%s_LIBRARY} ${%s_LIBRARIES} ${%s_LIBS} ${%s_LIBRARY} ${%s_LIBRARIES} ${%s_LIBS}"):format(
            opt.pkg_name,
            opt.pkg_name,
            opt.pkg_name,
            opt.pkg_name:upper(),
            opt.pkg_name:upper(),
            opt.pkg_name:upper()
        )
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
    -- We rely on opt.envs.CMAKE_BUILD_TYPE being set in find_package.main()
    local ok = try {function()
        os.vrunv(opt.cmake_tool.program, argv, {curdir = opt.work_dir, envs = opt.envs})
        return true
    end}
    return ok or false
end
