"""Shared subprocess policy for managed SDK tools and fixtures."""

import os


def subprocess_environment(environment=None):
    return dict(
        os.environ if environment is None else environment,
        DOTNET_CLI_TELEMETRY_OPTOUT="1",
        DOTNET_NOLOGO="1",
        DOTNET_CLI_USE_MSBUILD_SERVER="0",
        MSBUILDDISABLENODEREUSE="1",
    )
