local M = {}
local http = require("plenary.job")

local function get_state(state)
	if state then
		print("buf_id: " .. state.buf .. " win_id: " .. state.win)
	else
		print(nil)
	end
end

function M.make_request(tokens)
	local req = string.format('{"message":"%s"}', tokens)
	http:new({
		command = "curl",
		args = {
			"-X",
			"POST",
			"http://localhost:8000/test",
			"-H",
			"Content-Type: applicatoin/json",
			"-d",
			req,
		},
		on_exit = function(job, return_val)
			if return_val == 0 then
				local result = job:result()
				print(table.concat(result, "\n"))
			else
				print("Request failed")
			end
		end,
	}):start()
end

function M.state_manager()
	print("manager being called...")
	local context = nil

	local function create_win_and_buf()
		if not context then
			local buffer = vim.api.nvim_create_buf(false, true)
			local start_message = "hello, how can I assist you?"

			vim.cmd("75vsplit")
			local window = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(window, buffer)

			vim.bo[buffer].buftype = "nofile"
			vim.bo[buffer].bufhidden = "wipe"
			vim.bo[buffer].swapfile = false
			vim.bo[buffer].filetype = "markdown"

			vim.wo[window].relativenumber = false

			vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { start_message })

			vim.api.nvim_create_autocmd("InsertEnter", {
				group = vim.api.nvim_create_augroup("NotePanel", { clear = true }),
				callback = function()
					if vim.api.nvim_get_current_buf() == buffer then
						local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
						if #lines == 1 and lines[1] == start_message then
							vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "" })
						end
					end
				end,
			})

			context = { buf = buffer, win = window }
		end
	end

	local function destroy()
		if context then
			if vim.api.nvim_buf_is_valid(context.buf) and vim.api.nvim_win_is_valid(context.win) then
				vim.api.nvim_buf_delete(context.buf, { force = true })
				return nil
			end
		end
	end

	return {
		open = function()
			create_win_and_buf()
			get_state(context)
		end,
		close = function()
			context = destroy()
		end,
	}
end

function M.setup()
	local manager = M.state_manager()

	vim.keymap.set("n", "<leader>wo", manager.open, { desc = "[W]indow [O]pen Chat", noremap = true, silent = true })
	vim.keymap.set("n", "<leader>wc", manager.close, { desc = "[W]indow [C]lose", noremap = true, silent = true })
end

return M
