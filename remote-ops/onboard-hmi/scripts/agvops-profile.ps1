# PowerShell profile for the agvops account on AGV onboard HMI machines.
# Installed to $PROFILE so every SSH session picks it up automatically.
#
# Why: sshd sessions on these Chinese Windows 10 boxes come up with console
# code page 936 (gb2312). pwsh emits UTF-8, so any non-ASCII output -- Chinese
# log lines, error messages, file paths -- arrives as mojibake on the control
# workstation. Forcing UTF-8 on both ends of the console fixes it for good.

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
# InputEncoding is not always settable in a non-interactive session; ignore it
# if the host refuses.
try { [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch { }
# Governs how pwsh encodes text piped to native executables.
$OutputEncoding = [Text.Encoding]::UTF8
