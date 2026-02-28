CHATGPTPROGRAM Cockpit (No API Key)

Run:
  Desktop\CHATGPTPROGRAM\Run-Cockpit.ps1

Workflow:
  - Copy ChatGPT response containing a fenced `powershell` block.
  - App ingests clipboard, extracts the block, runs it when ARM is enabled,
    then copies output back to clipboard for manual paste into ChatGPT.

Safety defaults:
  - ARM OFF
  - Require fenced block ON
  - Optional marker requirement supported: # CHATGPTPROGRAM_RUN

Settings:
  %LOCALAPPDATA%\CHATGPTPROGRAM\settings.json

Logs:
  Desktop\CHATGPTPROGRAM\logs\
