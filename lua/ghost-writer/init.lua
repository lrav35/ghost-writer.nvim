local M = {}
local augroup = vim.api.nvim_create_augroup("ScratchBuffer", { clear = true })
local http = require("plenary.job")

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

function M.run()
	M.open_chat_window()
	M.make_request()
end

function M.open_chat_window()
	local buffer = vim.api.nvim_create_buf(false, true)
	local start_message = "hello, how can I assist you?"

	vim.cmd("75vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buffer)

	vim.bo[buffer].buftype = "nofile"
	vim.bo[buffer].bufhidden = "wipe"
	vim.bo[buffer].swapfile = false
	vim.bo[buffer].filetype = "markdown"

	vim.wo[win].relativenumber = false

	vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { start_message })

	vim.api.nvim_create_autocmd("InsertEnter", {

		group = vim.api.nvim_create_augroup("NotePanel", { clear = true }),
		callback = function()
			-- TODO: this doesnt really work the way i want it to, getting invalid buffer id warnings
			local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
			if #lines == 1 and lines[1] == start_message then
				vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "" })
			end
		end,
	})

	vim.api.nvim_set_current_win(win)
end

function M.setup()
	vim.api.nvim_create_autocmd("VimEnter", {
		group = augroup,
		desc = "set a scratch buffer on load",
		once = true,
		callback = M.run,
	})
end

return M
