local M = {}
local Job = require("plenary.job")

local helpful_prompt =
	"you are a helpful assistant, what I am sending you may be notes, code or context provided by our previous conversation"

local function get_api_key(name)
	if os.getenv(name) then
		return os.getenv(name)
	else
		return "not there, mate"
	end
end

local function write_debug(message)
	local debug_file = io.open("debug.log", "a")
	if debug_file then
		debug_file:write(os.date() .. " - " .. message .. "\n")
		debug_file:close()
	end
end

local waiting_states = {}

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

function M.parse_message(buf, result)
	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end

		local line_count = vim.api.nvim_buf_line_count(buf)
		local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1]

		local result_lines = vim.fn.split(result, "\n")

		if last_line:match("^[/-\\]$") then
			vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { "" })
			vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { result })
		else
			local current_response = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1]
			local first_line = current_response .. result_lines[1]
			local final_lines = { first_line }
			for i = 2, #result_lines do
				table.insert(final_lines, result_lines[i])
			end
			vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, final_lines)
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
	local api_key = opts.api_key_name and get_api_key("ANTHROPIC_API_KEY")

	local data = {
		system = opts.system_prompt,
		max_tokens = 1028,
		messages = { { role = "user", content = prompt } },
		model = opts.model,
		stream = true,
	}

	local json_data = vim.json.encode(data)

	local args = {
		"--no-buffer",
		"-N",
		url,
		"-H",
		"Content-Type: application/json",
		"-H",
		"anthropic-version: 2023-06-01",
		"-H",
		string.format("x-api-key: %s", api_key),
		"-d",
		json_data,
	}
	return args
end

function M.anthropic_spec_data(stream, state, buf, task)
	if state == "content_block_delta" then
		local task_id = tostring(task)
		if task and not waiting_states[task_id] then
			task:stop()
			task:close()
			waiting_states[task_id] = true
		end

		local success, json = pcall(vim.json.decode, stream)
		if success and json.delta and json.delta.text then
			M.parse_message(buf, json.delta.text)
		end
	end
end

local group = vim.api.nvim_create_augroup("sup", { clear = true })
local active_job = nil

function M.make_request(tokens, opts, curl_args_fn, buf)
	vim.api.nvim_clear_autocmds({ group = group })
	local curr_event_state = nil
	local waiting_task = waiting(buf)

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	local local_args = curl_args_fn(opts, tokens)

	active_job = Job:new({
		command = "curl",
		args = local_args,
		on_stdout = function(_, data)
			if data then
				local event = data:match("^event: (.+)$")
				if event then
					curr_event_state = event
				else
					local data_match = data:match("^data: (.+)$")
					if data_match then
						M.anthropic_spec_data(data_match, curr_event_state, buf, waiting_task)
					end
				end
			end
		end,
		on_stderr = function(_, data)
			write_debug("STDERR: " .. vim.inspect(data))
		end,
		on_exit = function(_)
			active_job = nil
		end,
		stdout_buffered = false,
		stderr_buffered = false,
	})

	active_job:start()

	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "model_escape_fn",
		callback = function()
			if active_job then
				active_job:shutdown()
				print("model streaming cancelled")
				active_job = nil
			end
		end,
	})

	vim.api.nvim_set_keymap("n", "<Esc>", ":doautocmd User model_escape_fn<CR>", { noremap = true, silent = true })
	return active_job
end

function M.state_manager()
	local context = nil

	local function setup_buffer(buffer)
		local bo = vim.bo[buffer]
		bo.buftype = "nofile"
		bo.bufhidden = "wipe"
		bo.swapfile = false
		bo.filetype = "markdown"
		return buffer
	end

	local function setup_window(window)
		vim.wo[window].relativenumber = false
		return window
	end

	local function setup_autocmd(buffer, start_message)
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
	end

	local function create_win_and_buf()
		local start_message = "hello, how can I assist you?"

		if context then
			return context
		end

		local buffer = setup_buffer(vim.api.nvim_create_buf(false, true))

		-- window width
		vim.cmd(70 .. "vsplit")
		local window = setup_window(vim.api.nvim_get_current_win())

		vim.api.nvim_win_set_buf(window, buffer)

		vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { start_message })

		setup_autocmd(buffer, start_message)
		context = { buf = buffer, win = window }
		return context
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
		exit = function()
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
	vim.keymap.set("n", "<leader>we", manager.exit, { desc = "[W]indow [E]xit", noremap = true, silent = true })
	vim.keymap.set("n", "<leader>p", manager.prompt, { desc = "[P]rompt", noremap = true, silent = true })
end

return M
