local M = {}
local http = require("plenary.job")

local function waiting(buf)
	local char_seq = { "\\", "-", "/" }

	local timer = vim.loop.new_timer()
	local index = 1

	timer:start(
		0,
		200,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(buf) then
				local line_count = vim.api.nvim_buf_line_count(buf)
				print(line_count)
				local new_line_idx = line_count - 1
				vim.api.nvim_buf_set_lines(buf, 2, new_line_idx + 1, false, { char_seq[index] })

				index = index % #char_seq + 1
			end
		end)
	)

	return timer
end

function M.parse_message(buf, result, waiting_task)
	vim.schedule(function()
		if waiting_task then
			local line_count = vim.api.nvim_buf_line_count(buf)
			vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "" })
			waiting_task:stop()
			waiting_task:close()
		end

		if vim.api.nvim_buf_is_valid(buf) then
			local response = table.concat(result, "\n")

			local success, res_json = pcall(vim.json.decode, response)
			if success and res_json and res_json.message then
				local message = res_json.message

				local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local line_count = #lines

				vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", message })
			end
		end
	end)
end

function M.make_request(tokens, buf)
	local req = string.format('{"message":"%s"}', tokens)

	local waiting_task = waiting(buf)
	http:new({
		command = "curl",
		args = {
			"-X",
			"POST",
			"http://localhost:8000/test",
			"-H",
			"Content-Type: application/json",
			"-d",
			req,
		},
		on_exit = function(job, return_val)
			if return_val == 0 then
				local result = job:result()
				M.parse_message(buf, result, waiting_task)
			else
				print("request failed :(")
			end
		end,
	}):start()
end

function M.state_manager()
	print("loading plugin...")
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

	local function request()
		if context and vim.api.nvim_buf_is_valid(context.buf) then
			local lines = vim.api.nvim_buf_get_lines(context.buf, 0, -1, false)
			local message = table.concat(lines, "\n")
			M.make_request(message, context.buf)
		end
	end

	return {
		open = function()
			create_win_and_buf()
		end,
		close = function()
			context = destroy()
		end,
		prompt = function()
			request()
		end,
	}
end

function M.setup()
	local manager = M.state_manager()

	vim.keymap.set("n", "<leader>wo", manager.open, { desc = "[W]indow [O]pen Chat", noremap = true, silent = true })
	vim.keymap.set("n", "<leader>wc", manager.close, { desc = "[W]indow [C]lose", noremap = true, silent = true })
	vim.keymap.set("n", "<leader>p", manager.prompt, { desc = "[P]rompt", noremap = true, silent = true })
end

return M
