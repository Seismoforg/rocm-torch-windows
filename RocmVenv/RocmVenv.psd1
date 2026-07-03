@{
    RootModule        = 'RocmVenv.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7f4e2a1-9c3d-4e8f-a1b2-6d5c4e3f2a10'
    Author            = 'rocm-venv-setup'
    Description       = 'One-click ROCm nightly + PyTorch virtual environment setup for Windows, reusable across projects.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-RocmGpuTarget', 'Initialize-RocmVenv', 'Invoke-RocmBenchmark')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('ROCm', 'PyTorch', 'AMD', 'GPU', 'venv', 'Windows')
            ProjectUri = 'https://github.com/ROCm/TheRock'
        }
    }
}
