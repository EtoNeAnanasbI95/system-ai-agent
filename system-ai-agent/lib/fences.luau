--!nonstrict
-- Splits Markdown into prose and fenced code blocks, so each code block can get its own
-- Copy button (ui.markdown renders one read-only block with no per-block controls).
--
--   Fences.split(text) -> { { kind = "md", text } | { kind = "code", lang, code, closed } }
--   Fences.wrap(lang, code) -> "```lang\n...\n```" with a fence longer than any backtick run inside
--
-- CommonMark subset: a fence is 3+ backticks or tildes indented by at most 3 spaces; it closes on
-- a line of the same character at least as long. An unclosed fence (still streaming) runs to the
-- end with closed = false.

local Fences = {}

local function opening(line)
  local fence, info = string.match(line, "^ ? ? ?(```+)(.*)$")
  if fence ~= nil and string.find(info, "`", 1, true) ~= nil then
    fence = nil -- a backtick fence's info string may not contain backticks (inline code)
  end
  if fence == nil then
    fence, info = string.match(line, "^ ? ? ?(~~~+)(.*)$")
  end
  if fence == nil then
    return nil
  end
  return string.sub(fence, 1, 1), #fence, string.match(info, "^%s*(%S*)") or ""
end

function Fences.split(text)
  local segments = {}
  local prose = {}
  local code, char, length, lang = nil, nil, 0, ""

  local function flushProse()
    if #prose > 0 then
      local chunk = table.concat(prose, "\n")
      if string.find(chunk, "%S") ~= nil then
        segments[#segments + 1] = { kind = "md", text = chunk }
      end
      prose = {}
    end
  end

  for line in string.gmatch(text .. "\n", "(.-)\n") do
    if code == nil then
      local c, n, info = opening(line)
      if c ~= nil then
        flushProse()
        code, char, length, lang = {}, c, n, info
      else
        prose[#prose + 1] = line
      end
    else
      local run = string.match(line, "^ ? ? ?([`~]+)%s*$")
      if run ~= nil and string.sub(run, 1, 1) == char and #run >= length
        and string.find(run, char == "`" and "~" or "`", 1, true) == nil then
        segments[#segments + 1] = { kind = "code", lang = lang, code = table.concat(code, "\n"), closed = true }
        code = nil
      else
        code[#code + 1] = line
      end
    end
  end
  if code ~= nil then
    -- the split added a final "\n"; drop the empty line it produced inside the open block
    if #code > 0 and code[#code] == "" then
      code[#code] = nil
    end
    segments[#segments + 1] = { kind = "code", lang = lang, code = table.concat(code, "\n"), closed = false }
  end
  flushProse()
  return segments
end

function Fences.wrap(lang, code)
  local longest = 0
  for run in string.gmatch(code, "`+") do
    if #run > longest then
      longest = #run
    end
  end
  local fence = string.rep("`", math.max(3, longest + 1))
  return fence .. (lang or "") .. "\n" .. code .. "\n" .. fence
end

return Fences
