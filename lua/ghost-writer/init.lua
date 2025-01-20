local M = {}
local defaults = {}
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

local waiting_states = {}

local function waiting(buf)
	local char_seq = { "\\", "-", "/" }

	local timer = vim.loop.new_timer()
	local index = 1

	local line_count = vim.api.nvim_buf_line_count(buf)

	-- add two lines to the end of the buffer
	vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", "" })
	local spinner_loc = line_count + 2

	timer:start(
		0,
		200,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(buf) then
				-- loading spinner to bottom
				vim.api.nvim_buf_set_lines(buf, spinner_loc - 1, spinner_loc, false, { char_seq[index] })
				cursor_to_bottom(buf)
				index = index % #char_seq + 1
			end
		end)
	)
	return timer
end

local function parse_and_output_message(buf, result)
	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end

		local success, parsed = pcall(vim.json.decode, result)
		if not success then
			parsed = { text = result }
		end

		local text = parsed.delta and parsed.delta.text or parsed.text
		local result_lines = vim.split(text, "\n", { plain = true })
		local line_count = vim.api.nvim_buf_line_count(buf)
		local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1]

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
		cursor_to_bottom(buf)
	end)
end

local anthropic_opts = {
	url = "https://api.anthropic.com/v1/messages",
	model = "claude-3-5-sonnet-20241022",
	target_state = "content_block_delta",
	api_key_name = "ANTHROPIC_API_KEY",
	system_prompt = helpful_prompt,
	replace = false,
}

function M.get_anthropic_specific_args(opts, prompt)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key("ANTHROPIC_API_KEY")

	local data = {
		system = opts.system_prompt,
		max_tokens = 2048,
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
		-- Check if this is a state we want to handle
		if state ~= opts.target_state then
			return
		end

		manage_task(task)

		local success, json = pcall(vim.json.decode, stream)
		if success and json.delta and json.delta.text then
			parse_and_output_message(buf, json.delta.text)
		end
	end
end

M.providers = {
	anthropic = {
		target_state = "content_block_delta",
	},

	-- Example for another provider
	-- openai = {
	--     target_state = "data", -- OpenAI-specific state
	--     parse_stream = function(stream)
	--         return pcall(vim.json.decode, stream)
	--     end,
	--     extract_content = function(parsed_data)
	--         return parsed_data.choices and parsed_data.choices[1].delta.content
	--     end
	-- }
}
-- function M.anthropic_spec_data(stream, state, buf, task)
-- 	if state == "content_block_delta" then
-- 		local task_id = tostring(task)
-- 		if task and not waiting_states[task_id] then
-- 			task:stop()
-- 			task:close()
-- 			waiting_states[task_id] = true
-- 		end
--
-- 		local success, json = pcall(vim.json.decode, stream)
-- 		if success and json.delta and json.delta.text then
-- 			M.parse_message(buf, json.delta.text)
-- 		end
-- 	end
-- end

local group = vim.api.nvim_create_augroup("LLM", { clear = true })
local active_job = nil

function M.make_request(tokens, curl_args_fn, buf)
	local provider = M.config.default
	local provider_opts = M.config.providers[provider]

	vim.api.nvim_clear_autocmds({ group = group })
	local curr_event_state = nil
	local waiting_task = waiting(buf)

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	local local_args = curl_args_fn(provider_opts, tokens)

	local function handle_stdout(data, curr_state, buffer, task, handle_data_fn)
		if not data then
			return
		end

		write_debug("STDOUT: " .. vim.inspect(data))
		local event = data:match("^event: (.+)$")
		if event then
			return event
		end

		local data_match = data:match("^data: (.+)$")
		if data_match then
			handle_data_fn(data_match, curr_state, buffer, task)
		end
		return curr_state
	end

	active_job = Job:new({
		command = "curl",
		args = local_args,
		on_stdout = function(_, data)
			curr_event_state =
				handle_stdout(data, curr_event_state, buf, waiting_task, M.handle_stream_data(provider_opts))
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
				return nil
			end
		end
	end

	local function request()
		if context and vim.api.nvim_buf_is_valid(context.buf) then
			local lines = vim.api.nvim_buf_get_lines(context.buf, 0, -1, false)
			local message = table.concat(lines, "\n")
			M.make_request(message, M.get_anthropic_specific_args, context.buf)
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

-- [[
-- TODO:
-- clean up funcions specific to anthropic and make more generic WIP
-- add capability for other apis
-- move most config based code to setup in nvim config
-- fix this bug:
-- Error executing vim.schedule lua callback: ...ode/personal/ghost-writer.nvim/lua/ghost-writer/init.lua:78: 'replacement string' item contains newlines
-- stack traceback:
--         [C]: in function 'nvim_buf_set_lines'
--         ...ode/personal/ghost-writer.nvim/lua/ghost-writer/init.lua:78: in function <...ode/personal/ghost-writer.nvim/lua/ghost-writer/init.lua:61>
--
-- ]]

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", defaults, opts or {})
	print(vim.inspect(M.config))
	local manager = M.state_manager()

	-- Set up global keymaps
	for action, keymap in pairs(M.config.keymaps) do
		if action ~= "buffer" then
			vim.keymap.set("n", keymap.key, manager[action], {
				desc = keymap.desc,
				noremap = true,
				silent = true,
			})
		end
	end
end

return M
