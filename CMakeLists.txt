cmake_minimum_required(VERSION 3.22)


#
# This file is generated only once,
# and is not re-generated if converter is called multiple times.
#
# User is free to modify the file as much as necessary
#

# Setup compiler settings
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)


# Define the build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Debug")
endif()

# Set the project name
set(CMAKE_PROJECT_NAME DevC)


# Enable compile command to ease indexing with e.g. clangd
set(CMAKE_EXPORT_COMPILE_COMMANDS TRUE)

# Core project settings
project(${CMAKE_PROJECT_NAME} LANGUAGES C CXX ASM)
message("Build type: " ${CMAKE_BUILD_TYPE})

# Create an executable object type
add_executable(${CMAKE_PROJECT_NAME})

# xrobot 1.x generates User/xrobot_main.hpp before CMake is configured.
# LibXR checks its recorded inputs on every build; CMake does not regenerate it.
set(XROBOT_CONFIG "" CACHE FILEPATH "Expected product selected by xrobot gen")
if(XROBOT_CONFIG)
    get_filename_component(XROBOT_CONFIG "${XROBOT_CONFIG}" ABSOLUTE
                           BASE_DIR "${CMAKE_SOURCE_DIR}")
    file(STRINGS "${CMAKE_SOURCE_DIR}/User/xrobot_main.hpp" XROBOT_CONFIG_LINE
         REGEX "^// xrobot: config ")
    string(REGEX REPLACE "^// xrobot: config \"([^\"]+)\"$" "\\1"
           XROBOT_SELECTED_CONFIG "${XROBOT_CONFIG_LINE}")
    get_filename_component(XROBOT_SELECTED_CONFIG "${XROBOT_SELECTED_CONFIG}" ABSOLUTE
                           BASE_DIR "${CMAKE_SOURCE_DIR}/User")
    if(NOT XROBOT_CONFIG STREQUAL XROBOT_SELECTED_CONFIG)
        message(FATAL_ERROR "Selected XRobot product differs from XROBOT_CONFIG; run xrobot gen -c ${XROBOT_CONFIG}")
    endif()
endif()

# Add -Werror
add_compile_options(-Werror)
target_compile_options(${CMAKE_PROJECT_NAME} PRIVATE -Werror)

# Add STM32CubeMX generated sources
add_subdirectory(cmake/stm32cubemx)

target_link_options(stm32cubemx INTERFACE -Wl,-u,_printf_float)

# Link directories setup
target_link_directories(${CMAKE_PROJECT_NAME} PRIVATE
    # Add user defined library search paths
)

# Add sources to executable
target_sources(${CMAKE_PROJECT_NAME} PRIVATE
    # Add user sources here
)

# Add include paths
target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE
    # Add user defined include paths
)

# Add project symbols (macros)
target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE
    # Add user defined symbols
)

# Remove wrong libob.a library dependency when using cpp files
list(REMOVE_ITEM CMAKE_C_IMPLICIT_LINK_LIBRARIES ob)

# Add linked libraries
target_link_libraries(${CMAKE_PROJECT_NAME}
    stm32cubemx

    # Add user defined libraries
)

# Add LibXR
include(${CMAKE_CURRENT_LIST_DIR}/cmake/LibXR.CMake)

# Optional cross-compiled probes emitted by the upstream XRobot generator.
set(SENTRY_STATIC_MODULE_CHECK_DIR "" CACHE PATH "Directory of module compile probes")
if(SENTRY_STATIC_MODULE_CHECK_DIR)
    file(GLOB SENTRY_MODULE_PROBES CONFIGURE_DEPENDS
         "${SENTRY_STATIC_MODULE_CHECK_DIR}/*.cpp")
    add_library(sentry_module_compile_check OBJECT ${SENTRY_MODULE_PROBES})
    target_link_libraries(sentry_module_compile_check PRIVATE xr stm32cubemx)
    target_compile_options(sentry_module_compile_check PRIVATE -Werror)
endif()

# Prints the section sizes
function(print_section_sizes TARGET)
  # Build Events command
  add_custom_command(
    TARGET ${TARGET}
    POST_BUILD
    COMMAND ${CMAKE_SIZE} ${TARGET}.elf)
endfunction()

# Creates output in hex format
function(create_hex_output TARGET)
  add_custom_target(
    ${TARGET}.hex ALL
    DEPENDS ${TARGET}
    COMMAND ${CMAKE_OBJCOPY} --output-target ihex ${TARGET}.elf ${TARGET}.hex)
endfunction()

# Creates output in binary format
function(create_bin_output TARGET)
  add_custom_target(
    ${TARGET}.bin ALL
    DEPENDS ${TARGET}
    COMMAND ${CMAKE_OBJCOPY} --output-target binary --strip-all ${TARGET}.elf
            ${TARGET}.bin)
endfunction()

create_hex_output(${PROJECT_NAME})
create_bin_output(${PROJECT_NAME})
print_section_sizes(${PROJECT_NAME})
