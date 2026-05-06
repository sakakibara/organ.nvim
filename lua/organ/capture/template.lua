-- Capture template validation, lookup, normalisation.

local M = {}

local VALID_KINDS = {
  file = true,
  file_headline = true,
  file_olp = true,
  file_olp_datetree = true,
  file_function = true,
  file_regexp = true,
}

local function validate_one(t, idx)
  local prefix = string.format("template[%d] (%s)", idx, t.name or "?")
  if type(t.name) ~= "string" or t.name == "" then
    error(prefix .. ": missing or empty name")
  end
  if type(t.target) ~= "table" then
    error(prefix .. ": missing target")
  end
  if not VALID_KINDS[t.target.kind] then
    error(prefix .. ": unknown target.kind '" .. tostring(t.target.kind) .. "'")
  end
  if
    t.target.kind ~= "file_function" and (type(t.target.path) ~= "string" or t.target.path == "")
  then
    error(prefix .. ": target.path required for kind " .. t.target.kind)
  end
  if
    t.target.kind == "file_headline"
    and (type(t.target.headline) ~= "string" or t.target.headline == "")
  then
    error(prefix .. ": target.headline required for file_headline")
  end
  if t.target.kind == "file_olp" then
    if type(t.target.olp) ~= "table" or #t.target.olp == 0 then
      error(prefix .. ": target.olp must be a non-empty list for file_olp")
    end
  end
  if t.target.kind == "file_function" and type(t.target.fn) ~= "function" then
    error(prefix .. ": target.fn must be a function for file_function")
  end
  if
    t.target.kind == "file_regexp" and (type(t.target.regexp) ~= "string" or t.target.regexp == "")
  then
    error(prefix .. ": target.regexp required (string Lua-pattern) for file_regexp")
  end
  if type(t.body) ~= "string" and type(t.body) ~= "function" then
    error(prefix .. ": body must be a string or function")
  end
end

function M.validate_all(templates)
  if type(templates) ~= "table" then
    error("capture.templates must be a list")
  end
  local seen_keys = {}
  for i, t in ipairs(templates) do
    validate_one(t, i)
    if t.key then
      if seen_keys[t.key] then
        error(
          string.format(
            "duplicate template key %q (templates[%d] and templates[%d])",
            t.key,
            seen_keys[t.key],
            i
          )
        )
      end
      seen_keys[t.key] = i
    end
  end
end

function M.find_by_key(templates, key)
  for _, t in ipairs(templates or {}) do
    if t.key == key then
      return t
    end
  end
  return nil
end

function M.normalise(t)
  -- Default to 0 blank-lines-before/after to match Emacs's
  -- org-capture-empty-lines-before / -after defaults.  Previous
  -- code defaulted to 1 before for "breathing room", but that
  -- inserted a blank between a parent headline (no body) and the
  -- child entry being captured -- visible as a stray fold marker.
  -- Templates that want the blank can opt in explicitly.
  local empty_lines_before = t.empty_lines_before
  if empty_lines_before == nil then
    empty_lines_before = 0
  end
  local empty_lines_after = t.empty_lines_after
  if empty_lines_after == nil then
    empty_lines_after = 0
  end
  local prepend = t.prepend
  if prepend == nil then
    prepend = false
  end
  return {
    name = t.name,
    description = t.description,
    key = t.key,
    target = t.target,
    body = t.body,
    empty_lines_before = empty_lines_before,
    empty_lines_after = empty_lines_after,
    prepend = prepend,
    jump_after_finalise = t.jump_after_finalise,
    on_finalise = t.on_finalise,
    compile_hooks = t.compile_hooks or {},
    whole_file = t.whole_file == true,
  }
end

-- Public: register an additional compile hook on a template at runtime.
-- Useful when the template comes from config but the hook is supplied
-- by a separate plugin. Idempotent — repeated calls append.
function M.add_compile_hook(template, fn)
  if type(template) ~= "table" or type(fn) ~= "function" then
    return
  end
  template.compile_hooks = template.compile_hooks or {}
  template.compile_hooks[#template.compile_hooks + 1] = fn
end

return M
