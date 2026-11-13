--!nonstrict
-- Feed -> ui.* tree for the chat panel.
--
--   render.panel(m, ui_state, settings, actions) -> tree
--
-- m        : lib/model.luau state
-- ui_state : { expanded = {[id]=true}, busy = {[request_id]=true}, draft, composerGen,
--              scrollRev, hasBridge, connected, bridgeError, status, notice }
-- settings : { send_on_enter = bool, default_cwd = string }
-- actions  : { send(text), stop(), newChat(), toggle(id), decide(request_id, decision),
--              draft(text), openSettings(), copy(text) }
--
-- Every prop that can change between renders is always passed: the host keeps a
-- retained prop when a later render omits it. Colors are palette roles only.

local M = {}

local tr = noctalia.tr
local Fences = require("./fences.luau")

local MONO = "monospace"
local PREVIEW_LINES = 40
local USER_BUBBLE_MAX_WIDTH = 400

local TOOL_GLYPHS = {
  Bash = "terminal-2",
  BashOutput = "terminal-2",
  KillShell = "terminal-2",
  Read = "file-text",
  Edit = "pencil",
  MultiEdit = "pencil",
  NotebookEdit = "pencil",
  Write = "file-plus",
  Glob = "folder-search",
  Grep = "file-search",
  WebFetch = "world",
  WebSearch = "world-search",
  Task = "robot",
  Agent = "robot",
  TodoWrite = "list-check",
}

local TOOL_STATUS = {
  running = { glyph = "loader-2", color = "on_surface_variant" },
  done = { glyph = "check", color = "primary" },
  error = { glyph = "x", color = "error" },
  denied = { glyph = "ban", color = "error" },
  stopped = { glyph = "player-stop", color = "on_surface_variant" },
}

-- A text spinner, one frame per 100 ms. Glyphs cannot rotate before plugin API 52, so the panel
-- re-renders while a spinner is on screen: drawing one sets state.spinning, and state.clock picks
-- the frame.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_MS = 100

local function spinnerText(state)
  state.spinning = true
  return SPINNER[math.floor((state.clock or 0) / SPINNER_MS) % #SPINNER + 1]
end

local function spinner(key, state, size, color)
  return ui.label({ key = key, text = spinnerText(state), fontSize = size, color = color or "primary" })
end

local RESOLVED = {
  allow_once = { glyph = "circle-check", color = "primary" },
  allow_session = { glyph = "shield-check", color = "primary" },
  deny = { glyph = "ban", color = "error" },
  cancelled = { glyph = "circle-x", color = "on_surface_variant" },
}

-- --------------------------------------------------------------- helpers

local function toolGlyph(name)
  if TOOL_GLYPHS[name] ~= nil then
    return TOOL_GLYPHS[name]
  end
  if string.sub(name, 1, 5) == "mcp__" then
    return "plug"
  end
  return "tool"
end

local function shortPath(path)
  if type(path) ~= "string" then
    return ""
  end
  return (string.gsub(path, "^/home/[^/]+", "~"))
end

-- First `max` lines of `text` and how many lines were left out.
local function headLines(text, max)
  if type(text) ~= "string" or text == "" then
    return {}, 0
  end
  local lines = {}
  local total = 0
  for line in string.gmatch(text .. "\n", "(.-)\n") do
    total += 1
    if total <= max then
      lines[#lines + 1] = line
    end
  end
  return lines, math.max(0, total - max)
end

local function prefixed(lines, prefix)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = prefix .. line
  end
  return table.concat(out, "\n")
end

local function jsonText(value)
  if value == nil then
    return ""
  end
  local ok, text = pcall(noctalia.json.encode, value, true)
  if ok and type(text) == "string" then
    return text
  end
  return tostring(value)
end

local function field(input, key)
  if type(input) == "table" and type(input[key]) == "string" then
    return input[key]
  end
  return nil
end

local function mono(key, text, color)
  return ui.label({
    key = key,
    text = text,
    fontFamily = MONO,
    fontSize = 11,
    color = color or "on_surface",
  })
end

local function codeBox(key, children)
  return ui.column({
    key = key,
    gap = 2,
    padding = 8,
    radius = 8,
    fill = "surface_container_highest",
  }, children)
end

local function muted(key, text, size)
  return ui.label({ key = key, text = text, fontSize = size or 11, color = "on_surface_variant" })
end

-- --------------------------------------------------------------- feed items

local function copyButton(key, text, ui_state, actions, label)
  local copied = ui_state.copied == key
  return ui.button({
    key = key,
    text = label and tr(copied and "panel.copied" or label) or nil,
    glyph = copied and "check" or "copy",
    glyphSize = 12,
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr(label or "panel.copy"),
    enabled = text ~= nil and text ~= "",
    onClick = function()
      actions.copy(text, key)
    end,
  })
end

local function userItem(item)
  local children = {}
  if type(item.images) == "table" and #item.images > 0 then
    local thumbs = {}
    for i, path in ipairs(item.images) do
      thumbs[#thumbs + 1] = ui.image({ key = item.id .. "-img-" .. tostring(i), path = path,
        width = 96, height = 72, radius = 8, fit = "cover" })
    end
    children[#children + 1] = ui.row({ key = item.id .. "-imgs", gap = 6, justify = "end" }, thumbs)
  elseif (item.image_count or 0) > 0 then
    children[#children + 1] = ui.row({ key = item.id .. "-imgcount", gap = 4, align = "center", justify = "end" }, {
      ui.glyph({ key = item.id .. "-imgcount-glyph", name = "photo", size = 14, color = "on_primary_container" }),
      ui.label({ key = item.id .. "-imgcount-text", text = tr("panel.images_count", { n = item.image_count }),
        fontSize = 11, color = "on_primary_container" }),
    })
  end
  if item.text ~= nil and item.text ~= "" then
    -- A bubble in a row is measured unconstrained: cap it so long text wraps.
    children[#children + 1] = ui.label({
      key = item.id .. "-text",
      text = item.text,
      fontSize = 13,
      color = "on_primary_container",
      maxWidth = USER_BUBBLE_MAX_WIDTH,
    })
  end
  return ui.row({ key = item.id, justify = "end" }, {
    ui.column({
      key = item.id .. "-bubble",
      fill = "primary_container",
      radius = 14,
      paddingH = 12,
      paddingV = 8,
      gap = 6,
    }, children),
  })
end

local function codeBlock(key, seg, ui_state, actions, streaming)
  return ui.column({ key = key, gap = 0, radius = 8, fill = "surface_container_high" }, {
    ui.row({ key = key .. "-bar", gap = 6, align = "center", paddingH = 10, paddingV = 2 }, {
      ui.label({ key = key .. "-lang", text = seg.lang ~= "" and seg.lang or tr("panel.code"),
        fontFamily = MONO, fontSize = 10, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
      copyButton(key .. "-copy", (seg.closed or not streaming) and seg.code or nil, ui_state, actions, "panel.copy_code"),
    }),
    ui.markdown({ key = key .. "-md", text = Fences.wrap(seg.lang, seg.code) }),
  })
end

local function assistantItem(item, ui_state, actions, canBranch)
  -- Split once per text change: streaming re-renders reuse the cached segments.
  if item.segmentsOf ~= item.text then
    item.segments = Fences.split(item.text)
    item.segmentsOf = item.text
  end
  local children = {}
  for i, seg in ipairs(item.segments) do
    local key = item.id .. "-s" .. tostring(i)
    if seg.kind == "code" then
      children[#children + 1] = codeBlock(key, seg, ui_state, actions, item.streaming)
    else
      children[#children + 1] = ui.markdown({ key = key .. "-md", text = seg.text })
    end
  end
  if item.uuid ~= nil and not item.streaming then
    children[#children + 1] = ui.row({ key = item.id .. "-actions", justify = "end" }, {
      ui.button({
        key = item.id .. "-branch",
        glyph = "git-fork",
        glyphSize = 12,
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.fork_here"),
        enabled = canBranch,
        onClick = function() actions.fork(nil, item.uuid) end,
      }),
    })
  end
  return ui.column({ key = item.id, gap = 8 }, children)
end

local function forkedItem(item)
  return ui.row({ key = item.id, gap = 8, align = "center", paddingH = 8, paddingV = 6, radius = 8,
    fill = "surface_container_low" }, {
    ui.glyph({ key = item.id .. "-glyph", name = "git-fork", size = 14, color = "primary" }),
    ui.label({ key = item.id .. "-text", text = tr("panel.forked"), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
  })
end

local function disclosureRow(key, open, glyph, title, summary, trailing, onClick)
  local children = {
    ui.glyph({ key = key .. "-chev", name = open and "chevron-down" or "chevron-right", size = 12, color = "on_surface_variant" }),
    ui.glyph({ key = key .. "-icon", name = glyph, size = 14, color = "on_surface_variant" }),
    ui.label({ key = key .. "-title", text = title, fontSize = 12, fontWeight = "medium", color = "on_surface" }),
    ui.label({
      key = key .. "-summary",
      text = summary,
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    }),
  }
  for _, node in ipairs(trailing) do
    children[#children + 1] = node
  end
  return ui.row({
    key = key .. "-row",
    gap = 8,
    align = "center",
    paddingH = 8,
    paddingV = 5,
    radius = 8,
    fill = open and "surface_container_high" or "surface_container_low",
    onClick = onClick,
  }, children)
end

local function thinkingItem(item, ui_state, actions)
  local open = ui_state.expanded[item.id] == true
  local children = {
    disclosureRow(item.id, open, "bulb", tr("panel.thinking"), "", {}, function()
      actions.toggle(item.id)
    end),
  }
  if open then
    children[#children + 1] = ui.column({ key = item.id .. "-body", paddingH = 12, paddingV = 4 }, {
      muted(item.id .. "-text", item.text ~= "" and item.text or "…", 12),
    })
  end
  return ui.column({ key = item.id, gap = 4 }, children)
end

local toolItem

local function toolDetails(item, ui_state, actions)
  local key = item.id
  local inputText
  if item.name == "Bash" and field(item.input, "command") ~= nil then
    inputText = field(item.input, "command")
  else
    inputText = jsonText(item.input)
  end
  local parts = {
    muted(key .. "-in-label", tr("panel.tool.input"), 10),
    codeBox(key .. "-in", { mono(key .. "-in-text", inputText) }),
  }
  if item.input_truncated then
    parts[#parts + 1] = muted(key .. "-in-cut", tr("panel.tool.truncated"), 10)
  end
  if #item.children > 0 then
    local steps = {}
    for _, child in ipairs(item.children) do
      steps[#steps + 1] = toolItem(child, ui_state, actions)
    end
    parts[#parts + 1] = ui.column({ key = key .. "-steps", gap = 4 }, steps)
  end
  parts[#parts + 1] = muted(key .. "-out-label", tr("panel.tool.output"), 10)
  if item.output ~= nil then
    local outText = item.output ~= "" and item.output or tr("panel.tool.empty")
    parts[#parts + 1] = codeBox(key .. "-out", {
      mono(key .. "-out-text", outText, item.status == "error" and "error" or "on_surface"),
    })
    if item.output_truncated then
      parts[#parts + 1] = muted(key .. "-out-cut", tr("panel.tool.truncated"), 10)
    end
  else
    parts[#parts + 1] = muted(key .. "-out-none", tr("panel.tool.no_output"), 11)
  end
  return ui.column({ key = key .. "-details", gap = 4, paddingH = 12, paddingV = 4 }, parts)
end

toolItem = function(item, ui_state, actions)
  local open = ui_state.expanded[item.id] == true
  local status = TOOL_STATUS[item.status] or TOOL_STATUS.running
  local trailing = {}
  if #item.children > 0 then
    trailing[#trailing + 1] = muted(item.id .. "-count", tr("panel.tool.steps", { n = #item.children }), 11)
  end
  if item.status == "running" and not item.historical then
    trailing[#trailing + 1] = spinner(item.id .. "-spin", ui_state, 13, "on_surface_variant")
  else
    trailing[#trailing + 1] = ui.glyph({ key = item.id .. "-status", name = status.glyph, size = 14, color = status.color })
  end
  local children = {
    disclosureRow(item.id, open, toolGlyph(item.name), item.name, item.summary, trailing, function()
      actions.toggle(item.id)
    end),
  }
  if open then
    children[#children + 1] = toolDetails(item, ui_state, actions)
  end
  return ui.column({ key = item.id, gap = 4 }, children)
end

-- Body of a permission card, by tool (spec §4).
local function permissionBody(item)
  local key = item.id
  local input = item.input
  local name = item.tool_name
  local out = {}
  if name == "Bash" and field(input, "command") ~= nil then
    local command = field(input, "command")
    local lines = select(2, string.gsub(command, "\n", "\n")) + 1
    local box = codeBox(key .. "-cmd", { mono(key .. "-cmd-text", command) })
    if lines > 14 or #command > 1500 then
      -- Full command, never cut: long ones scroll inside the card.
      box = ui.scroll({ key = key .. "-cmd-scroll", height = 220, radius = 8, fill = "surface_container_highest" }, {
        ui.column({ key = key .. "-cmd", padding = 8 }, { mono(key .. "-cmd-text", command) }),
      })
    end
    out[#out + 1] = box
  elseif (name == "Edit" or name == "Write") and field(input, "file_path") ~= nil then
    out[#out + 1] = mono(key .. "-path", shortPath(field(input, "file_path")), "on_surface_variant")
    local rows = {}
    if name == "Edit" then
      local old, oldMore = headLines(field(input, "old_string") or "", PREVIEW_LINES)
      local new, newMore = headLines(field(input, "new_string") or "", PREVIEW_LINES)
      if #old > 0 then
        rows[#rows + 1] = mono(key .. "-old", prefixed(old, "- "), "error")
      end
      if oldMore > 0 then
        rows[#rows + 1] = muted(key .. "-old-more", tr("panel.perm.more_lines", { n = oldMore }), 10)
      end
      rows[#rows + 1] = mono(key .. "-new", prefixed(new, "+ "), "primary")
      if newMore > 0 then
        rows[#rows + 1] = muted(key .. "-new-more", tr("panel.perm.more_lines", { n = newMore }), 10)
      end
    else
      local lines, more = headLines(field(input, "content") or "", PREVIEW_LINES)
      rows[#rows + 1] = mono(key .. "-content", table.concat(lines, "\n"))
      if more > 0 then
        rows[#rows + 1] = muted(key .. "-content-more", tr("panel.perm.more_lines", { n = more }), 10)
      end
    end
    out[#out + 1] = codeBox(key .. "-diff", rows)
  elseif name == "WebFetch" and field(input, "url") ~= nil then
    out[#out + 1] = codeBox(key .. "-url", { mono(key .. "-url-text", field(input, "url")) })
  else
    out[#out + 1] = codeBox(key .. "-json", { mono(key .. "-json-text", jsonText(input)) })
  end
  if item.input_truncated then
    out[#out + 1] = muted(key .. "-cut", tr("panel.perm.truncated"), 10)
  end
  if item.description ~= nil and item.description ~= "" then
    out[#out + 1] = ui.label({ key = key .. "-desc", text = item.description, fontSize = 12, color = "on_surface_variant" })
  end
  if item.blocked_path ~= nil and item.blocked_path ~= "" then
    out[#out + 1] = muted(key .. "-blocked", tr("panel.perm.blocked_path", { path = shortPath(item.blocked_path) }), 11)
  end
  return out
end

local function permissionItem(item, ui_state, actions)
  local key = item.id
  if item.decision ~= nil then
    local look = RESOLVED[item.decision] or RESOLVED.cancelled
    local label = tr("panel.perm.resolved." .. (RESOLVED[item.decision] and item.decision or "cancelled"))
    return ui.row({ key = key, gap = 8, align = "center", paddingH = 8 }, {
      ui.glyph({ key = key .. "-glyph", name = look.glyph, size = 14, color = look.color }),
      ui.label({ key = key .. "-outcome", text = label, fontSize = 12, color = look.color }),
      ui.label({
        key = key .. "-what",
        text = item.display_name .. "  " .. item.summary,
        fontSize = 12,
        color = "on_surface_variant",
        maxLines = 1,
        flexGrow = 1,
      }),
    })
  end

  local busy = ui_state.busy[item.request_id or ""] == true
  local function decide(decision)
    return function()
      if item.request_id ~= nil then
        actions.decide(item.request_id, decision)
      end
    end
  end
  local buttons = {
    ui.button({
      key = key .. "-allow",
      text = tr("panel.perm.allow"),
      glyph = "check",
      variant = "primary",
      controlSize = "sm",
      enabled = not busy,
      onClick = decide("allow_once"),
    }),
    ui.spacer({ key = key .. "-gap", flexGrow = 1 }),
    ui.button({
      key = key .. "-deny",
      text = tr("panel.perm.deny"),
      glyph = "ban",
      variant = "destructive",
      controlSize = "sm",
      enabled = not busy,
      onClick = decide("deny"),
    }),
  }
  -- Spec §8.3: the rule a session grant adds is consent text, so the card shows
  -- it in full (wrapping); the button itself stays short.
  local sessionRule = nil
  local sessionButton = nil
  if item.allow_session_available then
    local rule = item.session_rule_preview or item.display_name
    sessionRule = ui.column({ key = key .. "-rule", gap = 4 }, {
      muted(key .. "-rule-label", tr("panel.perm.session_rule"), 11),
      codeBox(key .. "-rule-box", { mono(key .. "-rule-text", rule) }),
    })
    sessionButton = ui.button({
      key = key .. "-session",
      text = tr("panel.perm.session"),
      glyph = "shield-check",
      variant = "outline",
      controlSize = "sm",
      enabled = not busy,
      onClick = decide("allow_session"),
    })
  end

  local children = {
    ui.row({ key = key .. "-head", gap = 8, align = "center" }, {
      ui.glyph({ key = key .. "-lock", name = "shield-lock", size = 16, color = "primary" }),
      ui.label({
        key = key .. "-title",
        text = tr("panel.perm.title", { tool = item.display_name }),
        fontSize = 13,
        fontWeight = "semibold",
        color = "on_surface",
        flexGrow = 1,
      }),
    }),
  }
  for _, node in ipairs(permissionBody(item)) do
    children[#children + 1] = node
  end
  if sessionRule ~= nil then
    children[#children + 1] = sessionRule
  end
  children[#children + 1] = ui.row({ key = key .. "-buttons", gap = 6, align = "center" }, buttons)
  if sessionButton ~= nil then
    children[#children + 1] = sessionButton
  end
  return ui.column({
    key = key,
    gap = 8,
    padding = 12,
    radius = 12,
    fill = "surface_container",
    border = "primary",
    borderWidth = 1,
  }, children)
end

local function resultItem(item, ui_state, actions)
  local key = item.id
  local text
  local color = "on_surface_variant"
  if item.ok then
    local parts = {}
    if item.duration_ms ~= nil then
      parts[#parts + 1] = tr("panel.result.seconds", { s = string.format("%.1f", item.duration_ms / 1000) })
    end
    if item.cost_usd ~= nil and item.cost_usd > 0 then
      parts[#parts + 1] = string.format("$%.3f", item.cost_usd)
    end
    text = table.concat(parts, " · ")
  elseif item.subtype == "interrupted" then
    text = tr("panel.result.stopped")
  else
    text = tr("panel.result.failed", { error = item.error or item.subtype or "?" })
    color = "error"
  end
  local children = {
    ui.label({ key = key .. "-text", text = text, fontSize = 10, color = color, flexGrow = 1, textAlign = "end" }),
  }
  if item.ok and item.copyText ~= nil and item.copyText ~= "" then
    children[#children + 1] = copyButton(key .. "-copy", item.copyText, ui_state, actions, "panel.copy_answer")
  end
  return ui.row({ key = key, gap = 4, align = "center" }, children)
end

local function errorText(kind, message)
  if kind == "auth" then
    return tr("panel.error.auth")
  end
  if kind == "crash" then
    return tr("panel.error.crash") .. (message ~= "" and ("\n" .. message) or "")
  end
  return message ~= "" and message or tr("widget.state.error")
end

local function banner(key, glyph, text, tone)
  local fill = tone == "error" and "error_container" or "surface_container_high"
  local fg = tone == "error" and "on_error_container" or "on_surface"
  return ui.row({ key = key, gap = 10, align = "start", padding = 10, radius = 10, fill = fill }, {
    ui.glyph({ key = key .. "-glyph", name = glyph, size = 16, color = fg }),
    ui.label({ key = key .. "-text", text = text, fontSize = 12, color = fg, flexGrow = 1 }),
  })
end

local function errorItem(item)
  return banner(item.id, "alert-triangle", errorText(item.errorKind, item.message), "error")
end

-- --------------------------------------------------------------- sections

local function statusInfo(m, ui_state)
  if ui_state.bridgeError ~= nil then
    return tr("widget.state.error"), "error"
  end
  if not ui_state.hasBridge or not ui_state.connected then
    return tr("panel.reconnecting"), "outline_variant"
  end
  local s = ui_state.status or "idle"
  if s == "running" then
    return tr("widget.state.running"), "tertiary"
  elseif s == "waiting_permission" then
    return tr("widget.state.waiting_permission"), "error"
  elseif s == "error" or m.error ~= nil then
    return tr("widget.state.error"), "error"
  end
  return tr("widget.state.idle"), "primary"
end

local function isBusy(m, state)
  for _, item in ipairs(m.items) do
    if item.kind == "permission" and not item.historical and item.decision == nil then return true end
  end
  return state.preferencesSaving or state.switching or state.sending or m.state == "running" or state.status == "running" or state.status == "waiting_permission"
end

local function header(m, ui_state, actions)
  local statusText, dotColor = statusInfo(m, ui_state)
  local sub = { statusText }
  if m.session ~= nil then
    if m.session.cwd ~= nil then
      sub[#sub + 1] = shortPath(m.session.cwd)
    end
    if m.session.model ~= nil then
      sub[#sub + 1] = m.session.model
    end
  end
  return ui.row({ key = "header", gap = 10, align = "center", paddingH = 4 }, {
    ui.glyph({ key = "header-glyph", name = "sparkles", size = 22, color = "primary" }),
    ui.column({ key = "header-text", gap = 2, flexGrow = 1 }, {
      ui.label({ key = "header-title", text = tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.row({ key = "header-status", gap = 6, align = "center" }, {
        ui.box({ key = "header-dot", width = 7, height = 7, radius = 4, fill = dotColor }),
        ui.label({
          key = "header-sub",
          text = table.concat(sub, " · "),
          fontSize = 11,
          color = "on_surface_variant",
          maxLines = 1,
          flexGrow = 1,
        }),
      }),
    }),
    ui.button({
      key = "header-chats",
      text = tr("panel.chats"),
      tooltip = tr("panel.chats_shortcut"),
      glyph = "messages",
      variant = "ghost",
      controlSize = "sm",
      enabled = ui_state.hasBridge and ui_state.connected,
      onClick = actions.toggleChats,
    }),
    ui.button({
      key = "header-new",
      text = tr("panel.new_chat"),
      glyph = "message-plus",
      variant = "ghost",
      controlSize = "sm",
      enabled = ui_state.hasBridge and ui_state.connected and not isBusy(m, ui_state),
      onClick = actions.newChat,
    }),
    ui.button({
      key = "header-settings",
      glyph = "settings",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.settings"),
      onClick = actions.openSettings,
    }),
  })
end

local function emptyState(settings)
  local cwd = shortPath(settings.default_cwd or "~")
  return ui.column({ key = "empty", gap = 8, align = "center", paddingV = 48 }, {
    ui.glyph({ key = "empty-glyph", name = "sparkles", size = 36, color = "primary/0.6" }),
    ui.label({ key = "empty-title", text = tr("panel.empty.title"), fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
    ui.label({
      key = "empty-hint",
      text = tr("panel.empty.hint", { cwd = cwd }),
      fontSize = 12,
      color = "on_surface_variant",
      textAlign = "center",
    }),
  })
end

local function workingRow(ui_state)
  return ui.row({ key = "working", gap = 8, align = "center", paddingH = 8 }, {
    spinner("working-spinner", ui_state, 14),
    ui.label({ key = "working-text", text = tr("widget.state.running"), fontSize = 12, color = "on_surface_variant" }),
  })
end

local function feed(m, ui_state, settings, actions)
  local rows = {}
  local canBranch = ui_state.hasBridge and ui_state.connected and not isBusy(m, ui_state)
  local display = ui_state.historyPage or m
  for _, item in ipairs(display.items) do
    local kind = item.kind
    if kind == "user" then
      rows[#rows + 1] = userItem(item)
    elseif kind == "assistant" then
      if item.text ~= "" then
        rows[#rows + 1] = assistantItem(item, ui_state, actions, canBranch)
      end
    elseif kind == "forked" then
      rows[#rows + 1] = forkedItem(item)
    elseif kind == "thinking" then
      rows[#rows + 1] = thinkingItem(item, ui_state, actions)
    elseif kind == "tool" then
      rows[#rows + 1] = toolItem(item, ui_state, actions)
    elseif kind == "permission" then
      rows[#rows + 1] = permissionItem(item, ui_state, actions)
    elseif kind == "result" then
      rows[#rows + 1] = resultItem(item, ui_state, actions)
    elseif kind == "error" then
      rows[#rows + 1] = errorItem(item)
    end
  end
  if #rows == 0 then
    rows[1] = emptyState(settings)
  end
  local last = display.items[#display.items]
  local busy = ui_state.historyPage == nil and (ui_state.status == "running" or m.state == "running")
  if busy and ui_state.status ~= "waiting_permission" and not (last ~= nil and last.kind == "assistant" and last.streaming) then
    rows[#rows + 1] = workingRow(ui_state)
  end
  return ui.scroll({
    key = ui_state.historyPage ~= nil and ("history-feed-" .. tostring(ui_state.historyOffset)) or "feed",
    flexGrow = 1,
    gap = 12,
    paddingH = 4,
    paddingV = 4,
    stickToBottom = ui_state.historyPage == nil,
    scrollToBottomRev = ui_state.scrollRev or 0,
  }, rows)
end

local function banners(ui_state)
  local out = {}
  if ui_state.bridgeError ~= nil then
    out[#out + 1] = banner("banner-bridge", "alert-triangle", ui_state.bridgeError, "error")
  elseif not ui_state.hasBridge or not ui_state.connected then
    out[#out + 1] = banner("banner-reconnect", "refresh", tr("panel.reconnecting"), "info")
  end
  if ui_state.notice ~= nil then
    out[#out + 1] = banner("banner-notice", "alert-circle", ui_state.notice, "error")
  end
  return out
end

-- Pasted images waiting to be sent: thumbnails with a remove button.
local function imageStrip(ui_state, actions)
  local tiles = {}
  for _, image in ipairs(ui_state.images or {}) do
    local id = image.id
    tiles[#tiles + 1] = ui.column({ key = "image-" .. id, gap = 2, align = "center" }, {
      ui.image({ key = "image-thumb-" .. id, path = image.path, width = 64, height = 48, radius = 6,
        fit = "cover", tooltip = image.name }),
      ui.button({ key = "image-remove-" .. id, glyph = "x", glyphSize = 11, variant = "ghost", controlSize = "sm",
        tooltip = tr("panel.remove_image"), enabled = not ui_state.switching,
        onClick = function() actions.removeImage(id) end }),
    })
  end
  return ui.row({ key = "composer-images", gap = 6, visible = #tiles > 0 }, tiles)
end

local function composer(m, ui_state, settings, actions)
  local generation = ui_state.composerGen
  local sendOnEnter = settings.send_on_enter == true
  local status = ui_state.status or "idle"
  local working = status == "running" or status == "waiting_permission" or m.state == "running"
  local canSend = ui_state.hasBridge and ui_state.connected and not ui_state.switching and not ui_state.sending and not ui_state.preferencesSaving
  local buttons = {
    ui.button({ key = "composer-attach", glyph = "paperclip", tooltip = tr("panel.attach_file"),
      variant = "ghost", controlSize = "sm", enabled = ui_state.connected and not ui_state.switching,
      onClick = actions.openFiles }),
    ui.button({ key = "composer-image", glyph = ui_state.imagePasting and "loader-2" or "photo-plus",
      tooltip = tr("panel.paste_image"), variant = "ghost", controlSize = "sm",
      enabled = ui_state.connected and not ui_state.switching and not ui_state.imagePasting,
      onClick = actions.pasteImage }),
    ui.label({
      key = "composer-hint",
      text = tr(sendOnEnter and "panel.hint.enter" or "panel.hint.ctrl_enter"),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    }),
  }
  if working then
    buttons[#buttons + 1] = ui.button({
      key = "composer-stop",
      text = tr("panel.stop"),
      glyph = "player-stop-filled",
      variant = "outline",
      controlSize = "sm",
      onClick = actions.stop,
    })
  end
  buttons[#buttons + 1] = ui.button({
    key = "composer-send",
    text = tr("panel.send"),
    glyph = "send",
    variant = "primary",
    controlSize = "sm",
    enabled = canSend,
    onClick = function()
      actions.send(ui_state.draft or "")
    end,
  })
  return ui.column({
    key = "composer",
    gap = 6,
    padding = 8,
    radius = 14,
    fill = "surface_container",
    border = "outline_variant",
    borderWidth = 1,
  }, {
    imageStrip(ui_state, actions),
    ui.input({
      -- A new key per sent message: the uncontrolled input is recreated empty
      -- and takes focus again (focus applies only when a control is created).
      key = "composer-input-" .. tostring(ui_state.composerGen or 0),
      value = ui_state.draft or "",
      placeholder = tr("panel.placeholder"),
      fontSize = 13,
      -- Always multiline so Shift+Enter can add a line in send-on-Enter mode;
      -- submitOnEnter flips the bindings (Enter sends, Ctrl+Enter sends either way).
      enabled = not ui_state.switching,
      multiline = true,
      submitOnEnter = sendOnEnter,
      frameVisible = false,
      focus = true,
      height = 84,
      onChange = function(value)
        if generation == ui_state.composerGen then actions.draft(value) end
      end,
      onSubmit = function(value)
        if generation == ui_state.composerGen then actions.submit(value) end
      end,
    }),
    ui.row({ key = "composer-actions", gap = 6, align = "center" }, buttons),
  })
end

local keyNames = { tab = "Tab", shift_tab = "Shift+Tab", up = "↑", down = "↓", enter = "Enter" }

-- "↓/↑ to move · Tab to pick", from the user's suggestion key settings.
local function withKeyHint(children, key, settings)
  local keys = settings and settings.suggestion_keys
  if keys == nil then return children end
  table.insert(children, 2, muted(key, tr("panel.suggestion_keys", { next = keyNames[keys.next] or "", previous = keyNames[keys.previous] or "",
    accept = keyNames[keys.accept] or "" }), 10))
  return children
end

-- The highlighted suggestion: the one the accept key picks.
-- Always sets the border: the host keeps a prop that disappears from a node, so a row that
-- lost the highlight would stay outlined. Unselected rows get a border in their own fill.
local function highlight(props, selected)
  props.border = selected and "primary" or props.fill
  props.borderWidth = 1
  return props
end

-- "Tab/Shift+Tab move · Enter open · Ctrl+R close" for the chat picker.
local function chatKeyHint(settings)
  local keys = settings and settings.suggestion_keys or {}
  return tr("panel.chat_keys", { next = keyNames[keys.next] or "↓", previous = keyNames[keys.previous] or "↑" })
end

local function picker(m, state, actions, settings)
  local blocked = isBusy(m, state) or not state.connected or state.sessionsLoading
  local rows = {}
  -- Browsing chats must not hide approvals for the currently running turn.
  for _, item in ipairs(m.items) do
    if item.kind == "permission" and item.decision == nil and not item.historical then
      rows[#rows + 1] = permissionItem(item, state, actions)
    end
  end
  for index, session in ipairs(state.sessions) do
    local entry = session
    rows[#rows + 1] = ui.column(highlight({
      key = "chat-" .. entry.id, gap = 4, padding = 10, radius = 10,
      fill = entry.selected == true and "surface_container_high" or "surface_container", onClick = function()
        if not blocked then actions.selectChat(entry, false) end
      end,
    }, index == (state.chatIndex or 1) and not state.sessionsLoading), {
      ui.label({ key = "chat-title-" .. entry.id, text = (entry.selected == true and (tr("panel.current_chat") .. " · ") or "") .. (entry.title or tr("panel.untitled")), fontSize = 13, fontWeight = "medium", color = blocked and "on_surface_variant" or "on_surface", maxLines = 2 }),
      muted("chat-cwd-" .. entry.id, shortPath(entry.cwd), 11),
      muted("chat-time-" .. entry.id, tostring(entry.updated_at or "") .. (entry.active and (" · " .. tr("panel.active_elsewhere")) or ""), 10),
    })
  end
  if #rows == 0 and state.sessionsLoading then
    rows[1] = ui.row({ key = "chats-loading", gap = 8, align = "center" }, {
      spinner("chats-loading-spinner", state, 13), muted("chats-loading-text", tr("panel.loading"), 12),
    })
  elseif #rows == 0 then
    rows[1] = muted("chats-empty", tr("panel.no_chats"), 12)
  end
  local children = {
    ui.row({ key = "chats-heading", gap = 8, align = "center" }, {
      ui.label({ key = "chats-title", text = tr("panel.chats"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ key = "chats-busy-spinner", text = state.sessionsLoading and spinnerText(state) or "", fontSize = 14, color = "primary" }),
      ui.button({ key = "chats-refresh", glyph = "refresh", tooltip = tr("panel.refresh"), variant = "ghost", onClick = function() actions.loadChats(0) end }),
      ui.button({ key = "chats-close", glyph = "x", tooltip = tr("panel.close"), variant = "ghost", onClick = actions.closeChats }),
    }),
    ui.input({ key = "chats-search-" .. tostring(state.pickerGen or 0), value = state.query, placeholder = tr("panel.search_chats"), focus = true, onChange = actions.searchChats,
      onSubmit = function() if not blocked then actions.openHighlightedChat() end end }),
    muted("chats-order", tr("panel.newest_first") .. " · " .. chatKeyHint(settings), 10),
  }
  if isBusy(m, state) then
    children[#children + 1] = ui.row({ key = "chats-running", gap = 8, align = "center" }, {
      muted("chats-busy", tr("panel.session_busy"), 12),
      ui.button({ key = "chats-stop", text = tr("panel.stop"), glyph = "player-stop-filled",
        variant = "outline", controlSize = "sm", onClick = actions.stop }),
    })
  end
  if state.activeWarning ~= nil then
    local selected = state.activeWarning
    children[#children + 1] = banner("chats-warning", "alert-triangle", tr("panel.session_active_elsewhere"), "info")
    children[#children + 1] = ui.button({ key = "chats-continue", text = tr("panel.continue_chat"), variant = "outline", enabled = not blocked, onClick = function() actions.selectChat(selected, true) end })
  end
  local highlighted = state.sessions[state.chatIndex or 1]
  children[#children + 1] = ui.scroll({ key = "chats-list", flexGrow = 1, gap = 6,
    revealKey = highlighted ~= nil and ("chat-" .. highlighted.id) or nil }, rows)
  children[#children + 1] = ui.row({ key = "chats-pages", gap = 8, align = "center" }, {
    ui.button({ key = "chats-prev", text = tr("panel.previous"), variant = "ghost", enabled = not state.sessionsLoading and state.sessionsOffset > 0, onClick = function() actions.loadChats(math.max(0, state.sessionsOffset - 30)) end }),
    muted("chats-count", tr("panel.chat_count", { n = state.sessionsTotal }), 11),
    ui.button({ key = "chats-next", text = tr("panel.next"), variant = "ghost", enabled = not state.sessionsLoading and state.sessionsOffset + 30 < state.sessionsTotal, onClick = function() actions.loadChats(state.sessionsOffset + 30) end }),
  })
  return ui.column({ key = "chats-picker", gap = 8, flexGrow = 1 }, children)
end

-- Explicit character limits: the host does not constrain scroll height.
local function compact(value, limit)
  local text = type(value) == "string" and string.gsub(value, "%s+", " ") or ""
  if (utf8.len(text) or #text) > limit then
    local at = utf8.offset(text, limit)
    text = string.sub(text, 1, (at or limit) - 1) .. "…"
  end
  return text
end

local controlSpecs = {
  { field = "model", key = "model", values = { "default", "fable", "opus", "sonnet", "haiku" } },
  { field = "effort", key = "effort", values = { "default", "low", "medium", "high", "xhigh", "max" } },
  { field = "permission_mode", key = "access", values = { "bypassPermissions", "default", "acceptEdits", "plan" } },
}

local function preferenceLabel(field, value)
  -- Translation keys are lowercase: acceptEdits -> accept_edits.
  local key = string.gsub(value, "%u", function(c) return "_" .. string.lower(c) end)
  return tr("panel.preference." .. field .. "." .. key)
end

local function controlRow(m, state, actions)
  local rows = {}
  local enabled = state.connected and not isBusy(m, state) and not state.preferencesLoading
  for _, spec in ipairs(controlSpecs) do
    local field = spec.field
    local value = state.preferences[field]
    local label = preferenceLabel(field, value)
    if value == "default" then label = tr("panel.preference.auto_short") end
    if value == "bypassPermissions" then label = "Bypass" end
    if value == "acceptEdits" then label = tr("panel.preference.edits_short") end
    rows[#rows + 1] = ui.button({ key = "control-" .. spec.key,
      text = tr("panel.control." .. spec.key) .. ": " .. compact(label, 14),
      tooltip = tr("panel.control." .. spec.key) .. ": " .. preferenceLabel(field, value),
      enabled = enabled, variant = "ghost", controlSize = "sm", onClick = function() actions.controls(field) end })
  end
  return ui.row({ key = "preference-controls", gap = 4, align = "center" }, rows)
end

local function preferenceMenu(m, state, actions)
  local rows = { ui.button({ key = "preferences-close", text = tr("panel.close"), variant = "ghost", controlSize = "sm", onClick = function() actions.controls(state.controlsMenu) end }) }
  for _, spec in ipairs(controlSpecs) do
    if spec.field == state.controlsMenu then
      for _, option in ipairs(spec.values) do
        local value, field = option, spec.field
        local selected = state.preferences[field] == value
        rows[#rows + 1] = ui.column({ key = "preference-" .. field .. "-" .. value, padding = 6, radius = 6,
          fill = selected and "surface_container_high" or "surface_container", onClick = function() actions.setPreference(field, value) end }, {
          ui.label({ key = "preference-label-" .. value, text = (selected and "✓ " or "") .. preferenceLabel(field, value), fontSize = 12, maxLines = 1 }),
        })
      end
    end
  end
  return ui.column({ key = "preferences-menu", gap = 4, flexGrow = 1 }, rows)
end

local function suggestions(state, actions, settings)
  local rows = {
    ui.row({ key = "commands-heading", align = "center", gap = 6 }, withKeyHint({
      ui.label({ key = "commands-title", text = tr("panel.commands"), fontSize = 11, flexGrow = 1, color = "on_surface_variant" }),
      ui.button({ key = "commands-dismiss", glyph = "x", tooltip = tr("panel.close"), controlSize = "sm", variant = "ghost", onClick = actions.dismissSuggestions }),
    }, "commands-keys", settings)),
  }
  local page = state.suggestionsPage or 0
  for index = page * 4 + 1, math.min(#state.suggestions, page * 4 + 4) do
    local entry = state.suggestions[index]
    rows[#rows + 1] = ui.column(highlight({ key = "command-" .. entry.name, gap = 2, padding = 6, radius = 6, fill = "surface_container_high", onClick = function() actions.chooseCommand(entry) end }, index == (state.suggestionIndex or 1)), {
      ui.label({ key = "command-name-" .. entry.name, text = compact("/" .. entry.name, 60), maxLines = 1, fontSize = 12, color = "primary" }),
      ui.label({ key = "command-description-" .. entry.name, text = compact(entry.description, 95), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    })
  end
  rows[#rows + 1] = ui.row({ key = "commands-pages", gap = 6 }, {
    ui.button({ key = "commands-prev", text = tr("panel.previous"), controlSize = "sm", variant = "ghost", enabled = page > 0, onClick = function() actions.suggestionPage(page - 1) end }),
    muted("commands-page", tostring(page + 1) .. "/" .. tostring(math.max(1, math.ceil(#state.suggestions / 4))), 10),
    ui.button({ key = "commands-next", text = tr("panel.next"), controlSize = "sm", variant = "ghost", enabled = (page + 1) * 4 < #state.suggestions, onClick = function() actions.suggestionPage(page + 1) end }),
  })
  return ui.column({ key = "commands", gap = 4 }, rows)
end

local function fileControls(state, actions, settings)
  local rows = {}
  if state.fileBrowser or state.pathsLoading or #state.paths > 0 then
    rows[#rows + 1] = ui.row({ key = "paths-heading", gap = 4, align = "center" }, withKeyHint({
      ui.label({ key = "paths-title", text = tr(state.fileBrowser and "panel.files" or "panel.references"), fontSize = 11, flexGrow = 1, maxLines = 1 }),
      ui.button({ key = "paths-parent", text = tr("panel.parent_directory"), glyph = "arrow-up", variant = "ghost", controlSize = "sm", enabled = state.fileBrowser and not state.switching, onClick = actions.parentFiles }),
      ui.button({ key = "paths-close", glyph = "x", tooltip = tr("panel.close"), variant = "ghost", controlSize = "sm", onClick = actions.closeFiles }),
    }, "paths-keys", #state.paths > 0 and settings or nil))
    if state.fileBrowser then
      rows[#rows + 1] = ui.row({ key = "files-typed", gap = 4 }, {
        ui.input({ key = "files-path", value = state.filePath or "", placeholder = tr("panel.file_path"), flexGrow = 1,
          enabled = not state.switching, onChange = actions.filePath,
          onSubmit = function(value) actions.submitFilePath(value) end }),
        ui.button({ key = "files-attach", text = tr("panel.attach_file"), variant = "ghost", controlSize = "sm",
          enabled = not state.switching and #(state.filePath or "") > 0,
          onClick = function() actions.attachFile(state.filePath or "") end }),
      })
      rows[#rows + 1] = ui.label({ key = "paths-directory", text = compact(state.pathsDirectory, 65), maxLines = 1, fontSize = 10, color = "on_surface_variant" })
    end
    if state.pathsLoading or #state.paths == 0 then
      rows[#rows + 1] = state.pathsLoading and ui.row({ key = "paths-loading", gap = 6, align = "center" }, {
        spinner("paths-loading-spinner", state, 12), muted("paths-loading-text", tr("panel.loading"), 11),
      }) or muted("paths-empty", tr("panel.no_files"), 11)
    end
    for index = 1, math.min(4, #state.paths) do
      local entry = state.paths[index]
      rows[#rows + 1] = ui.row(highlight({ key = "path-" .. tostring(index), gap = 6, padding = 5, radius = 6, fill = "surface_container_high",
        onClick = function() actions.choosePath(entry) end }, index == (state.pathIndex or 1)), {
        ui.glyph({ key = "path-icon-" .. tostring(index), name = entry.is_dir and "folder" or "file", size = 14 }),
        ui.label({ key = "path-label-" .. tostring(index), text = compact(entry.relative or entry.name, 65), maxLines = 1, fontSize = 12, flexGrow = 1 }),
      })
    end
    rows[#rows + 1] = ui.row({ key = "paths-pages", gap = 4 }, {
      ui.button({ key = "paths-prev", text = tr("panel.previous"), variant = "ghost", controlSize = "sm", enabled = not state.pathsLoading and state.pathsOffset > 0, onClick = function() actions.loadPaths(math.max(0, state.pathsOffset - 4)) end }),
      ui.label({ key = "paths-count", text = tostring(state.pathsOffset + 1) .. " / " .. tostring(state.pathsTotal), fontSize = 10, flexGrow = 1, maxLines = 1 }),
      ui.button({ key = "paths-next", text = tr("panel.next"), variant = "ghost", controlSize = "sm", enabled = not state.pathsLoading and state.pathsOffset + 4 < state.pathsTotal, onClick = function() actions.loadPaths(state.pathsOffset + 4) end }),
    })
    if state.pathsTruncated then rows[#rows + 1] = muted("paths-truncated", tr("panel.paths_truncated"), 10) end
  end
  -- Five compact rows at most, each holding two removable file chips.
  for index = 1, #state.attachments, 2 do
    local chips = {}
    for i = index, math.min(index + 1, #state.attachments) do
      local item = state.attachments[i]
      chips[#chips + 1] = ui.button({ key = "attachment-" .. tostring(item.id), text = compact(item.name, 24), glyph = "x",
        tooltip = tr("panel.remove_attachment") .. ": " .. item.path, variant = "outline", controlSize = "sm", enabled = not state.switching,
        onClick = function() actions.removeAttachment(item.id) end })
    end
    rows[#rows + 1] = ui.row({ key = "attachment-row-" .. tostring(index), gap = 4 }, chips)
  end
  return ui.column({ key = "file-controls", gap = 3 }, rows)
end

function M.panel(m, ui_state, settings, actions)
  local children = {
    header(m, ui_state, actions),
    ui.separator({ key = "header-sep", color = "outline_variant" }),
  }
  if ui_state.picker then
    children[#children + 1] = picker(m, ui_state, actions, settings)
  elseif ui_state.controlsMenu ~= nil and not isBusy(m, ui_state) then
    children[#children + 1] = preferenceMenu(m, ui_state, actions)
  else
    local controls = {
      ui.button({ key = "history-older", text = ui_state.historyLoading and (spinnerText(ui_state) .. " " .. tr("panel.loading")) or tr("panel.older_history"), variant = "ghost", controlSize = "sm", enabled = ui_state.connected and not ui_state.historyLoading and not ui_state.switching and (ui_state.historyPage ~= nil and ui_state.historyOffset > 0 or ui_state.historyPage == nil and (ui_state.historyStart == nil or ui_state.historyStart > 0 or m.evicted == true)), onClick = function()
        local offset = ui_state.historyPage ~= nil and ui_state.historyOffset or ui_state.historyStart
        if ui_state.historyPage == nil and m.evicted then offset = nil end
        actions.history(offset ~= nil and math.max(0, offset - 100) or nil)
      end }),
    }
    if ui_state.historyPage ~= nil then
      controls[#controls + 1] = muted("history-position", tr("panel.history_position", { n = math.min(ui_state.historyOffset + 1, ui_state.historyTotal), total = ui_state.historyTotal }), 10)
      controls[#controls + 1] = ui.button({ key = "history-latest", text = tr("panel.latest"), variant = "ghost", controlSize = "sm", onClick = actions.latest })
    end
    children[#children + 1] = ui.row({ key = "history-controls", gap = 6, align = "center" }, controls)
    children[#children + 1] = feed(m, ui_state, settings, actions)
  end
  for _, node in ipairs(banners(ui_state)) do children[#children + 1] = node end
  if not ui_state.picker then
    children[#children + 1] = controlRow(m, ui_state, actions)
    if not ui_state.fileBrowser and #ui_state.paths == 0 and ui_state.controlsMenu == nil and #ui_state.suggestions > 0 then children[#children + 1] = suggestions(ui_state, actions, settings) end
    children[#children + 1] = fileControls(ui_state, actions, settings)
    children[#children + 1] = composer(m, ui_state, settings, actions)
  end
  return ui.column({ key = "root", gap = 10, flexGrow = 1 }, children)
end

return M
