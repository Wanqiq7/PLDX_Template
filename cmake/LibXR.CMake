set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# LibXR
set(LIBXR_SYSTEM FreeRTOS)
set(LIBXR_DRIVER st)
set(XROBOT_MODULES_DIR ${CMAKE_CURRENT_SOURCE_DIR}/Modules)
set(LIBXR_SOURCE_DIR "${CMAKE_SOURCE_DIR}/.tooling/LibXR-v2.0.1" CACHE PATH
    "LibXR v2.0.1 checkout (see tools/setup_libxr2.py)")
if(NOT EXISTS "${LIBXR_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "LibXR v2.0.1 is missing; run python3 tools/setup_libxr2.py")
endif()
add_subdirectory("${LIBXR_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/LibXR")
add_dependencies(xrobot_freshness_check xrobot_generate)
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU")
    target_compile_options(xr PRIVATE -Wno-tautological-compare -Wno-maybe-uninitialized)
endif()
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    target_compile_options(xr PRIVATE -Wno-deprecated-volatile)
endif()
target_link_libraries(xr
    PUBLIC stm32cubemx
)

target_compile_features(xr PUBLIC cxx_std_20)
target_include_directories(xr
    PUBLIC $<TARGET_PROPERTY:stm32cubemx,INTERFACE_INCLUDE_DIRECTORIES>
    PUBLIC Core/Inc
    PUBLIC User
)

# Add include paths
set_target_properties(${CMAKE_PROJECT_NAME} PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)


target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE
    # Add user defined include paths
    PUBLIC $<TARGET_PROPERTY:xr,INTERFACE_INCLUDE_DIRECTORIES>
    PUBLIC User
)

# Add linked libraries
target_link_libraries(${CMAKE_PROJECT_NAME}
    stm32cubemx

    # Add user defined libraries
    xr
)

file(
    GLOB LIBXR_USER_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/User/*.cpp")


target_sources(${CMAKE_PROJECT_NAME}
    PRIVATE ${LIBXR_USER_SOURCES}
)

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(${CMAKE_PROJECT_NAME} PRIVATE -Og)
    target_compile_options(xr PRIVATE -O2)
    if(TARGET FreeRTOS)
        target_compile_options(FreeRTOS PRIVATE -O2)
    endif()

    if(TARGET STM32_Drivers)
        target_compile_options(STM32_Drivers PRIVATE -O2)
    endif()

    if(TARGET USB_Device_Library)
        target_compile_options(USB_Device_Library PRIVATE -O2)
    endif()
endif()
