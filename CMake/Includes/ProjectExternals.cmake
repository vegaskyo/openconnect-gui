if(MINGW)
    if(NOT CMAKE_CROSSCOMPILING)
        file(STRINGS "${CMAKE_SOURCE_DIR}/contrib/openconnect-version.txt" OPENCONNECT_DEFAULT_TAG LIMIT_COUNT 1)
        set(openconnect-TAG "${OPENCONNECT_DEFAULT_TAG}" CACHE STRING "Please specify openconnect version")
        set(openconnect-TAG_CHOICES "${OPENCONNECT_DEFAULT_TAG}" "v9.12" "v8.10" "v7.08" "master")
        set_property(CACHE openconnect-TAG PROPERTY STRINGS ${openconnect-TAG_CHOICES})
        if(NOT openconnect-TAG MATCHES "^(v[0-9]+\\.[0-9]+(\\.[0-9]+)?|master)$")
            message(FATAL_ERROR "Specify an OpenConnect version tag (e.g. v9.21) or master")
        endif()
    endif()
endif()

set(vpnc-scripts-TAG ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101)
set(qt-solutions-TAG master)

if(CMAKE_CROSSCOMPILING AND MINGW)
    # Fedora mingw32/mingw64
    if(CMAKE_SIZEOF_VOID_P EQUAL 8)
        set(CMAKE_CROSS_COMMAND mingw64-cmake)
    else()
        set(CMAKE_CROSS_COMMAND mingw32-cmake)
    endif()
else()
    # Windows mingw32 & macOS & native GNU/Linux
    set(CMAKE_CROSS_COMMAND ${CMAKE_COMMAND})
endif()
message(STATUS "Using '${CMAKE_CROSS_COMMAND}' as CMake...")


include(ExternalProject)

file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR}/external/include)

if(NOT spdlog_FOUND)
    message(STATUS "Using local spdlog build")
    set(spdlog-TAG v1.15.3)
    include(ProjectExternals_spdlog)
endif()

include(ProjectExternals_qt-solutions)
if(MINGW)
    if (NOT CMAKE_CROSSCOMPILING)
        include(ProjectExternals_openconnect)
    endif()
    include(ProjectExternals_vpnc-scripts-win)
endif()

