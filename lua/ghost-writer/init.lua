local M = {}
local Job = require("plenary.job")

local helpful_prompt =
	"you are a helpful assistant, what I am sending you may be notes, code or context provided by our previous conversation"

local function waiting(buf)
	local char_seq = { "\\", "-", "/" }

	local timer = vim.loop.new_timer()
	local index = 1

	timer:start(
		0,
		200,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(buf) then
				local cursor_pos = vim.api.nvim_win_get_cursor(0)
				local line_idx = cursor_pos[1] + 2

				local line_count = vim.api.nvim_buf_line_count(buf)
				if line_idx > line_count then
					vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", "" })
				end

				vim.api.nvim_buf_set_lines(buf, line_idx - 1, line_idx, false, { char_seq[index] })
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
			local current_window = vim.api.nvim_get_current_win()

			local cursor_position = vim.api.nvim_win_get_cursor(current_window)
			local row, col = cursor_position[1], cursor_position[2]

			local lines = vim.split(result, "\n")
			vim.cmd("undojoin")
			vim.api.nvim_put(lines, "c", true, true)
			local num_lines = #lines
			local last_line_length = #lines[num_lines]
			vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
		end
	end)
end

local anthropic_opts = {
	url = "https://api.anthropic.com/v1/messages",
	model = "claude-3-5-sonnet-20241022",

	api_key_name = "ANTHROPIC_API_KEY",
	system_prompt = helpful_prompt,
	replace = false,
}

function M.get_anthropic_specific_args(opts, prompt)
	local url = opts.url
	local system_prompt = opts.system_prompt
	--TODO: make this a env variable
	local api_key = opts.api_key_name and "REDACTED"

	local data = {
		messages = { { role = "system", content = system_prompt }, { role = "user", content = prompt } },
		model = opts.model,
		stream = true,
	}
	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)
	return args
end

function M.anthropic_spec_data(stream, state, buf, task)
	if state == "event_block_delta" then
		local json = vim.json.decode(stream)
		if json.delta and json.delta.text then
			print("got here")
			M.parse_message(buf, json.delta.text, task)
		end
	end
end

local group = vim.api.nvim_create_augroup("sup", { clear = true })
local active_job = nil

function M.make_request(tokens, opts, curl_args_fn, buf)
	vim.api.nvim_clear_autocmds({ group = group })
	local prompt = tokens
	local system_prompt = opts.system_prompt
	local args = curl_args_fn(opts, prompt, system_prompt)
	print(vim.inspect(args))
	local curr_event_state = nil

	local json_data = { message = tokens }

	local req, err = vim.json.encode(json_data)
	if not req then
		print("Error encoding JSON", err)
		return
	end

	local waiting_task = waiting(buf)

	local function parse_and_call(result)
		local event = result:match("^event: (.+)$")
		if event then
			curr_event_state = event
			return
		end
		local data_match = result:match("^data: (.+)$")
		if data_match then
			M.anthropic_spec_data(data_match, curr_event_state, buf, waiting_task)
		end
	end

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	local function log_error_to_file(data)
		local log_file = "error_log.txt" -- Specify the log file path
		local file, err = io.open(log_file, "a") -- Open the file in append mode

		if not file then
			print("Failed to open log file:", err)
			return
		end

		file:write(os.date("[%Y-%m-%d %H:%M:%S]"), " ", data, "\n") -- Write timestamp and error message
		file:close() -- Close the file
	end

	active_job = Job:new({
		command = "curl",
		args = { "-s", "-v", args },
		on_stdout = function(_, out)
			--TODO: handle streaming now, this wont work yet
			parse_and_call(out)
		end,
		on_stderr = function(_, data)
			print("failed, printing to error_log.txt")
			log_error_to_file(data)
		end,
		on_exit = function()
			active_job = nil
		end,
	})

	active_job:start()

	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "DING_LLM_Escape",
		callback = function()
			if active_job then
				active_job:shutdown()
				print("LLM streaming cancelled")
				active_job = nil
			end
		end,
	})

	vim.api.nvim_set_keymap("n", "<Esc>", ":doautocmd User DING_LLM_Escape<CR>", { noremap = true, silent = true })
	return active_job
end

function M.state_manager()
	local context = nil

	local function create_win_and_buf()
		if not context then
			local buffer = vim.api.nvim_create_buf(false, true)
			local start_message = "hello, how can I assist you?"

			vim.cmd("70vsplit")
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
			M.make_request(message, anthropic_opts, M.get_anthropic_specific_args, context.buf)
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
