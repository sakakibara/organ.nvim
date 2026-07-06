-- lua/organ/modern/badge.lua
-- The one place a rounded, reversed badge is built and drawn, so every
-- badge in modern mode (TODO/state, later priority/tags) is identical in
-- shape. The body group must NOT link (nvim_set_hl drops gui attributes
-- when link is present); it copies the resolved fg and applies reverse. The
-- caps are INLINE virt_text placed at the range boundaries so the buffer's
-- surrounding spaces stay intact -- that is what gives the badge breathing
-- room instead of hugging the bullet and the title.

local M = {}

function M.groups(name, color_group)
  local color = require("organ.highlights").resolved_fg(color_group)
  local body = "@organ.modern.badge." .. name
  local cap = "@organ.modern.badgecap." .. name
  if color then
    vim.api.nvim_set_hl(0, body, { fg = color, reverse = true, bold = true })
    vim.api.nvim_set_hl(0, cap, { fg = color })
  end
  return body, cap
end

function M.emit(ns, bufnr, row, sc, ec, opts)
  local eph = opts.ephemeral or nil
  local pri = opts.priority or 200
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, sc, {
    end_col = ec,
    hl_group = opts.body_hl,
    priority = pri,
    ephemeral = eph,
  })
  if opts.left_cap and opts.left_cap ~= "" then
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, sc, {
      virt_text = { { opts.left_cap, opts.cap_hl } },
      virt_text_pos = "inline",
      priority = pri,
      ephemeral = eph,
    })
  end
  if opts.right_cap and opts.right_cap ~= "" then
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, ec, {
      virt_text = { { opts.right_cap, opts.cap_hl } },
      virt_text_pos = "inline",
      priority = pri,
      ephemeral = eph,
    })
  end
end

return M
