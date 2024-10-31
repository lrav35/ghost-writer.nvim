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
	print("hello from the plugin!")
	M.make_request("hello world!")
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
