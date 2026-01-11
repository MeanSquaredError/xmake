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
-- @file        find_package.lua
--

-- imports
import("core.base.semver")
import("lib.detect.find_tool")
import("package.manager.cmake.run_cmake")

-- map xmake mode to cmake mode
function _cmake_mode(mode)
    if mode == "debug" then return "Debug"
    elseif mode == "releasedbg" then return "RelWithDebInfo"
    elseif mode == "minsizerel" then return "MinSizeRel"
    else return "Release"
    end
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
    local cmake_tool = find_tool("cmake", {version = true})
    if not cmake_tool then
        return
    end
    local configs = opt.configs or {}
    local envs = configs.envs or opt.envs or {}
    envs.CMAKE_BUILD_TYPE = envs.CMAKE_BUILD_TYPE or _cmake_mode(opt.mode)
    local opt = {
        allow_empty_package = configs.allow_empty_package,
        cmake_tool = cmake_tool,
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
        use_file_api = cmake_tool.version and semver.new(cmake_tool.version) >= "3.14",
        work_dir = os.tmpfile() .. ".dir"
    }
    local parsed = nil
    if run_cmake(opt) then
        if opt.use_file_api then
            import("package.manager.cmake.parse_file_api")
            parsed = parse_file_api(opt)
        else
            import("package.manager.cmake.parse_legacy")
            parsed = parse_legacy(opt)
        end
    end
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
