if vim.g.loaded_docusaurus then
	return
end

vim.g.loaded_docusaurus = true

-- Single entry point command with tab completion
vim.api.nvim_create_user_command("Docusaurus", function(opts)
	require("docusaurus").run_command(opts)
end, {
	nargs = "?",
	complete = function(arg_lead, cmd_line, cursor_pos)
		local subcmds = require("docusaurus").get_subcommands()
		-- Filter based on what user has typed
		if arg_lead == "" then
			return subcmds
		end
		local matches = {}
		for _, cmd in ipairs(subcmds) do
			if cmd:sub(1, #arg_lead) == arg_lead then
				table.insert(matches, cmd)
			end
		end
		return matches
	end,
	desc = "Docusaurus commands - run without args to see all options",
})
