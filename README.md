# CHATGPTPROGRAM Cockpit

Windows-only PowerShell/WPF cockpit that helps run a manual ChatGPT “loop” (no API key).
- Watches clipboard for a marker line: ---NEXT---
- Extracts the last fenced \\\powershell\\\ block before the marker
- Runs it (when armed)
- Copies output back to clipboard for manual paste into ChatGPT

## Run
- Run-Cockpit.ps1

## Protocol (ChatGPT output format)
ChatGPT should respond with:

\\\powershell
# your code
\\\
---NEXT---

## Safety
- Keep ARM OFF until ready
- Only copy/paste content you intend to execute
