local wezterm = require("wezterm")
local act = wezterm.action

local config = {}
if wezterm.config_builder then
  config = wezterm.config_builder()
end

local is_windows = wezterm.target_triple:find("windows") ~= nil
local is_macos = wezterm.target_triple:find("darwin") ~= nil

if is_windows then
  config.font = wezterm.font_with_fallback({
    "CaskaydiaCove Nerd Font",
    "Cascadia Mono",
    "Consolas",
  })
else
  config.font = wezterm.font_with_fallback({
    "CaskaydiaCove Nerd Font",
    "JetBrainsMono Nerd Font",
    "Menlo",
    "Monaco",
  })
end
config.font_size = is_windows and 12.5 or 13.0
config.color_scheme = "Catppuccin Mocha"
config.window_background_opacity = is_windows and 0.97 or 0.96
config.macos_window_background_blur = is_macos and 20 or 0
config.window_decorations = "RESIZE"
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = false
config.tab_bar_at_bottom = false
config.default_cursor_style = "SteadyBar"
config.scrollback_lines = 10000
config.enable_scroll_bar = false
config.adjust_window_size_when_changing_font_size = false
config.audible_bell = "Disabled"

if is_windows then
  config.default_prog = { "pwsh.exe", "-NoLogo" }
  config.launch_menu = {
    { label = "PowerShell 7", args = { "pwsh.exe", "-NoLogo" } },
    { label = "Windows PowerShell", args = { "powershell.exe", "-NoLogo" } },
    { label = "WSL", args = { "wsl.exe", "--cd", "~" } },
    { label = "SSH pc-pwsh", args = { "ssh.exe", "pc-pwsh" } },
    { label = "SSH pc-wsl", args = { "ssh.exe", "pc-wsl" } },
  }
end

config.keys = {
  { key = "L", mods = "CTRL|SHIFT", action = act.ShowLauncher },
  { key = "P", mods = "CTRL|SHIFT", action = act.ActivateCommandPalette },
  { key = "d", mods = "CTRL|SHIFT", action = act.SplitHorizontal { domain = "CurrentPaneDomain" } },
  { key = "D", mods = "CTRL|SHIFT", action = act.SplitVertical { domain = "CurrentPaneDomain" } },
  { key = "w", mods = "CTRL|SHIFT", action = act.CloseCurrentPane { confirm = true } },
  { key = "h", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Left") },
  { key = "j", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Down") },
  { key = "k", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Up") },
  { key = "l", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Right") },
}

return config
