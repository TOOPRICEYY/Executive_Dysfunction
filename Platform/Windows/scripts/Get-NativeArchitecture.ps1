function ConvertTo-HoldfastNativeArchitecture([string]$Machine) {
    if ([string]::IsNullOrWhiteSpace($Machine)) { throw 'Native Windows architecture is unavailable.' }
    switch ($Machine.ToUpperInvariant()) {
        'ARM64' { return 'ARM64' }
        'AMD64' { return 'x64' }
        default { throw "Unsupported native Windows architecture: $Machine" }
    }
}
function Get-HoldfastNativeArchitecture {
    # .NET Framework's RuntimeInformation can report X64 on ARM64 Windows
    # when launched through the guest agent. Use the machine environment,
    # not the current (potentially emulated) process environment.
    $machine = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')
    return ConvertTo-HoldfastNativeArchitecture $machine
}
