@echo off
REM Compile Vulkan compute shaders (.comp -> .spv)
REM Requires glslc on PATH (available from the Vulkan SDK)

where glslc >nul 2>nul || (
    echo error: glslc not found. Install the Vulkan SDK or add glslc to PATH.
    exit /b 1
)

setlocal
set SHADER_DIR=%~dp0src\shaders
set COMPILED=0

for %%f in ("%SHADER_DIR%\*.comp") do (
    echo Compiling %%~nf.comp -^> %%~nf.spv
    glslc "%%f" -o "%SHADER_DIR%\%%~nf.spv"
    set /a COMPILED+=1
)

echo Done.
endlocal
