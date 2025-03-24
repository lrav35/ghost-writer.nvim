local M = {}
local waiting_states = {}
local Job = require("plenary.job")
local conversation_history = {}
local response = ""
local ASSISTANT_START = "<assistant--->"
local ASSISTANT_END = "<---assistant>"

local function write_debug(message)
	if M.config.debug then
		local debug_file = io.open("debug.log", "a")
		if debug_file then
			debug_file:write(os.date() .. " - " .. message .. "\n")
			debug_file:close()
		end
	end
end

local function cursor_to_bottom(buf)
	local win_id = vim.fn.bufwinid(buf)
	if win_id ~= -1 then
		local line_count = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(win_id, { line_count, 0 })
	end
end

local function waiting(buf)
	local char_seq = { "-", "\\", "/" }
	local timer = vim.loop.new_timer()
	local index = 1
	local line_count = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { ASSISTANT_START, char_seq[index] })
	local spinner_line = line_count + 1
	timer:start(
		0,
		200,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_set_lines(buf, spinner_line, spinner_line + 1, false, { char_seq[index] })
				cursor_to_bottom(buf)
				index = index % #char_seq + 1
			end
		end)
	)
	return timer
end

local function parse_and_output_message(buf, result, spinner_timer)
	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end

		-- Parse the JSON result, fallback to raw text if parsing fails
		local success, parsed = pcall(vim.json.decode, result)
		local text = parsed.delta and parsed.delta.text or (success and parsed.text) or result
		if not text or text == "" then
			return
		end

		-- Get current buffer state
		local line_count = vim.api.nvim_buf_line_count(buf)
		local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
		local second_to_last_line = vim.api.nvim_buf_get_lines(buf, line_count - 2, line_count - 1, false)[1] or ""

		-- Accumulate response
		response = response .. text

		-- Split text by newlines to handle multi-line chunks
		local new_lines = vim.split(text, "\n", { plain = true })

		-- Prepare output lines
		local output_lines = {}
		if last_line:match("^[-/\\]$") and second_to_last_line == ASSISTANT_START then
			-- Replace spinner, keeping ASSISTANT_START on its own line
			if spinner_timer then
				spinner_timer:stop()
				spinner_timer:close()
			end
			table.insert(output_lines, ASSISTANT_START) -- Keep tag on its own line
			for i, line in ipairs(new_lines) do
				table.insert(output_lines, line) -- Start text on next line
			end
		else
			-- Append to the last non-tag line, preserving ASSISTANT_START on its own
			local start_idx = line_count - 1
			if second_to_last_line == ASSISTANT_START then
				start_idx = line_count - 2 -- Adjust to append after ASSISTANT_START
				table.insert(output_lines, ASSISTANT_START)
			end
			local updated_last_line = last_line .. new_lines[1]
			table.insert(output_lines, updated_last_line)
			for i = 2, #new_lines do
				table.insert(output_lines, new_lines[i])
			end
		end

		-- Update buffer: replace from the spinner line or append after ASSISTANT_START
		local start_line = (last_line:match("^[-/\\]$") and second_to_last_line == ASSISTANT_START) and (line_count - 2)
			or (line_count - 1)
		if second_to_last_line == ASSISTANT_START and not last_line:match("^[-/\\]$") then
			start_line = line_count - 2 -- Append after ASSISTANT_START
		end
		vim.api.nvim_buf_set_lines(buf, start_line, line_count, false, output_lines)
		cursor_to_bottom(buf)
	end)
end

local function manage_task(task)
	if not task then
		return
	end
	local task_id = tostring(task)
	if not waiting_states[task_id] then
		task:stop()
		task:close()
		waiting_states[task_id] = true
	end
end

function M.handle_stream_data(opts)
	return function(stream, state, buf, task)
		if opts.event_based and state ~= opts.target_state then
			return
		end

		manage_task(task)

		local content = opts.parser(stream)
		if content then
			parse_and_output_message(buf, content)
		end
	end
end

local group = vim.api.nvim_create_augroup("LLM", { clear = true })
local active_job = nil

local function parse_stream(data, event_based)
	if event_based and data:match("^event: ") then
		return "event", data:match("^event: (.+)$")
	end
	if data:match("^data: ") then
		return "data", data:match("^data: (.+)$")
	end
end

function M.make_request(messages, buf)
	local provider = M.config.default
	local provider_opts = M.config.providers[provider]
	local curl_args_fn = provider_opts.curl_args_fn
	provider_opts.system_prompt = M.config.system_prompt

	vim.api.nvim_clear_autocmds({ group = group })
	local curr_event_state = nil
	local waiting_task = waiting(buf)

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	local formatted_messages = messages

	local local_args = curl_args_fn(provider_opts, formatted_messages)

	local function handle_stdout(data, curr_state, buffer, task, handle_data_fn, opts)
		if not data then
			return curr_state
		end

		local type, content = parse_stream(data, opts.event_based)

		if type == "data" then
			handle_data_fn(content, curr_state, buffer, task)
		end

		return type == "event" and content or curr_state
	end

	active_job = Job:new({
		command = "curl",
		args = local_args,
		on_stdout = function(_, data)
			write_debug("STDOUT: " .. vim.inspect(data))
			curr_event_state = handle_stdout(
				data,
				curr_event_state,
				buf,
				waiting_task,
				M.handle_stream_data(provider_opts),
				provider_opts
			)
		end,
		on_stderr = function(_, data)
			write_debug("STDERR: " .. vim.inspect(data))
		end,
		on_exit = function(_, data)
			write_debug("STDEXIT: " .. vim.inspect(data))
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(buf) then
					local line_count = vim.api.nvim_buf_line_count(buf)
					local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1]
					if not last_line:match(ASSISTANT_END) then
						vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { last_line, ASSISTANT_END })
					end
				end
			end)
			table.insert(conversation_history, {
				role = "assistant",
				content = response,
			})
			response = ""
			active_job = nil
		end,
		stdout_buffered = false,
		stderr_buffered = false,
	})

	active_job:start()

	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = M.config.keymaps.escape.pattern,
		callback = function()
			if active_job then
				active_job:shutdown()
				print("model streaming cancelled")
				active_job = nil
			end
		end,
	})

	vim.keymap.set(
		"n",
		M.config.keymaps.escape.key,
		string.format(":doautocmd User %s<CR>", M.config.keymaps.escape.pattern),
		{ noremap = true, silent = true }
	)

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

	local function setup_autocmd(buffer)
		vim.api.nvim_create_autocmd("InsertEnter", {
			group = vim.api.nvim_create_augroup("NotePanel", { clear = true }),
			callback = function()
				if vim.api.nvim_get_current_buf() == buffer then
					local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
					if #lines == 1 and lines[1] == M.config.ui.default_message then
						vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "" })
					end
				end
			end,
		})
	end

	local function resize_window(direction)
		local amount = 5
		local commands = {
			right = "vertical resize -" .. amount,
			left = "vertical resize +" .. amount,
		}
		vim.cmd(commands[direction])
	end

	local function setup_keybindings(buffer)
		local opts = { noremap = true, silent = true, buffer = buffer }
		vim.keymap.set("n", M.config.keymaps.buffer.resize_left.key, function()
			resize_window("left")
		end, opts)
		vim.keymap.set("n", M.config.keymaps.buffer.resize_right.key, function()
			resize_window("right")
		end, opts)
	end

	local function create_win_and_buf()
		if context then
			return context
		end

		local buffer = setup_buffer(vim.api.nvim_create_buf(false, true))

		-- window width
		vim.cmd(M.config.ui.window_width .. "vsplit")
		local window = setup_window(vim.api.nvim_get_current_win())

		vim.api.nvim_win_set_buf(window, buffer)

		vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { M.config.ui.default_message })

		setup_autocmd(buffer)
		setup_keybindings(buffer)
		context = { buf = buffer, win = window }
		return context
	end

	local function destroy()
		if context then
			if vim.api.nvim_buf_is_valid(context.buf) and vim.api.nvim_win_is_valid(context.win) then
				vim.api.nvim_buf_delete(context.buf, { force = true })
				conversation_history = {}
				return nil
			end
		end
	end

	local function get_user_prompt_toks(buf)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local message = ""

		local marker_index
		for i = #lines, 1, -1 do
			if lines[i]:match(vim.pesc(ASSISTANT_END)) then
				marker_index = i
				break
			end
		end

		local relevant_lines = {}
		if marker_index then
			for i = marker_index + 1, #lines, 1 do
				if lines[i] and lines[i]:match("%S") then -- Only add non-empty lines
					table.insert(relevant_lines, lines[i])
				end
			end
		else
			relevant_lines = lines
		end

		message = table.concat(relevant_lines, "\n")
		return message
	end

	local function request()
		if context and vim.api.nvim_buf_is_valid(context.buf) then
			local user_message = get_user_prompt_toks(context.buf)

			if user_message ~= "" then
				table.insert(conversation_history, {
					role = "user",
					content = user_message,
				})

				M.make_request(conversation_history, context.buf)
			end
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

function M.setup(opts)
	M.config = opts
	local manager = M.state_manager()
	local global_actions = { open = true, exit = true, prompt = true, reset = true }

	-- Set up global keymaps
	for action, keymap in pairs(M.config.keymaps) do
		if global_actions[action] then
			vim.keymap.set("n", keymap.key, manager[action], {
				desc = keymap.desc,
				noremap = true,
				silent = true,
			})
		end
	end
end

return M
