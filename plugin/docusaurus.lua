if vim.g.loaded_docusaurus then
	return
end

vim.g.loaded_docusaurus = true

-- Create user commands
vim.api.nvim_create_user_command("DocusaurusInsertComponent", function()
	require("docusaurus").select_component()
end, { desc = "Insert a Docusaurus component" })

vim.api.nvim_create_user_command("DocusaurusInsertPartial", function()
	require("docusaurus").select_partial()
end, { desc = "Insert a Docusaurus partial" })

vim.api.nvim_create_user_command("DocusaurusInsertCodeBlock", function()
	require("docusaurus").select_code_block()
end, { desc = "Insert a Docusaurus code block" })

vim.api.nvim_create_user_command("DocusaurusInsertURL", function()
	require("docusaurus").insert_url_reference()
end, { desc = "Insert a Docusaurus URL reference" })

vim.api.nvim_create_user_command("DocusaurusCreatePlugin", function()
	require("docusaurus").create_plugin()
end, { desc = "Scaffold a new Docusaurus plugin" })

vim.api.nvim_create_user_command("DocusaurusBrowseAPI", function()
	require("docusaurus").browse_api()
end, { desc = "Browse Docusaurus configuration API" })

-- External repo management commands
vim.api.nvim_create_user_command("DocusaurusImportRepo", function()
	require("docusaurus").import_repo()
end, { desc = "Import an external Docusaurus repository" })

vim.api.nvim_create_user_command("DocusaurusSelectRepo", function()
	require("docusaurus").select_repo()
end, { desc = "Select an external Docusaurus repository" })

vim.api.nvim_create_user_command("DocusaurusRemoveRepo", function()
	require("docusaurus").remove_repo()
end, { desc = "Remove an external Docusaurus repository" })

vim.api.nvim_create_user_command("DocusaurusCommitAndPush", function()
	require("docusaurus").commit_and_push()
end, { desc = "Commit and push changes to the active repo" })

vim.api.nvim_create_user_command("DocusaurusSyncRepo", function()
	require("docusaurus").sync_repo()
end, { desc = "Sync active repo with upstream" })

vim.api.nvim_create_user_command("DocusaurusShowPath", function()
	require("docusaurus").show_doc_path()
end, { desc = "Show active repo's doc path" })

vim.api.nvim_create_user_command("DocusaurusCreateSymlink", function()
	require("docusaurus").create_symlink()
end, { desc = "Create symlink to active repo in current directory" })
